import 'package:flutter/material.dart';
import '../models/event_model.dart';
import '../services/settings_service.dart';
import '../services/sse_service.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService settingsService;
  final SSEService sseService;
  final Function(EventType) onTestEvent;

  const SettingsScreen({
    super.key,
    required this.settingsService,
    required this.sseService,
    required this.onTestEvent,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.settingsService.serverUrl);
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
                            widget.sseService.disconnect();
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
                        widget.sseService.disconnect();
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
                      '소리 볼륨 (공통)',
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
              ],
            ),
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
        ],
      ),
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
