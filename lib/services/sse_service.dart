import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/event_model.dart';

/// SSE (Server-Sent Events) 서비스
/// Flask 서버(app.py/app_v2.py)와 SSE 연결을 유지하고 이벤트를 수신합니다.
///
/// 서버가 보내는 메시지 3종류 (data 필드 JSON의 "type"):
///   connected        - 연결 직후 1회, 무시(연결 확인용)
///   new_event        - 새 이벤트 발생 → eventStream으로 전달 (알림 트리거)
///   loiter_confirmed - v2 전용. 체류 확인 결과 동기화 → loiterStream으로 전달
///                       (v1 서버에는 이 메시지가 오지 않으므로 자연히 안 쓰임)
class SSEService {
  final StreamController<EventModel> _eventController =
      StreamController<EventModel>.broadcast();
  final StreamController<EventModel> _loiterController =
      StreamController<EventModel>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  http.Client? _client;
  bool _isConnected = false;
  bool _shouldReconnect = true;
  String _serverUrl = 'http://10.91.157.5:5000';

  /// 새 이벤트 스트림 (알림 트리거용)
  Stream<EventModel> get eventStream => _eventController.stream;

  /// 체류 확인(loiter) 갱신 스트림 (v2 전용, 기존 카드 상태 갱신용 — 새 알림은 아님)
  Stream<EventModel> get loiterStream => _loiterController.stream;

  /// 연결 상태 스트림
  Stream<bool> get connectionStream => _connectionController.stream;

  /// 현재 연결 상태
  bool get isConnected => _isConnected;

  /// 서버 URL 설정
  void setServerUrl(String url) {
    _serverUrl = url;
  }

  /// SSE 연결 시작
  Future<void> connect() async {
    _shouldReconnect = true;
    await _startConnection();
  }

  /// SSE 연결 종료
  void disconnect() {
    _shouldReconnect = false;
    _client?.close();
    _client = null;
    _updateConnectionStatus(false);
  }

  /// SSE 연결 실행
  Future<void> _startConnection() async {
    if (_isConnected) return;

    try {
      _client = http.Client();
      // 서버(app.py/app_v2.py) 실제 경로는 /stream (v1/v2 동일)
      final request = http.Request('GET', Uri.parse('$_serverUrl/stream'));
      request.headers['Accept'] = 'text/event-stream';
      request.headers['Cache-Control'] = 'no-cache';

      final response = await _client!.send(request);

      if (response.statusCode == 200) {
        _updateConnectionStatus(true);

        // SSE 스트림 파싱
        String buffer = '';
        await for (final chunk in response.stream.transform(utf8.decoder)) {
          buffer += chunk;
          // SSE 이벤트는 빈 줄로 구분
          while (buffer.contains('\n\n')) {
            final eventEnd = buffer.indexOf('\n\n');
            final eventStr = buffer.substring(0, eventEnd);
            buffer = buffer.substring(eventEnd + 2);
            _parseSSEEvent(eventStr);
          }
        }
      }
    } catch (e) {
      debugPrint('SSE 연결 오류: $e');
    } finally {
      _updateConnectionStatus(false);
      // 3초 후 자동 재연결
      if (_shouldReconnect) {
        await Future.delayed(const Duration(seconds: 3));
        if (_shouldReconnect) {
          await _startConnection();
        }
      }
    }
  }

  /// SSE 이벤트 파싱
  /// keepalive 주석(": keepalive")은 "data: "로 시작하지 않으므로 자동으로 무시된다.
  void _parseSSEEvent(String eventStr) {
    for (final line in eventStr.split('\n')) {
      if (line.startsWith('data: ')) {
        final jsonStr = line.substring(6).trim();
        try {
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;
          final type = json['type'] as String?;

          switch (type) {
            case 'new_event':
              final event = EventModel.fromJson(json);
              if (event.requiresAlert) {
                _eventController.add(event);
              }
              break;
            case 'loiter_confirmed':
              // v2 전용. 이미 떠 있는 이벤트 카드의 체류확인 상태만 갱신하는 용도라
              // 새 알림 팝업을 띄우지 않고 별도 스트림으로만 전달한다.
              _loiterController.add(EventModel.fromJson(json));
              break;
            case 'connected':
              // 연결 성공 확인용, 처리할 것 없음
              break;
            default:
              // 알 수 없는 타입은 무시 (서버 쪽에 새 메시지 타입이 추가돼도 앱이 죽지 않도록)
              break;
          }
        } catch (e) {
          debugPrint('이벤트 파싱 오류: $e');
        }
      }
    }
  }

  /// 연결 상태 업데이트
  void _updateConnectionStatus(bool connected) {
    _isConnected = connected;
    _connectionController.add(connected);
  }

  /// 스냅샷 이미지 다운로드
  /// [imageFilename]은 이벤트의 image 필드(파일명만, 예: "20260713_..._a1b2c3.jpg").
  /// 서버 실제 경로는 GET /photos/<filename> 이므로 여기서 조합한다.
  Future<List<int>?> downloadSnapshot(String imageFilename) async {
    try {
      final url = '$_serverUrl/photos/$imageFilename';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
    } catch (e) {
      debugPrint('스냅샷 다운로드 오류: $e');
    }
    return null;
  }

  /// 이벤트 이력 조회 (GET /events?limit=)
  Future<List<EventModel>> getEventHistory({int limit = 10}) async {
    try {
      final response = await http.get(
        Uri.parse('$_serverUrl/events?limit=$limit'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(response.body);
        return jsonList
            .map((json) => EventModel.fromJson(json as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('이벤트 이력 조회 오류: $e');
    }
    return [];
  }

  /// 체류 확인(loiter) 보고 — v2(app_v2.py) 전용 엔드포인트.
  /// POST /events/<id>/loiter
  /// v1(app.py) 서버에는 이 엔드포인트가 없어 404가 오는데, 그 경우에도
  /// 앱이 죽지 않도록 결과를 무시하고 넘어간다(best-effort).
  Future<void> reportLoiterConfirmed(String eventId) async {
    try {
      await http.post(Uri.parse('$_serverUrl/events/$eventId/loiter'));
    } catch (e) {
      debugPrint('체류 확인 보고 실패(v1 서버는 정상): $e');
    }
  }

  /// 리소스 해제
  void dispose() {
    disconnect();
    _eventController.close();
    _loiterController.close();
    _connectionController.close();
  }
}
