"""
백그라운드 알림(Foreground Service) 검증용 테스트 이벤트 발사 스크립트.

이 레포에는 실제 ESP32/업로드 엔드포인트가 없어서, app.py의 로컬 테스트용
POST /trigger 엔드포인트를 대신 호출한다. 표준 라이브러리만 쓴다
(서버가 flask만 의존하므로 여기서 requests를 새로 추가하지 않기 위함).

사용 예:
    python3 test_upload.py --type IMPACT
    python3 test_upload.py --type EMERGENCY --url http://10.0.2.2:5000
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

VALID_SOUND_TYPES = ["KNOCK", "DOORBELL", "IMPACT", "EMERGENCY"]


def send_test_event(url: str, sound_type: str, confidence: float, image: str | None) -> None:
    payload = {"sound_type": sound_type, "confidence": confidence}
    if image:
        payload["image"] = image

    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{url.rstrip('/')}/trigger",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            body = response.read().decode("utf-8")
            print(f"[{response.status}] {body}")
    except urllib.error.URLError as e:
        print(f"요청 실패: {e}", file=sys.stderr)
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--type",
        choices=VALID_SOUND_TYPES,
        default="KNOCK",
        help="이벤트 타입 (기본값: KNOCK)",
    )
    parser.add_argument(
        "--url",
        default="http://127.0.0.1:5000",
        help="Flask 서버 주소 (기본값: http://127.0.0.1:5000)",
    )
    parser.add_argument(
        "--confidence",
        type=float,
        default=0.9,
        help="신뢰도 0~1 (기본값: 0.9)",
    )
    parser.add_argument(
        "--image",
        default=None,
        help="server/photos/ 안의 기존 이미지 파일명 (선택)",
    )
    args = parser.parse_args()

    send_test_event(args.url, args.type, args.confidence, args.image)


if __name__ == "__main__":
    main()
