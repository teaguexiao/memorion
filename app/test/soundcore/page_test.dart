import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/soundcore_recordings_page.dart';
import 'package:memorion/services/devices/soundcore/import_store.dart';
import 'package:memorion/services/devices/soundcore/protocol_error.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore/sync_controller.dart';
import 'package:memorion/services/devices/soundcore/wifi_transport.dart';

import 'fake_device.dart';
import 'fake_wifi.dart';

/// Observe the UI's network-change boundary without running sockets/file I/O
/// inside a dialog animation. Real transfer behavior lives in wifi_test.dart.
class _ConfirmationSync extends SoundcoreSyncController {
  int checks = 0;
  int wifiRequests = 0;
  _ConfirmationSync(
      {bool Function()? isCurrentOwner,
      Future<Map<int, AudioRecordingUploadState>> Function(List<SoundcoreRecording>)? lookupRecordings})
      : super(
          openStore: () async => throw StateError('UI boundary only'),
          openSession: () async => null,
          isCurrentOwner: isCurrentOwner ?? () => true,
          lookupRecordings: lookupRecordings,
          openWifi: (_, __) async => throw StateError('UI boundary only'),
        );

  @override
  Future<void> sync() async => checks++;

  @override
  Future<void> syncOverWifi() async => wifiRequests++;

  void showPhase(SoundcoreWifiState? state) {
    wifiState = state;
    notifyListeners();
  }
}

class _LifecycleSync extends _ConfirmationSync {
  int polls = 0;
  @override
  Future<void> refreshProcessing({int? recordingId, bool includeTerminal = false}) async => polls++;
}

class _ManualSync extends _ConfirmationSync {
  final requested = <int>[];
  @override
  bool get busy => true;
  @override
  Future<void> retry(int id) async => requested.add(id);
}

class _ReceiptSync extends _ConfirmationSync {
  bool verified = false;
  final requested = <int>[];
  _ReceiptSync() : super(lookupRecordings: (_) async => {});
  @override
  bool needsCloudCheck(int id) => !verified && super.needsCloudCheck(id);
  @override
  Future<void> retry(int id) async => requested.add(id);

