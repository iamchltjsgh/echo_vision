"""
Echo Vision 로컬 테스트용 Flask 서버 (app_v2 스펙 호환)

Flutter 앱(lib/services/sse_service.dart)이 기대하는 API:
  GET  /stream              - SSE. type: connected / new_event / loiter_confirmed
  GET  /events?limit=N      - 최근 이벤트 이력 (최신순)
  GET  /photos/<filename>   - 스냅샷 이미지
  POST /events/<id>/loiter  - 체류 확인 보고 (v2 전용, 앱은 v1처럼 404 나도 무시함)

이웃 프라이버시 마스킹 (앱의 설치 모드 화면이 좌표를 지정·저장, ESP32가 촬영 시점에
적용 — 계약은 docs/mask-regions-contract.md 참고):
  GET  /device/mask-regions         - 저장된 마스킹 영역 좌표 목록 (ESP32가 폴링)
  POST /device/mask-regions         - 마스킹 영역 좌표 저장 (앱의 설치 모드가 호출)
  GET  /device/mask-regions/status  - 설정 화면에 보여줄 요약 상태

로컬 테스트 전용 (Flask 앱이 아니라 이 서버 자체를 손으로 찔러보기 위한 것):
  POST /trigger             - 실제 오디오 AI 없이 가짜 이벤트 하나를 SSE로 브로드캐스트
  GET  /                    - 브라우저에서 /trigger 눌러볼 수 있는 테스트 페이지
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
VALID_SOUND_TYPES = {"KNOCK", "DOORBELL", "IMPACT", "EMERGENCY", "NORMAL"}

_lock = threading.Lock()
_events: list[dict] = []  # 오래된 것부터 append됨
_subscribers: "set[queue.Queue]" = set()

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


def _make_event(sound_type: str, confidence: float, image: str | None) -> dict:
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

    event = _make_event(sound_type, confidence, image)
    with _lock:
        _events.append(event)
    _broadcast(event)
    return jsonify(event), 201


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
      <button onclick="fire('IMPACT')">위협</button>
      <button onclick="fire('EMERGENCY')">화재</button>
      <pre id="log"></pre>
      <script>
        async function fire(type) {
          const res = await fetch('/trigger', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({sound_type: type})
          });
          document.getElementById('log').textContent = await res.text();
        }
      </script>
    </body></html>
    """


if __name__ == "__main__":
    # 0.0.0.0으로 열어야 같은 와이파이의 실기기/에뮬레이터에서 접속 가능
    app.run(host="0.0.0.0", port=5000, debug=True, threaded=True)
