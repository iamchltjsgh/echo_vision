import 'package:flutter/material.dart';

/// 심각도(0~3) 표시 헬퍼.
///
/// 시각 이상 사용자를 고려해 심각도 구분을 색상만으로 하지 않는다 — 아이콘
/// 모양도 함께 다르게 해서, 색을 구분 못 해도 아이콘으로 심각도를 알 수 있게
/// 한다(rev.4 섹션 8). 카드/이력 리스트/이벤트 팝업에서 색상 하나로만
/// 구분하던 부분에는 반드시 이 아이콘도 같이 붙인다.
Color colorForSeverity(int severity) {
  switch (severity) {
    case 3:
      return const Color(0xFFEF4444); // 최고 — 빨강
    case 2:
      return const Color(0xFFFB923C); // 경고 — 주황
    case 1:
      return const Color(0xFF3B82F6); // 방문 — 파랑
    default:
      return const Color(0xFF6B7280); // 회색(정상/미분류)
  }
}

IconData iconForSeverity(int severity) {
  switch (severity) {
    case 3:
      return Icons.crisis_alert; // 경고/사이렌
    case 2:
      return Icons.lock_outline; // 도어락(자물쇠) 이상
    case 1:
      return Icons.notifications_active_outlined; // 종/방문 알림
    default:
      return Icons.help_outline;
  }
}

String labelForSeverity(int severity) {
  switch (severity) {
    case 3:
      return '최고';
    case 2:
      return '경고';
    case 1:
      return '방문';
    default:
      return '알수없음';
  }
}
