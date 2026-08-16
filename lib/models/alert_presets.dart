/// 플래시 점멸 길이 프리셋. 이벤트 타입별로 사용자가 직접 고른다(SettingsService 참고).
enum FlashPreset {
  short,
  normal,
  long;

  String get displayName {
    switch (this) {
      case FlashPreset.short:
        return '짧게';
      case FlashPreset.normal:
        return '보통';
      case FlashPreset.long:
        return '길게';
    }
  }

  /// 한 번 점멸에 켜져 있는 시간(ms)
  int get blinkDurationMs {
    switch (this) {
      case FlashPreset.short:
        return 150;
      case FlashPreset.normal:
        return 300;
      case FlashPreset.long:
        return 600;
    }
  }
}

/// 진동 패턴 프리셋. 이벤트 타입별로 사용자가 직접 고른다(SettingsService 참고).
enum VibrationPreset {
  /// 짧게 반복 — 짧은 진동을 여러 번
  shortRepeat,

  /// 길게 반복 — 긴 진동을 여러 번
  longRepeat,

  /// 쭉 길게 — 반복 없이 한 번 길게
  continuousLong;

  String get displayName {
    switch (this) {
      case VibrationPreset.shortRepeat:
        return '짧게 반복';
      case VibrationPreset.longRepeat:
        return '길게 반복';
      case VibrationPreset.continuousLong:
        return '쭉 길게';
    }
  }
}

/// [blinkCount]번(flashParamsForSeverity가 정함) 점멸하는 (켜짐 시간, 꺼짐 시간) ms 목록을 만든다.
/// 꺼짐(간격)은 켜짐 시간의 절반으로 둔다.
List<(int onMs, int offMs)> buildFlashBlinks(int blinkCount, FlashPreset preset) {
  final onMs = preset.blinkDurationMs;
  final offMs = (onMs / 2).round();
  return List.generate(blinkCount, (_) => (onMs, offMs));
}

/// [repeatCount]번(vibrationParamsForSeverity가 정함) 반복하는 진동 패턴을 만든다.
/// vibration 패키지의 pattern 형식: [대기, 진동, 대기, 진동, ...] (첫 대기는 보통 0).
/// continuousLong은 "반복"이라는 개념 자체가 없어서 repeatCount는 강도(길이) 힌트로만 쓴다.
///
/// 일부러 List<int>를 돌려준다(Int64List 아님) — vibration 패키지의 안드로이드 네이티브
/// 코드가 `List<Integer> pattern = call.argument("pattern")`로 읽는데, Int64List를 넘기면
/// 플랫폼 채널에서 long[]로 인코딩돼서 캐스팅이 실패해 진동이 조용히 씹힌다(예외가
/// _triggerHaptic의 try/catch에 잡혀서 로그만 남고 사용자는 못 알아챔).
/// flutter_local_notifications 쪽(Int64List? 요구)은 호출부에서 Int64List.fromList()로 감싸 쓴다.
List<int> buildVibrationPattern(int repeatCount, VibrationPreset preset) {
  switch (preset) {
    case VibrationPreset.shortRepeat:
      return _repeatingPattern(repeatCount, onMs: 150, offMs: 100);
    case VibrationPreset.longRepeat:
      return _repeatingPattern(repeatCount, onMs: 400, offMs: 150);
    case VibrationPreset.continuousLong:
      final durationMs = 1000 + (repeatCount - 1) * 200;
      return [0, durationMs];
  }
}

List<int> _repeatingPattern(int repeatCount, {required int onMs, required int offMs}) {
  final pattern = <int>[0];
  for (var i = 0; i < repeatCount; i++) {
    pattern.add(onMs);
    if (i < repeatCount - 1) pattern.add(offMs);
  }
  return pattern;
}

/// rev.4: 진동/플래시의 "강도(반복 횟수·길이)"는 더 이상 사용자가 이벤트 타입별로
/// 직접 고르지 않는다 — severity(0~3)가 자동으로 결정한다(리듬으로 심각도가
/// 구분되는 게 핵심 — 안 보는 사이에도 "강한지 약한지"를 손끝으로 알 수 있게).
/// 채널(플래시/진동/소리) 자체를 켤지 말지는 기존처럼 사용자 설정(EventAlertConfig)을
/// 그대로 따르고, 여기서 나온 (preset, count)로 buildVibrationPattern/buildFlashBlinks를
/// 호출해 실제 패턴을 만든다.
(VibrationPreset preset, int repeatCount) vibrationParamsForSeverity(int severity) {
  switch (severity) {
    case 3:
      return (VibrationPreset.longRepeat, 3);
    case 2:
      return (VibrationPreset.shortRepeat, 2);
    case 1:
      return (VibrationPreset.shortRepeat, 1);
    default:
      return (VibrationPreset.shortRepeat, 1);
  }
}

(FlashPreset preset, int blinkCount) flashParamsForSeverity(int severity) {
  switch (severity) {
    case 3:
      return (FlashPreset.long, 5);
    case 2:
      return (FlashPreset.normal, 3);
    case 1:
      return (FlashPreset.short, 1);
    default:
      return (FlashPreset.short, 1);
  }
}
