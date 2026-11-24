import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/a1_recordings_page.dart';
import 'package:memorion/pages/today_chapters/a1_setup_page.dart';
import 'package:memorion/services/devices/dingtalk_a1/identity_store.dart';
import 'package:memorion/services/devices/dingtalk_a1/identity.dart';
import 'package:memorion/services/devices/dingtalk_a1/protocol.dart';
import 'package:memorion/services/devices/dingtalk_a1/sync_controller.dart';
import 'package:memorion/services/devices/offline_recordings/import_store.dart';
import 'package:memorion/services/devices/offline_recordings/models.dart';

class ListSync extends A1SyncController {
  int refreshes = 0, polls = 0, autoWrites = 0;
  final controls = <String>[];
  ListSync()
      : super(
            openStore: () async => throw StateError('UI test'),
            openSession: () async => null,
            isCurrentOwner: () => true,
            readAutoSync: () async => false,
            writeAutoSync: (_) async {}) {
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

  @override
  Future<void> setAutoSync(bool enabled) async {
    autoWrites++;
    autoSync = enabled;
    notifyListeners();
  }

  @override
  Future<void> recordingControl(String action) async => controls.add(action);

  void update({bool? transferring, String? recordingStatus}) {
    if (transferring != null) busy = transferring;
    if (recordingStatus != null) {
      connected = true;
      info = A1Info(
          battery: 80, totalStorageMb: 64000, freeStorageMb: 62000, firmware: 'test', audioStatus: recordingStatus);
    }
    notifyListeners();
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))).load();
  });
  final device = BtDevice(id: 'test-a1', name: 'DingTalk A1', type: DeviceType.dingtalkA1, rssi: -45);
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

    testWidgets('20-item pagination preserves controller and clears data on account change ($language)',
        (tester) async {
      final sync = ListSync();
      addTearDown(sync.dispose);
      await open(tester, A1RecordingsPage(device: device, controller: sync));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('a1_recording_1700000000')), 160);
      expect(find.byKey(const ValueKey('a1_recording_1700000000')), findsOneWidget);
      expect(find.byKey(const ValueKey('a1_recording_1699998800')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('a1_next_page')), 500);
      await tester.tap(find.byKey(const ValueKey('a1_next_page')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('a1_recording_1699998800')), 160);
      expect(find.byKey(const ValueKey('a1_recording_1699998800')), findsOneWidget);
      expect(find.byKey(const ValueKey('a1_recording_1700000000')), findsNothing);
      expect(sync.refreshes, 1);
      sync.retire();
      await tester.pump();
      expect(find.byType(Card), findsNothing);
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
      await open(tester, A1RecordingsPage(device: device, controller: sync));
      final card = find.byKey(ValueKey('a1_recording_${recording.id}'));
      await tester.scrollUntilVisible(card, 160);
      expect(
          find.descendant(
              of: card,
              matching:
                  find.text(language == 'zh' ? '未识别到清晰语音，音频已保留。' : 'No recognizable speech. Your audio is kept.')),
          findsOneWidget);
      expect(find.descendant(of: card, matching: find.text(language == 'zh' ? '试听' : 'Listen')), findsOneWidget);
      expect(find.byKey(ValueKey('a1_sync_${recording.id}')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('automatic cloud import requires the displayed consent ($language)', (tester) async {
      final sync = ListSync();
      addTearDown(sync.dispose);
      await open(tester, A1RecordingsPage(device: device, controller: sync));
      await tester.scrollUntilVisible(find.byType(Switch), 160);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(sync.autoWrites, 0);
      await tester.tap(find.text(language == 'zh' ? '取消' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(sync.autoWrites, 0);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text(language == 'zh' ? '开启' : 'Enable'));
      await tester.pumpAndSettle();
      expect(sync.autoWrites, 1);
      expect(sync.autoSync, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('refresh waits for an active transfer and coalesces repeated requests ($language)', (tester) async {
      final sync = ListSync();
      addTearDown(sync.dispose);
      await open(tester, A1RecordingsPage(device: device, controller: sync));
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
      await open(tester, A1RecordingsPage(device: device, controller: sync));
      final progress = find.byKey(ValueKey('a1_download_progress_$active'));
      await tester.scrollUntilVisible(progress, 160);
      expect(tester.widget<CircularProgressIndicator>(progress).value, 0.5);
      expect(find.byKey(ValueKey('a1_sync_$active')), findsNothing);
      final pendingAction = find.byKey(ValueKey('a1_sync_$pending'));
      await tester.scrollUntilVisible(pendingAction, 160);
      expect(tester.widget<TextButton>(pendingAction).onPressed, isNull);
      sync.stages[active] = OfflineImportStage.uploading;
      sync.uploadProgress = 1;
      sync.update();
      await tester.pumpAndSettle();
      final card = find.byKey(ValueKey('a1_recording_$active'));
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
        await open(tester, A1RecordingsPage(device: device, controller: sync));
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
    testWidgets('recording controls follow device state and cannot run during sync ($language)', (tester) async {
      final sync = ListSync()..recordings = [];
      addTearDown(sync.dispose);
      sync.update(recordingStatus: 'idle');
      await open(tester, A1RecordingsPage(device: device, controller: sync));
      for (final state in ['idle', 'recording', 'paused', 'rec_streaming', 'streaming']) {
        sync.update(recordingStatus: state);
        await tester.pump();
        final expected = switch (state) {
          'idle' => [language == 'zh' ? '开始录音' : 'Start recording'],
          'paused' => [language == 'zh' ? '继续录音' : 'Resume', language == 'zh' ? '结束录音' : 'Stop recording'],
          'streaming' => [language == 'zh' ? '结束录音' : 'Stop recording'],
          _ => [language == 'zh' ? '暂停' : 'Pause', language == 'zh' ? '结束录音' : 'Stop recording'],
        };
        await tester.scrollUntilVisible(find.widgetWithText(OutlinedButton, expected.first), 160);
        expect(
            tester.widgetList<OutlinedButton>(find.byType(OutlinedButton)).map((button) => find
                .descendant(of: find.byWidget(button), matching: find.byType(Text))
                .evaluate()
                .map((e) => (e.widget as Text).data)
                .single),
            expected);
        for (final label in expected) {
          await tester.ensureVisible(find.text(label));
          await tester.tap(find.text(label));
        }
        final before = sync.controls.length;
        sync.update(transferring: true);
        await tester.pump();
        for (final button in tester.widgetList<OutlinedButton>(find.byType(OutlinedButton))) {
          expect(button.onPressed, isNull);
        }
        expect(sync.controls.length, before);
        sync.update(transferring: false);
        await tester.pump();
      }
      expect(sync.controls, ['start', 'pause', 'stop', 'resume', 'stop', 'pause', 'stop', 'stop']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('credential setup obscures secrets and reports invalid JSON without echoing it ($language)',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await open(tester, A1SetupPage(device: device, currentOwner: () => 'test-owner'));
      expect(find.byKey(const ValueKey('a1_credentials')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('a1_manual_credentials')), 180);
      await tester.tap(find.byKey(const ValueKey('a1_manual_credentials')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byKey(const ValueKey('a1_credentials')));
      expect(field.obscureText, isTrue);
      expect(field.enableSuggestions, isFalse);
      await tester.enterText(find.byKey(const ValueKey('a1_credentials')), 'private-test-secret');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('a1_save_credentials')), 200,
          scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
      await tester.tap(find.byKey(const ValueKey('a1_save_credentials')));
      await tester.pumpAndSettle();
      expect(find.textContaining('32'), findsOneWidget);
      expect(await const A1IdentityStore().read('test-owner', device.id), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('setup guide opens the localized public page without importing or saving credentials ($language)',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      Uri? opened;
      var picks = 0;
      await open(
          tester,
          A1SetupPage(
            device: device,
            currentOwner: () => 'test-owner',
            openGuide: (uri) async {
              opened = uri;
              return true;
            },
            pickIdentity: () async {
              picks++;
              return null;
            },
          ));
      await tester.tap(find.byKey(const ValueKey('a1_setup_guide')));
      await tester.pumpAndSettle();
      expect(opened.toString(), 'https://memorion.me/$language/docs/dingtalk-a1');
      expect(opened!.query, isEmpty);
      expect(picks, 0);
      expect(await const A1IdentityStore().read('test-owner', device.id), isNull);
      expect(find.byKey(const ValueKey('a1_setup_guide_fallback')), findsNothing);
      expect(tester.takeException(), isNull);
    });
    for (final throwsError in [false, true]) {
      testWidgets('browser failure leaves a selectable guide address ($language, throws=$throwsError)', (tester) async {
        await open(
            tester,
            A1SetupPage(
              device: device,
              currentOwner: () => 'test-owner',
              openGuide: (_) async {
                if (throwsError) throw StateError('private-launcher-error');
                return false;
              },
            ));
        await tester.tap(find.byKey(const ValueKey('a1_setup_guide')));
        await tester.pumpAndSettle();
        final address = tester.widget<SelectableText>(find.byKey(const ValueKey('a1_setup_guide_fallback')));
        expect(address.data, 'https://memorion.me/$language/docs/dingtalk-a1');
        expect(find.textContaining('private-launcher-error'), findsNothing);
        expect(tester.widget<FilledButton>(find.byKey(const ValueKey('a1_setup_guide'))).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('first-time setup remains usable with large text on a small screen ($language)', (tester) async {
      var opened = false;
      await open(
          tester,
          A1SetupPage(
            device: device,
            currentOwner: () => 'test-owner',
            openGuide: (_) async {
              opened = true;
              return true;
            },
          ),
          textScale: 1.7);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('a1_setup_guide')), 180);
      await tester.tap(find.byKey(const ValueKey('a1_setup_guide')));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('a1_import_credentials')), 180);
      expect(find.byKey(const ValueKey('a1_import_credentials')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets('file import saves locally without JSON entry and keeps automatic upload off ($language)',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      const store = A1IdentityStore();
      await store.setAutoSync('test-owner', device.id, true);
      await open(
          tester,
          A1SetupPage(
            device: device,
            currentOwner: () => 'test-owner',
            pickIdentity: () async => A1Identity('test-did', 'test-corp', 'a' * 32),
          ));
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('a1_import_credentials')));
      await tester.pumpAndSettle();
      expect((await store.read('test-owner', device.id))?.did, 'test-did');
      expect(await store.autoSync('test-owner', device.id), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('cancelling file selection leaves credentials untouched ($language)', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await open(
          tester,
          A1SetupPage(
            device: device,
            currentOwner: () => 'test-owner',
            pickIdentity: () async => null,
          ));
      await tester.tap(find.byKey(const ValueKey('a1_import_credentials')));
      await tester.pumpAndSettle();
      expect(await const A1IdentityStore().read('test-owner', device.id), isNull);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('a1_import_credentials'))).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('file picker errors never expose paths or supplied secrets ($language)', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await open(
          tester,
          A1SetupPage(
            device: device,
            currentOwner: () => 'test-owner',
            pickIdentity: () async => throw const FormatException('private-test-secret'),
          ));
      await tester.tap(find.byKey(const ValueKey('a1_import_credentials')));
      await tester.pumpAndSettle();
      expect(find.textContaining('private-test-secret'), findsNothing);
      expect(find.textContaining(language == 'zh' ? '无法导入此授权文件' : 'Could not import'), findsOneWidget);
      expect(await const A1IdentityStore().read('test-owner', device.id), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('account change during file selection cannot save to either account ($language)', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      var owner = 'test-owner';
      var picks = 0;
      final selected = Completer<A1Identity?>();
      await open(
          tester,
          A1SetupPage(
            device: device,
            currentOwner: () => owner,
            pickIdentity: () {
              picks++;
              return selected.future;
            },
          ));
      await tester.tap(find.byKey(const ValueKey('a1_import_credentials')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('a1_import_credentials')));
      owner = 'another-owner';
      selected.complete(A1Identity('test-did', 'test-corp', 'a' * 32));
      await tester.pumpAndSettle();
      expect(picks, 1);
      expect(await const A1IdentityStore().read('test-owner', device.id), isNull);
      expect(await const A1IdentityStore().read('another-owner', device.id), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
