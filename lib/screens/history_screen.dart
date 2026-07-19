import 'package:flutter/material.dart';
import '../models/event_model.dart';
import '../services/sse_service.dart';

class HistoryScreen extends StatelessWidget {
  final SSEService sseService;
  final List<EventModel> eventHistory;

  const HistoryScreen({
    super.key,
    required this.sseService,
    required this.eventHistory,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 20, right: 20,
        top: MediaQuery.of(context).padding.top + 16,
        bottom: 120,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '이벤트 이력',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.bold,
              color: Color(0xFFE2E8F0),
            ),
          ),
          const SizedBox(height: 20),
          if (eventHistory.isEmpty)
            Container(
              padding: const EdgeInsets.all(40),
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF1E2535),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Icon(Icons.history, size: 48, color: Colors.white.withValues(alpha: 0.3)),
                  const SizedBox(height: 12),
                  const Text(
                    '기록된 이벤트가 없습니다',
                    style: TextStyle(fontSize: 16, color: Color(0xFF9CA3AF)),
                  ),
                ],
              ),
            )
          else
            ...eventHistory.map((event) {
              final borderColor = _getEventColor(event.eventType);
              final dt = DateTime.tryParse(event.timestamp) ?? DateTime.now();
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E2535),
                    borderRadius: BorderRadius.circular(12),
                    border: Border(
                      left: BorderSide(color: borderColor, width: 4),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Text(event.eventType.emoji, style: const TextStyle(fontSize: 20)),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                event.eventType.displayName,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: borderColor,
                                ),
                              ),
                              Text(
                                '신뢰도 ${(event.confidence * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Text(
                        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}',
                        style: const TextStyle(fontSize: 16, color: Color(0xFF9CA3AF)),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Color _getEventColor(EventType type) {
    switch (type) {
      case EventType.knock:
      case EventType.doorbell:
        return const Color(0xFF3B82F6);
      case EventType.impact:
        return const Color(0xFFFB923C);
      case EventType.emergency:
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF3B82F6);
    }
  }
}
