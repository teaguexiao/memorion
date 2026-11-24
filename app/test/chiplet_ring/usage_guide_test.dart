import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/widgets/ring_usage_guide.dart';
import 'fake_ring.dart';

void main() {
  late RingHarness h;
  setUp(() => h = RingHarness(Directory.systemTemp.createTempSync('ring-guide-')));
  tearDown(() => h.close());

  test('clock calibration shares recording/import lock and ignores a lost connection', () async {
    h.peer.clockGate = Completer<void>();
    final result = expectLater(h.sync.synchronizeClock(const Duration(hours: 8)), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(h.sync.busy, true);
    await h.sync.startRecording();
    await h.sync.sync();
    expect(h.peer.starts, 0);
    expect(h.peer.downloads, 0);
    await h.peer.disconnect();
    h.peer.clockGate!.complete();
    await result;
    expect(h.sync.busy, false);
    expect(h.uploads, 0);
  });

  Future<void> open(WidgetTester tester, String language, {bool connected = true}) async {
    await tester.pumpWidget(MaterialApp(
      locale: Locale(language),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: RingUsageGuide(controller: h.sync, connected: connected))),
    ));
    await tester.tap(find.byKey(const ValueKey('ring_usage_guide')));
    await tester.pumpAndSettle();
  }

  for (final language in ['zh', 'en']) {
    testWidgets('guide explains unverified hardware and clock failure without false success ($language)',
        (tester) async {
      h.peer.failClock = true;
      await open(tester, language);
      expect(find.textContaining(language == 'zh' ? '没有震动' : 'produced no vibration'), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '开始长振一次' : 'one long pulse at start'), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '亮绿灯已确认' : 'has been confirmed'), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? 'Z62 的默认' : 'Z62 defaults'), findsOneWidget);
      final button = find.byKey(const ValueKey('ring_calibrate_clock'));
      await tester.ensureVisible(button);
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      // Stream subscription cancellation completes on the real async queue.
      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(h.peer.clockWrites, 1);
      expect(find.textContaining(language == 'zh' ? '未能验证校准' : 'Calibration was not verified'), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '戒指回读时间：' : 'Verified ring time:'), findsNothing);
      expect(h.uploads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('clock action is disabled offline and during transfers', (tester) async {
    await open(tester, 'en', connected: false);
    final button = find.byKey(const ValueKey('ring_calibrate_clock'));
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    h.sync.maintenanceBusy = true;
    await open(tester, 'en');
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
