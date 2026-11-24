import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/pages/today_chapters/widgets/ring_health_card.dart';
import 'package:memorion/services/devices/chiplet_ring/health.dart';

import 'fake_ring.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RingHarness h;
  setUp(() {
    h = RingHarness(Directory.systemTemp.createTempSync('ring-health-refresh-'));
  });
  tearDown(() => h.close());

  Widget page({bool connected = true, GlobalKey<NavigatorState>? navigatorKey}) => MaterialApp(
      navigatorKey: navigatorKey,
      home: Scaffold(body: SingleChildScrollView(child: RingHealthCard(controller: h.sync, connected: connected))));

  Future<void> settleRead(WidgetTester tester) async {
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.tap(find.byKey(const ValueKey('ring_health_expand')));
    await settleRead(tester);
  }

  testWidgets('expanded details read every five minutes, and one click resets the interval', (tester) async {
    h.peer.health = RingHealthSnapshot(1, {'heartRate': RingHealthValue(72, DateTime.utc(2026, 11, 17))});
    await tester.pumpWidget(page());
    await tester.pump(const Duration(minutes: 5));
    expect(h.peer.healthReads, 0); // Collapsed health never starts a read.
    await tester.tap(find.byKey(const ValueKey('ring_health_expand')));
    await settleRead(tester);
    expect(h.peer.healthReads, 1);
    expect(find.text('72 bpm'), findsOneWidget);
    expect(find.byKey(const ValueKey('ring_health_last_read')), findsOneWidget);

    await tester.pump(const Duration(minutes: 4));
    expect(h.peer.healthReads, 1);
    await tester.ensureVisible(find.byKey(const ValueKey('ring_refresh_health')));
    await tester.tap(find.byKey(const ValueKey('ring_refresh_health')));
    await settleRead(tester);
    expect(h.peer.healthReads, 2);
    await tester.pump(const Duration(minutes: 1));
    expect(h.peer.healthReads, 2);
    h.peer.health = RingHealthSnapshot(2, {
      'heartRate': RingHealthValue(75, DateTime.utc(2026, 11, 17)),
      'oxygen': RingHealthValue(97, DateTime.utc(2026, 11, 17))
    });
    await tester.pump(const Duration(minutes: 4));
    await settleRead(tester);
    expect(h.peer.healthReads, 3);
    expect(find.text('75 bpm'), findsOneWidget);
    expect(find.text('97 %'), findsOneWidget);
    expect(h.uploads, 0);
    expect(h.peer.erases, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('background intervals coalesce into one read on foreground return', (tester) async {
    await open(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 15));
    expect(h.peer.healthReads, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settleRead(tester);
    expect(h.peer.healthReads, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a covered detail route does not read and returns with one due refresh', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(page(navigatorKey: navigator));
    await tester.tap(find.byKey(const ValueKey('ring_health_expand')));
    await settleRead(tester);
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 10));
    expect(h.peer.healthReads, 1);
    navigator.currentState!.pop();
    await settleRead(tester);
    expect(h.peer.healthReads, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reads wait for recording/import lock without overlapping a pending read', (tester) async {
    h.peer.storageGate = Completer<void>();
    final storage = h.sync.inspectDevice();
    await open(tester);
    expect(h.peer.healthReads, 0);
    await tester.pump(const Duration(minutes: 10));
    expect(h.peer.healthReads, 0);
    h.peer.healthGate = Completer<void>();
    await tester.runAsync(() async {
      h.peer.storageGate!.complete();
      await storage;
    });
    await settleRead(tester);
    expect(h.peer.healthReads, 1);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('ring_refresh_health'))).onPressed, isNull);
    await tester.pump(const Duration(minutes: 10));
    expect(h.peer.healthReads, 1);
    await tester.runAsync(() async {
      h.peer.healthGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await settleRead(tester);
    expect(h.peer.healthReads, 2); // One deferred read, not a backlog.
    expect(h.peer.starts, 0);
    expect(h.peer.downloads, 0);
    expect(h.uploads, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disconnect, collapse, account change and disposal stop automatic reads', (tester) async {
    await open(tester);
    await tester.pumpWidget(page(connected: false));
    await tester.pump(const Duration(minutes: 5));
    expect(h.peer.healthReads, 1);
    await tester.pumpWidget(page());
    await settleRead(tester);
    expect(h.peer.healthReads, 2);
    await tester.ensureVisible(find.text('Ring health metrics'));
    await tester.tap(find.text('Ring health metrics'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 10));
    expect(h.peer.healthReads, 2);
    await tester.tap(find.byKey(const ValueKey('ring_health_expand')));
    await settleRead(tester);
    expect(h.peer.healthReads, 3);
    h.owner = 'bob';
    await tester.pump(const Duration(minutes: 10));
    expect(h.peer.healthReads, 3);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
    expect(h.peer.healthReads, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed refresh retains timestamped prior data and does not invent new values', (tester) async {
    h.peer.health = RingHealthSnapshot(1, {'heartRate': RingHealthValue(72, DateTime.utc(2026, 11, 17))});
    await open(tester);
    h.peer.healthError = PlatformException(code: 'timeout');
    await tester.pump(const Duration(minutes: 5));
    await settleRead(tester);
    expect(find.text('72 bpm'), findsOneWidget);
    expect(find.byKey(const ValueKey('ring_health_read_failed')), findsOneWidget);
    expect(find.textContaining('showing previous data'), findsOneWidget);
    expect(find.text('Vendor service not connected'), findsWidgets);
    expect(h.peer.healthReads, 2);
    expect(h.uploads, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
