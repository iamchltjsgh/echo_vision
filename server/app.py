"""
Echo Vision 로컬 테스트용 Flask 서버 (app_v2 스펙 호환)

Flutter 앱(lib/services/sse_service.dart)이 기대하는 API:
  GET  /stream              - SSE. type: connected / new_event / loiter_confirmed / video_ready
  GET  /events?limit=N      - 최근 이벤트 이력 (최신순)
  GET  /photos/<filename>   - 스냅샷 이미지
  POST /events/<id>/loiter  - 체류 확인 보고 (v2 전용, 앱은 v1처럼 404 나도 무시함)

이웃 프라이버시 마스킹 (앱의 설치 모드 화면이 좌표를 지정·저장, ESP32가 촬영 시점에
적용 — 계약은 docs/mask-regions-contract.md 참고):
  GET  /device/mask-regions         - 저장된 마스킹 영역 좌표 목록 (ESP32가 폴링)
  POST /device/mask-regions         - 마스킹 영역 좌표 저장 (앱의 설치 모드가 호출)
  GET  /device/mask-regions/status  - 설정 화면에 보여줄 요약 상태

기기 자가진단 (rev.4 섹션 5 — ESP32가 주기 보고, 앱 홈 화면 상단 배지가 조회):
  POST /heartbeat                - ESP32가 보내는 생존 4필드 + 자가진단 6필드(총 10개) 수신
  GET  /device/heartbeat-status  - 위 값 + 서버가 계산한 seconds_since_last (앱용 요약)

로컬 테스트 전용 (Flask 앱이 아니라 이 서버 자체를 손으로 찔러보기 위한 것):
  POST /trigger               - 실제 오디오 AI 없이 가짜 이벤트 하나를 SSE로 브로드캐스트
                                 (severity, video_pending도 함께 지정 가능. DOORLOCK_ERROR는
                                 severity를 안 주면 180초 반복 카운터로 자동 산정됨 — rev.4 섹션 3)
  POST /trigger/video-ready   - 가짜 video_ready 이벤트를 SSE로 브로드캐스트
  POST /device/heartbeat-status - 자가진단 값을 임의로 덮어써서 이상 상태를 재현
  GET  /                      - 브라우저에서 위 트리거들을 눌러볼 수 있는 테스트 페이지
"""

from __future__ import annotations

import json
import queue
import threading
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from flask import Flask, Response, abort, jsonify, request, send_from_directory

BASE_DIR = Path(__file__).resolve().parent
PHOTOS_DIR = BASE_DIR / "photos"
PHOTOS_DIR.mkdir(exist_ok=True)

app = Flask(__name__)

KST = timezone(timedelta(hours=9))
# rev.4: 기존 IMPACT(카메라 충격 감지) 판정은 폐기하고 도어락이 스스로 내는
# 경보음/오류음(DOORLOCK_ALARM/DOORLOCK_ERROR)으로 대체했다.
VALID_SOUND_TYPES = {
    "KNOCK",
    "DOORBELL",
    "DOORLOCK_ALARM",
    "DOORLOCK_ERROR",
    "EMERGENCY",
    "IMPACT",    # 폐기된 판정이지만 구버전 호환을 위해 유지 (앱은 doorlockAlarm으로 취급)
    "NORMAL",
    "UNKNOWN",
}
# sound_type별 기본 severity(0~3). /trigger 호출 시 severity를 안 주면 이 값을 쓴다 —
# 실제로는 오디오 AI가 각 이벤트마다 계산해서 보내는 값이라 여기 건 로컬 테스트용 근사치.
# DOORLOCK_ERROR는 예외: 180초 반복 카운터가 있으면 이 기본값 대신 그쪽을 따른다
# (아래 _doorlock_error_severity 참고, rev.4 섹션 3).
DEFAULT_SEVERITY = {
    "KNOCK": 1,
    "DOORBELL": 1,
    "DOORLOCK_ERROR": 2,
    "DOORLOCK_ALARM": 3,
    "EMERGENCY": 3,
    "IMPACT": 1,
    "NORMAL": 0,
    "UNKNOWN": 1,
}

