import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'models/event_model.dart';
import 'services/sse_service.dart';
import 'services/notification_service.dart';
import 'services/tflite_service.dart';
import 'services/settings_service.dart';
import 'services/history_service.dart';
import 'screens/home_screen.dart';
import 'screens/event_screen.dart';

/// 알림을 탭했을 때 이동할 화면을 위해 전역 Navigator에 접근하는 키.
/// 알림 콜백(특히 백그라운드/콜드스타트)에는 특정 위젯의 BuildContext가 없으므로
/// 이 키로 대신 화면을 띄운다.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

/// 알림이 백그라운드(앱이 안 떠 있는 상태)에서 탭됐을 때 호출되는 최상위 콜백.
/// 실제 화면 이동은 콜드스타트 시 main()의 getNotificationAppLaunchDetails()가
/// 처리한다(그때 비로소 위젯 트리/Navigator가 생기므로) — 여기서는 할 일이 없다.
@pragma('vm:entry-point')
void _notificationTapBackground(NotificationResponse response) {}

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

  await _initLocalNotifications();
  _initForegroundTask();

  final sseService = SSEService();
  sseService.setServerUrl(settingsService.serverUrl);

  final notificationService = NotificationService(settingsService);
  final historyService = HistoryService();

  await sseService.connect();

  // 알림을 탭해서 앱이 콜드스타트된 경우 어떤 이벤트였는지 미리 확인해둔다.
  // 아직 위젯 트리가 없어서 지금 당장은 화면을 못 띄우니, runApp 이후 첫 프레임으로 미룬다.
  final launchDetails = await _localNotifications
      .getNotificationAppLaunchDetails();
  final launchEventId = (launchDetails?.didNotificationLaunchApp ?? false)
      ? launchDetails!.notificationResponse?.payload
      : null;

  runApp(
    EchoVisionApp(
      settingsService: settingsService,
      sseService: sseService,
      notificationService: notificationService,
      tfliteService: tfliteService,
      historyService: historyService,
    ),
  );

  if (launchEventId != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      openEventFromNotification(launchEventId);
    });
  }
}

/// 알림 payload(eventId)로 로컬 이력(HistoryService — 백그라운드 isolate가
/// 이벤트를 받을 때마다 저장해둔 것)에서 이벤트를 찾아 상세 화면(팝업)을 띄운다.
/// 알림 탭(포그라운드)과 콜드스타트 양쪽에서 공용으로 쓴다.
Future<void> openEventFromNotification(String? eventId) async {
  if (eventId == null) return;

  final history = await HistoryService().load();
  EventModel? event;
  for (final e in history) {
    if (e.eventId == eventId) {
      event = e;
      break;
    }
  }
  if (event == null) return;

  final context = navigatorKey.currentContext;
  if (context == null) return;
  // navigatorKey.currentContext는 await 이후 방금 새로 읽은 "지금" 값이라
  // (위젯 State가 들고 있는 캡처된 context와 달리) stale해질 수 없다.
  showDialog(
    // ignore: use_build_context_synchronously
    context: context,
    barrierDismissible: false,
    builder: (_) => EventScreen(event: event!),
  );
}

Future<void> _initLocalNotifications() async {
  const androidSettings = AndroidInitializationSettings('ic_notification');
  await _localNotifications.initialize(
    settings: const InitializationSettings(android: androidSettings),
    onDidReceiveNotificationResponse: (response) {
      openEventFromNotification(response.payload);
    },
    onDidReceiveBackgroundNotificationResponse: _notificationTapBackground,
  );
}

/// 백그라운드(앱 종료 상태 포함) 감시를 위한 Foreground Service 설정.
/// 실제 태스크 핸들러는 lib/services/background_sse_handler.dart 참고.
void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'echo_vision_watch',
      channelName: 'Echo Vision 감시',
      channelDescription: '백그라운드에서 현관 이벤트를 감시하는 동안 표시됩니다.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      iconData: const NotificationIconData(
        resType: ResourceType.mipmap,
        resPrefix: ResourcePrefix.ic,
        name: 'launcher',
      ),
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: const ForegroundTaskOptions(
      // 주기적으로 할 일이 없어서(연결은 TaskHandler.onStart에서 한 번 시작하면
      // 알아서 재시도 루프를 도니까) onRepeatEvent는 안 쓴다 — 한 번만.
      interval: 60000,
      isOnceEvent: true,
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
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
      navigatorKey: navigatorKey,
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
