import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../models/event_model.dart';
import '../models/heartbeat_status.dart';
import '../models/severity.dart';
import '../services/sse_service.dart';
import '../services/notification_service.dart';
import '../services/tflite_service.dart';
import '../services/settings_service.dart';
import '../services/history_service.dart';
import 'event_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final SSEService sseService;
  final NotificationService notificationService;
  final TFLiteService tfliteService;
  final SettingsService settingsService;
  final HistoryService historyService;

  const HomeScreen({
    super.key,
    required this.sseService,
    required this.notificationService,
    required this.tfliteService,
    required this.settingsService,
    required this.historyService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  StreamSubscription<EventModel>? _eventSubscription;
  StreamSubscription<EventModel>? _loiterSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  bool _isConnected = false;
  EventModel? _lastEvent;
  final List<EventModel> _eventHistory = [];

  HeartbeatStatus? _heartbeat;
  bool _loadingHeartbeat = true;
  Timer? _heartbeatTimer;

  @override
  void initState() {
    super.initState();
    _isConnected = widget.sseService.isConnected;
    _loadHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybePromptBatteryOptimization();
    });

    _refreshHeartbeat();
    // 1~5분 간격 권장 범위 안에서 2분마다 폴링 — 홈 화면에 머무는 동안만.
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 2), (_) => _refreshHeartbeat());

    _connectionSubscription = widget.sseService.connectionStream.listen((connected) {
      if (mounted) setState(() => _isConnected = connected);
    });

    // v2 전용: 체류 확인(loiter) 보고가 다른 클라이언트/재연결에서 들어오면
    // 새 알림을 띄우지 않고 해당 이벤트 카드만 갱신한다. v1 서버는 이 메시지를 보내지 않으므로 그냥 안 쓰인다.
    _loiterSubscription = widget.sseService.loiterStream.listen((update) {
      if (!mounted || update.eventId == null) return;
      setState(() {
        for (final e in _eventHistory) {
          if (e.eventId == update.eventId) {
            e.loiterConfirmed = true;
          }
        }
        if (_lastEvent?.eventId == update.eventId) {
          _lastEvent!.loiterConfirmed = true;
        }
      });
      // 저장은 안 함 — 백그라운드 isolate(background_sse_handler.dart)가 같은 이벤트를
      // 받아서 이미 영구저장까지 했다. 여기서 또 read-modify-write 하면 서로 다른
      // 시점에 읽은 리스트를 덮어써서 최신 항목이 사라지는 경합이 생긴다.
    });

    _eventSubscription = widget.sseService.eventStream.listen((event) async {
      if (!mounted) return;
      setState(() {
        _lastEvent = event;
        // 화면 표시용으로만 낙관적 추가 — 영구저장은 백그라운드 isolate 전담(위 참고).
        _eventHistory.insert(0, event);
        if (_eventHistory.length > 50) _eventHistory.removeLast();
      });

      if (event.image != null) {
        final bytes = await widget.sseService.downloadSnapshot(event.image!);
        if (bytes != null) {
          event.snapshotBytes = bytes;
          // 카메라 피드에 방금 받은 사진을 바로 보여주기 위한 갱신.
          if (mounted) setState(() {});

          // EMERGENCY는 비전 분석(사람/택배 판별) 자체를 건너뛴다 — 사진 다운로드는
          // 타입 상관없이 항상 하되, 체류 확인 로직만 스킵한다.
          if (!event.bypassVision) {
            final result = await widget.tfliteService.analyzeImage(bytes);
            event.visionResult = result;
            // v2(app_v2.py) 전용: 사람으로 판정되면 서버에 체류 확인을 보고해
            // 다른 기기/재연결 클라이언트에도 동기화한다. v1 서버는 해당 엔드포인트가
            // 없어 조용히 실패하므로 그냥 무시된다(SSEService.reportLoiterConfirmed 참고).
            if (result == VisionResult.person && event.eventId != null) {
              await widget.sseService.reportLoiterConfirmed(event.eventId!);
            }
          }
        }
      }

      await widget.notificationService.triggerAlert(event);

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => EventScreen(event: event, sseService: widget.sseService),
        );
      }
    });
  }

  Future<void> _refreshHeartbeat() async {
    final status = await widget.sseService.getHeartbeatStatus();
    if (!mounted) return;
    setState(() {
      _heartbeat = status;
      _loadingHeartbeat = false;
    });
  }

  Future<void> _loadHistory() async {
    final saved = await widget.historyService.load();
    if (!mounted || saved.isEmpty) return;
    setState(() {
      _eventHistory.addAll(saved);
      _lastEvent ??= saved.first;
    });
    await _ensureLastEventSnapshot();
  }

  /// 스냅샷 바이트는 용량 문제로 이력에 영구저장하지 않으므로(HistoryService 참고),
  /// 앱을 다시 켰을 때는 가장 최근 이벤트 사진이 비어있다 — 카메라 피드에 보여주려면
  /// 파일명(image)으로 한 번 다시 받아와야 한다.
  Future<void> _ensureLastEventSnapshot() async {
    final event = _lastEvent;
    if (event == null || event.image == null || event.snapshotBytes != null) {
      return;
    }
    final bytes = await widget.sseService.downloadSnapshot(event.image!);
    if (bytes != null && mounted) {
      setState(() => event.snapshotBytes = bytes);
    }
  }

  /// 앱을 처음 켰을 때 딱 한 번, 배터리 최적화 제외를 안내한다.
  /// 이걸 안 해두면 기기가 백그라운드 감시 서비스를 강제로 죽일 수 있어서
  /// (특히 앱을 완전히 종료한 상태에서) 핵심 기능이 조용히 멈출 수 있다.
  /// "나중에"를 눌러도 설정 탭 > 백그라운드 감시에서 언제든 다시 허용 가능.
  Future<void> _maybePromptBatteryOptimization() async {
    if (widget.settingsService.batteryPromptShown) return;
    if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      widget.settingsService.batteryPromptShown = true;
      return;
    }
    if (!mounted) return;

    widget.settingsService.batteryPromptShown = true;
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1E2535),
        title: const Text('배터리 최적화 제외', style: TextStyle(color: Color(0xFFE2E8F0))),
        content: const Text(
          '기기가 앱을 강제로 꺼버리면 완전히 종료한 상태에서는 알림이 오지 않을 수 있어요. '
          '배터리 최적화에서 Echo Vision을 제외해주세요.',
          style: TextStyle(color: Color(0xFF9CA3AF)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('나중에', style: TextStyle(color: Color(0xFF6B7280))),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              FlutterForegroundTask.requestIgnoreBatteryOptimization();
            },
            child: const Text('허용하기', style: TextStyle(color: Color(0xFF3B82F6))),
          ),
        ],
      ),
    );
  }

  /// 이력 탭의 삭제 버튼(확인 다이얼로그는 HistoryScreen에서 이미 거침)에서 호출.
  Future<void> _clearHistory() async {
    await widget.historyService.clear();
    if (!mounted) return;
    setState(() {
      _eventHistory.clear();
      _lastEvent = null;
    });
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _loiterSubscription?.cancel();
    _connectionSubscription?.cancel();
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  void _simulateEvent(EventType type, {int severity = 1}) async {
    final now = DateTime.now();
    final event = EventModel(
      eventType: type,
      severity: severity,
      confidence: 0.85, // 임시값 (테스트 버튼용)
      time: _formatTime(now),
      timestamp: now.toIso8601String(),
    );
    setState(() {
      _lastEvent = event;
      _eventHistory.insert(0, event);
    });
    widget.historyService.save(_eventHistory);
    await widget.notificationService.triggerAlert(event);
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => EventScreen(event: event, sseService: widget.sseService),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Container(
            width: double.infinity,
            height: double.infinity,
            color: const Color(0xFF1A1A2E),
            child: _buildCurrentTab(),
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildCurrentTab() {
    switch (_currentIndex) {
      case 0:
        return _buildHomeTab();
      case 1:
        return HistoryScreen(
          sseService: widget.sseService,
          eventHistory: _eventHistory,
          onClear: _clearHistory,
        );
      case 2:
        return SettingsScreen(
          settingsService: widget.settingsService,
          sseService: widget.sseService,
          historyService: widget.historyService,
          onTestEvent: _simulateEvent,
        );
      default:
        return _buildHomeTab();
    }
  }

  Widget _buildHomeTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 16, bottom: 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: MediaQuery.of(context).padding.top),
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Echo Vision',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFE2E8F0),
                  letterSpacing: -0.5,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _isConnected ? const Color(0xFF0D3D1F) : const Color(0xFF3D0D0D),
                  borderRadius: BorderRadius.circular(50),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _isConnected ? const Color(0xFF4ADE80) : const Color(0xFFEF4444),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isConnected ? '감시 중' : '연결 끊김',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: _isConnected ? const Color(0xFF4ADE80) : const Color(0xFFEF4444),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildHeartbeatBadge(),
          const SizedBox(height: 20),
          // Camera Preview — 가장 최근 이벤트 사진이 있으면 그걸, 없으면 자리표시자
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: _lastEvent?.snapshotBytes != null
                  ? Image.memory(
                      _lastEvent!.snapshotBytes!,
                      fit: BoxFit.cover,
                    )
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.videocam_outlined, size: 48, color: Colors.white.withValues(alpha: 0.3)),
                          const SizedBox(height: 8),
                          Text(
                            '카메라 피드',
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 16),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 20),
          // Last Event Card
          if (_lastEvent != null)
            _buildEventCard(_lastEvent!)
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2535),
                borderRadius: BorderRadius.circular(12),
                border: const Border(
                  left: BorderSide(color: Color(0xFF3B82F6), width: 4),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        '대기 중',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF3B82F6),
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '이벤트를 기다리고 있습니다',
                        style: TextStyle(fontSize: 16, color: Color(0xFF9CA3AF)),
                      ),
                    ],
                  ),
                  Text(
                    _formatTime(DateTime.now()),
                    style: const TextStyle(fontSize: 16, color: Color(0xFF9CA3AF)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          // Status Grid
          Row(
            children: [
              _buildStatusTile(
                icon: Icons.flash_on,
                label: '플래시',
                color: widget.settingsService.flashEnabled ? const Color(0xFFFACC15) : const Color(0xFF6B7280),
                enabled: widget.settingsService.flashEnabled,
              ),
              const SizedBox(width: 12),
              _buildStatusTile(
                icon: Icons.waves,
                label: '진동',
                color: widget.settingsService.hapticEnabled ? const Color(0xFFA78BFA) : const Color(0xFF6B7280),
                enabled: widget.settingsService.hapticEnabled,
              ),
              const SizedBox(width: 12),
              _buildStatusTile(
                icon: widget.settingsService.soundEnabled ? Icons.volume_up : Icons.volume_off,
                label: widget.settingsService.soundEnabled ? '소리 켜짐' : '소리 꺼짐',
                color: widget.settingsService.soundEnabled ? const Color(0xFF3B82F6) : const Color(0xFF6B7280),
                enabled: widget.settingsService.soundEnabled,
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Test Buttons
          const Text(
            '알림 팝업 미리보기',
            style: TextStyle(fontSize: 16, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildTestButton('노크', const Color(0xFF0F2744), const Color(0xFF3B82F6), EventType.knock, severity: 1),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTestButton('초인종', const Color(0xFF0F2744), const Color(0xFF3B82F6), EventType.doorbell, severity: 1),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildTestButton('도어락 오류', const Color(0xFF2D1A00), const Color(0xFFFB923C), EventType.doorlockError, severity: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTestButton('도어락 경보', const Color(0xFF2D0F0F), const Color(0xFFEF4444), EventType.doorlockAlarm, severity: 3),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildTestButton('화재', const Color(0xFF2D0F0F), const Color(0xFFEF4444), EventType.emergency, severity: 3),
              ),
              const SizedBox(width: 12),
              const Expanded(child: SizedBox()),
            ],
          ),
        ],
      ),
    );
  }

  /// 기기 자가진단 상태 배지. 정상이면 조용히 초록, 이상이 있으면 색+아이콘으로
  /// 심각도를 알리고 탭하면 상세 목록을 보여준다(rev.4 섹션 5).
  Widget _buildHeartbeatBadge() {
    final awayMode = widget.settingsService.awayMode;
    if (_loadingHeartbeat) {
      return const SizedBox.shrink();
    }
    if (_heartbeat == null) {
      // 조회 실패(연결 안 됨 등)는 별도로 크게 떠들지 않는다 — 상단 연결 배지가
      // 이미 "연결 끊김"을 보여주고 있으므로 중복 경고를 피한다.
      return const SizedBox.shrink();
    }

    final evaluation = evaluateHeartbeat(_heartbeat!, awayModeSuppresses24hWarning: awayMode);
    final Color badgeColor;
    final IconData badgeIcon;
    final String badgeText;
    switch (evaluation.level) {
      case DeviceHealthLevel.critical:
        badgeColor = const Color(0xFFEF4444);
        badgeIcon = Icons.error_outline;
        badgeText = '기기 이상 ${evaluation.issues.length}건';
        break;
      case DeviceHealthLevel.warning:
        badgeColor = const Color(0xFFFB923C);
        badgeIcon = Icons.warning_amber_rounded;
        badgeText = '확인 필요 ${evaluation.issues.length}건';
        break;
      case DeviceHealthLevel.normal:
        badgeColor = const Color(0xFF4ADE80);
        badgeIcon = Icons.check_circle_outline;
        badgeText = '기기 정상';
        break;
    }

    return GestureDetector(
      onTap: () => _showHeartbeatDetail(evaluation),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(50),
              border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(badgeIcon, size: 14, color: badgeColor),
                const SizedBox(width: 4),
                Text(badgeText, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: badgeColor)),
              ],
            ),
          ),
          if (awayMode) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF3B82F6).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(50),
                border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.4)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.luggage_outlined, size: 14, color: Color(0xFF3B82F6)),
                  SizedBox(width: 4),
                  Text('외출 중', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF3B82F6))),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showHeartbeatDetail(DeviceHealthEvaluation evaluation) {
    final status = _heartbeat!;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1E2535),
        title: Text(
          evaluation.isNormal ? '기기 정상' : '기기 상태 확인',
          style: const TextStyle(color: Color(0xFFE2E8F0)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (evaluation.isNormal)
              const Text('모든 항목이 정상입니다.', style: TextStyle(color: Color(0xFF9CA3AF)))
            else
              ...evaluation.issues.map(
                (issue) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('• $issue', style: const TextStyle(color: Color(0xFFE2E8F0))),
                ),
              ),
            const Divider(color: Color(0xFF2A2A3D), height: 24),
            Text(
              '마지막 응답: ${status.secondsSinceLast}초 전 · 마이크 ${status.micOk ? '정상' : '이상'} · '
              '웨이크핀 ${status.wakePinIdle} · 카메라 ${status.camOk ? '정상' : '이상'} · '
              '무음 ${status.hoursSinceSound.toStringAsFixed(1)}시간째',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('닫기', style: TextStyle(color: Color(0xFF3B82F6))),
          ),
        ],
      ),
    );
  }

  Widget _buildEventCard(EventModel event) {
    final color = colorForSeverity(event.severity);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2535),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: color, width: 4),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(iconForSeverity(event.severity), size: 15, color: color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        event.displayMessage,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  event.loiterConfirmed
                      ? '방문자 체류 확인'
                      : (event.visionResult?.displayName ?? event.eventType.emoji),
                  style: const TextStyle(fontSize: 16, color: Color(0xFF9CA3AF)),
                ),
              ],
            ),
          ),
          Text(
            _formatTime(DateTime.tryParse(event.timestamp) ?? DateTime.now()),
            style: const TextStyle(fontSize: 16, color: Color(0xFF9CA3AF)),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusTile({
    required IconData icon,
    required String label,
    required Color color,
    required bool enabled,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E2535),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestButton(String label, Color bgColor, Color textColor, EventType type, {int severity = 1}) {
    return GestureDetector(
      onTap: () => _simulateEvent(type, severity: severity),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D1A),
        border: Border(top: BorderSide(color: Color(0xFF2A2A3D))),
      ),
      padding: EdgeInsets.only(
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildNavItem(Icons.home_outlined, '홈', 0),
          _buildNavItem(Icons.access_time, '이력', 1),
          _buildNavItem(Icons.settings_outlined, '설정', 2),
        ],
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isSelected = _currentIndex == index;
    final color = isSelected ? const Color(0xFF3B82F6) : const Color(0xFF6B7280);
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: color)),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