# rev.4 섹션 3: DOORLOCK_ERROR가 180초 안에 반복되면 severity가 1→2→3으로 오른다.
# 거주자가 비밀번호를 한두 번 틀리는 건 흔하지만, 세 번째부터는 실제 침입
# 시도일 가능성이 높다고 보기 때문(문서 "3회 기준" 근거 참고). 3회째부터는
# video_pending도 함께 True로 만들어 영상 확보 대상에 올린다.
DOORLOCK_ERROR_WINDOW_SEC = 180

_doorlock_error_lock = threading.Lock()
_doorlock_error_events: list[datetime] = []  # 최근 DOORLOCK_ERROR 발생 시각(슬라이딩 윈도우)


def _doorlock_error_severity() -> tuple[int, bool]:
    """DOORLOCK_ERROR 발생을 기록하고, 180초 윈도우 내 반복 횟수 기준 (severity, video_pending)을 반환한다."""
    now = datetime.now(KST)
    with _doorlock_error_lock:
        cutoff = now - timedelta(seconds=DOORLOCK_ERROR_WINDOW_SEC)
        _doorlock_error_events[:] = [t for t in _doorlock_error_events if t > cutoff]
        _doorlock_error_events.append(now)
        count = len(_doorlock_error_events)
    severity = min(count, 3)
    return severity, count >= 3


_lock = threading.Lock()
_events: list[dict] = []  # 오래된 것부터 append됨
_subscribers: "set[queue.Queue]" = set()

# 기기(ESP32) 자가진단 상태 (rev.4 섹션 5). 생존 4필드 + 자가진단 6필드, 총
# 10개를 POST /heartbeat로 받아 최신 값만 저장한다. seconds_since_last는 저장하지
# 않고 _heartbeat_last_at으로부터 조회 시점마다 계산한다 — 그래야 서버가 오래
# 떠 있어도(또는 기기가 응답을 멈춰도) 값이 실제 경과 시간과 어긋나지 않는다.
# 실기기가 없는 이 저장소에서는 건강한 기본값을 깔아두고, POST
# /device/heartbeat-status로 테스트 시 임의 항목만 덮어쓸 수 있게 지원한다.
_heartbeat_lock = threading.Lock()
_heartbeat_status: dict = {
    # 생존 4필드
    "wake_count": 0,
    "battery_mv": 3900,
    "sd_ok": True,
    "pending": 0,
    # 자가진단 6필드
    "mic_ok": True,
    "mic_rms": 120,
    "cam_ok": True,
    "cam_frame_size": 24500,
    "wake_pin_idle": "HIGH",
    "hours_since_sound": 0.1,
}
_heartbeat_last_at: datetime = datetime.now(KST)

# 이웃 프라이버시 마스킹 영역. 이벤트(_events)와 달리 카메라 화각이 거의 안 바뀌는
# 설치형 기기 특성상 자주 안 바뀌므로, 메모리 캐시 + 파일(mask_regions.json)
# 두 곳에 둔다 — 서버 재시작 후에도 유지되어야 ESP32가 부팅 시 바로 받아갈 수 있다.
MASK_REGIONS_FILE = BASE_DIR / "mask_regions.json"
MAX_MASK_REGIONS = 4

_mask_lock = threading.Lock()
_mask_regions: list[dict] = []
_mask_regions_updated_at: str | None = None


