import 'dart:typed_data';

/// 이벤트 타입 열거형
/// 값은 Flask 서버(app.py)의 sound_type과 1:1로 맞춘다.
///
/// rev.4: 기존 IMPACT 기반(카메라 충격 감지) 위협 판정은 폐기하고, 도어락이
/// 스스로 내는 경보음/오류음을 인식하는 DOORLOCK_ALARM/DOORLOCK_ERROR로 대체했다.
/// **색상·아이콘·진동/플래시 패턴은 더 이상 이 타입으로 직접 분기하지 않는다** —
/// 전부 EventModel.severity(0~3)로 분기한다(severity.dart 참고). 이 enum은 이제
/// "무슨 소리였는지"를 나타내는 라벨 용도로만 쓰인다.
enum EventType {
  knock,
  doorbell,
  doorlockAlarm,
  doorlockError,
  emergency,
  normal,
  unknown;

  static EventType fromString(String value) {
    switch (value.toUpperCase()) {
      case 'KNOCK':
        return EventType.knock;
      case 'DOORBELL':
        return EventType.doorbell;
      case 'DOORLOCK_ALARM':
        return EventType.doorlockAlarm;
      // 구버전 서버 호환 — IMPACT는 폐기된 판정이지만, 혹시 옛 서버가 여전히
      // 보내오면 개념적으로 가장 가까운 DOORLOCK_ALARM으로 취급한다.
      case 'IMPACT':
        return EventType.doorlockAlarm;
      case 'DOORLOCK_ERROR':
        return EventType.doorlockError;
      case 'EMERGENCY':
        return EventType.emergency;
      case 'NORMAL':
        return EventType.normal;
      default:
        // 서버가 미등록 라벨도 문자열 그대로 저장하므로(app.py 참고),
        // 여기서 걸리는 값은 UNKNOWN으로 처리해 알림 로직이 죽지 않게 한다.
        return EventType.unknown;
    }
  }

  /// 화면/알림에 쓰는 기본 설명 문구.
  /// "위협 감지"·"침입자 발견" 같은 단정적 표현은 피하고, 무슨 소리가 났는지를
  /// 있는 그대로 전달한다(rev.4 원칙 — 사용자가 스스로 판단할 수 있게).
  /// DOORLOCK_ERROR는 심각도에 따라 문구가 더 세분화된다 → EventModel.displayMessage 참고.
  String get displayName {
    switch (this) {
      case EventType.knock:
      case EventType.doorbell:
        return '방문자가 있습니다';
      case EventType.doorlockAlarm:
        return '도어락이 침입을 감지했습니다';
      case EventType.doorlockError:
        return '도어락 오류가 감지되었습니다';
      case EventType.emergency:
        return '화재경보가 울리고 있습니다';
      case EventType.normal:
        return '정상';
      case EventType.unknown:
        return '알 수 없는 소리가 감지되었습니다';
    }
  }

  String get emoji {
    switch (this) {
      case EventType.knock:
        return '🚪';
      case EventType.doorbell:
        return '🔔';
      case EventType.doorlockAlarm:
        return '🚨';
      case EventType.doorlockError:
        return '🔒';
      case EventType.emergency:
        return '🔥';
      case EventType.normal:
        return '✅';
      case EventType.unknown:
        return '❓';
    }
  }
}

/// Vision AI 분류 결과 (앱 내부 TFLite 판정, 서버와 무관)
enum VisionResult {
  person,
  package,
  empty;

  String get displayName {
    switch (this) {
      case VisionResult.person:
        return '방문자 있음';
      case VisionResult.package:
        return '택배 도착';
      case VisionResult.empty:
        return '빈 화면';
    }
  }
}

/// 이벤트 모델
/// Flask 서버(app.py)가 /events, SSE로 내려주는 이벤트 JSON을 그대로 반영한다.
///
/// v1 필드: time, sound_type, confidence, image, timestamp
/// v2 추가 필드: event_id, emergency, loiter_confirmed
/// rev.4 추가 필드: severity, video, video_pending
/// → 구버전 서버 응답에는 이 필드들이 없으므로 전부 nullable/기본값 처리해서
///   크래시 없이 동작하도록 한다.
class EventModel {
  /// v2에서만 내려옴. v1 서버 연결 시 null.
  final String? eventId;
  final EventType eventType;

  /// 탐지 신뢰도(0.0~1.0). 서버가 값을 안 보내는 구버전 호환을 위해 nullable —
  /// null이면 "신뢰도를 알 수 없음"이므로 화면에 이 항목 자체를 표시하지 않는다
  /// (예전처럼 1.0으로 대체해서 가짜 확신을 보여주지 않는다).
  final double? confidence;
  final String time;
  final String timestamp;

