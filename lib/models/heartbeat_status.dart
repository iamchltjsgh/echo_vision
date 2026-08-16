/// 기기(ESP32) 자가진단 상태 — GET /device/heartbeat-status 응답.
/// "정상/이상" 이분법이 아니라 "어느 부분이 이상한지"를 구분해서 알려주기
/// 위한 원본 값들이다. 판정 로직은 evaluateHeartbeat() 참고.
class HeartbeatStatus {
  /// 기기가 마지막으로 응답한 지 몇 초 지났는지.
  final int secondsSinceLast;

  final bool micOk;

  /// 웨이크핀 유휴 상태. "LOW"면 하드웨어 이상(오작동 가능) — 정상은 "HIGH".
  final String wakePinIdle;

  final bool camOk;

  /// 마지막으로 소리를 감지한 지 몇 시간 지났는지.
  final double hoursSinceSound;

  const HeartbeatStatus({
    required this.secondsSinceLast,
    required this.micOk,
    required this.wakePinIdle,
    required this.camOk,
    required this.hoursSinceSound,
  });

  factory HeartbeatStatus.fromJson(Map<String, dynamic> json) {
    return HeartbeatStatus(
      secondsSinceLast: (json['seconds_since_last'] as num?)?.toInt() ?? 0,
      micOk: json['mic_ok'] as bool? ?? true,
      wakePinIdle: json['wake_pin_idle'] as String? ?? 'HIGH',
      camOk: json['cam_ok'] as bool? ?? true,
      hoursSinceSound: (json['hours_since_sound'] as num?)?.toDouble() ?? 0,
    );
  }
}

enum DeviceHealthLevel { normal, warning, critical }

class DeviceHealthEvaluation {
  final DeviceHealthLevel level;

  /// 우선순위 순(가장 심각한 것부터)으로 정렬된, 사람이 읽을 수 있는 이상 항목 문구.
  final List<String> issues;

  const DeviceHealthEvaluation({required this.level, required this.issues});

  bool get isNormal => level == DeviceHealthLevel.normal;
}

/// rev.4 섹션 5 — 우선순위표(위쪽일수록 심각)를 그대로 코드로 옮긴 것.
/// [awayModeSuppresses24hWarning]이 true면(설정 화면의 "외출 중" 토글) 24시간
/// 무음 경고만 숨긴다 — 그 외 항목(마이크/웨이크핀/카메라/무응답)은 외출 여부와
/// 무관하게 그대로 뜬다(하드웨어 고장은 사람이 집을 비운 것과 상관없으므로).
DeviceHealthEvaluation evaluateHeartbeat(
  HeartbeatStatus status, {
  bool awayModeSuppresses24hWarning = false,
}) {
  final issues = <String>[];
  var level = DeviceHealthLevel.normal;

  void critical(String message) {
    level = DeviceHealthLevel.critical;
    issues.add(message);
  }

  void warning(String message) {
    if (level != DeviceHealthLevel.critical) level = DeviceHealthLevel.warning;
    issues.add(message);
  }

  if (status.secondsSinceLast > 3600) {
    critical('기기 응답 없음');
  }
  if (!status.micOk) {
    critical('마이크 이상 — 소리를 감지하지 못합니다');
  }
  if (status.wakePinIdle == 'LOW') {
    critical('웨이크핀 하드웨어 이상 — 오작동 가능');
  }
  if (!status.camOk) {
    warning('카메라 이상 — 사진 없이 알림만 갑니다');
  }
  if (status.hoursSinceSound > 24 && !awayModeSuppresses24hWarning) {
    warning('24시간 동안 소리 감지 없음 — 확인 필요');
  }

  return DeviceHealthEvaluation(level: level, issues: issues);
}
