import 'package:flutter/material.dart';
import '../models/event_model.dart';

class EventScreen extends StatelessWidget {
  final EventModel event;

  const EventScreen({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 400,
          maxHeight: MediaQuery.of(context).size.height - 40,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _getBorderColor().withValues(alpha: 0.3), width: 1),
            boxShadow: [
              BoxShadow(
                color: _getBorderColor().withValues(alpha: 0.2),
                blurRadius: 30,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Stack(
            children: [
              SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            _getBorderColor().withValues(alpha: 0.15),
                            Colors.transparent,
                          ],
                        ),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                      ),
                      child: Column(
                        children: [
                          Text(
                            event.eventType.emoji,
                            style: const TextStyle(fontSize: 56),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            event.eventType.displayName,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: _getBorderColor(),
                            ),
                          ),
                          if (event.visionResult != null) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: _getBorderColor().withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(50),
                              ),
                              child: Text(
                                event.visionResult!.displayName,
                                style: const TextStyle(fontSize: 16, color: Color(0xFF9CA3AF)),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Snapshot
                    if (event.snapshotBytes != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            event.snapshotBytes!,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: 200,
                          ),
                        ),
                      ),
                    // Info
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          _buildInfoRow('신뢰도', '${(event.confidence * 100).toStringAsFixed(1)}%'),
                          const SizedBox(height: 8),
                          _buildInfoRow('시간', _formatTimestamp(event.timestamp)),
                          const SizedBox(height: 24),
                          // 예전엔 닫기/확인 버튼이 따로 있었는데 둘 다 그냥 팝업을 닫기만
                          // 해서(동작 차이 없음) 하나로 합쳤다.
                          SizedBox(
                            width: double.infinity,
                            child: GestureDetector(
                              onTap: () => Navigator.of(context).pop(),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                decoration: BoxDecoration(
                                  color: _getBorderColor(),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Center(
                                  child: Text(
                                    '확인',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Close button (always reachable, even if content overflows / back button is unavailable)
              Positioned(
                top: 12,
                right: 12,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.3),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, size: 18, color: Color(0xFFE2E8F0)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 16, color: Color(0xFF9CA3AF))),
        Text(value, style: const TextStyle(fontSize: 16, color: Color(0xFFE2E8F0))),
      ],
    );
  }

  Color _getBorderColor() {
    switch (event.eventType) {
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

  String _formatTimestamp(String ts) {
    try {
      final dt = DateTime.parse(ts);
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
    } catch (_) {
      return ts;
    }
  }
}
