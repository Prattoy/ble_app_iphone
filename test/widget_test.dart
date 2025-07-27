// This is a basic Flutter widget test for the LED Control BLE app.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:led_control_ble/main.dart';

void main() {
  testWidgets('LED Control app smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(MyApp());

    // Verify that the app loads with the correct title
    expect(find.text('LED Control BLE'), findsOneWidget);

    // Verify that we have the connection status text
    expect(find.text('Disconnected'), findsOneWidget);

    // Verify that we have the scan button
    expect(find.text('Scan for ESP32'), findsOneWidget);

    // Tap the scan button
    await tester.tap(find.text('Scan for ESP32'));
    await tester.pump();

    // Verify that scanning status appears
    expect(find.text('Scanning for devices...'), findsOneWidget);
  });

  testWidgets('LED Control widgets exist', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(MyApp());

    // Verify the app bar title
    expect(find.text('LED Control BLE'), findsOneWidget);

    // Verify the scan button exists
    expect(find.widgetWithText(ElevatedButton, 'Scan for ESP32'), findsOneWidget);
  });
}