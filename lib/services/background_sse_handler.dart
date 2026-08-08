import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/event_model.dart';
import 'history_service.dart';
import 'settings_service.dart';

/// Foreground Service가 시작될 때 호출되는 최상위 콜백.
/// 반드시 최상위 함수여야 하며, 이 안에서 setTaskHandler를 부르는 게
/// flutter_foreground_task가 요구하는 유일한 계약이다.
@pragma('vm:entry-point')
void sseServiceCallback() {
  FlutterForegroundTask.setTaskHandler(SseTaskHandler());
}

/// 백그라운드(앱이 완전히 종료된 상태 포함)에서 /stream SSE 연결을 유지하는 TaskHandler.
///
/// 이 isolate가 연결의 유일한 소유자다 — 앱이 떠 있든 아니든 항상 이 isolate가
/// 연결하고, 새 이벤트가 오면 (1) HistoryService에 저장 (2) 시스템 알림 표시
/// (3) UI가 떠 있으면 sendPort로 릴레이, 이 3가지를 전담한다.
/// UI 쪽 SSEService는 더 이상 직접 연결하지 않고 이 relay만 구독한다.
class SseTaskHandler extends TaskHandler {
  static const String _channelNormalId = 'echo_vision_normal';
  static const String _channelAlertId = 'echo_vision_alert';
  static const String _channelEmergencyId = 'echo_vision_emergency';

  final HistoryService _history = HistoryService();
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  http.Client? _client;
  bool _isConnected = false;
  bool _shouldReconnect = true;

  /// 연결 시도 "세대" 번호. onDestroy 등으로 이전 재시도 체인을 무효화할 때 올린다.
  /// (sse_service.dart에 있던 것과 같은 목적 — 재연결 누수/중복 방지)
  int _connectionGeneration = 0;

  SendPort? _sendPort;

