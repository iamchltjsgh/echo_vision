"""
Echo Vision 로컬 테스트용 Flask 서버 (app_v2 스펙 호환)

Flutter 앱(lib/services/sse_service.dart)이 기대하는 API:
  GET  /stream              - SSE. type: connected / new_event / loiter_confirmed
  GET  /events?limit=N      - 최근 이벤트 이력 (최신순)
  GET  /photos/<filename>   - 스냅샷 이미지
  POST /events/<id>/loiter  - 체류 확인 보고 (v2 전용, 앱은 v1처럼 404 나도 무시함)

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
