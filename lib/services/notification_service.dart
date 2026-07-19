import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:torch_light/torch_light.dart';
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

    // 설정값에 따라 독립적으로 알림 실행
    final futures = <Future>[];

    if (_settings.soundEnabled) {
      futures.add(_playSound(event.eventType));
    }
    if (_settings.hapticEnabled) {
      futures.add(_triggerHaptic(event.eventType));
    }
    if (_settings.flashEnabled) {
      futures.add(_triggerFlash(event.eventType));
    }

    await Future.wait(futures);
  }

  /// 소리 알림 재생
  Future<void> _playSound(EventType type) async {
    try {
      // 볼륨 설정
      await _audioPlayer.setVolume(_settings.volume);

      String assetPath;
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
          return;
      }

      try {
        await _audioPlayer.play(AssetSource(assetPath));
      } catch (e) {
        // mp3 파일이 없으면 시스템 기본 알림음으로 대체
        debugPrint('알림음 파일 없음, 기본음 사용: $e');
        // System default notification sound fallback
        await _audioPlayer.play(
          UrlSource('content://settings/system/notification_sound'),
        );
      }
    } catch (e) {
      debugPrint('소리 알림 오류: $e');
    }
  }

  /// 햅틱 진동 실행
  Future<void> _triggerHaptic(EventType type) async {
    try {
      final hasVibrator = await Vibration.hasVibrator() ?? false;
      if (!hasVibrator) return;

      switch (type) {
        case EventType.knock:
          // 짧게 3번: [대기, 진동, 대기, 진동, 대기, 진동]
          await Vibration.vibrate(pattern: [0, 200, 100, 200, 100, 200]);
          break;
        case EventType.doorbell:
          // 짧게 2번
          await Vibration.vibrate(pattern: [0, 300, 150, 300]);
          break;
        case EventType.impact:
          // 길게 강하게 1초
          await Vibration.vibrate(duration: 1000, amplitude: 255);
          break;
        case EventType.emergency:
          // 연속 5회 반복 [300ms ON, 100ms OFF]
          await Vibration.vibrate(
            pattern: [0, 300, 100, 300, 100, 300, 100, 300, 100, 300],
          );
          break;
        default:
          break;
      }
    } catch (e) {
      debugPrint('햅틱 진동 오류: $e');
    }
  }

  /// 플래시 점멸 실행
  Future<void> _triggerFlash(EventType type) async {
    try {
      switch (type) {
        case EventType.knock:
        case EventType.doorbell:
          // KNOCK/DOORBELL은 플래시 없음
          return;
        case EventType.impact:
          // 500ms 점멸 1회
          await TorchLight.enableTorch();
          await Future.delayed(const Duration(milliseconds: 500));
          await TorchLight.disableTorch();
          break;
        case EventType.emergency:
          // 연속 5회 점멸 [200ms ON, 100ms OFF]
          for (int i = 0; i < 5; i++) {
            await TorchLight.enableTorch();
            await Future.delayed(const Duration(milliseconds: 200));
            await TorchLight.disableTorch();
            if (i < 4) {
              await Future.delayed(const Duration(milliseconds: 100));
            }
          }
          break;
        default:
          break;
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