  @override
  void onStart(DateTime timestamp, SendPort? sendPort) async {
    WidgetsFlutterBinding.ensureInitialized();
    _sendPort = sendPort;
    await _initNotifications();
    _shouldReconnect = true;
    unawaited(_startConnection());
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {}

  @override
  void onDestroy(DateTime timestamp, SendPort? sendPort) {
    _shouldReconnect = false;
    _connectionGeneration++;
    _client?.close();
    _client = null;
    _isConnected = false;
  }

  @override
  void onNotificationPressed() {
    // 상시 "감시 중" 알림(서비스 알림 자체) 탭 — 특정 이벤트가 아니라 그냥 앱을 연다.
    FlutterForegroundTask.launchApp();
  }

  Future<void> _initNotifications() async {
    const androidSettings = AndroidInitializationSettings('ic_notification');
    await _notifications.initialize(
      settings: const InitializationSettings(android: androidSettings),
    );

    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelNormalId,
        '일반 알림',
        description: '노크·초인종 감지',
        importance: Importance.high,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelAlertId,
        '위협 알림',
        description: '위협(충격) 감지',
        importance: Importance.high,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelEmergencyId,
        '긴급 알림',
        description: '화재 등 긴급 상황',
        importance: Importance.max,
        // DND(방해금지) 우회는 hasNotificationPolicyAccess 권한이 없으면
        // 경고만 찍히고 무시된다 — 권한 유도는 main.dart/settings_screen.dart에서.
        bypassDnd: true,
      ),
    );
  }

  Future<String> _readServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(SettingsService.keyServerUrl) ??
        SettingsService.defaultServerUrl;
  }

  /// 연결 상태를 기록하고, UI(SSEService)가 "감시 중"/"연결 끊김" 배지를
  /// 정확히 표시할 수 있도록 두 가지 방법으로 알린다:
  /// - sendPort로 push (UI가 지금 떠서 듣고 있으면 바로 반영)
  /// - FlutterForegroundTask.saveData로도 저장 (UI가 나중에 (재)시작해서
  ///   receivePort를 새로 구독했을 때, 이전 push를 놓쳤어도 현재 상태를 조회할 수 있게)
  void _updateConnectionStatus(bool connected) {
    if (_isConnected == connected) return;
    _isConnected = connected;
    _sendPort?.send(
      jsonEncode({'type': '_connection_status', 'connected': connected}),
    );
    unawaited(
      FlutterForegroundTask.saveData(key: 'is_connected', value: connected),
    );
  }

  /// SSE 연결 실행. lib/services/sse_service.dart의 재연결 로직과 동일한 패턴
  /// (로컬 client 변수, finally에서 항상 close, 세대 카운터로 중복 방지).
  Future<void> _startConnection() async {
    if (_isConnected) return;

    final myGeneration = _connectionGeneration;
    http.Client? client;
    try {
      final serverUrl = await _readServerUrl();
      client = http.Client();
      _client = client;
      final request = http.Request('GET', Uri.parse('$serverUrl/stream'));
      request.headers['Accept'] = 'text/event-stream';
      request.headers['Cache-Control'] = 'no-cache';

      final response = await client.send(request);

      if (response.statusCode == 200) {
        _updateConnectionStatus(true);

        String buffer = '';
        await for (final chunk in response.stream.transform(utf8.decoder)) {
          buffer += chunk;
          while (buffer.contains('\n\n')) {
            final eventEnd = buffer.indexOf('\n\n');
            final eventStr = buffer.substring(0, eventEnd);
            buffer = buffer.substring(eventEnd + 2);
            await _parseSSEEvent(eventStr);
          }
        }
      }
    } catch (e) {
      // 백그라운드 isolate라 debugPrint 대신 print — adb logcat으로는 동일하게 보인다.
      // ignore: avoid_print
      print('[SSE-BG] 연결 오류: $e');
    } finally {
      client?.close();
      if (identical(_client, client)) {
        _client = null;
      }
      _updateConnectionStatus(false);

      if (_shouldReconnect && myGeneration == _connectionGeneration) {
        await Future.delayed(const Duration(seconds: 3));
        if (_shouldReconnect && myGeneration == _connectionGeneration) {
          await _startConnection();
        }
      }
    }
  }

  Future<void> _parseSSEEvent(String eventStr) async {
    for (final line in eventStr.split('\n')) {
      if (!line.startsWith('data: ')) continue;
      final jsonStr = line.substring(6).trim();
      try {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        switch (json['type']) {
          case 'new_event':
            await _handleNewEvent(json);
            break;
          case 'loiter_confirmed':
            await _handleLoiterConfirmed(json);
            break;
          default:
            // connected 확인용 메시지 및 미지의 타입은 무시.
            break;
        }
      } catch (e) {
        // ignore: avoid_print
        print('[SSE-BG] 이벤트 파싱 오류: $e');
      }
    }
  }

  Future<void> _handleNewEvent(Map<String, dynamic> json) async {
    final event = EventModel.fromJson(json);
    if (!event.requiresAlert) return;

    // UI가 안 떠 있어도 이력에 남아야 나중에 알림 탭으로 콜드스타트했을 때
    // eventId로 찾을 수 있다. 이력 쓰기는 이 isolate가 전담한다(UI는 더 이상 안 씀).
    final history = await _history.load();
    history.insert(0, event);
    await _history.save(history);

    await _showEventNotification(event);

    // UI가 떠 있으면 SSEService가 이걸 받아서 기존 인앱 알림/화면 갱신 흐름을 그대로 탄다.
    _sendPort?.send(jsonEncode(json));
  }

  Future<void> _handleLoiterConfirmed(Map<String, dynamic> json) async {
    final eventId = json['event_id'] as String?;
    if (eventId == null) return;

    final history = await _history.load();
    for (final e in history) {
      if (e.eventId == eventId) {
        e.loiterConfirmed = true;
      }
    }
    await _history.save(history);

    _sendPort?.send(jsonEncode(json));
  }

  Future<void> _showEventNotification(EventModel event) async {
    // 앱이 지금 포그라운드면 인앱 알림(NotificationService.triggerAlert)이
    // 곧 따로 실행되므로, 시스템 알림은 소리/진동 없이 조용히만(배지처럼) 띄운다.
    // EMERGENCY는 예외 — 놓치면 안 되니 포그라운드여도 그대로 강행한다.
    final isForeground = await FlutterForegroundTask.isAppOnForeground;
    final isEmergency = event.eventType == EventType.emergency;
    final alertLoudly = isEmergency || !isForeground;

    String channelId;
    String channelName;
    Importance importance;
    Color color;
    switch (event.eventType) {
      case EventType.impact:
        channelId = _channelAlertId;
        channelName = '위협 알림';
        importance = Importance.high;
        color = const Color(0xFFFB923C);
        break;
      case EventType.emergency:
        channelId = _channelEmergencyId;
        channelName = '긴급 알림';
        importance = Importance.max;
        color = const Color(0xFFEF4444);
        break;
      default:
        channelId = _channelNormalId;
        channelName = '일반 알림';
        importance = Importance.high;
        color = const Color(0xFF3B82F6);
    }

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: '이벤트 알림',
      importance: importance,
      priority: Priority.high,
      icon: 'ic_notification',
      color: color,
      playSound: alertLoudly,
      enableVibration: alertLoudly,
      vibrationPattern: event.eventType.vibrationPattern,
      // Android 14+에서는 USE_FULL_SCREEN_INTENT를 사용자가 수동으로 허용해야
      // 실제로 잠금화면 위로 뜬다 (main.dart 온보딩 참고) — 안 돼 있으면
      // 그냥 최우선 헤드업 알림으로 자연 강등된다.
      fullScreenIntent: isEmergency,
      category: isEmergency ? AndroidNotificationCategory.alarm : null,
    );

    final id = event.eventId?.hashCode.abs() ??
        DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);

    await _notifications.show(
      id: id,
      title: '${event.eventType.emoji} ${event.eventType.displayName}',
      body: isEmergency ? '지금 바로 확인하세요' : '탭하면 자세히 볼 수 있어요',
      notificationDetails: NotificationDetails(android: androidDetails),
      payload: event.eventId,
    );
  }
}
