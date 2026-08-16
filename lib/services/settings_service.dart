import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/alert_presets.dart';
import '../models/event_model.dart';

/// 이벤트 하나에 대한 알림 채널(플래시/진동/소리) on-off 조합 + 길이/스타일 프리셋
class EventAlertConfig {
  final bool flash;
  final bool haptic;
  final bool sound;
  final FlashPreset flashPreset;
  final VibrationPreset vibrationPreset;

  const EventAlertConfig({
    this.flash = false,
    this.haptic = false,
    this.sound = false,
    this.flashPreset = FlashPreset.normal,
    this.vibrationPreset = VibrationPreset.shortRepeat,
  });

  EventAlertConfig copyWith({
    bool? flash,
    bool? haptic,
    bool? sound,
    FlashPreset? flashPreset,
    VibrationPreset? vibrationPreset,
  }) {
    return EventAlertConfig(
      flash: flash ?? this.flash,
      haptic: haptic ?? this.haptic,
      sound: sound ?? this.sound,
      flashPreset: flashPreset ?? this.flashPreset,
      vibrationPreset: vibrationPreset ?? this.vibrationPreset,
    );
  }

  factory EventAlertConfig.fromJson(Map<String, dynamic> json) {
    return EventAlertConfig(
      flash: json['flash'] as bool? ?? false,
      haptic: json['haptic'] as bool? ?? false,
      sound: json['sound'] as bool? ?? false,
      flashPreset: FlashPreset.values.firstWhere(
        (p) => p.name == json['flashPreset'],
        orElse: () => FlashPreset.normal,
      ),
      vibrationPreset: VibrationPreset.values.firstWhere(
        (p) => p.name == json['vibrationPreset'],
        orElse: () => VibrationPreset.shortRepeat,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'flash': flash,
    'haptic': haptic,
    'sound': sound,
    'flashPreset': flashPreset.name,
    'vibrationPreset': vibrationPreset.name,
  };
}

/// 앱 설정 관리 서비스
/// SharedPreferences를 통해 설정값을 저장/로드합니다.
class SettingsService {
  static const String _keyAlertConfig = 'event_alert_config';
  static const String _keyVolume = 'volume';
  static const String _keyBatteryPromptShown = 'battery_optimization_prompt_shown';
  static const String _keyAwayMode = 'away_mode';

  /// SharedPreferences 키. background_sse_handler.dart도 같은 서버 URL을 읽어야 해서 공개.
  static const String keyServerUrl = 'server_url';
  static const String defaultServerUrl = 'http://10.91.157.5:5000';

  /// 알림을 설정할 수 있는 이벤트 타입 (NORMAL은 requiresAlert가 false라 제외)
  static const List<EventType> alertEventTypes = [
    EventType.knock,
    EventType.doorbell,
    EventType.doorlockAlarm,
    EventType.doorlockError,
    EventType.emergency,
    EventType.unknown,
  ];

  /// 타입별 설정을 저장한 적 없을 때 쓰는 기본값 — 채널(플래시/진동/소리) ON/OFF만
  /// 여기서 정한다. 실제 진동/플래시의 세기·리듬은 더 이상 타입별이 아니라
  /// severity가 자동으로 정한다(alert_presets.dart의 *ParamsForSeverity 참고) —
  /// 그래서 flashPreset/vibrationPreset 값은 이제 의미 없는 기본값일 뿐이다.
  static const Map<EventType, EventAlertConfig> _defaultAlertConfig = {
    EventType.knock: EventAlertConfig(haptic: true),
    EventType.doorbell: EventAlertConfig(haptic: true),
    EventType.doorlockAlarm: EventAlertConfig(flash: true, haptic: true),
    EventType.doorlockError: EventAlertConfig(flash: true, haptic: true),
    EventType.emergency: EventAlertConfig(flash: true, haptic: true),
    EventType.unknown: EventAlertConfig(haptic: true),
  };

  SharedPreferences? _prefs;

  /// 초기화
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Map<String, dynamic> _readAlertConfigMap() {
    final raw = _prefs?.getString(_keyAlertConfig);
    if (raw == null) return {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// 이벤트 타입별 알림 채널(플래시/진동/소리) 설정 조회
  EventAlertConfig alertConfigFor(EventType type) {
    final entry = _readAlertConfigMap()[type.name];
    if (entry is Map<String, dynamic>) {
      return EventAlertConfig.fromJson(entry);
    }
    return _defaultAlertConfig[type] ?? const EventAlertConfig();
  }

  /// 이벤트 타입별 알림 채널 설정 저장
  void setAlertConfigFor(EventType type, EventAlertConfig config) {
    final map = _readAlertConfigMap();
    map[type.name] = config.toJson();
    _prefs?.setString(_keyAlertConfig, jsonEncode(map));
  }

  /// 알림 대상 이벤트 타입 중 하나라도 플래시가 켜져 있는지 (홈 화면 상태 표시용)
  bool get flashEnabled => alertEventTypes.any((t) => alertConfigFor(t).flash);

  /// 알림 대상 이벤트 타입 중 하나라도 진동이 켜져 있는지 (홈 화면 상태 표시용)
  bool get hapticEnabled => alertEventTypes.any((t) => alertConfigFor(t).haptic);

  /// 알림 대상 이벤트 타입 중 하나라도 소리가 켜져 있는지 (홈 화면 상태 표시용)
  bool get soundEnabled => alertEventTypes.any((t) => alertConfigFor(t).sound);

  /// 볼륨 (0.0 ~ 1.0, 기본값: 0.7)
  double get volume => _prefs?.getDouble(_keyVolume) ?? 0.7;
  set volume(double value) => _prefs?.setDouble(_keyVolume, value);

  /// 서버 URL (기본값: http://192.168.0.100:5000)
  String get serverUrl => _prefs?.getString(keyServerUrl) ?? defaultServerUrl;
  set serverUrl(String value) => _prefs?.setString(keyServerUrl, value);

  /// 배터리 최적화 제외 안내를 이미 한 번 보여줬는지 (최초 1회만 자동으로 뜨게 하기 위함).
  /// 나중에 다시 허용하고 싶으면 설정 탭의 "백그라운드 감시" 섹션에서 언제든 가능.
  bool get batteryPromptShown => _prefs?.getBool(_keyBatteryPromptShown) ?? false;
  set batteryPromptShown(bool value) => _prefs?.setBool(_keyBatteryPromptShown, value);

  /// "외출 중" 모드. 켜져 있으면 24시간 무음 경고만 숨긴다(그 외 기기 이상 경고는
  /// 그대로 뜬다) — 장기간 집을 비운 사용자가 당연한 무음을 이상으로 오해하지
  /// 않도록. 기본값 false.
  bool get awayMode => _prefs?.getBool(_keyAwayMode) ?? false;
  set awayMode(bool value) => _prefs?.setBool(_keyAwayMode, value);
}