  /// 서버가 주는 건 파일명뿐이라(예: "20260713_113700_a1b2c3.jpg"),
  /// 실제 다운로드 경로는 SSEService에서 "/photos/$image"로 조합한다.
  final String? image;

  /// v2 emergency 플래그. v1은 필드 자체가 없으므로 sound_type=='EMERGENCY'로 대체 판단.
  final bool emergency;

  /// v2 체류 확인 여부. v1은 항상 false(개념 자체가 없음).
  /// loiterStream으로 갱신되므로 final이 아님(HomeScreen에서 직접 true로 바꿔줌).
  bool loiterConfirmed;

  /// 심각도 0~3. 색상·아이콘·진동/플래시 패턴·시스템 알림 채널을 전부 이 값으로
  /// 결정한다(severity.dart, alert_presets.dart 참고). 서버가 안 보내면(구버전)
  /// 1(방문 수준)로 안전하게 기본 처리.
  int severity;

  /// 영상 파일명. 아직 도착 전이면 null(=videoPending 참고).
  String? video;

  /// true면 "영상 준비 중" — 스냅샷보다 최대 30분가량 늦게 도착하는 영상을
  /// 기다리는 중이라는 뜻. video_ready SSE로 video가 채워지면 false로 바뀐다.
  bool videoPending;

  VisionResult? visionResult;

  /// 스냅샷 이미지 바이트 (다운로드 후 저장)
  Uint8List? snapshotBytes;

  EventModel({
    this.eventId,
    required this.eventType,
    this.confidence,
    required this.time,
    required this.timestamp,
    this.image,
    this.emergency = false,
    this.loiterConfirmed = false,
    this.severity = 1,
    this.video,
    this.videoPending = false,
    this.visionResult,
    this.snapshotBytes,
  });

  factory EventModel.fromJson(Map<String, dynamic> json) {
    final type = EventType.fromString(json['sound_type'] ?? 'NORMAL');
    return EventModel(
      eventId: json['event_id'] as String?,
      eventType: type,
      confidence: (json['confidence'] as num?)?.toDouble(),
      time: json['time'] ?? '',
      timestamp: json['timestamp'] ?? '',
      image: json['image'] as String?,
      // v2는 emergency를 boolean으로 명시해서 줌. v1은 필드가 없으므로
      // sound_type이 EMERGENCY인지로 판단(Emergency Bypass 의미는 동일).
      emergency: (json['emergency'] as bool?) ?? (type == EventType.emergency),
      loiterConfirmed: (json['loiter_confirmed'] as bool?) ?? false,
      // 과거에 저장된 이력(이 필드들이 아예 없던 시절 데이터)을 역직렬화할 때도
      // 안전하게 기본값으로 떨어지도록 — 하위 호환.
      severity: (json['severity'] as num?)?.toInt() ?? 1,
      video: json['video'] as String?,
      videoPending: (json['video_pending'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'event_id': eventId,
      'sound_type': eventType.name.toUpperCase(),
      'confidence': confidence,
      'time': time,
      'timestamp': timestamp,
      'image': image,
      'emergency': emergency,
      'loiter_confirmed': loiterConfirmed,
      'severity': severity,
      'video': video,
      'video_pending': videoPending,
    };
  }

  /// EMERGENCY 이벤트인지 확인 (Emergency Bypass: 채널 설정 무시하고 최고강도 알림)
  bool get isEmergency => emergency;

  /// 알림이 필요한 이벤트인지 확인 (NORMAL만 제외)
  bool get requiresAlert => eventType != EventType.normal;

  /// Vision AI 결과를 무시해야 하는지 (EMERGENCY는 무시)
  bool get bypassVision => emergency;

  /// 화면에 표시할 설명 문구. DOORLOCK_ERROR는 반복될수록(=severity가 높을수록)
  /// 더 구체적인 문구로 바뀐다 — 나머지 타입은 EventType.displayName 그대로.
  /// (rev.4 섹션 9 — 시스템 알림/팝업 제목/이력 리스트 텍스트가 전부 이걸 쓴다)
  String get displayMessage {
    if (eventType == EventType.doorlockError) {
      switch (severity) {
        case 3:
          return '침입 시도가 의심됩니다';
        case 2:
          return '비밀번호 오류가 반복됩니다';
        default:
          return '도어락 조작이 감지되었습니다';
      }
    }
    return eventType.displayName;
  }
}
