import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/ring_recordings_page.dart';
import 'package:memorion/pages/today_chapters/recorder_widgets.dart';
import 'package:memorion/pages/today_chapters/audio_jobs_page.dart';
import 'package:memorion/services/devices/chiplet_ring/models.dart';
import 'fake_ring.dart';
import 'integration_test.dart' show until;

void main() {
  late RingHarness h;
  setUp(() => h = RingHarness(Directory.systemTemp.createTempSync('ring-page-')));
  tearDown(() => h.close());
  setUpAll(() async {
    await (FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))).load();
  });
  final device = BtDevice(id: 'ring-fixture', name: 'BCL603B2C8', type: DeviceType.chipletRing, rssi: -45);
  Future<void> open(WidgetTester tester, String language) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // The page starts file-backed synchronization from initState. Start it in
    // the real async zone so filesystem futures can finish during runAsync.
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(
          locale: Locale(language),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!),
          home: RingRecordingsPage(device: device, controller: h.sync),
        )));
  }

  for (final language in ['zh', 'en']) {
    testWidgets('Bluetooth byte events display the shared circular progress and timestamp ($language)', (tester) async {
      final file = fixtureRecording(0);
      h.peer.directory = [file];
      h.peer.downloadGate = Completer<void>();
      await open(tester, language);
      await tester.runAsync(() => until(() => h.peer.downloads == 1));
      h.peer.stream.add({'event': 'progress', 'name': file.name, 'bytes': 12000});
      await tester.pump();
      expect(find.byType(AudioJobsLink), findsOneWidget);
      expect(find.byKey(const ValueKey('ring_refresh_status')), findsOneWidget);
      final ring = find.byKey(ValueKey('ring_download_progress_${file.id}'));
      await tester.scrollUntilVisible(ring, 200);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<CircularProgressIndicator>(ring).value, 0.5);
      expect(find.ancestor(of: ring, matching: find.byType(RecorderProgressRing)), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text(DateFormat('yyyy-MM-dd HH:mm:ss').format(file.startedAt!.toLocal())), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        h.peer.downloadGate!.complete();
        await h.sync.sync();
      });
    });
    testWidgets('offline device timestamp is shown without implicitly confirming upload ($language)', (tester) async {
      final file = RingRecording.fromNative({
        'name': '010203040506_2025_12_06:15:04:55_8.bin',
        'size': 24000,
        'type': '8',
        'date': '2025_12_06:15:04:55',
      });
      h.peer.directory = [file];
      await tester.runAsync(() => h.sync.sync());
      await open(tester, language);
      await tester.runAsync(() => h.sync.sync());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(ValueKey('ring_confirm_time_${file.id}')), 200);
      await tester.pumpAndSettle();
      expect(find.text('2025-12-06 15:04:55'), findsOneWidget);
      expect(find.text(language == 'zh' ? '设备时间 · 待确认' : 'Device time · unconfirmed'), findsOneWidget);
      expect(h.sync.recordings.single.startedAt, isNull);
      expect(h.uploads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('live recording displays start timestamp and elapsed mm:ss ($language)', (tester) async {
      await tester.runAsync(() => h.sync.startRecording());
      await open(tester, language);
      h.peer.stream.add({'event': 'recording', 'durationMs': 65000});
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('ring_recording_started_at')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(DateFormat('yyyy-MM-dd HH:mm:ss').format(h.sync.recordingStartedAt!.toLocal())), findsOneWidget);
      expect(find.text(language == 'zh' ? '录音中 · 01:05' : 'Recording · 01:05'), findsOneWidget);
      expect(find.byKey(const ValueKey('ring_recording_active')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => h.sync.cancelForAccount());
    });
  }
}
