import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/alert_presets.dart';
import '../models/event_model.dart';
import '../models/mask_region.dart';
import '../services/history_service.dart';
import '../services/settings_service.dart';
import '../services/sse_service.dart';
import 'install_mode_screen.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService settingsService;
  final SSEService sseService;
  final HistoryService historyService;
  final Function(EventType) onTestEvent;

  const SettingsScreen({
    super.key,
    required this.settingsService,
    required this.sseService,
    required this.historyService,
    required this.onTestEvent,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _urlController;
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _ignoringBatteryOptimizations = false;
  MaskRegionsStatus? _maskRegionsStatus;
  bool _loadingMaskStatus = true;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.settingsService.serverUrl);
    _refreshBatteryOptimizationStatus();
    _refreshMaskRegionsStatus();
  }

  Future<void> _refreshMaskRegionsStatus() async {
    setState(() => _loadingMaskStatus = true);
    final status = await widget.sseService.getMaskRegionsStatus();
    if (mounted) {
      setState(() {
        _maskRegionsStatus = status;
        _loadingMaskStatus = false;
      });
    }
  }

  Future<void> _openInstallMode() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InstallModeScreen(
          sseService: widget.sseService,
          historyService: widget.historyService,
        ),
      ),
    );
    // 재설정을 마치고(또는 그냥 뒤로 나가도) 최신 상태로 갱신 — 저장 여부와 무관하게
    // 서버 값을 다시 조회하는 편이 낙관적 갱신보다 안전하다(저장 실패 케이스 포함).
    _refreshMaskRegionsStatus();
  }

  Future<void> _refreshBatteryOptimizationStatus() async {
    final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (mounted) setState(() => _ignoringBatteryOptimizations = ignoring);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
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
          const Text(
            '설정',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.bold,
              color: Color(0xFFE2E8F0),
            ),
          ),
          const SizedBox(height: 24),
          // Server URL Section
          _buildSectionTitle('서버 연결'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2535),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '서버 URL',
                  style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A0A14),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF2A2A3D)),
                        ),
                        child: TextField(
                          controller: _urlController,
                          style: const TextStyle(fontSize: 16, color: Color(0xFFE2E8F0)),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'http://192.168.0.100:5000',
                            hintStyle: TextStyle(color: Color(0xFF6B7280)),
                          ),
                          onSubmitted: (value) {
                            widget.settingsService.serverUrl = value;
                            widget.sseService.setServerUrl(value);
                            // connect()가 이미 떠 있으면 멈췄다가 새로 시작하므로
                            // disconnect()를 따로 부를 필요 없음.
                            widget.sseService.connect();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        widget.settingsService.serverUrl = _urlController.text;
                        widget.sseService.setServerUrl(_urlController.text);
                        widget.sseService.connect();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('서버에 재연결 중...'),
                            backgroundColor: const Color(0xFF3B82F6),
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF3B82F6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.refresh, color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Notification Settings
          _buildSectionTitle('알림 설정'),
          const SizedBox(height: 4),
          const Text(
            '이벤트 종류마다 플래시·진동·소리를 원하는 조합으로 켜고 끌 수 있어요.',
            style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 12),
          ...SettingsService.alertEventTypes.map(
            (type) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildEventAlertCard(type),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2535),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '소리 볼륨 (앱 실행 중)',
                      style: TextStyle(fontSize: 16, color: Color(0xFFE2E8F0)),
                    ),
                    Text(
                      '${(widget.settingsService.volume * 100).toInt()}%',
                      style: const TextStyle(fontSize: 16, color: Color(0xFF3B82F6)),
                    ),
                  ],
                ),
                Slider(
                  value: widget.settingsService.volume,
                  onChanged: (v) {
                    setState(() => widget.settingsService.volume = v);
                  },
                  activeColor: const Color(0xFF3B82F6),
                  inactiveColor: const Color(0xFF2A2A3D),
                ),
                const Text(
                  '앱이 꺼져 있을 때 오는 알림 소리는 이 값이 아니라 폰 자체의 알림 볼륨을 따라요 '
                  '(화재는 알람 볼륨을 따로 써서 더 잘 들리게 했어요).',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Background Watch Section
          _buildSectionTitle('백그라운드 감시'),
          const SizedBox(height: 4),
          const Text(
            '앱을 완전히 꺼도 알림이 오게 하려면 아래 두 가지를 허용해주세요.',
            style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 12),
          _buildActionRow(
            icon: Icons.battery_saver,
            iconColor: _ignoringBatteryOptimizations
                ? const Color(0xFF4ADE80)
                : const Color(0xFFFACC15),
            title: '배터리 최적화 제외',
            subtitle: _ignoringBatteryOptimizations
                ? '허용됨 — 백그라운드 감시가 계속 유지돼요'
                : '기기가 앱을 강제로 꺼버리지 않도록 허용해주세요',
            buttonLabel: _ignoringBatteryOptimizations ? '완료' : '허용하기',
            onTap: _ignoringBatteryOptimizations
                ? null
                : () async {
                    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
                    await _refreshBatteryOptimizationStatus();
                  },
          ),
          const SizedBox(height: 8),
          _buildActionRow(
            icon: Icons.warning_amber_rounded,
            iconColor: const Color(0xFFEF4444),
            title: '긴급 알림 잠금화면 표시',
            subtitle: '화재 등 긴급 상황은 화면이 잠겨 있어도 바로 보이게 할 수 있어요',
            buttonLabel: '허용하기',
            onTap: () {
              _notifications
                  .resolvePlatformSpecificImplementation<
                      AndroidFlutterLocalNotificationsPlugin>()
                  ?.requestFullScreenIntentPermission();
            },
          ),
          const SizedBox(height: 24),
          // Neighbor Privacy Masking
          _buildSectionTitle('이웃 프라이버시'),
          const SizedBox(height: 4),
          const Text(
            '복도형 구조 등에서 이웃집 문이 함께 찍힌다면, 해당 영역을 가리도록 설정할 수 있어요.',
            style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 12),
          _buildActionRow(
            icon: Icons.privacy_tip_outlined,
            iconColor: (_maskRegionsStatus?.configured ?? false)
                ? const Color(0xFF4ADE80)
                : const Color(0xFF3B82F6),
            title: '이웃 프라이버시 마스킹',
            subtitle: _loadingMaskStatus
                ? '상태 확인 중...'
                : (_maskRegionsStatus?.configured ?? false)
                    ? '${_maskRegionsStatus!.regionCount}개 영역 설정됨'
                    : '설정 안 됨 (권장)',
            buttonLabel: (_maskRegionsStatus?.configured ?? false) ? '재설정' : '설정하기',
            onTap: _openInstallMode,
          ),
          const SizedBox(height: 24),
          // App Info
          _buildSectionTitle('앱 정보'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2535),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _buildInfoRow('앱 이름', 'Echo Vision'),
                const Divider(color: Color(0xFF2A2A3D), height: 24),
                _buildInfoRow('버전', '1.0.0'),
                const Divider(color: Color(0xFF2A2A3D), height: 24),
                _buildInfoRow('설정', '환경설정'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Color(0xFF9CA3AF),
        letterSpacing: 0.5,
      ),
    );
  }

  /// 이벤트 타입 하나에 대한 플래시/진동/소리 조합 설정 카드
  Widget _buildEventAlertCard(EventType type) {
    final config = widget.settingsService.alertConfigFor(type);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2535),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(type.emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Text(
                type.displayName,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFFE2E8F0)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildChannelChip(
                icon: Icons.flash_on,
                label: '플래시',
                selected: config.flash,
                onTap: () {
                  setState(() {
                    widget.settingsService.setAlertConfigFor(type, config.copyWith(flash: !config.flash));
                  });
                },
              ),
              _buildChannelChip(
                icon: Icons.waves,
                label: '진동',
                selected: config.haptic,
                onTap: () {
                  setState(() {
                    widget.settingsService.setAlertConfigFor(type, config.copyWith(haptic: !config.haptic));
                  });
                },
              ),
              _buildChannelChip(
                icon: Icons.volume_up,
                label: '소리',
                selected: config.sound,
                onTap: () {
                  setState(() {
                    widget.settingsService.setAlertConfigFor(type, config.copyWith(sound: !config.sound));
                  });
                },
              ),
            ],
          ),
          if (config.flash) ...[
            const SizedBox(height: 10),
            _buildPresetRow<FlashPreset>(
              label: '플래시 길이',
              options: FlashPreset.values,
              selected: config.flashPreset,
              displayName: (p) => p.displayName,
              onSelect: (p) {
                setState(() {
                  widget.settingsService.setAlertConfigFor(type, config.copyWith(flashPreset: p));
                });
              },
            ),
          ],
          if (config.haptic) ...[
            const SizedBox(height: 10),
            _buildPresetRow<VibrationPreset>(
              label: '진동 스타일',
              options: VibrationPreset.values,
              selected: config.vibrationPreset,
              displayName: (p) => p.displayName,
              onSelect: (p) {
                setState(() {
                  widget.settingsService.setAlertConfigFor(type, config.copyWith(vibrationPreset: p));
                });
              },
            ),
          ],
        ],
      ),
    );
  }

  /// 프리셋(짧게/보통/길게 등) 고르는 작은 알약 버튼 줄 — 플래시 길이/진동 스타일 공용
  Widget _buildPresetRow<T>({
    required String label,
    required List<T> options,
    required T selected,
    required String Function(T) displayName,
    required ValueChanged<T> onSelect,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: options.map((option) {
            final isSelected = option == selected;
            return GestureDetector(
              onTap: () => onSelect(option),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected ? const Color(0xFF3B82F6) : const Color(0xFF0A0A14),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isSelected ? const Color(0xFF3B82F6) : const Color(0xFF2A2A3D),
                  ),
                ),
                child: Text(
                  displayName(option),
                  style: TextStyle(
                    fontSize: 12,
                    color: isSelected ? Colors.white : const Color(0xFF9CA3AF),
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  /// 켜기/끄기가 가능한 알림 채널 칩 (플래시/진동/소리 공용)
  Widget _buildChannelChip({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    const activeColor = Color(0xFF3B82F6);
    const inactiveColor = Color(0xFF6B7280);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? activeColor.withValues(alpha: 0.15) : const Color(0xFF0A0A14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? activeColor : const Color(0xFF2A2A3D)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? activeColor : inactiveColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: selected ? activeColor : inactiveColor,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 상태 문구 + 허용 버튼 한 줄 (배터리 최적화 제외, 잠금화면 알림 등 온보딩용)
  Widget _buildActionRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String buttonLabel,
    required VoidCallback? onTap,
  }) {
    final done = onTap == null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2535),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFFE2E8F0))),
                Text(subtitle, style: const TextStyle(fontSize: 14, color: Color(0xFF9CA3AF))),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: done ? const Color(0xFF0A0A14) : const Color(0xFF3B82F6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                buttonLabel,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: done ? const Color(0xFF6B7280) : Colors.white,
                ),
              ),
            ),
          ),
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
}
