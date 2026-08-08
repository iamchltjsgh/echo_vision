import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/event_model.dart';

/// 이벤트 이력을 기기에 영구 저장하는 서비스.
/// 앱을 완전히 종료했다가 다시 켜도 이력 탭에 과거 이벤트가 남아있도록
/// SharedPreferences에 JSON 문자열로 저장/로드한다.
/// (스냅샷 이미지 바이트는 용량 문제로 저장하지 않고, 다음 실행 시 재다운로드하지 않는다)
///
/// UI(메인) isolate와 백그라운드 포그라운드 서비스 isolate 양쪽에서 쓴다 — 실제
/// 쓰기는 백그라운드 isolate가 전담하지만(background_sse_handler.dart), UI가 콜드스타트
/// 직후 딥링크로 이벤트를 찾을 때 방금 다른 isolate가 쓴 값을 놓치면 안 되므로
/// load()는 항상 캐시 말고 디스크에서 새로 읽는다.
class HistoryService {
  static const String _key = 'event_history';
  static const int maxStored = 50;

  Future<List<EventModel>> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => EventModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<EventModel> events) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = events.take(maxStored).map((e) => e.toJson()).toList();
    await prefs.setString(_key, jsonEncode(trimmed));
  }

  /// 이력 전체 삭제
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
