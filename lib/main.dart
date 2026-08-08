import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/sse_service.dart';
import 'services/notification_service.dart';
import 'services/tflite_service.dart';
import 'services/settings_service.dart';
import 'services/history_service.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0D0D1A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // 앱 시작 시 필수 권한 요청
  await _requestPermissions();

  final settingsService = SettingsService();
  await settingsService.init();

  final tfliteService = TFLiteService();
  await tfliteService.init();

  final sseService = SSEService();
  sseService.setServerUrl(settingsService.serverUrl);

  final notificationService = NotificationService(settingsService);
  final historyService = HistoryService();

  sseService.connect();

  runApp(
    EchoVisionApp(
      settingsService: settingsService,
      sseService: sseService,
      notificationService: notificationService,
      tfliteService: tfliteService,
      historyService: historyService,
    ),
  );
}

/// 앱 시작 시 필수 권한을 한꺼번에 요청
/// - 알림 (Android 13+)
/// 카메라 권한은 요청하지 않음 — torch_light는 CameraManager.setTorchMode()로 플래시를 제어하며
/// API 23+(본 앱 minSdk 24)에서는 카메라 런타임 권한 없이 동작하므로 불필요.
/// 마이크 권한은 요청하지 않음 — 커스텀 소리 등록 기능을 제외하기로 해서 더 이상 불필요.
Future<void> _requestPermissions() async {
  try {
    final permissions = <Permission>[
      Permission.notification, // 알림 표시용 (Android 13+)
    ];

    // 한번에 모든 권한 요청
    final statuses = await permissions.request();

    for (final entry in statuses.entries) {
      final name = entry.key.toString();
      final status = entry.value;
      debugPrint('권한 $name: $status');
    }
  } catch (e) {
    // 웹에서는 permission_handler가 작동하지 않으므로 무시
    debugPrint('권한 요청 건너뜀 (웹 환경): $e');
  }
}

class EchoVisionApp extends StatelessWidget {
  final SettingsService settingsService;
  final SSEService sseService;
  final NotificationService notificationService;
  final TFLiteService tfliteService;
  final HistoryService historyService;

  const EchoVisionApp({
    super.key,
    required this.settingsService,
    required this.sseService,
    required this.notificationService,
    required this.tfliteService,
    required this.historyService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Echo Vision',
      debugShowCheckedModeBanner: false,
      scrollBehavior:
          const MaterialScrollBehavior().copyWith(overscroll: false),
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1A1A2E),
        primaryColor: const Color(0xFF3B82F6),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF4ADE80),
          surface: Color(0xFF1E2535),
          error: Color(0xFFEF4444),
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 16, color: Color(0xFFE2E8F0)),
          bodyMedium: TextStyle(fontSize: 16, color: Color(0xFFE2E8F0)),
          bodySmall: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
        ),
      ),
      home: HomeScreen(
        sseService: sseService,
        notificationService: notificationService,
        tfliteService: tfliteService,
        settingsService: settingsService,
        historyService: historyService,
      ),
    );
  }
}
