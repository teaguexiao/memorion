import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/widgets/ring_health_card.dart';
import 'package:memorion/services/devices/chiplet_ring/health.dart';
import 'package:memorion/services/devices/chiplet_ring/bridge.dart';
import 'package:memorion/services/devices/chiplet_ring_connection.dart';
import 'fake_ring.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RingHarness h;
  setUp(() {
    h = RingHarness(Directory.systemTemp.createTempSync('ring-health-'));
  });
  tearDown(() => h.close());

  test('connection cannot report ready when recording feedback configuration fails', () async {
    final device = BtDevice(id: 'ring-fixture', name: 'BCL603B2C8', type: DeviceType.chipletRing, rssi: -50);
    final c = RingDeviceConnection(device, BluetoothDevice.fromId(device.id), transport: h.peer);
    h.peer.failFeedback = true;
    await expectLater(c.connect(), throwsStateError);
    expect(await c.isConnected(), false);
    h.peer.failFeedback = false;
    await c.connect();
    expect(await c.isConnected(), true);
    expect(h.peer.feedbackConfigurations, 2);
    await c.retire();
  });
  test('acknowledged feedback writes do not claim firmware readback verification', () async {
    const channel = MethodChannel('ring-feedback-fixture');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final peer = NativeRingTransport(channel: channel, eventStream: const Stream.empty());
    for (final verified in [0, 1]) {
      messenger.setMockMethodCallHandler(channel, (_) async => {'start': 2, 'stop': 2, 'readbackVerified': verified});
      expect((await peer.configureRecordingFeedback())['readbackVerified'], verified);
    }
    messenger.setMockMethodCallHandler(channel, (_) async => {'start': 2, 'stop': 0, 'readbackVerified': 0});
    await expectLater(peer.configureRecordingFeedback(), throwsFormatException);
    messenger.setMockMethodCallHandler(channel, (_) async => {'start': 1, 'stop': 1, 'readbackVerified': 1});
    await expectLater(peer.configureRecordingFeedback(), throwsFormatException);
  });
  test('health inspection shares the recording/import lock and never uploads', () async {
    h.peer.healthGate = Completer();
    final read = h.sync.inspectHealth();
    await Future<void>.delayed(Duration.zero);
    await h.sync.startRecording();
    await h.sync.sync();
    await expectLater(h.sync.inspectDevice(), throwsStateError);
    expect(h.peer.starts, 0);
    expect(h.peer.downloads, 0);
    h.peer.healthGate!.complete();
    await read;
    expect(h.uploads, 0);
    expect(h.sync.maintenanceBusy, false);
  });
  test('health result is discarded after logout or BLE loss', () async {
    for (final accountLoss in [true, false]) {
      h.owner = 'alice';
      h.peer.healthGate = Completer();
      final read = h.sync.inspectHealth();
      final check = expectLater(read, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      if (accountLoss) {
        h.owner = 'bob';
        await h.sync.cancelForAccount();
      } else {
        h.peer.stream.add({'event': 'connection', 'connected': false});
      }
      h.peer.healthGate!.complete();
      await check;
    }
  });
  test('invalid and unknown native metric values are not treated as measurements', () {
    expect(() => RingHealthSnapshot.fromNative({'recordCount': -1, 'metrics': {}}), throwsFormatException);
    expect(
        () => RingHealthSnapshot.fromNative({
              'recordCount': 1,
              'metrics': {
                'oxygen': {'value': 0, 'time': 1700000000}
              }
            }),
        throwsFormatException);
    expect(
        RingHealthSnapshot.fromNative({
          'recordCount': 1,
          'metrics': {
            'unknown': {'value': 2, 'time': 1700000000}
          }
        }).metrics,
        isEmpty);
  });
  for (final language in ['zh', 'en']) {
    testWidgets('timeout remains visible after BLE loss and differs from a successful empty read ($language)',
        (tester) async {
      Widget card(bool connected) => MaterialApp(
          locale: Locale(language),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: RingHealthCard(controller: h.sync, connected: connected))));
      h.peer.healthGate = Completer<void>();
      h.peer.healthError = PlatformException(code: 'timeout');
      await tester.pumpWidget(card(true));
      await tester.tap(find.byKey(const ValueKey('ring_health_expand')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('ring_refresh_health')));
      await tester.tap(find.byKey(const ValueKey('ring_refresh_health')));
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(h.peer.healthReads, 1);
      await tester.pumpWidget(card(false));
      await tester.runAsync(() async {
        h.peer.healthGate!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ring_health_read_failed')), findsOneWidget);
      expect(find.byKey(const ValueKey('ring_health_read_result')), findsNothing);
      expect(find.textContaining(language == 'zh' ? '未响应健康读取' : 'did not respond to the health'), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '读取失败 · 尚未确认' : 'Read failed · availability'), findsWidgets);
      h.peer.healthError = null;
      h.peer.healthGate = null;
      await tester.pumpWidget(card(true));
      await tester.ensureVisible(find.byKey(const ValueKey('ring_refresh_health')));
      await tester.tap(find.byKey(const ValueKey('ring_refresh_health')));
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ring_health_read_failed')), findsNothing);
      expect(find.textContaining(language == 'zh' ? '读取完成 · 0 条记录' : 'Read completed · 0 records'), findsOneWidget);
      expect(h.uploads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('all official metrics stay visible in details without invented values ($language)', (tester) async {
      h.peer.health = RingHealthSnapshot(1, {'heartRate': RingHealthValue(72, DateTime.utc(2026, 11, 16))});
      await tester.pumpWidget(MaterialApp(
          locale: Locale(language),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: RingHealthCard(controller: h.sync, connected: true)))));
      await tester.tap(find.byKey(const ValueKey('ring_health_expand')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(h.peer.healthReads, 1);
      expect(find.byKey(const ValueKey('ring_health_glucose')), findsOneWidget);
      expect(find.byKey(const ValueKey('ring_health_systolic')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('ring_refresh_health')));
      await tester.tap(find.byKey(const ValueKey('ring_refresh_health')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.text('72 bpm'), findsOneWidget);
      expect(h.peer.healthReads, 2);
      expect(find.text(language == 'zh' ? '读取全部指标' : 'Read all metrics'), findsOneWidget);
      expect(find.byKey(const ValueKey('ring_health_auto_refresh_note')), findsOneWidget);
      expect(find.text(language == 'zh' ? '厂商算法尚未接通' : 'Vendor service not connected'), findsWidgets);
      expect(h.uploads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('health read is disabled during recording and when disconnected', (tester) async {
    await tester.runAsync(() => h.sync.startRecording());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: RingHealthCard(controller: h.sync, connected: true)))));
    await tester.tap(find.byKey(const ValueKey('ring_health_expand')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('ring_refresh_health'))).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => h.sync.cancelForAccount());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: RingHealthCard(controller: h.sync, connected: false)))));
    await tester.tap(find.byKey(const ValueKey('ring_health_expand')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('ring_refresh_health'))).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
