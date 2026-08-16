import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import '../models/event_model.dart';
import '../models/heartbeat_status.dart';
import '../models/mask_region.dart';
import 'background_sse_handler.dart';

/// SSE(Server-Sent Events) 서비스 — UI(메인) isolate 쪽 파사드.
///
/// 실제 /stream 연결은 더 이상 여기서 열지 않는다. background_sse_handler.dart의
/// Foreground Service TaskHandler가 앱이 꺼져 있어도 항상 연결을 유지하고,
/// 이 클래스는 그 TaskHandler가 sendPort로 릴레이해주는 이벤트/연결상태를 받아
/// 기존과 동일한 eventStream/loiterStream/connectionStream API로 흘려보내는 역할만 한다.
/// (연결을 UI/백그라운드 두 군데서 각자 열면 서버에 기기당 연결이 2개씩 생기고
/// 이벤트도 중복 처리되므로, 백그라운드 isolate가 유일한 소유자다.)
///
/// 서버가 보내는 메시지 3종류 (data 필드 JSON의 "type", background_sse_handler가 그대로 릴레이):
///   connected        - 연결 직후 1회, 무시(연결 확인용)
///   new_event        - 새 이벤트 발생 → eventStream으로 전달 (알림 트리거)
///   loiter_confirmed - v2 전용. 체류 확인 결과 동기화 → loiterStream으로 전달
/// 그 외 "_connection_status"는 서버가 아니라 TaskHandler 자신이 만들어 보내는
/// 합성 메시지로, connectionStream 갱신에만 쓰인다.
class SSEService {
  final StreamController<EventModel> _eventController =
      StreamController<EventModel>.broadcast();
  final StreamController<EventModel> _loiterController =
      StreamController<EventModel>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<Map<String, dynamic>> _videoReadyController =
      StreamController<Map<String, dynamic>>.broadcast();

  bool _isConnected = false;
  String _serverUrl = 'http://10.91.157.5:5000';
  ReceivePort? _receivePort;
  StreamSubscription? _portSubscription;

  /// 새 이벤트 스트림 (알림 트리거용)
  Stream<EventModel> get eventStream => _eventController.stream;

  /// 체류 확인(loiter) 갱신 스트림 (v2 전용, 기존 카드 상태 갱신용 — 새 알림은 아님)
  Stream<EventModel> get loiterStream => _loiterController.stream;

  /// 연결 상태 스트림
  Stream<bool> get connectionStream => _connectionController.stream;

  /// 영상 준비 완료 스트림. {event_id, video} 형태의 가벼운 알림만 흘려보내므로
  /// 구독하는 화면이 event_id로 자기가 들고 있는 이벤트를 직접 찾아 갱신해야 한다.
  Stream<Map<String, dynamic>> get videoReadyStream => _videoReadyController.stream;

  /// 현재 연결 상태
  bool get isConnected => _isConnected;

  /// 서버 URL 설정
  void setServerUrl(String url) {
    _serverUrl = url;
  }

  /// 백그라운드 감시 서비스를 시작하고 릴레이를 구독한다.
  /// 이미 떠 있어도 안전하게 멈췄다가 새로 시작한다 — 서버 URL을 바꾼 뒤
  /// 재연결하는 경우도 이 한 경로로 처리된다(연결 로직은 TaskHandler.onStart에서
  /// 매번 서버 URL을 새로 읽으므로, 서비스를 새로 시작하기만 하면 됨).
  Future<void> connect() async {
    await _attachRelay();
    await FlutterForegroundTask.stopService();
    await FlutterForegroundTask.startService(
      notificationTitle: 'Echo Vision 감시 중',
      notificationText: '현관 이벤트를 실시간으로 감지하고 있어요',
      callback: sseServiceCallback,
    );
  }

  /// 백그라운드 감시 서비스 종료
  void disconnect() {
    FlutterForegroundTask.stopService();
    _updateConnectionStatus(false);
  }

