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
          const SizedBox(height: 12),
          _buildToggleTile(
            icon: Icons.flash_on,
            iconColor: const Color(0xFFFACC15),
            title: '플래시 점멸',
            subtitle: '위협/화재 시 후면 플래시 점멸',
            value: widget.settingsService.flashEnabled,
            onChanged: (v) {
              setState(() => widget.settingsService.flashEnabled = v);
            },
          ),
          const SizedBox(height: 8),
          _buildToggleTile(
            icon: Icons.waves,
            iconColor: const Color(0xFFA78BFA),
            title: '햅틱 진동',
            subtitle: '이벤트 유형별 진동 패턴',
            value: widget.settingsService.hapticEnabled,
            onChanged: (v) {
              setState(() => widget.settingsService.hapticEnabled = v);
            },
          ),
          const SizedBox(height: 8),
          _buildToggleTile(
            icon: Icons.volume_up,
            iconColor: const Color(0xFF3B82F6),
            title: '소리 알림',
            subtitle: '이벤트 유형별 알림음 재생',
            value: widget.settingsService.soundEnabled,
            onChanged: (v) {
              setState(() => widget.settingsService.soundEnabled = v);
            },
          ),
          if (widget.settingsService.soundEnabled) ...[
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
                        '볼륨',
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
          ],
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

  Widget _buildToggleTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
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
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: const Color(0xFF3B82F6),
            activeTrackColor: const Color(0xFF3B82F6).withValues(alpha: 0.3),
            inactiveThumbColor: const Color(0xFF6B7280),
            inactiveTrackColor: const Color(0xFF2A2A3D),
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
