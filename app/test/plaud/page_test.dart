import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/plaud_recordings_page.dart';
import 'package:memorion/services/devices/plaud/sync_controller.dart';
import 'package:memorion/services/devices/offline_recordings/import_store.dart';
import 'package:memorion/services/devices/offline_recordings/models.dart';

class ListSync extends PlaudSyncController {
  int refreshes = 0, polls = 0;
  ListSync()
      : super(
            openStore: () async => throw StateError('UI test'),
            openSession: () async => null,
            readIdentity: () async => null,
            isCurrentOwner: () => true) {
    recordings = List.generate(45, (i) => OfflineRecording(1700000000 - i * 60, 0, 6000));
  }
  @override
  Future<void> refresh() async {
    refreshes++;
  }

  @override
  Future<void> refreshProcessing() async {
    polls++;
  }

  void update({bool? transferring, bool? refreshing}) {
    if (transferring != null) busy = transferring;
    if (refreshing != null) loading = refreshing;
    notifyListeners();
  }
}

class WifiListSync extends ListSync {
  int wifiStarts = 0;
  @override
  bool get wifiAvailable => true;
  @override
  Future<void> syncOverWifi() async {
    wifiStarts++;
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))).load();
  });
  final device = BtDevice(id: 'test-a1', name: 'PLAUD Note', type: DeviceType.plaudNote, rssi: -45);
  for (final language in ['zh', 'en']) {
    Future<void> open(WidgetTester tester, Widget page, {double textScale = 1}) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          locale: Locale(language),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
          home: page));
      await tester.pumpAndSettle();
    }

    testWidgets('Wi-Fi confirmation is single, cancellable and localized ($language)', (tester) async {
      final sync = WifiListSync()..recordings = [];
      addTearDown(sync.dispose);
      await open(tester, PlaudRecordingsPage(device: device, controller: sync), textScale: 1.3);
      final start = find.byKey(const ValueKey('plaud_wifi_start'));
      await tester.scrollUntilVisible(start, 120);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '该热点无法上网' : 'has no internet access'), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '将暂停蓝牙下载' : 'Bluetooth downloading will pause'), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '当前同步完成后' : 'After the current sync finishes'), findsNothing);
      expect(sync.wifiStarts, 0);
      await tester.tap(find.byKey(const ValueKey('plaud_wifi_cancel')));
      await tester.pumpAndSettle();
      expect(sync.wifiStarts, 0);
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plaud_wifi_confirm')));
      await tester.pumpAndSettle();
      expect(sync.wifiStarts, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('20-item pagination preserves controller and clears data on account change ($language)',
        (tester) async {
      final sync = ListSync();
      addTearDown(sync.dispose);
      await open(tester, PlaudRecordingsPage(device: device, controller: sync));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('plaud_recording_1700000000')), 160);
      expect(find.byKey(const ValueKey('plaud_recording_1700000000')), findsOneWidget);
      expect(find.byKey(const ValueKey('plaud_recording_1699998800')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('plaud_next_page')), 500);
      await tester.tap(find.byKey(const ValueKey('plaud_next_page')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('plaud_recording_1699998800')), 160);
      expect(find.byKey(const ValueKey('plaud_recording_1699998800')), findsOneWidget);
      expect(find.byKey(const ValueKey('plaud_recording_1700000000')), findsNothing);
      expect(sync.refreshes, 1);
      sync.retire();
      await tester.pump();
      expect(find.byType(Card), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('background refresh keeps cached rows and summary in place ($language)', (tester) async {
      final sync = ListSync()..lastRefresh = DateTime(2026, 11, 3);
      sync.recordings = [sync.recordings.first];
      addTearDown(sync.dispose);
      await open(tester, PlaudRecordingsPage(device: device, controller: sync));
      // Keep both the summary and first row built in the lazy list in either
      // language, so their positions can be compared during refresh.
      tester.view.physicalSize = const Size(320, 1200);
      await tester.pump();
      final card = find.byKey(ValueKey('plaud_recording_${sync.recordings.first.id}'));
      await tester.scrollUntilVisible(card, 100);
      for (final connected in [false, true]) {
        sync.connected = connected;
        sync.deviceFileCount = 1;
        sync.update();
        await tester.pump();
        final position = tester.getTopLeft(card);
        final summary = find.textContaining(language == 'zh' ? '待同步 1 条' : 'Pending: 1');
        expect(summary, findsOneWidget);
        for (var i = 0; i < 3; i++) {
          sync.update(refreshing: true);
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(summary, findsOneWidget);
          expect(tester.getTopLeft(card), position);
          sync.update(refreshing: false);
          await tester.pump();
          expect(tester.getTopLeft(card), position);
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('cloud failure detail is visible without offering duplicate upload ($language)', (tester) async {
      final sync = ListSync();
      addTearDown(sync.dispose);
      final recording = sync.recordings.first;
      sync.recordings = [recording];
      sync.stages[recording.id] = OfflineImportStage.uploaded;
      sync.processingJobs[recording.id] = AudioProcessingJob.fromJson({
        'id': 'test-job',
        'conversation_id': 'test-job',
        'status': 'failed',
        'stage': 'validate',
        'error_code': 'no_speech',
        'started_at': recording.startedAt.toIso8601String(),
        'can_retry': false,
      });
      await open(tester, PlaudRecordingsPage(device: device, controller: sync));
      final card = find.byKey(ValueKey('plaud_recording_${recording.id}'));
      await tester.scrollUntilVisible(card, 160);
      expect(
          find.descendant(
              of: card,
              matching:
                  find.text(language == 'zh' ? '未识别到清晰语音，音频已保留。' : 'No recognizable speech. Your audio is kept.')),
          findsOneWidget);
      expect(find.descendant(of: card, matching: find.text(language == 'zh' ? '试听' : 'Listen')), findsNothing);
      expect(find.byKey(ValueKey('plaud_sync_${recording.id}')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('automatic sync is explained without an off switch ($language)', (tester) async {
      final sync = ListSync();
      addTearDown(sync.dispose);
      await open(tester, PlaudRecordingsPage(device: device, controller: sync));
      expect(find.textContaining(language == 'zh' ? '设备连接后自动同步录音' : 'Recordings sync automatically'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('authorization opens the website during sync without changing credentials ($language)', (tester) async {
      final sync = ListSync()..recordings = [];
      sync.busy = true;
      addTearDown(sync.dispose);
      Uri? opened;
      await open(
          tester,
          PlaudRecordingsPage(
              device: device,
              controller: sync,
              openGuide: (uri) async {
                opened = uri;
                return true;
              }));
      final guide = find.byKey(const ValueKey('plaud_device_credentials'));
      await tester.scrollUntilVisible(guide, 160);
      await tester.pumpAndSettle();
      await tester.tap(guide);
      await tester.pumpAndSettle();
      expect(opened.toString(), 'https://memorion.me/$language/docs/plaud-note');
      expect(sync.busy, isTrue);
      final localImport = find.byKey(const ValueKey('plaud_update_credentials'));
      expect(tester.widget<TextButton>(localImport).onPressed, isNull);
      sync.update(transferring: false);
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(localImport).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('failed website launch shows a copyable localized address ($language)', (tester) async {
      final sync = ListSync()..recordings = [];
      addTearDown(sync.dispose);
      await open(
          tester,
          PlaudRecordingsPage(
              device: device,
              controller: sync,
              openGuide: (_) async {
                if (language == 'en') throw StateError('Browser unavailable');
                return false;
              }),
          textScale: 1.5);
      final guide = find.byKey(const ValueKey('plaud_device_credentials'));
      await tester.scrollUntilVisible(guide, 160);
      await tester.pumpAndSettle();
      await tester.tap(guide);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byType(SelectableText), 160);
      await tester.pumpAndSettle();
      expect(find.text('https://memorion.me/$language/docs/plaud-note'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('refresh waits for an active transfer and coalesces repeated requests ($language)', (tester) async {
      final sync = ListSync();
      addTearDown(sync.dispose);
      await open(tester, PlaudRecordingsPage(device: device, controller: sync));
      sync.update(transferring: true);
      await tester.pump();
      final refresh = find.byTooltip(language == 'zh' ? '刷新' : 'Refresh');
      await tester.tap(refresh);
      await tester.tap(refresh);
      await tester.pump();
      expect(sync.refreshes, 1);
      sync.update(transferring: false);
      await tester.pumpAndSettle();
      expect(sync.refreshes, 2);
      sync.update(transferring: false);
      await tester.pump();
      expect(sync.refreshes, 2);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('transfer progress replaces sync and waits for the server receipt ($language)', (tester) async {
      final sync = ListSync();
      addTearDown(sync.dispose);
      sync.recordings = sync.recordings.take(2).toList();
      final active = sync.recordings.first.id;
      final pending = sync.recordings.last.id;
      sync.activeId = active;
      sync.stages[active] = OfflineImportStage.downloading;
      sync.bytes = 500;
      sync.totalBytes = 1000;
      sync.busy = true;
      await open(tester, PlaudRecordingsPage(device: device, controller: sync));
      final progress = find.byKey(ValueKey('plaud_download_progress_$active'));
      await tester.scrollUntilVisible(progress, 160);
      expect(tester.widget<CircularProgressIndicator>(progress).value, 0.5);
      expect(find.byKey(ValueKey('plaud_sync_$active')), findsNothing);
      final pendingAction = find.byKey(ValueKey('plaud_sync_$pending'));
      await tester.scrollUntilVisible(pendingAction, 160);
      expect(tester.widget<TextButton>(pendingAction).onPressed, isNull);
      sync.stages[active] = OfflineImportStage.uploading;
      sync.uploadProgress = 1;
      sync.update();
      await tester.pumpAndSettle();
      final card = find.byKey(ValueKey('plaud_recording_$active'));
      expect(find.descendant(of: card, matching: find.text(language == 'zh' ? '已完成' : 'Completed')), findsNothing);
      expect(find.byTooltip(language == 'zh' ? '已发送 · 等待服务器确认…' : 'Sent · waiting for server confirmation…'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    for (final leavePage in [false, true]) {
      testWidgets('queued refresh is cancelled on ${leavePage ? 'navigation' : 'account change'} ($language)',
          (tester) async {
        final sync = ListSync();
        addTearDown(sync.dispose);
        await open(tester, PlaudRecordingsPage(device: device, controller: sync));
        sync.update(transferring: true);
        await tester.pump();
        await tester.tap(find.byTooltip(language == 'zh' ? '刷新' : 'Refresh'));
        await tester.pump();
        if (leavePage) {
          await tester.pumpWidget(const SizedBox());
        } else {
          sync.retire();
        }
        sync.update(transferring: false);
        await tester.pump();
        expect(sync.refreshes, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
