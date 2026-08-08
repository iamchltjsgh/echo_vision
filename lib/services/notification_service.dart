import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:torch_light/torch_light.dart';
import '../models/alert_presets.dart';
import '../models/event_model.dart';
import 'settings_service.dart';

/// 알림 서비스
/// 소리, 햅틱 진동, 플래시 점멸을 이벤트 타입에 따라 실행합니다.
class NotificationService {
  final SettingsService _settings;
  final AudioPlayer _audioPlayer = AudioPlayer();

  NotificationService(this._settings);

  /// 이벤트에 따른 알림 실행
  Future<void> triggerAlert(EventModel event) async {
    if (!event.requiresAlert) return;

    // 이벤트 타입별로 사용자가 설정한 채널만 독립적으로 실행
    final config = _settings.alertConfigFor(event.eventType);
    final futures = <Future>[];

    if (config.sound) {
      futures.add(_playSound(event.eventType));
    }
    if (config.haptic) {
      futures.add(_triggerHaptic(event.eventType, config.vibrationPreset));
    }
    if (config.flash) {
      futures.add(_triggerFlash(event.eventType, config.flashPreset));
    }

    await Future.wait(futures);
  }

  /// 소리 알림 재생
  Future<void> _playSound(EventType type) async {
    try {
      // 볼륨 설정
      await _audioPlayer.setVolume(_settings.volume);

      // UNKNOWN 등 전용 음원이 없는 타입은 기기 기본 알림음으로 대체
      String? assetPath;
      switch (type) {
        case EventType.knock:
          assetPath = 'sounds/knock.mp3';
          break;
        case EventType.doorbell:
          assetPath = 'sounds/bell.mp3';
          break;
        case EventType.impact:
          assetPath = 'sounds/threat.mp3';
          break;
        case EventType.emergency:
          assetPath = 'sounds/emergency.mp3';
          break;
        default:
          assetPath = null;
      }

      try {
        if (assetPath != null) {
          await _audioPlayer.play(AssetSource(assetPath));
        } else {
          // System default notification sound fallback
          await _audioPlayer.play(
            UrlSource('content://settings/system/notification_sound'),
          );
        }
      } catch (e) {
        // mp3 파일이 없으면 시스템 기본 알림음으로 대체
        debugPrint('알림음 파일 없음, 기본음 사용: $e');
        await _audioPlayer.play(
          UrlSource('content://settings/system/notification_sound'),
        );
      }
    } catch (e) {
      debugPrint('소리 알림 오류: $e');
    }
  }

  /// 햅틱 진동 실행.
  /// 반복 횟수는 EventType.vibrationRepeatCount(타입 정체성),
  /// 길이/스타일은 preset(사용자가 설정 화면에서 고른 값) — 백그라운드 시스템 알림도
  /// 같은 alert_presets.dart 함수를 써서 인앱/백그라운드 진동이 항상 일치한다.
  Future<void> _triggerHaptic(EventType type, VibrationPreset preset) async {
    try {
      final hasVibrator = await Vibration.hasVibrator();
      if (!hasVibrator) return;

      final pattern = buildVibrationPattern(type.vibrationRepeatCount, preset);
      await Vibration.vibrate(
        pattern: pattern,
        // 위협 감지는 강도를 최대로 (기기가 강도 조절을 지원하지 않으면 무시됨).
        // intensities는 pattern과 길이가 같아야 하고, 대기 구간(짝수 인덱스)은 0.
        intensities: type == EventType.impact
            ? List.generate(pattern.length, (i) => i.isEven ? 0 : 255)
            : const [],
      );
    } catch (e) {
      debugPrint('햅틱 진동 오류: $e');
    }
  }

  /// 플래시 점멸 실행.
  /// 몇 번 점멸할지는 EventType.flashBlinkCount(타입 정체성),
  /// 한 번 켜지는 길이는 preset(사용자가 설정 화면에서 고른 값)에서 가져온다.
  Future<void> _triggerFlash(EventType type, FlashPreset preset) async {
    try {
      final blinks = buildFlashBlinks(type.flashBlinkCount, preset);
      for (var i = 0; i < blinks.length; i++) {
        final (onMs, offMs) = blinks[i];
        await TorchLight.enableTorch();
        await Future.delayed(Duration(milliseconds: onMs));
        await TorchLight.disableTorch();
        if (i < blinks.length - 1) {
          await Future.delayed(Duration(milliseconds: offMs));
        }
      }
    } catch (e) {
      debugPrint('플래시 점멸 오류: $e');
    }
  }

  /// 리소스 해제
  void dispose() {
    _audioPlayer.dispose();
  }
}