  /// TaskHandler의 릴레이 포트를 (다시) 구독한다.
  /// FlutterForegroundTask.receivePort는 부를 때마다 새 포트를 등록해주므로,
  /// 앱이 완전히 새로 시작될 때(콜드스타트) 이전 isolate가 쓰던 죽은 포트 참조를
  /// 안 쓰고 항상 새 포트를 받게 된다.
  Future<void> _attachRelay() async {
    await _portSubscription?.cancel();
    _receivePort = FlutterForegroundTask.receivePort;
    _portSubscription = _receivePort?.listen(_handleRelayMessage);

    // 서비스가 이 attach 이전부터 이미 돌고 있었을 수 있으니(예: 앱을 다시 켰을 때),
    // TaskHandler가 저장해둔 마지막 연결 상태를 조회해서 배지에 바로 반영한다.
    final savedConnected = await FlutterForegroundTask.getData<bool>(
      key: 'is_connected',
    );
    if (savedConnected != null) {
      _updateConnectionStatus(savedConnected);
    }
  }

  void _handleRelayMessage(dynamic message) {
    if (message is! String) return;
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      switch (json['type']) {
        case '_connection_status':
          _updateConnectionStatus(json['connected'] as bool? ?? false);
          break;
        case 'new_event':
          final event = EventModel.fromJson(json);
          if (event.requiresAlert) {
            _eventController.add(event);
          }
          break;
        case 'loiter_confirmed':
          _loiterController.add(EventModel.fromJson(json));
          break;
        case 'video_ready':
          _videoReadyController.add(json);
          break;
        default:
          break;
      }
    } catch (e) {
      debugPrint('릴레이 메시지 파싱 오류: $e');
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
  Future<Uint8List?> downloadSnapshot(String imageFilename) async {
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

  /// 이웃 프라이버시 마스킹 영역 저장 (POST /device/mask-regions)
  /// 좌표는 이미지 전체 대비 0.0~1.0 비율(설치 모드 화면 참고). 성공 여부만 반환.
  Future<bool> saveMaskRegions(List<MaskRegion> regions) async {
    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/device/mask-regions'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'regions': regions.map((r) => r.toJson()).toList()}),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('마스킹 영역 저장 오류: $e');
      return false;
    }
  }

  /// 저장된 마스킹 영역 조회 (GET /device/mask-regions) — 재설정 진입 시 기존 값을
  /// 불러와 편집할 수 있게 하는 용도.
  Future<List<MaskRegion>> getMaskRegions() async {
    try {
      final response = await http.get(Uri.parse('$_serverUrl/device/mask-regions'));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final list = json['regions'] as List<dynamic>? ?? [];
        return list
            .map((e) => MaskRegion.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('마스킹 영역 조회 오류: $e');
    }
    return [];
  }

  /// 마스킹 설정 상태 조회 (GET /device/mask-regions/status) — 설정 화면에 표시용.
  Future<MaskRegionsStatus?> getMaskRegionsStatus() async {
    try {
      final response =
          await http.get(Uri.parse('$_serverUrl/device/mask-regions/status'));
      if (response.statusCode == 200) {
        return MaskRegionsStatus.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      debugPrint('마스킹 설정 상태 조회 오류: $e');
    }
    return null;
  }

  /// 기기 자가진단 상태 조회 (GET /device/heartbeat-status) — 홈 화면 상단 배지용.
  /// 실패(연결 안 됨 등)하면 null — 호출부가 "확인 불가"로 처리한다.
  Future<HeartbeatStatus?> getHeartbeatStatus() async {
    try {
      final response =
          await http.get(Uri.parse('$_serverUrl/device/heartbeat-status'));
      if (response.statusCode == 200) {
        return HeartbeatStatus.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      debugPrint('기기 상태 조회 오류: $e');
    }
    return null;
  }

  /// 리소스 해제
  void dispose() {
    _portSubscription?.cancel();
    _eventController.close();
    _loiterController.close();
    _connectionController.close();
    _videoReadyController.close();
  }
}
