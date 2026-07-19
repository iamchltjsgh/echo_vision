import 'package:shared_preferences/shared_preferences.dart';

/// 앱 설정 관리 서비스
/// SharedPreferences를 통해 설정값을 저장/로드합니다.
class SettingsService {
  static const String _keySoundEnabled = 'sound_enabled';
  static const String _keyHapticEnabled = 'haptic_enabled';
  static const String _keyFlashEnabled = 'flash_enabled';
  static const String _keyVolume = 'volume';
  static const String _keyServerUrl = 'server_url';
  static const String _defaultServerUrl = 'http://10.91.157.5:5000';

  SharedPreferences? _prefs;

  /// 초기화
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// 소리 알림 활성화 여부 (기본값: OFF)
  bool get soundEnabled => _prefs?.getBool(_keySoundEnabled) ?? false;
  set soundEnabled(bool value) => _prefs?.setBool(_keySoundEnabled, value);

  /// 햅틱 진동 활성화 여부 (기본값: ON)
  bool get hapticEnabled => _prefs?.getBool(_keyHapticEnabled) ?? true;
  set hapticEnabled(bool value) => _prefs?.setBool(_keyHapticEnabled, value);

  /// 플래시 점멸 활성화 여부 (기본값: ON)
  bool get flashEnabled => _prefs?.getBool(_keyFlashEnabled) ?? true;
  set flashEnabled(bool value) => _prefs?.setBool(_keyFlashEnabled, value);

  /// 볼륨 (0.0 ~ 1.0, 기본값: 0.7)
  double get volume => _prefs?.getDouble(_keyVolume) ?? 0.7;
  set volume(double value) => _prefs?.setDouble(_keyVolume, value);

  /// 서버 URL (기본값: http://192.168.0.100:5000)
  String get serverUrl => _prefs?.getString(_keyServerUrl) ?? _defaultServerUrl;
  set serverUrl(String value) => _prefs?.setString(_keyServerUrl, value);
}
