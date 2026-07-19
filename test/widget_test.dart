// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stealth_eye/main.dart';
import 'package:stealth_eye/services/settings_service.dart';
import 'package:stealth_eye/services/sse_service.dart';
import 'package:stealth_eye/services/notification_service.dart';
import 'package:stealth_eye/services/tflite_service.dart';

void main() {
  testWidgets('EchoVisionApp builds without crashing', (WidgetTester tester) async {
    final settingsService = SettingsService();
    final sseService = SSEService();
    final tfliteService = TFLiteService();
    final notificationService = NotificationService(settingsService);

    // Build our app and trigger a frame.
    await tester.pumpWidget(EchoVisionApp(
      settingsService: settingsService,
      sseService: sseService,
      notificationService: notificationService,
      tfliteService: tfliteService,
    ));

    // Verify that the app renders its root MaterialApp.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
