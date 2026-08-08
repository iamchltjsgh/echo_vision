import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/event_model.dart';

/// 이벤트 하나에 대한 알림 채널(플래시/진동/소리) on-off 조합
class EventAlertConfig {
  final bool flash;
  final bool haptic;
  final bool sound;

  const EventAlertConfig({
    this.flash = false,
    this.haptic = false,
    this.sound = false,
  });

  EventAlertConfig copyWith({bool? flash, bool? haptic, bool? sound}) {
    return EventAlertConfig(
      flash: flash ?? this.flash,
      haptic: haptic ?? this.haptic,
      sound: sound ?? this.sound,
    );
  }

  factory EventAlertConfig.fromJson(Map<String, dynamic> json) {
    return EventAlertConfig(
      flash: json['flash'] as bool? ?? false,
      haptic: json['haptic'] as bool? ?? false,
      sound: json['sound'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {'flash': flash, 'haptic': haptic, 'sound': sound};
}

/// 앱 설정 관리 서비스
/// SharedPreferences를 통해 설정값을 저장/로드합니다.
class SettingsService {
  static const String _keyAlertConfig = 'event_alert_config';
  static const String _keyVolume = 'volume';
  static const String _keyServerUrl = 'server_url';
  static const String _defaultServerUrl = 'http://10.91.157.5:5000';

  /// 알림을 설정할 수 있는 이벤트 타입 (NORMAL은 requiresAlert가 false라 제외)
  static const List<EventType> alertEventTypes = [
    EventType.knock,
    EventType.doorbell,
    EventType.impact,
    EventType.emergency,
    EventType.unknown,
  ];

  /// 타입별 설정을 저장한 적 없을 때 쓰는 기본값.
  /// 과거 하드코딩 동작(노크/초인종은 진동만, 위협/화재는 플래시+진동, 미분류는 무알림)과 동일하게 맞춘다.
  static const Map<EventType, EventAlertConfig> _defaultAlertConfig = {
    EventType.knock: EventAlertConfig(haptic: true),
    EventType.doorbell: EventAlertConfig(haptic: true),
    EventType.impact: EventAlertConfig(flash: true, haptic: true),
    EventType.emergency: EventAlertConfig(flash: true, haptic: true),
    EventType.unknown: EventAlertConfig(),
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
  String get serverUrl => _prefs?.getString(_keyServerUrl) ?? _defaultServerUrl;
  set serverUrl(String value) => _prefs?.setString(_keyServerUrl, value);
}
