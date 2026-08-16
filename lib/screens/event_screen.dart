import 'dart:async';
import 'package:flutter/material.dart';
import '../models/event_model.dart';
import '../models/severity.dart';
import '../services/sse_service.dart';

class EventScreen extends StatefulWidget {
  final EventModel event;

  /// 영상 준비 완료(video_ready) 실시간 갱신을 위한 스트림 소스. 알림 탭으로
  /// 콜드스타트된 경로(main.dart)처럼 마땅한 인스턴스가 없으면 null로 둬도 된다
  /// — 그 경우 팝업이 떠 있는 동안의 실시간 갱신만 안 될 뿐, 이미 이력에 저장된
  /// video 값은 그대로 정상 표시된다.
  final SSEService? sseService;

  const EventScreen({super.key, required this.event, this.sseService});

  @override
  State<EventScreen> createState() => _EventScreenState();
}

class _EventScreenState extends State<EventScreen> {
  StreamSubscription<Map<String, dynamic>>? _videoReadySubscription;

  @override
  void initState() {
    super.initState();
    _videoReadySubscription = widget.sseService?.videoReadyStream.listen((json) {
      if (!mounted || json['event_id'] != widget.event.eventId) return;
      setState(() {
        widget.event.video = json['video'] as String?;
        widget.event.videoPending = false;
      });
    });
  }

  @override
  void dispose() {
    _videoReadySubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final color = colorForSeverity(event.severity);
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
            border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.2),
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
                            color.withValues(alpha: 0.15),
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
                          const SizedBox(height: 12),
                          // 색상만으로 심각도를 구분하지 않는다 — 아이콘 + 라벨을 함께.
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(50),
                              border: Border.all(color: color.withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(iconForSeverity(event.severity), size: 14, color: color),
                                const SizedBox(width: 4),
                                Text(
                                  labelForSeverity(event.severity),
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            event.displayMessage,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: color,
                            ),
                          ),
                          if (event.visionResult != null) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.1),
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
                    // Video pending/ready
                    if (event.videoPending || event.video != null) ...[
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: event.video != null
                              ? _buildVideoReady(color)
                              : _buildVideoPending(),
                        ),
                      ),
                    ],
                    // Info
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          if (event.confidence != null) ...[
                            _buildInfoRow('신뢰도', '${(event.confidence! * 100).toStringAsFixed(0)}%'),
                            const SizedBox(height: 8),
                          ],
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
                                  color: color,
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

  /// 영상 대기 중 플레이스홀더. 로딩 스피너는 일부러 안 쓴다 — 최대 30분씩
  /// 걸릴 수 있어서 계속 돌면 사용자가 "멈췄나?" 오해한다.
  Widget _buildVideoPending() {
    return Container(
      key: const ValueKey('video-pending'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2535),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        children: [
          Icon(Icons.videocam_outlined, size: 28, color: Color(0xFF9CA3AF)),
          SizedBox(height: 8),
          Text('영상 준비 중', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFE2E8F0))),
          SizedBox(height: 4),
          Text('최대 30분 정도 걸릴 수 있어요', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
        ],
      ),
    );
  }

  Widget _buildVideoReady(Color color) {
    return Container(
      key: const ValueKey('video-ready'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2535),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Icon(Icons.play_circle_outline, size: 32, color: color),
          const SizedBox(height: 6),
          const Text('영상 준비 완료', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFE2E8F0))),
        ],
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

  String _formatTimestamp(String ts) {
    try {
      final dt = DateTime.parse(ts);
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
    } catch (_) {
      return ts;
    }
  }
}