  void restore(int id, {required bool uploaded}) {
    verified = true;
    cloudLookupError = null;
    if (uploaded) stages[id] = SoundcoreImportStage.processed;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final language in ['en', 'zh']) {
    for (final uploaded in [false, true]) {
      testWidgets('reinstall row checks cloud before offering sync in $language, uploaded=$uploaded', (tester) async {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const recording = SoundcoreRecording(1700000000, 1700000060, 0);
        final controller = _ReceiptSync()..recordings = [recording];
        controller.cloudLookupError = const SocketException('Offline');
        await tester.pumpWidget(MaterialApp(
          locale: Locale(language),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: SoundcoreRecordingsPage(
            device: BtDevice(id: 'test', name: '', type: DeviceType.soundcore, rssi: -50),
            controller: controller,
          ),
        ));
        await tester.pumpAndSettle();
        final check = find.byKey(ValueKey('soundcore_check_${recording.id}'));
        final transfer = find.byKey(ValueKey('soundcore_sync_${recording.id}'));
        expect(transfer, findsNothing);
        expect(find.text(language == 'zh' ? '待核对 1 条' : 'Checking cloud status: 1'), findsOneWidget);
        expect(find.text(language == 'zh' ? '待同步 0 条 · 已上传 0 条' : 'Pending: 0 · Uploaded: 0'), findsOneWidget);
        await tester.scrollUntilVisible(check, 160);
        await tester.pumpAndSettle();
        final initial = controller.checks;
        await tester.tap(check);
        expect(controller.checks, initial + 1);
        expect(controller.requested, isEmpty);
        controller.cloudLookupError = null;
        controller.showPhase(null);
        await tester.pumpAndSettle();
        expect(find.descendant(of: check, matching: find.text(language == 'zh' ? '核对状态' : 'Check status')),
            findsOneWidget);
        expect(find.text(language == 'zh' ? '核对中' : 'Checking'), findsNothing);
        controller.restore(recording.id, uploaded: uploaded);
        await tester.pumpAndSettle();
        expect(check, findsNothing);
        if (uploaded) {
          expect(transfer, findsNothing);
          expect(find.text(language == 'zh' ? '已完成' : 'Completed'), findsOneWidget);
          final card = find.byKey(ValueKey('soundcore_recording_${recording.id}'));
          final status = find.byKey(ValueKey('soundcore_status_${recording.id}'));
          final receiptCardSize = tester.getSize(card);
          final receiptStatusPosition = tester.getTopRight(status);
          controller.processingJobs[recording.id] = AudioProcessingJob.fromJson({
            'id': 'cloud-recording',
            'conversation_id': 'cloud-recording',
            'status': 'completed',
            'stage': 'publish',
            'started_at': recording.startedAt.toIso8601String(),
          });
          controller.showPhase(null);
          await tester.pumpAndSettle();
          expect(find.text(language == 'zh' ? '已完成' : 'Completed'), findsOneWidget);
          expect(tester.getSize(card), receiptCardSize);
          expect(tester.getTopRight(status), receiptStatusPosition);
        } else {
          await tester.ensureVisible(transfer);
          await tester.pumpAndSettle();
          await tester.tap(transfer);
          expect(controller.requested, [recording.id]);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
    }
  }
  for (final preparing in [false, true]) {
    testWidgets('sync action is disabled while ${preparing ? 'preparing the current file' : 'signed out'}',
        (tester) async {
      const recording = SoundcoreRecording(1700000000, 1700000060, 0);
      final controller = _ConfirmationSync(isCurrentOwner: () => preparing);
      controller.recordings = [recording];
      if (preparing) controller.activeId = recording.id;
      await tester.pumpWidget(MaterialApp(
        home: SoundcoreRecordingsPage(
          device: BtDevice(id: 'test', name: '', type: DeviceType.soundcore, rssi: -50),
          controller: controller,
        ),
      ));
      await tester.pumpAndSettle();
      final action = find.byKey(ValueKey('soundcore_sync_${recording.id}'));
      await tester.scrollUntilVisible(action, 160);
      expect(tester.widget<TextButton>(action).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
  testWidgets('an uploaded recording shows its cloud processing failure on the device row', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _ConfirmationSync();
    const recording = SoundcoreRecording(1700000000, 1700000014, 14000);
    controller.recordings = [recording];
    controller.stages[recording.id] = SoundcoreImportStage.uploaded;
    controller.processingJobs[recording.id] = AudioProcessingJob.fromJson({
      'id': 'cloud-recording',
      'conversation_id': 'cloud-recording',
      'status': 'failed',
      'stage': 'validate',
      'error_code': 'no_speech',
      'started_at': recording.startedAt.toIso8601String(),
    });
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: S.supportedLocales,
      localizationsDelegates: S.localizationsDelegates,
      home: SoundcoreRecordingsPage(
        device: BtDevice(id: 'test', name: '', type: DeviceType.soundcore, rssi: -50),
        controller: controller,
      ),
    ));
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('soundcore_recording_${recording.id}'));
    await tester.scrollUntilVisible(card, 160);
    expect(find.descendant(of: card, matching: find.text('处理失败')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('未识别到清晰语音，音频已保留。')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('已上传')), findsNothing);
    expect(find.byKey(ValueKey('soundcore_sync_${recording.id}')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  for (final language in ['en', 'zh']) {
    testWidgets('queued and failed recordings allow manual sync while another file is busy in $language',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _ManualSync();
      controller.recordings = [
        const SoundcoreRecording(1700000000, 1700000060, 0),
        const SoundcoreRecording(1700000001, 1700000061, 0),
      ];
      controller.failures[1700000001] = const SoundcoreImportException(503);
      await tester.pumpWidget(MaterialApp(
        locale: Locale(language),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        home: SoundcoreRecordingsPage(
          device: BtDevice(id: 'test', name: '', type: DeviceType.soundcore, rssi: -50),
          controller: controller,
        ),
      ));
      await tester.pumpAndSettle();
      for (final id in [1700000000, 1700000001]) {
        final action = find.byKey(ValueKey('soundcore_sync_$id'));
        expect(action, findsOneWidget);
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
      }
      expect(controller.requested, [1700000000, 1700000001]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
  testWidgets('processing polling pauses in the background and resumes', (tester) async {
    final controller = _LifecycleSync();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: SoundcoreRecordingsPage(
        device: BtDevice(id: 'test', name: '', type: DeviceType.soundcore, rssi: -50),
        controller: controller,
      ),
    ));
    await tester.pumpAndSettle();
    final initial = controller.polls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(controller.polls, initial);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(controller.polls, greaterThan(initial));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('legacy HTTP 400 rejection does not promise automatic retry', (tester) async {
    final controller = _ConfirmationSync();
    controller.recordings = [const SoundcoreRecording(1700000000, 1700000060, 0)];
    controller.failures[1700000000] = const SoundcoreImportException(400);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      supportedLocales: S.supportedLocales,
      localizationsDelegates: S.localizationsDelegates,
      home: SoundcoreRecordingsPage(
        device: BtDevice(id: 'test', name: '', type: DeviceType.soundcore, rssi: -50),
        controller: controller,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('The server rejected this recording (HTTP 400). The original is saved.'), findsOneWidget);
    expect(find.textContaining('retrying later'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  setUpAll(() async {
    // Measure the compact numeric rows with the same bundled font as the App,
    // rather than Flutter tests' deliberately wide Ahem placeholder glyphs.
    await (FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))).load();
  });
  for (final failure in [false, true]) {
    testWidgets('refresh reports ${failure ? "timeout and retry recovery" : "empty list and newly recorded file"}',
        (tester) async {
      final root = Directory.systemTemp.createTempSync('soundcore_refresh_test_');
      final peer =
          FakeSoundcoreDevice(DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000)
            ..fileCount = 0
            ..listTimeout = failure;
      final session = SoundcoreSession(
        notifications: peer.inbound.stream,
        send: peer.send,
        commandTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(() {
        session.close();
        unawaited(peer.inbound.close());
        root.deleteSync(recursive: true);
      });
      var uploads = 0;
      final store = SoundcoreImportStore(
        root: root,
        ownerId: 'refresh-test',
        deviceId: 'test-device',
        currentOwner: () => 'refresh-test',
        upload: (_, __) async {
          uploads++;
          return const SoundcoreImportReceipt('unexpected-upload', processing: true);
        },
      );
      final controller = SoundcoreSyncController(
        openStore: () async => store,
        openSession: () async => session,
        isCurrentOwner: () => true,
      );
      addTearDown(controller.dispose);
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: SoundcoreRecordingsPage(
            device: BtDevice(name: '', id: 'test-device', type: DeviceType.soundcore, rssi: -55),
            controller: controller,
          ),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pumpAndSettle();
      expect(find.text(failure ? '刷新失败' : '设备中有 0 条录音'), findsOneWidget);
      if (failure) expect(find.textContaining('响应超时'), findsOneWidget);
      peer
        ..fileCount = 1
        ..listTimeout = false;
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('刷新'));
        await controller.sync();
      });
      await tester.pumpAndSettle();
      expect(find.text('设备中有 1 条录音'), findsOneWidget);
      expect(find.text('待同步 0 条 · 已上传 1 条'), findsOneWidget);
      expect(find.textContaining('上次刷新：'), findsOneWidget);
      expect(find.textContaining('响应超时'), findsNothing);
      expect(uploads, 1);
      expect(tester.takeException(), isNull);
    });
  }
  for (final language in ['en', 'zh']) {
    testWidgets('download ring and ETA in $language survive navigation and end before upload', (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('soundcore_progress_page_');
      final peer =
          FakeSoundcoreDevice(DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000)
            ..stall = true
            ..zeroSize = true;
      final session = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
      var time = DateTime.now();
      final uploadGate = Completer<void>();
      AudioUploadProgress? uploadProgress;
      final store = SoundcoreImportStore(
        root: root,
        ownerId: 'progress-owner',
        deviceId: 'progress-device',
        currentOwner: () => 'progress-owner',
        uploadWithProgress: (_, __, progress) async {
          uploadProgress = progress;
          progress?.call(0, 100000);
          await uploadGate.future;
          return const SoundcoreImportReceipt('progress-result', processing: true);
        },
      );
      final controller = SoundcoreSyncController(
        openStore: () async => store,
        openSession: () async => session,
        isCurrentOwner: () => true,
        now: () => time,
      );
      late Future<void> work;
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 300 && !ready(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(ready(), isTrue);
      }

      addTearDown(() async {
        controller.dispose();
        session.close();
        if (!uploadGate.isCompleted) uploadGate.complete();
        await work;
        await peer.inbound.close();
        root.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        work = controller.sync();
        await waitFor(() => peer.commands.any((c) => c[5] == 0x1a && c[6] == 7));
      });
      time = time.add(const Duration(seconds: 3));
      for (var i = 0; i < 150; i++) {
        peer.emit(response(0x1a, 8, peer.slice(i)));
      }
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        locale: Locale(language),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: const Scaffold(body: Text('Parent')),
      ));
      void openPage() => unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
            builder: (_) => SoundcoreRecordingsPage(
              device: BtDevice(id: 'progress-device', name: '', type: DeviceType.soundcore, rssi: -50),
              controller: controller,
            ),
          )));
      openPage();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final ring = find.byKey(ValueKey('soundcore_download_progress_${peer.fileId}'));
      await tester.scrollUntilVisible(ring, 160);
      expect(tester.widget<CircularProgressIndicator>(ring).value, 0.5);
      expect(find.text('≈50%'), findsOneWidget);
      final card = find.byKey(ValueKey('soundcore_recording_${peer.fileId}'));
      expect(
          find.descendant(
              of: card, matching: find.text(language == 'zh' ? '蓝牙 · 约剩余 00:05' : 'Bluetooth · ~00:05 left')),
          findsOneWidget);
      final metadata = find.byKey(ValueKey('soundcore_metadata_${peer.fileId}'));
      expect(tester.widget<Text>(metadata).data, '≈ 00:06');
      expect(tester.getSize(find.byKey(ValueKey('soundcore_recording_${peer.fileId}'))).height, lessThanOrEqualTo(108));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(controller.downloadEstimate!.fraction, 0.5);
      openPage();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.scrollUntilVisible(ring, 160);
      expect(tester.widget<CircularProgressIndicator>(ring).value, 0.5);
      await tester.runAsync(() async {
        time = time.add(const Duration(seconds: 3));
        for (var i = 150; i < 300; i++) {
          peer.emit(response(0x1a, 8, peer.slice(i)));
        }
        peer.emit(response(0x1a, 0x0a));
        await waitFor(() => controller.stages[peer.fileId] == SoundcoreImportStage.uploading);
      });
      await tester.pump();
      expect(ring, findsNothing);
      final uploadRing = find.byKey(ValueKey('soundcore_upload_progress_${peer.fileId}'));
      expect(uploadRing, findsOneWidget);
      time = time.add(const Duration(seconds: 5));
      uploadProgress!(50000, 100000);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<CircularProgressIndicator>(uploadRing).value, 0.5);
      expect(find.text('≈50%'), findsOneWidget);
      expect(
          find.descendant(
              of: card, matching: find.text(language == 'zh' ? '上传中 · 约剩余 5 秒' : 'Uploading · about 5 s left')),
          findsOneWidget);
      uploadProgress!(100000, 100000);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<CircularProgressIndicator>(uploadRing).value, 1.0);
      expect(
          find.descendant(
              of: card,
              matching: find.textContaining(language == 'zh' ? '等待服务器确认' : 'waiting for server confirmation')),
          findsOneWidget);
      expect(controller.stages[peer.fileId], SoundcoreImportStage.uploading);
      expect(controller.downloadEstimate, isNull);
      expect(tester.widget<Text>(metadata).data, startsWith('00:06 · '));
      await tester.runAsync(() async {
        uploadGate.complete();
        await work;
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Wi-Fi setup phases and empty download explanation remain visible at 320px in $language',
        (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _ConfirmationSync();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        locale: Locale(language),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: SoundcoreRecordingsPage(
          device: BtDevice(name: '', id: 'test-device', type: DeviceType.soundcore, rssi: -50),
          controller: controller,
        ),
      ));
      final labels = language == 'zh'
          ? [
              '正在停止蓝牙下载，准备切换…',
              '正在重新连接录音豆控制通道…',
              '正在开启录音豆热点…',
              '正在等待热点就绪，约 10 秒…',
              '正在加入录音豆 Wi-Fi，请确认系统提示…',
              '正在等待录音豆网络就绪…',
              '正在建立 Wi-Fi 传输连接…',
              '正在通过 Wi-Fi 下载…',
              '正在退出录音豆 Wi-Fi…'
            ]
          : [
              'Preparing Wi-Fi transfer…',
              'Reconnecting recorder controls…',
              'Enabling recorder hotspot…',
              'Waiting for hotspot startup…',
              'Joining recorder Wi-Fi…',
              'Waiting for the recorder network…',
              'Establishing Wi-Fi transfer…',
              'Downloading over Wi-Fi…',
              'Disconnecting recorder Wi-Fi…'
            ];
      for (final phase in SoundcoreWifiState.values) {
        controller.showPhase(phase);
        await tester.pump();
        expect(find.text(labels[phase.index]), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      controller.wifiNothingToDownload = true;
      controller.showPhase(null);
      await tester.pump();
      expect(find.textContaining(language == 'zh' ? '录音已全部下载到手机' : 'All recordings are already downloaded'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      controller.wifiNothingToDownload = false;
      controller.wifiAwaitingCloudCheck = true;
      controller.showPhase(null);
      await tester.pump();
      expect(find.textContaining(language == 'zh' ? '尚有录音需要核对云端状态' : 'Some recordings still need a cloud status check'),
          findsOneWidget);
      expect(
          find.textContaining(language == 'zh' ? '录音已全部下载到手机' : 'All recordings are already downloaded'), findsNothing);
      expect(tester.takeException(), isNull);
      controller.wifiAwaitingCloudCheck = false;
      for (final phase in SoundcoreWifiPhase.values) {
        controller.wifiError = SoundcoreWifiFailure(phase, TimeoutException('not displayed'));
        controller.showPhase(null);
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      controller.wifiError = SoundcoreWifiFailure(SoundcoreWifiPhase.downloading, TimeoutException('not displayed'));
      controller.wifiFailedStep = SoundcoreTransferStep.checkingRecorder;
      controller.showPhase(null);
      await tester.pump();
      expect(find.textContaining(language == 'zh' ? '下载会话未能就绪' : 'download session could not be prepared'),
          findsOneWidget);
      controller.wifiFailedStep = SoundcoreTransferStep.receiving;
      controller.wifiFailedBytes = 1600;
      controller.showPhase(null);
      await tester.pump();
      expect(find.textContaining(language == 'zh' ? 'Wi-Fi 已收到部分音频' : 'Wi-Fi downloaded some audio'), findsOneWidget);
      controller.wifiError = const SoundcoreWifiFailure(SoundcoreWifiPhase.downloading,
          SoundcoreProtocolException(SoundcoreProtocolIssue.checksum, actual: 12, expected: 13));
      controller.showPhase(null);
      await tester.pump();
      expect(find.textContaining(language == 'zh' ? '音频数据校验失败' : 'audio data validation failed'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('Wi-Fi in $language requires explicit confirmation; cancel and dismiss keep Bluetooth', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _ConfirmationSync();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        locale: Locale(language),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: SoundcoreRecordingsPage(
          device: BtDevice(name: '', id: 'test-device', type: DeviceType.soundcore, rssi: -50),
          controller: controller,
        ),
      ));
      await tester.pumpAndSettle();
      expect(controller.checks, 1); // entry requests normal sync, never Wi-Fi
      expect(controller.wifiRequests, 0);

      Future<void> openDialog() async {
        final button = find.byKey(const ValueKey('soundcore_wifi_start'));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('soundcore_wifi_confirmation')), findsOneWidget);
        expect(find.textContaining(language == 'zh' ? '手机会暂时断开当前 Wi-Fi' : 'temporarily leave its current Wi-Fi'),
            findsOneWidget);
        expect(controller.wifiRequests, 0);
        expect(controller.wifiState, isNull);
        expect(tester.takeException(), isNull);
      }

      await openDialog();
      await tester.tap(find.byKey(const ValueKey('soundcore_wifi_cancel')));
      await tester.pumpAndSettle();
      expect(controller.wifiRequests, 0);
      expect(controller.wifiState, isNull);
      await openDialog();
      await tester.tapAt(const Offset(5, 5)); // modal barrier is cancellation
      await tester.pumpAndSettle();
      expect(controller.wifiRequests, 0);
      await openDialog();
      await tester.binding.handlePopRoute(); // system back is also cancellation
      await tester.pumpAndSettle();
      expect(controller.wifiRequests, 0);
      await openDialog();
      await tester.tap(find.byKey(const ValueKey('soundcore_wifi_confirm')));
      await tester.pumpAndSettle();
      expect(controller.wifiRequests, 1);
      expect(find.byKey(const ValueKey('soundcore_wifi_confirmation')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Wi-Fi progress at 320px in $language survives leaving the list', (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('soundcore_wifi_page_');
      final peer =
          FakeSoundcoreDevice(DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000);
      final session = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
      final gate = Completer<void>();
      final wifi = FakeSoundcoreWifi(peer)..gate = gate.future;
      var uploads = 0;
      final store = SoundcoreImportStore(
        root: root,
        ownerId: 'wifi-widget',
        deviceId: 'test-device',
        currentOwner: () => 'wifi-widget',
        upload: (_, __) async {
          expect(wifi.closed, isTrue);
          uploads++;
          return const SoundcoreImportReceipt('wifi-widget', processing: true);
        },
      );
      final controller = SoundcoreSyncController(
        openStore: () async => store,
        openSession: () async => session,
        isCurrentOwner: () => true,
        openWifi: (ble, __) => openFakeSoundcoreWifi(ble, wifi),
      );
      addTearDown(() async {
        controller.dispose();
        session.close();
        await wifi.close();
        await peer.inbound.close();
        root.deleteSync(recursive: true);
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        locale: Locale(language),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: const Scaffold(body: Text('Parent')),
      ));
      late Future<void> work;
      await tester.runAsync(() async {
        work = controller.syncOverWifi();
        for (var i = 0; i < 200 && wifi.requested.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(wifi.requested, hasLength(1));
      });
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => SoundcoreRecordingsPage(
          device: BtDevice(name: '', id: 'test-device', type: DeviceType.soundcore, rssi: -50),
          controller: controller,
        ),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const ValueKey('soundcore_wifi_option')), findsOneWidget);
      expect(find.text(language == 'zh' ? '正在通过 Wi-Fi 下载…' : 'Downloading over Wi-Fi…'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('soundcore_wifi_start'))).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Parent'), findsOneWidget);
      expect(wifi.closed, isFalse);
      expect(controller.activeId, peer.fileId);
      await tester.runAsync(() async {
        gate.complete();
        await work;
      });
      expect(uploads, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('automatic sync page works at 320px in $language and preserves file metadata', (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('soundcore_widget_test_');
      final peer =
          FakeSoundcoreDevice(DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000)
            ..recording = true;
      final session = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
      addTearDown(() {
        session.close();
        unawaited(peer.inbound.close());
        root.deleteSync(recursive: true);
      });
      var uploads = 0;
      final store = SoundcoreImportStore(
        root: root,
        ownerId: 'widget-test',
        deviceId: 'test-device',
        currentOwner: () => 'widget-test',
        upload: (_, __) async {
          uploads++;
          return const SoundcoreImportReceipt('widget-conversation', processing: true);
        },
      );
      final controller = SoundcoreSyncController(
        openStore: () async => store,
        openSession: () async => session,
        isCurrentOwner: () => true,
      );
      addTearDown(controller.dispose);
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          locale: Locale(language),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: SoundcoreRecordingsPage(
            device: BtDevice(name: 'soundcore Work', id: 'test-device', type: DeviceType.soundcore, rssi: -55),
            controller: controller,
          ),
        ));
        // Real filesystem I/O is deliberately outside FakeAsync.
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(uploads, 0);
      final queued = find.text(language == 'zh' ? '等待设备结束录音' : 'Waiting for recording to end');
      await tester.scrollUntilVisible(queued, 160);
      await tester.pumpAndSettle();
      final card = find.byKey(ValueKey('soundcore_recording_${peer.fileId}'));
      final metadata = find.byKey(ValueKey('soundcore_metadata_${peer.fileId}'));
      expect(tester.widget<Text>(metadata).data, '≈ 00:48');
      expect(tester.getSize(card).height, lessThanOrEqualTo(84));
      peer.recording = false;
      await tester.runAsync(controller.sync);
      await tester.pumpAndSettle();
      expect(uploads, 1);
      expect(find.text(language == 'zh' ? '录音列表 · 上传后显示云端处理状态' : 'Recordings · cloud status updates after upload'),
          findsOneWidget);
      expect(queued, findsNothing);
      expect(tester.widget<Text>(metadata).data, startsWith('00:06 · '));
      expect(tester.widget<Text>(metadata).data, isNot(contains(language == 'zh' ? '大小待下载' : 'Size pending')));
      // Existing imports retain their measured values after reopening/refreshing.
      await tester.ensureVisible(find.byTooltip(language == 'zh' ? '刷新' : 'Refresh'));
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip(language == 'zh' ? '刷新' : 'Refresh'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(metadata).data, startsWith('00:06 · '));
      expect(uploads, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
