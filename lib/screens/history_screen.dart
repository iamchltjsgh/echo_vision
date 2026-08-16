import 'package:flutter/material.dart';
import '../models/event_model.dart';
import '../models/severity.dart';
import '../services/sse_service.dart';
import 'event_screen.dart';

class HistoryScreen extends StatelessWidget {
  final SSEService sseService;
  final List<EventModel> eventHistory;
  final VoidCallback onClear;

  const HistoryScreen({
    super.key,
    required this.sseService,
    required this.eventHistory,
    required this.onClear,
  });

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1E2535),
        title: const Text('이력을 모두 삭제할까요?', style: TextStyle(color: Color(0xFFE2E8F0))),
        content: const Text(
          '삭제하면 되돌릴 수 없어요.',
          style: TextStyle(color: Color(0xFF9CA3AF)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소', style: TextStyle(color: Color(0xFF6B7280))),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제', style: TextStyle(color: Color(0xFFEF4444))),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      onClear();
    }
  }

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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '이벤트 이력',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFE2E8F0),
                ),
              ),
              if (eventHistory.isNotEmpty)
                GestureDetector(
                  onTap: () => _confirmClear(context),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E2535),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFEF4444)),
                  ),
                ),
            ],
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
              final dt = DateTime.tryParse(event.timestamp) ?? DateTime.now();
              return _HistoryEventTile(
                sseService: sseService,
                event: event,
                borderColor: colorForSeverity(event.severity),
                timestamp: dt,
              );
            }),
        ],
      ),
    );
  }
}

/// 이력 리스트 한 항목. 탭하면 스냅샷을 보여준다.
/// 스냅샷 바이트는 이력에 영구저장하지 않으므로(HistoryService 참고) event.image
/// 파일명으로 서버에서 다시 받아온 뒤(아직 없을 때만), EventScreen을 그대로 재사용해 띄운다.
class _HistoryEventTile extends StatefulWidget {
  final SSEService sseService;
  final EventModel event;
  final Color borderColor;
  final DateTime timestamp;

  const _HistoryEventTile({
    required this.sseService,
    required this.event,
    required this.borderColor,
    required this.timestamp,
  });

  @override
  State<_HistoryEventTile> createState() => _HistoryEventTileState();
}

class _HistoryEventTileState extends State<_HistoryEventTile> {
  bool _loading = false;

  Future<void> _open() async {
    if (_loading) return;
    final event = widget.event;
    if (event.snapshotBytes == null && event.image != null) {
      setState(() => _loading = true);
      final bytes = await widget.sseService.downloadSnapshot(event.image!);
      if (bytes != null) event.snapshotBytes = bytes;
      if (!mounted) return;
      setState(() => _loading = false);
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => EventScreen(event: event, sseService: widget.sseService),
    );
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: _open,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2535),
            borderRadius: BorderRadius.circular(12),
            border: Border(
              left: BorderSide(color: widget.borderColor, width: 4),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(event.eventType.emoji, style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              // 색상만으로 심각도를 구분하지 않는다 — 아이콘도 함께.
                              Icon(iconForSeverity(event.severity), size: 13, color: widget.borderColor),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  event.displayMessage,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: widget.borderColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (event.confidence != null)
                            Text(
                              '신뢰도 ${(event.confidence! * 100).toStringAsFixed(0)}%',
                              style: const TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
                            ),
                          if (event.videoPending || event.video != null) ...[
                            const SizedBox(height: 4),
                            _buildVideoBadge(event),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF9CA3AF),
                      ),
                    )
                  : Text(
                      '${widget.timestamp.hour.toString().padLeft(2, '0')}:${widget.timestamp.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(fontSize: 16, color: Color(0xFF9CA3AF)),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoBadge(EventModel event) {
    final ready = event.video != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ready ? Icons.play_circle_outline : Icons.videocam_outlined,
            size: 12,
            color: ready ? const Color(0xFF4ADE80) : const Color(0xFF9CA3AF),
          ),
          const SizedBox(width: 3),
          Text(
            ready ? '영상 재생 가능' : '영상 준비 중',
            style: TextStyle(
              fontSize: 11,
              color: ready ? const Color(0xFF4ADE80) : const Color(0xFF9CA3AF),
            ),
          ),
        ],
      ),
    );
  }
}
