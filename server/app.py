"""
Echo Vision 서버 (app_v2 스펙 호환 + rev.4 확장)

**2026-08-17 개정 (민선우 리뷰 반영)**: ESP32 실기기 연동 경로(POST /upload,
POST /video, POST /heartbeat form-encoding, 사진 서버 마스킹)를 추가했다.
자세한 배경은 각 엔드포인트 주석과 docs/mask-regions-contract.md 참고.

Flutter 앱(lib/services/sse_service.dart)이 기대하는 API:
  GET  /stream              - SSE. type: connected / new_event / loiter_confirmed / video_ready
  GET  /events?limit=N      - 최근 이벤트 이력 (최신순)
  GET  /photos/<filename>   - 마스킹 완료된 스냅샷 이미지
  POST /events/<id>/loiter  - 체류 확인 보고 (v2 전용, 앱은 v1처럼 404 나도 무시함)

ESP32가 실제로 호출하는 업로드 경로 (multipart/form-data):
  POST /upload  - 사진. 필드: sound_type, confidence(문자열, 예 "0.8734"), photo(파일).
                  서버가 크롭(322,197,552,414→230×217)·손상 프레임 검사·마스킹까지
                  전부 수행한다 — ESP32는 원본을 그대로 올리기만 한다.
                  불합격 사진(blank/truncated)은 photos_rejected/에만 저장되고
                  이벤트를 만들지 않는다(앱에 노출 안 됨).
  POST /video   - 영상(rev.4 섹션 4). 필드: sound_type, video(.avi 파일). ESP32는
                  event_id 개념이 없으므로 sound_type만 보내고, 서버가 "같은
                  sound_type이면서 video_pending인 이벤트 중 가장 오래된 것"에
                  매칭한다(민선우 리뷰 §3-1). 서버가 프레임별로 마스킹 후 저장하고,
                  원본은 처리 직후(성공·실패 무관) 즉시 삭제한다.
  GET  /videos/<filename> - 마스킹 처리 완료된 영상만 서빙 (원본은 서빙 라우트 자체가 없음)

이웃 프라이버시 마스킹 좌표 (앱이 지정·저장, 서버가 사진·영상 마스킹에 직접
사용 — ESP32는 이 좌표를 직접 다루지 않는다. 계약은 docs/mask-regions-contract.md):
  GET  /device/mask-regions         - 저장된 마스킹 영역 좌표 목록 (앱의 재설정 화면용)
  POST /device/mask-regions         - 마스킹 영역 좌표 저장 (앱의 설치 모드가 호출)
  GET  /device/mask-regions/status  - 설정 화면에 보여줄 요약 상태

기기 자가진단 (rev.4 섹션 5 — ESP32가 30분마다 form-urlencoded로 보고, 앱 홈
화면 상단 배지가 조회):
  POST /heartbeat                - ESP32가 보내는 생존 4필드 + 자가진단 6필드(총 10개) 수신
                                    (form-urlencoded — JSON 아님, 민선우 리뷰 §2-2)
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

import cv2
import numpy as np
from flask import Flask, Response, abort, jsonify, request, send_from_directory

BASE_DIR = Path(__file__).resolve().parent
PHOTOS_DIR = BASE_DIR / "photos"
PHOTOS_DIR.mkdir(exist_ok=True)

# 손상 프레임(blank/truncated) 검사에 불합격한 사진의 격리소. 여기 담긴 사진은
# 이벤트를 만들지 않으므로 앱에는 절대 노출되지 않는다(서빙 라우트도 없음) —
# 디버깅·임계값 튜닝용으로만 사람이 직접 열어본다.
PHOTOS_REJECTED_DIR = BASE_DIR / "photos_rejected"
PHOTOS_REJECTED_DIR.mkdir(exist_ok=True)

# ESP32가 올리는 원본(SVGA 800x600)에서 실제 방문자가 보이는 영역만 잘라내는
# 고정 크롭 박스. (left, top, right, bottom) px → 230x217. 실측 데이터로 정한
# 값이라 바꾸려면 실기기로 재보정이 필요하다(민선우 리뷰 §1 근거).
PHOTO_CROP_BOX = (322, 197, 552, 414)

# 손상 프레임 판정 임계값(민선우 리뷰 §6-2 — 기존 서버 기준: blank는 표준편차
# < 10, truncated는 하단 균일 행 비율 >= 25%).
# blank: 크롭된 흑백 이미지의 표준편차가 이보다 작으면 "그냥 단색 화면"으로 간주.
# truncated: 전송 중 끊긴 JPEG는 디코드 안 된 하단 영역이 단색으로 채워지는
# 경우가 많다 — 아래(맨 밑 행부터)에서 "균일한" 행의 비율이 이 이상이면
# 잘린 프레임으로 간주.
BLANK_STDDEV_THRESHOLD = 10.0
TRUNCATED_ROW_RATIO_THRESHOLD = 0.25
# "균일한 행"의 판정 폭. 완전히 단색(원본이 raw 패딩 등)이면 0이지만, 실제로는
# JPEG 재인코딩 과정의 DCT 양자화 잡음 때문에 완벽한 단색 영역도 디코드 후
# 행 안에서 값이 몇 픽셀 흔들린다(직접 검증: 순수 회색 영역을 JPEG로 왕복하면
# 행별 min/max 차이가 10~15까지 남는다) — 그래서 "행 전체가 정확히 같은 값"으로
# 검사하면 실제 잘린 프레임도 거의 걸리지 않는다. 정상 프레임(문 앞 풍경)의 행
# 범위는 200 안팎이므로, 20이면 압축 잡음은 통과시키고 진짜 잘린 프레임만 잡는다.
TRUNCATED_ROW_RANGE_TOLERANCE = 20

# 마스킹 처리 완료된 영상만 여기 저장되고, 이 디렉터리만 서빙된다(GET /videos/<name>).
VIDEOS_DIR = BASE_DIR / "videos"
VIDEOS_DIR.mkdir(exist_ok=True)
# 기기가 올린 마스킹 전 원본의 임시 보관소. 서빙 라우트가 아예 없고, 처리
# 완료·실패 여부와 무관하게 처리 직후 항상 삭제한다(docs/mask-regions-contract.md
# 참고 — 마스킹 전 원본은 앱/외부에 절대 노출되면 안 된다).
VIDEOS_RAW_TMP_DIR = BASE_DIR / "videos_raw_tmp"
VIDEOS_RAW_TMP_DIR.mkdir(exist_ok=True)

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

# 이웃 프라이버시 마스킹 영역. ESP32는 이 좌표를 직접 다루지 않는다 — 서버가
# /upload(사진), /video(영상) 처리 중에 직접 적용한다(민선우 리뷰 §3-2로 확정).
# 이벤트(_events)와 달리 카메라 화각이 거의 안 바뀌는 설치형 기기 특성상 자주
# 안 바뀌므로, 메모리 캐시 + 파일(mask_regions.json) 두 곳에 둔다 — 서버가
# 재시작돼도 그 사이 올라오는 사진·영상에 계속 같은 마스킹이 적용되도록.
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


def parse_confidence(raw: str | None) -> float:
    """ESP32가 보내는 confidence 문자열(예: "0.8734")을 실수로 변환한다.
    값이 없거나(구버전 호환) 형식이 깨져 있으면 1.0(확신)으로 간주한다 —
    민선우 리뷰 §4-1, 기존에도 이 규칙이었다."""
    if raw is None or raw == "":
        return 1.0
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return 1.0
    return max(0.0, min(1.0, value))


def _crop_photo(image: np.ndarray) -> np.ndarray:
    """ESP32가 올리는 SVGA(800x600) 원본에서 방문자가 보이는 영역만 잘라낸다
    (PHOTO_CROP_BOX 참고). 실제 프레임이 그보다 작아도 범위를 벗어나지
    않도록 클램프한다 — 테스트 이미지 등 예상 밖 해상도에도 안전하게."""
    left, top, right, bottom = PHOTO_CROP_BOX
    h, w = image.shape[:2]
    left = max(0, min(left, w))
    right = max(left, min(right, w))
    top = max(0, min(top, h))
    bottom = max(top, min(bottom, h))
    return image[top:bottom, left:right]


def _is_blank_frame(gray: np.ndarray) -> bool:
    """표준편차가 임계값보다 작으면 사실상 단색 화면(렌즈 가림, 완전 노출
    오류 등)으로 본다."""
    return bool(gray.size) and float(gray.std()) < BLANK_STDDEV_THRESHOLD


def _is_truncated_frame(gray: np.ndarray) -> bool:
    """맨 아래 행부터 위로 올라가며 "균일한"(min/max 차이가
    TRUNCATED_ROW_RANGE_TOLERANCE 이내인) 행이 몇 개나 연속되는지 센다 —
    전송 중 끊긴 JPEG은 디코드 안 된 나머지 영역이 그렇게 채워지는 경우가
    많다. 정확히 같은 값(==)으로 비교하지 않는다 — JPEG 압축 잡음 때문에
    완전한 단색 영역도 디코드 후엔 행 안에서 값이 몇 픽셀 흔들린다. 그
    비율이 임계값 이상이면 잘린 프레임으로 본다."""
    height = gray.shape[0]
    if height == 0:
        return False
    uniform_rows = 0
    for row in gray[::-1]:
        row_range = int(row.max()) - int(row.min())
        if row_range <= TRUNCATED_ROW_RANGE_TOLERANCE:
            uniform_rows += 1
        else:
            break
    return (uniform_rows / height) >= TRUNCATED_ROW_RATIO_THRESHOLD


def _mask_photo(cropped: np.ndarray, regions: list[dict]) -> np.ndarray:
    """이미 크롭된 사진(= 사용자가 설치 모드에서 실제로 보고 좌표를 찍는
    기준 프레임)에 regions를 검은 사각형으로 적용한다. 크롭이 이미 적용된
    프레임이 곧 좌표의 기준이므로 오프셋 변환이 필요 없다 — 영상은 다르다
    (아래 _regions_to_full_frame 참고, docs/mask-regions-contract.md "좌표계" 절)."""
    if not regions:
        return cropped
    height, width = cropped.shape[:2]
    result = cropped.copy()
    for r in regions:
        x1 = round(r["x"] * width)
        y1 = round(r["y"] * height)
        x2 = round((r["x"] + r["width"]) * width)
        y2 = round((r["y"] + r["height"]) * height)
        cv2.rectangle(result, (x1, y1), (x2, y2), (0, 0, 0), thickness=-1)
    return result


def _regions_to_full_frame(regions: list[dict], full_width: int, full_height: int) -> list[dict]:
    """마스킹 좌표는 사용자가 크롭된 사진(230x217, PHOTO_CROP_BOX)을 보고 찍은
    것이라 그 프레임 기준 정규화 좌표다. 영상은 ESP32가 크롭 없이 원본(SVGA
    800x600)을 그대로 올리므로, 크롭 오프셋을 반영해 원본 프레임 기준 좌표로
    바꿔야 사진과 같은 위치가 가려진다 — 안 하면 마스킹이 엉뚱한 곳에 찍힌다
    (docs/mask-regions-contract.md "좌표계" 절 참고)."""
    left, top, right, bottom = PHOTO_CROP_BOX
    crop_w, crop_h = right - left, bottom - top
    return [
        {
            "x": (left + r["x"] * crop_w) / full_width,
            "y": (top + r["y"] * crop_h) / full_height,
            "width": (r["width"] * crop_w) / full_width,
            "height": (r["height"] * crop_h) / full_height,
        }
        for r in regions
    ]


def _mask_video_frames(src_path: Path, dst_path: Path, regions: list[dict]) -> int:
    """src_path 영상의 모든 프레임에 regions(크롭 프레임 기준 정규화 0.0~1.0
    좌표 — 원본 프레임 좌표로 변환한 뒤)를 검은 사각형으로 적용해 dst_path에
    새 파일로 인코딩한다. regions가 비어 있으면 마스킹 없이 그대로(재인코딩만)
    저장한다 — mask-regions-contract.md의 "좌표 없으면 원본 그대로" 원칙을
    사진과 동일하게 따른다.

    프레임을 리스트에 모으지 않고 읽는 즉시 마스킹해 쓰고 버린다(스트리밍
    처리) — 75프레임을 한꺼번에 디코드해서 들고 있으면 SVGA RGB 기준 100MB
    이상 잡을 수 있다(민선우 리뷰 §7).

    반환값은 처리한 프레임 수(검증/로그용).
    """
    cap = cv2.VideoCapture(str(src_path))
    if not cap.isOpened():
        raise RuntimeError("영상을 열 수 없습니다 (지원하지 않는 포맷이거나 손상됨)")

    try:
        fps = cap.get(cv2.CAP_PROP_FPS) or 5.0
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        if width <= 0 or height <= 0:
            raise RuntimeError("영상 해상도를 읽을 수 없습니다")

        # 크롭 프레임 기준 좌표 → 이 영상(크롭 안 된 원본)의 실제 픽셀 좌표로 변환.
        full_frame_regions = _regions_to_full_frame(regions, width, height) if regions else []
        pixel_regions = [
            (
                round(r["x"] * width), round(r["y"] * height),
                round((r["x"] + r["width"]) * width), round((r["y"] + r["height"]) * height),
            )
            for r in full_frame_regions
        ]

        writer = cv2.VideoWriter(str(dst_path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))
        if not writer.isOpened():
            raise RuntimeError("출력 영상을 생성할 수 없습니다")

        try:
            frame_count = 0
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                for x1, y1, x2, y2 in pixel_regions:
                    cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 0, 0), thickness=-1)
                writer.write(frame)
                frame_count += 1
            if frame_count == 0:
                raise RuntimeError("읽은 프레임이 0개입니다 (빈 영상이거나 디코딩 실패)")
            return frame_count
        finally:
            writer.release()
    finally:
        cap.release()


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


@app.route("/upload", methods=["POST"])
def upload_photo():
    """ESP32가 이벤트마다 올리는 원본 사진 (민선우 리뷰 §2-1 — 이게 없으면
    사진·알림이 전부 끊긴다). multipart/form-data:
      sound_type   문자열 (예: KNOCK, DOORLOCK_ERROR, DOORLOCK_ALARM, EMERGENCY,
                            DOORBELL, UNKNOWN, NORMAL)
      confidence   실수 문자열 (예: "0.8734") — severity는 안 보낸다, 서버가
                   sound_type으로 매핑한다(등급 기준은 정책이라 서버가 관리)
      photo        파일 (filename="esp32.jpg", Content-Type: image/jpeg)

    처리 순서: 크롭 → 손상 프레임 검사(blank/truncated, 불합격 시
    photos_rejected/에만 저장하고 이벤트 없이 종료) → 마스킹 → 저장 → 이벤트
    생성·SSE 브로드캐스트. 크롭·마스킹 전 원본은 이 요청 처리 동안 메모리에만
    존재하고 디스크에 쓰이지 않는다(docs/mask-regions-contract.md 참고).
    """
    sound_type = str(request.form.get("sound_type", "")).upper()
    if sound_type not in VALID_SOUND_TYPES:
        return jsonify(
            {"error": f"invalid sound_type, expected one of {sorted(VALID_SOUND_TYPES)}"}
        ), 400

    confidence = parse_confidence(request.form.get("confidence"))

    if "photo" not in request.files:
        return jsonify({"error": "'photo' 파일 필드가 없습니다"}), 400
    file = request.files["photo"]
    raw_bytes = file.read()
    if not raw_bytes:
        return jsonify({"error": "빈 파일입니다"}), 400

    array = np.frombuffer(raw_bytes, dtype=np.uint8)
    image = cv2.imdecode(array, cv2.IMREAD_COLOR)
    if image is None:
        return jsonify({"error": "JPEG 디코딩 실패"}), 400

    cropped = _crop_photo(image)
    gray = cv2.cvtColor(cropped, cv2.COLOR_BGR2GRAY)

    now = datetime.now(KST)
    stamp = now.strftime("%Y%m%d_%H%M%S")
    suffix = uuid.uuid4().hex[:6]

    blank = _is_blank_frame(gray)
    truncated = (not blank) and _is_truncated_frame(gray)
    if blank or truncated:
        reason = "blank" if blank else "truncated"
        reject_name = f"{stamp}_{suffix}_{reason}.jpg"
        cv2.imwrite(str(PHOTOS_REJECTED_DIR / reject_name), cropped)
        print(f"[사진] 불합격({reason}) — {reject_name}", flush=True)
        return jsonify({"status": "rejected", "reason": reason}), 200

    with _mask_lock:
        regions = list(_mask_regions)
    masked = _mask_photo(cropped, regions)

    image_name = f"{stamp}_{suffix}.jpg"
    cv2.imwrite(str(PHOTOS_DIR / image_name), masked)

    if sound_type == "DOORLOCK_ERROR" and "severity" not in request.form:
        severity, video_pending = _doorlock_error_severity()
    else:
        severity = int(request.form.get("severity", DEFAULT_SEVERITY.get(sound_type, 1)))
        video_pending = bool(request.form.get("video_pending", severity >= 3))

    event = _make_event(sound_type, confidence, image_name, severity, video_pending)
    with _lock:
        _events.append(event)
    _broadcast(event)
    return jsonify(event), 201


@app.route("/videos/<path:filename>")
def videos(filename):
    """마스킹 처리 완료된 영상만 서빙한다. 처리 전 원본(videos_raw_tmp/)은
    이 라우트가 절대 다루지 않는다 — 그 디렉터리를 가리키는 라우트 자체가 없다."""
    if not (VIDEOS_DIR / filename).is_file():
        abort(404)
    return send_from_directory(VIDEOS_DIR, filename)


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
        # 앱 전용(설치 모드 재설정 화면이 기존 좌표를 불러와 편집할 때 호출).
        # ESP32는 이 엔드포인트를 호출하지 않는다 — 좌표는 서버가 들고 있다가
        # /upload, /video 처리 시 직접 적용한다.
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
        # 영상은 severity 3에서만 생성되므로(민선우 리뷰 §3-1), 명시적으로
        # 지정하지 않으면 severity 3일 때만 기본으로 video_pending을 켠다.
        video_pending = bool(body.get("video_pending", severity >= 3))

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


def _find_pending_video_event(sound_type: str) -> dict | None:
    """같은 sound_type이면서 아직 영상을 못 받은(video_pending) 이벤트 중 가장
    오래된 것을 찾는다 — ESP32는 event_id 개념이 없어 sound_type + 파일만
    보내므로, 서버가 이렇게 매칭한다(민선우 리뷰 §3-1).

    근거: 영상은 severity 3에서만 생성되므로 후보가 매우 적고, 기기는 SD
    큐 특성상 파일을 오래된 것부터 순서대로 올린다. _events는 오래된 것부터
    append되므로 리스트를 앞에서부터 스캔하면 가장 오래된 후보가 먼저 나온다.
    """
    with _lock:
        return next(
            (e for e in _events if e.get("sound_type") == sound_type and e.get("video_pending")),
            None,
        )


@app.route("/video", methods=["POST"])
def upload_video():
    """ESP32가 severity 3 이벤트 발생 후 최대 30분 내 비동기로 올리는 15초
    분량 MJPEG(.avi) 영상 (rev.4 섹션 4, 민선우 리뷰 §2-3/§3-1).

    multipart/form-data:
      sound_type   문자열 (DOORLOCK_ALARM 또는 DOORLOCK_ERROR)
      video        파일 (filename="rec_000042_DOORLOCK_ALARM.avi",
                          Content-Type: video/x-msvideo)

    event_id는 안 받는다 — ESP32가 그 개념을 모르기 때문에(딥슬립 사이 RTC
    보존 문제) 서버가 _find_pending_video_event()로 매칭한다. 매칭에 실패해도
    영상 자체는 저장하고 event_id만 null로 둔다 — 유실 없음.

    기기는 크롭·마스킹을 하지 않고 원본을 그대로 올린다(사진과 동일한 이유로
    디코더 부담을 서버로 옮긴 설계). 여기서 저장된 mask_regions 좌표를
    (크롭 프레임 기준 → 원본 프레임 기준으로 변환해) 모든 프레임에 적용해 새
    파일로 인코딩하고, 마스킹 전 원본은 처리 직후(성공·실패 무관) 항상
    삭제한다 — 원본이 잠깐이라도 앱/외부에 노출되는 경로가 없어야 한다는
    계약(docs/mask-regions-contract.md)을 영상에서도 지킨다.

    curl 테스트 예시:
      curl -X POST -F "sound_type=DOORLOCK_ALARM" -F "video=@clip.avi" http://localhost:5000/video
    """
    sound_type = str(request.form.get("sound_type", "")).upper()
    if sound_type not in VALID_SOUND_TYPES:
        return jsonify(
            {"error": f"invalid sound_type, expected one of {sorted(VALID_SOUND_TYPES)}"}
        ), 400

    if "video" not in request.files:
        return jsonify({"error": "'video' 파일 필드가 없습니다"}), 400
    file = request.files["video"]
    if not file.filename:
        return jsonify({"error": "파일명이 비어있습니다"}), 400

    target = _find_pending_video_event(sound_type)
    event_id = target.get("event_id") if target else None
    tag = event_id or uuid.uuid4().hex[:12]

    raw_path = VIDEOS_RAW_TMP_DIR / f"{tag}_{uuid.uuid4().hex[:8]}.raw"
    file.save(raw_path)

    out_name = f"{tag}.mp4"
    out_path = VIDEOS_DIR / out_name

    try:
        with _mask_lock:
            regions = list(_mask_regions)
        frame_count = _mask_video_frames(raw_path, out_path, regions)
    except Exception as e:
        out_path.unlink(missing_ok=True)  # 실패 시 부분적으로 쓰인 출력 파일 정리
        return jsonify({"error": f"영상 처리 실패: {e}"}), 500
    finally:
        raw_path.unlink(missing_ok=True)  # 마스킹 전 원본은 성공·실패와 무관하게 즉시 폐기

    if target is not None:
        with _lock:
            target["video"] = out_name
            target["video_pending"] = False
    else:
        print(
            f"[영상] 매칭되는 대기 이벤트 없음 (sound_type={sound_type}) "
            f"— event_id 없이 저장: {out_name}",
            flush=True,
        )

    print(
        f"[영상] {tag} 마스킹 완료 (프레임 {frame_count}개, 마스킹 영역 {len(regions)}개, "
        f"매칭={'성공' if target else '실패'})",
        flush=True,
    )

    payload = {"type": "video_ready", "event_id": event_id, "video": out_name}
    _broadcast(payload)
    return jsonify(payload), 200


# 0/1 정수 문자열로 오는 불리언 필드. wake_pin_idle은 서버 내부에서 문자열
# "HIGH"/"LOW"로 다룬다(Flutter 쪽 HeartbeatStatus 모델과 맞춤).
_HEARTBEAT_BOOL_FIELDS = {"sd_ok", "mic_ok", "cam_ok"}
_HEARTBEAT_FLOAT_FIELDS = {"mic_rms", "hours_since_sound"}


def _coerce_heartbeat_value(key: str, raw: str):
    if key in _HEARTBEAT_BOOL_FIELDS:
        return bool(int(raw))
    if key == "wake_pin_idle":
        return "HIGH" if int(raw) else "LOW"
    if key in _HEARTBEAT_FLOAT_FIELDS:
        return float(raw)
    return int(raw)  # wake_count, battery_mv, pending, cam_frame_size


@app.route("/heartbeat", methods=["POST"])
def heartbeat_ingest():
    """ESP32가 30분마다 보내는 자가진단 보고 (rev.4 섹션 5, 민선우 리뷰 §2-2).

    **form-urlencoded로 온다 — JSON이 아니다.** 예:
      wake_count=42&battery_mv=3820&sd_ok=1&pending=0&mic_ok=1&mic_rms=182.4&...
    이전엔 request.get_json(silent=True)로 받고 있었는데, 이건 JSON이 아닌
    본문에도 에러 없이 빈 딕셔너리를 반환해서 실기기를 붙이기 전에는 발견되지
    않는 방식으로 10개 필드가 전부 비어 있었다(민선우 리뷰에서 발견).

    생존 4필드(wake_count, battery_mv, sd_ok, pending) + 자가진단 6필드(mic_ok,
    mic_rms, cam_ok, cam_frame_size, wake_pin_idle, hours_since_sound), 총
    10개 중 보내온 필드만 최신 값으로 갱신한다. seconds_since_last는 여기서
    받는 값이 아니라 이 보고가 도착한 시각으로부터 GET 쪽에서 계산한다.

    cam_frame_size가 -1이면 "이번 주기엔 카메라 진단을 안 함"이라는 뜻이고,
    그때의 cam_ok는 기기가 이미 "마지막 판정 유지" 값을 넣어 보내주므로
    서버는 그냥 받은 값을 그대로 저장한다 — -1 자체를 이상으로 해석하는
    별도 로직을 넣지 않는다(민선우 리뷰 §4-3 주의사항)."""
    global _heartbeat_last_at
    body = request.form
    with _heartbeat_lock:
        for key in _heartbeat_status:
            if key not in body:
                continue
            try:
                _heartbeat_status[key] = _coerce_heartbeat_value(key, body[key])
            except (TypeError, ValueError):
                continue  # 형 변환 실패한 필드는 건드리지 않고 이전 값 유지
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