def _load_mask_regions() -> None:
    global _mask_regions, _mask_regions_updated_at
    if not MASK_REGIONS_FILE.is_file():
        return
    try:
        data = json.loads(MASK_REGIONS_FILE.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return
    with _mask_lock:
        _mask_regions = data.get("regions", [])
        _mask_regions_updated_at = data.get("updated_at")


def _save_mask_regions(regions: list[dict]) -> str:
    """regions를 파일에 쓰고, 이번에 기록한 updated_at을 반환한다."""
    updated_at = datetime.now(KST).isoformat()
    payload = {"regions": regions, "updated_at": updated_at}
    MASK_REGIONS_FILE.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return updated_at


def _is_valid_mask_region(region: object) -> bool:
    """정규화(0.0~1.0) 좌표인지, 영역이 이미지 범위를 벗어나지 않는지 검증한다."""
    if not isinstance(region, dict):
        return False
    try:
        x = float(region["x"])
        y = float(region["y"])
        width = float(region["width"])
        height = float(region["height"])
    except (KeyError, TypeError, ValueError):
        return False
    if not (0.0 <= x <= 1.0 and 0.0 <= y <= 1.0):
        return False
    if not (0.0 < width <= 1.0 and 0.0 < height <= 1.0):
        return False
    # 부동소수 오차 감안한 약간의 여유(1e-6)를 둔다.
    if x + width > 1.0 + 1e-6 or y + height > 1.0 + 1e-6:
        return False
    return True


_load_mask_regions()  # 서버 시작 시 이전 저장값 복원


def _broadcast(payload: dict) -> None:
    data = f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
    with _lock:
        subs = list(_subscribers)
    for q in subs:
        q.put(data)


def _make_event(
    sound_type: str,
    confidence: float,
    image: str | None,
    severity: int,
    video_pending: bool,
) -> dict:
    now = datetime.now(KST)
    return {
        "type": "new_event",
        "event_id": uuid.uuid4().hex[:12],
        "sound_type": sound_type,
        "confidence": confidence,
        "time": now.strftime("%H:%M"),
        "timestamp": now.isoformat(),
        "image": image,
        "emergency": sound_type == "EMERGENCY",
        "loiter_confirmed": False,
        "severity": severity,
        "video": None,
        "video_pending": video_pending,
    }


@app.route("/stream")
def stream():
    def gen():
        q: queue.Queue = queue.Queue()
        with _lock:
            _subscribers.add(q)
            count = len(_subscribers)
        print(f"[SSE] 클라이언트 연결 (현재 {count}개)", flush=True)
        try:
            yield f"data: {json.dumps({'type': 'connected'})}\n\n"
            while True:
                try:
                    yield q.get(timeout=15)
                except queue.Empty:
                    yield ": keepalive\n\n"
        finally:
            with _lock:
                _subscribers.discard(q)
                count = len(_subscribers)
            print(f"[SSE] 클라이언트 해제 (현재 {count}개)", flush=True)

    return Response(
        gen(),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


@app.route("/events")
def list_events():
    limit = request.args.get("limit", default=10, type=int)
    with _lock:
        history = list(reversed(_events[-limit:]))
    return jsonify(history)


@app.route("/photos/<path:filename>")
def photos(filename):
    if not (PHOTOS_DIR / filename).is_file():
        abort(404)
    return send_from_directory(PHOTOS_DIR, filename)


@app.route("/events/<event_id>/loiter", methods=["POST"])
def loiter(event_id):
    with _lock:
        target = next((e for e in _events if e.get("event_id") == event_id), None)
        if target is None:
            return jsonify({"error": "not found"}), 404
        target["loiter_confirmed"] = True
        payload = {**target, "type": "loiter_confirmed"}
    _broadcast(payload)
    return jsonify({"ok": True})


@app.route("/device/mask-regions", methods=["GET", "POST"])
def mask_regions():
    global _mask_regions, _mask_regions_updated_at

    if request.method == "GET":
        # ESP32가 부팅 시/주기적으로 폴링해서 최신 마스킹 좌표를 받아가는 용도.
        with _mask_lock:
            return jsonify({"regions": _mask_regions})

    body = request.get_json(silent=True) or {}
    regions = body.get("regions")
    if not isinstance(regions, list):
        return jsonify({"error": "regions must be a list"}), 400
    if len(regions) > MAX_MASK_REGIONS:
        return jsonify({"error": f"최대 {MAX_MASK_REGIONS}개까지 설정할 수 있습니다"}), 400
    if not all(_is_valid_mask_region(r) for r in regions):
        return jsonify(
            {"error": "각 영역은 0.0~1.0 범위의 x, y, width, height를 가져야 합니다"}
        ), 400

    normalized = [
        {"x": r["x"], "y": r["y"], "width": r["width"], "height": r["height"]}
        for r in regions
    ]
    with _mask_lock:
        _mask_regions = normalized
        _mask_regions_updated_at = _save_mask_regions(normalized)
        result = {"regions": _mask_regions, "updated_at": _mask_regions_updated_at}
    return jsonify(result), 200


@app.route("/device/mask-regions/status")
def mask_regions_status():
    with _mask_lock:
        return jsonify(
            {
                "configured": len(_mask_regions) > 0,
                "region_count": len(_mask_regions),
                "updated_at": _mask_regions_updated_at,
            }
        )


@app.route("/trigger", methods=["POST"])
def trigger():
    """로컬 테스트용: 실제 오디오 AI 없이 이벤트를 강제로 하나 발생시킨다."""
    body = request.get_json(silent=True) or {}
    sound_type = str(body.get("sound_type", "KNOCK")).upper()
    if sound_type not in VALID_SOUND_TYPES:
        return jsonify(
            {"error": f"invalid sound_type, expected one of {sorted(VALID_SOUND_TYPES)}"}
        ), 400

    confidence = float(body.get("confidence", 0.9))
    image = body.get("image")

    if sound_type == "DOORLOCK_ERROR" and "severity" not in body:
        # 실제 흐름(펌웨어는 severity를 보내지 않음)을 재현: 180초 반복
        # 카운터로 severity를 자동 산정한다. severity를 명시하면 이 로직을
        # 건너뛰고 지정값을 그대로 쓴다(특정 등급을 바로 테스트하고 싶을 때).
        auto_severity, auto_video_pending = _doorlock_error_severity()
        severity = auto_severity
        video_pending = bool(body.get("video_pending", auto_video_pending))
    else:
        severity = int(body.get("severity", DEFAULT_SEVERITY.get(sound_type, 1)))
        video_pending = bool(body.get("video_pending", False))

    if not 0 <= severity <= 3:
        return jsonify({"error": "severity must be 0~3"}), 400

    event = _make_event(sound_type, confidence, image, severity, video_pending)
    with _lock:
        _events.append(event)
    _broadcast(event)
    return jsonify(event), 201


@app.route("/trigger/video-ready", methods=["POST"])
def trigger_video_ready():
    """로컬 테스트용: /trigger로 만든 이벤트에 영상이 뒤늦게 도착한 상황을 재현한다."""
    body = request.get_json(silent=True) or {}
    event_id = body.get("event_id")
    video = body.get("video", "sample.mp4")
    if not event_id:
        return jsonify({"error": "event_id is required"}), 400

    with _lock:
        target = next((e for e in _events if e.get("event_id") == event_id), None)
        if target is None:
            return jsonify({"error": "not found"}), 404
        target["video"] = video
        target["video_pending"] = False

    payload = {"type": "video_ready", "event_id": event_id, "video": video}
    _broadcast(payload)
    return jsonify(payload), 200


@app.route("/heartbeat", methods=["POST"])
def heartbeat_ingest():
    """ESP32가 주기적으로 보내는 자가진단 보고 (rev.4 섹션 5).
    생존 4필드(wake_count, battery_mv, sd_ok, pending) + 자가진단 6필드(mic_ok,
    mic_rms, cam_ok, cam_frame_size, wake_pin_idle, hours_since_sound), 총
    10개 중 보내온 필드만 최신 값으로 갱신한다. seconds_since_last는 여기서
    받는 값이 아니라 이 보고가 도착한 시각으로부터 GET 쪽에서 계산한다."""
    global _heartbeat_last_at
    body = request.get_json(silent=True) or {}
    with _heartbeat_lock:
        for key in _heartbeat_status:
            if key in body:
                _heartbeat_status[key] = body[key]
        _heartbeat_last_at = datetime.now(KST)
        result = dict(_heartbeat_status)
    return jsonify(result), 200


@app.route("/device/heartbeat-status", methods=["GET", "POST"])
def heartbeat_status():
    """기기 자가진단 상태 (앱용 요약). GET은 앱이 주기적으로 조회하고, POST는
    로컬 테스트용으로 특정 항목만 골라 이상 상태를 재현할 때 쓴다
    (예: {"mic_ok": false}). 실제 기기 보고는 POST /heartbeat로 들어온다."""
    global _heartbeat_last_at

    if request.method == "GET":
        with _heartbeat_lock:
            seconds_since_last = int((datetime.now(KST) - _heartbeat_last_at).total_seconds())
            result = {
                **_heartbeat_status,
                "seconds_since_last": seconds_since_last,
                "last_heartbeat_at": _heartbeat_last_at.isoformat(),
            }
        return jsonify(result)

    body = request.get_json(silent=True) or {}
    with _heartbeat_lock:
        for key in _heartbeat_status:
            if key in body:
                _heartbeat_status[key] = body[key]
        # 테스트 페이지가 "620초 전"처럼 경과 시간을 직접 지정하고 싶을 때를
        # 위한 예외 — 그 외에는 이 POST 자체를 "방금 보고 도착"으로 취급한다.
        if "seconds_since_last" in body:
            _heartbeat_last_at = datetime.now(KST) - timedelta(seconds=float(body["seconds_since_last"]))
        else:
            _heartbeat_last_at = datetime.now(KST)
        seconds_since_last = int((datetime.now(KST) - _heartbeat_last_at).total_seconds())
        result = {
            **_heartbeat_status,
            "seconds_since_last": seconds_since_last,
            "last_heartbeat_at": _heartbeat_last_at.isoformat(),
        }
    return jsonify(result), 200


@app.route("/")
def index():
    return """
    <html><body style="font-family: -apple-system, sans-serif; padding: 24px;">
      <h2>Echo Vision 로컬 테스트 서버</h2>
      <p>앱 설정 &rarr; 서버 URL에 입력할 값:</p>
      <ul>
        <li>Android 에뮬레이터: <code>http://10.0.2.2:5000</code></li>
        <li>실기기(같은 Wi-Fi): <code>http://이 PC의 LAN IP:5000</code></li>
      </ul>
      <p>버튼을 누르면 실제 오디오 AI 없이 가짜 이벤트를 SSE로 쏩니다:</p>
      <button onclick="fire('KNOCK')">노크</button>
      <button onclick="fire('DOORBELL')">초인종</button>
      <button onclick="fire('DOORLOCK_ERROR')">도어락 오류</button>
      <button onclick="fire('DOORLOCK_ALARM')">도어락 경보</button>
      <button onclick="fire('EMERGENCY')">화재</button>
      <button onclick="fire('KNOCK', {video_pending: true})">노크(영상 대기)</button>
      <hr>
      <p>기기 자가진단 이상 재현:</p>
      <button onclick="heartbeat({mic_ok: false})">마이크 이상</button>
      <button onclick="heartbeat({cam_ok: false})">카메라 이상</button>
      <button onclick="heartbeat({wake_pin_idle: 'LOW'})">웨이크핀 이상</button>
      <button onclick="heartbeat({hours_since_sound: 30})">24시간 무음</button>
      <button onclick="heartbeat({mic_ok: true, cam_ok: true, wake_pin_idle: 'HIGH', hours_since_sound: 0.1, seconds_since_last: 5})">모두 정상으로 복구</button>
      <pre id="log"></pre>
      <script>
        async function fire(type, extra) {
          const res = await fetch('/trigger', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(Object.assign({sound_type: type}, extra || {}))
          });
          document.getElementById('log').textContent = await res.text();
        }
        async function heartbeat(fields) {
          const res = await fetch('/device/heartbeat-status', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(fields)
          });
          document.getElementById('log').textContent = await res.text();
        }
      </script>
    </body></html>
    """


if __name__ == "__main__":
    # 0.0.0.0으로 열어야 같은 와이파이의 실기기/에뮬레이터에서 접속 가능
    app.run(host="0.0.0.0", port=5000, debug=True, threaded=True)
