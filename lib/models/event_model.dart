/// 이벤트 타입 열거형
/// 값은 Flask 서버(app.py / app_v2.py)의 sound_type과 1:1로 맞춘다.
/// (오디오 AI가 KNOCK/DOORBELL/IMPACT/EMERGENCY/NORMAL/UNKNOWN 중 하나로 분류해 보냄)
enum EventType {
  knock,
  doorbell,
  impact,
  emergency,
  normal,
  unknown;

  static EventType fromString(String value) {
    switch (value.toUpperCase()) {
      case 'KNOCK':
        return EventType.knock;
      case 'DOORBELL':
        return EventType.doorbell;
      case 'IMPACT':
        return EventType.impact;
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

  String get displayName {
    switch (this) {
      case EventType.knock:
        return '노크 감지';
      case EventType.doorbell:
        return '초인종';
      case EventType.impact:
        return '위협 감지';
      case EventType.emergency:
        return '화재 경보';
      case EventType.normal:
        return '정상';
      case EventType.unknown:
        return '알 수 없는 소리';
    }
  }

  String get emoji {
    switch (this) {
      case EventType.knock:
        return '🚪';
      case EventType.doorbell:
        return '🔔';
      case EventType.impact:
        return '⚠️';
      case EventType.emergency:
        return '🚨';
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
/// Flask 서버(app.py/app_v2.py)가 /upload, /events, /latest, SSE로 내려주는
/// 이벤트 JSON을 그대로 반영한다.
///
/// v1(app.py) 필드: time, sound_type, confidence, image, timestamp
/// v2(app_v2.py) 추가 필드: event_id, emergency, loiter_confirmed
/// → v1 응답에는 eventId/emergency/loiterConfirmed가 없으므로 전부 nullable/기본값 처리해서
///   두 버전 서버 모두에서 크래시 없이 동작하도록 한다.
class EventModel {
  /// v2에서만 내려옴. v1 서버 연결 시 null.
  final String? eventId;
  final EventType eventType;
  final double confidence;
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

  VisionResult? visionResult;

  /// 스냅샷 이미지 바이트 (다운로드 후 저장)
  List<int>? snapshotBytes;

  EventModel({
    this.eventId,
    required this.eventType,
    required this.confidence,
    required this.time,
    required this.timestamp,
    this.image,
    this.emergency = false,
    this.loiterConfirmed = false,
    this.visionResult,
    this.snapshotBytes,
  });

  factory EventModel.fromJson(Map<String, dynamic> json) {
    final type = EventType.fromString(json['sound_type'] ?? 'NORMAL');
    return EventModel(
      eventId: json['event_id'] as String?,
      eventType: type,
      // 서버(app.py/app_v2.py)가 confidence를 안 보내는 구버전과의 호환을 위해
      // 값이 없으면 1.0(확신)으로 간주 — parse_confidence()의 기본값과 동일한 규칙.
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
      time: json['time'] ?? '',
      timestamp: json['timestamp'] ?? '',
      image: json['image'] as String?,
      // v2는 emergency를 boolean으로 명시해서 줌. v1은 필드가 없으므로
      // sound_type이 EMERGENCY인지로 판단(Emergency Bypass 의미는 동일).
      emergency: (json['emergency'] as bool?) ?? (type == EventType.emergency),
      loiterConfirmed: (json['loiter_confirmed'] as bool?) ?? false,
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
    };
  }

  /// EMERGENCY 이벤트인지 확인 (Emergency Bypass: 채널 설정 무시하고 최고강도 알림)
  bool get isEmergency => emergency;

  /// 알림이 필요한 이벤트인지 확인 (NORMAL만 제외)
  bool get requiresAlert => eventType != EventType.normal;

  /// Vision AI 결과를 무시해야 하는지 (EMERGENCY는 무시)
  bool get bypassVision => emergency;
}
