import 'dart:async';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/soundcore_recordings_page.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/soundcore/import_store.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore/sync_controller.dart';
import 'package:memorion/services/devices/soundcore/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_device.dart';

class _PollingStore extends Fake implements SoundcoreImportStore {
  @override
  Future<String?> conversationId(int id) async => 'job-$id';
}

class _Devices extends Fake implements IDeviceService {
  @override
  BtDevice? connectedDevice;
  IDeviceServiceSubsciption? listener;
  @override
  void subscribe(IDeviceServiceSubsciption subscription, Object context) => listener = subscription;
  @override
  void unsubscribe(Object context) => listener = null;
}

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'Asynchronous sync did not reach the expected state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeSoundcoreDevice peer;
  late SoundcoreSession session;
  late SoundcoreImportStore store;
  late SoundcoreSyncController sync;
  late String owner;
  late int uploads;
  late bool connected;
  late DateTime time;
  int? uploadError;
  AudioUploadFailure? uploadFailure;
  Completer<void>? uploadGate;
  final device = BtDevice(id: 'sync-recorder', name: '', type: DeviceType.soundcore, rssi: -50);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('soundcore_auto_sync_');
    // Quota scenarios below use this fixed month. Their recordings must not
    // become future-dated when the test runner's wall clock moves forward.
    time = DateTime.utc(2026, 9, 21);
    peer = FakeSoundcoreDevice(time.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000);
    session = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
    owner = 'owner-a';
    uploads = 0;
    connected = true;
    uploadError = null;
    uploadFailure = null;
    uploadGate = null;
    store = SoundcoreImportStore(
      root: root,
      ownerId: 'owner-a',
      deviceId: device.id,
      currentOwner: () => owner,
      now: () => time,
      upload: (_, __) async {
        uploads++;
        if (uploadGate != null) await uploadGate!.future;
        if (uploadError != null || uploadFailure != null) {
          throw SoundcoreImportException(uploadError ?? uploadFailure?.statusCode, uploadFailure);
        }
        return SoundcoreImportReceipt('conversation-$uploads', processing: true);
      },
    );
    sync = SoundcoreSyncController(
      openStore: () async => store,
      openSession: () async => connected ? session : null,
      isCurrentOwner: () => owner == 'owner-a',
      now: () => time,
      stopDelay: Duration.zero,
    );
  });

  tearDown(() async {
    sync.dispose();
    session.close();
    await peer.inbound.close();
    root.deleteSync(recursive: true);
  });

  test('upload callback is required in release as well as debug', () {
    expect(
        () => SoundcoreImportStore(
              root: root,
              ownerId: owner,
              deviceId: device.id,
              currentOwner: () => owner,
            ),
        throwsArgumentError);
  });

  test('cloud polling captures local cache failures for timer callers', () async {
    sync.dispose();
    sync = SoundcoreSyncController(
      openStore: () async => throw const FileSystemException('Cannot open cache'),
      openSession: () async => null,
      isCurrentOwner: () => true,
      fetchProcessingJob: (_) async => throw StateError('Must not request the network'),
    );
    await sync.refreshProcessing();
    expect(sync.cacheError, isA<FileSystemException>());
    await sync.refreshProcessing();
    expect(sync.cacheError, isA<FileSystemException>());
  });

  test('cloud processing retry uses saved receipt without reconnecting or uploading', () async {
    await sync.sync();
    expect(uploads, 1);
    final savedRecordings = sync.recordings.toList();
    sync.dispose();
    connected = false;
    var status = 'failed';
    var retries = 0;
    var bleCalls = 0;
    var reads = 0;
    final stalePoll = Completer<AudioProcessingJob>();
    sync = SoundcoreSyncController(
      openStore: () async => store,
      openSession: () async {
        bleCalls++;
        return null;
      },
      isCurrentOwner: () => owner == 'owner-a',
      fetchProcessingJob: (id) async {
        if (++reads == 2) return stalePoll.future;
        return AudioProcessingJob.fromJson({
          'id': id,
          'conversation_id': id,
          'status': status,
          'stage': 'summarize',
          'started_at': DateTime.now().toUtc().toIso8601String(),
          'can_retry': status == 'failed',
          'error_code': status == 'failed' ? 'processing_unavailable' : null,
        });
      },
      retryProcessingJob: (id) async {
        retries++;
        status = 'completed';
      },
    );
    sync.recordings = savedRecordings;
    sync.stages[peer.fileId] = SoundcoreImportStage.uploaded;
    await sync.refreshProcessing();
    expect(sync.processingJobs[peer.fileId]!.status, 'failed');
    final oldFailure = sync.processingJobs[peer.fileId]!;
    final pendingRefresh = sync.refreshProcessing(includeTerminal: true);
    await until(() => reads == 2);
    await sync.retryProcessing(peer.fileId);
    stalePoll.complete(oldFailure);
    await pendingRefresh;
    expect(sync.processingJobs[peer.fileId]!.status, 'completed');
    expect(retries, 1);
    expect(uploads, 1);
    expect(bleCalls, 0);
    expect(await store.status(peer.fileId), SoundcoreImportStage.processed);
  });

  test('cloud polling is bounded and rotates across every recording', () async {
    sync.dispose();
    final requests = <String>[];
    sync = SoundcoreSyncController(
      openStore: () async => _PollingStore(),
      openSession: () async => null,
      isCurrentOwner: () => true,
      fetchProcessingJob: (id) async {
        requests.add(id);
        return AudioProcessingJob.fromJson({
          'id': id,
          'conversation_id': id,
          'status': 'queued',
          'stage': 'transcribe',
          'started_at': '2026-09-19T00:00:00Z',
        });
      },
    );
    sync.recordings = List.generate(17, (i) => SoundcoreRecording(1700000000 + i, 1700000060 + i, 0));
    await sync.refreshProcessing();
    expect(requests, hasLength(8));
    await sync.refreshProcessing();
    expect(requests.toSet(), hasLength(16));
    await sync.refreshProcessing();
    expect(requests, hasLength(24));
    expect(requests.toSet(), hasLength(17));
    requests.clear();
    await sync.refreshProcessing(recordingId: sync.recordings.last.id);
    expect(requests, ['job-${sync.recordings.last.id}']);
  });

  test('cloud failure polling continues during another upload but pauses for recorder Wi-Fi', () async {
    await sync.sync();
    sync.dispose();
    var reads = 0;
    sync = SoundcoreSyncController(
      openStore: () async => store,
      openSession: () async => connected ? session : null,
      isCurrentOwner: () => owner == 'owner-a',
      fetchProcessingJob: (id) async {
        reads++;
        return AudioProcessingJob.fromJson({
          'id': id,
          'conversation_id': id,
          'status': 'failed',
          'stage': 'validate',
          'error_code': 'no_speech',
          'started_at': time.toIso8601String(),
        });
      },
    );
    peer.fileCount = 2;
    uploadGate = Completer<void>();
    final work = sync.sync();
    try {
      await until(() => uploads == 2);
      expect(sync.busy, isTrue);
      await sync.refreshProcessing();
      expect(reads, 1);
      expect(sync.processingJobs[peer.fileId]!.errorCode, 'no_speech');
      expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);
      sync.wifiState = SoundcoreWifiState.verifyingNetwork;
      await sync.refreshProcessing(includeTerminal: true);
      expect(reads, 1);
    } finally {
      sync.wifiState = null;
      uploadGate!.complete();
      await work;
    }
    expect(uploads, 2);
  });

  test('disconnect keeps known undownloaded recordings until a successful directory refresh', () async {
    peer.recording = true;
    peer.fileCount = 3;
    await sync.sync();
    expect(sync.recordings, hasLength(3));
    connected = false;
    await sync.sync();
    expect(sync.deviceFileCount, isNull);
    expect(sync.recordings, hasLength(3));
    expect(sync.waitReason(peer.fileId), SoundcoreSyncWaitReason.connection);
    connected = true;
    peer.fileCount = 1;
    await sync.sync();
    expect(sync.deviceFileCount, 1);
    expect(sync.recordings, hasLength(1));
    expect(uploads, 0);
  });

  test('terminal jobs stop polling until explicitly refreshed', () async {
    sync.dispose();
    var requests = 0;
    sync = SoundcoreSyncController(
      openStore: () async => _PollingStore(),
      openSession: () async => null,
      isCurrentOwner: () => true,
      fetchProcessingJob: (id) async {
        requests++;
        return AudioProcessingJob.fromJson({
          'id': id,
          'conversation_id': id,
          'status': 'failed',
          'stage': 'transcribe',
          'started_at': '2026-09-19T00:00:00Z',
          'can_retry': true,
        });
      },
    );
    sync.recordings = [const SoundcoreRecording(1700000000, 1700000060, 0)];
    await sync.refreshProcessing();
    await sync.refreshProcessing();
    expect(requests, 1);
    await sync.refreshProcessing(includeTerminal: true);
    expect(requests, 2);
    await sync.refreshProcessing();
    expect(requests, 2);
  });

  test('connection and recording-stop trigger automatic sync without opening any page', () async {
    connected = false;
    final devices = _Devices();
    final service = SoundcoreSyncService(
      devices: devices,
      pairedDevice: () => device,
      currentOwner: () => owner,
      createController: (_, __) => sync,
    );
    service.start();
    await service.checkNow();
    expect(uploads, 0);
    connected = true;
    devices.connectedDevice = device;
    peer.recording = true;
    devices.listener!.onDeviceConnectionStateChanged(device.id, DeviceConnectionState.connected);
    await until(() => sync.recordings.isNotEmpty && !sync.busy);
    expect(uploads, 0);
    peer.emit(response(0x18, 0x82, [2]));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await service.checkNow();
    expect(uploads, 0); // paused files must not download either
    peer.recording = false;
    peer.emit(response(0x18, 0x82, [0]));
    await until(() => uploads == 1 && !sync.busy);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);
    // A new file discovered on resume is synced once, with no UI interaction.
    peer.fileCount = 2;
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await until(() => uploads == 2 && !sync.busy);
    await service.checkNow();
    expect(uploads, 2);
    // Service owns this controller; avoid a second dispose in tearDown.
    service.stop();
    sync = SoundcoreSyncController(
        openStore: () async => store, openSession: () async => null, isCurrentOwner: () => false);
  });

  test('simultaneous sync triggers serialize multiple recordings and deduplicate receipts', () async {
    peer.fileCount = 3;
    uploadGate = Completer<void>();
    final first = sync.sync();
    await until(() => uploads == 1);
    final duplicate = sync.sync();
    expect(identical(first, duplicate), isTrue);
    expect(uploads, 1);
    uploadGate!.complete();
    await first;
    expect(uploads, 3);
    expect(peer.commands.where((c) => c[5] == 0x1a && c[6] == 7), hasLength(3));
    await sync.sync();
    expect(uploads, 3);
  });

  test('failed upload backs off then retries cached audio without Bluetooth', () async {
    uploadError = 503;
    await sync.sync();
    expect(uploads, 1);
    expect(sync.failures, contains(peer.fileId));
    await sync.sync();
    expect(uploads, 1);
    connected = false;
    uploadError = null;
    time = time.add(const Duration(minutes: 1));
    await sync.sync();
    expect(uploads, 2);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);
    expect(peer.commands.where((c) => c[5] == 0x1a && c[6] == 7), hasLength(1));
  });

  test('monthly quota response persists but manual retry can resume after upgrade', () async {
    time = DateTime.utc(2026, 9, 21);
    uploadFailure = const AudioUploadFailure(
      AudioUploadIssue.quota,
      statusCode: 429,
      errorCode: 'monthly_cloud_transcription_allowance_exceeded',
    );
    await sync.sync();
    expect(uploads, 1);

    time = DateTime.utc(2026, 9, 25);
    await sync.sync();
    expect(uploads, 1);

    sync.dispose();
    sync = SoundcoreSyncController(
      openStore: () async => store,
      openSession: () async => null,
      isCurrentOwner: () => owner == 'owner-a',
      now: () => time,
    );
    await sync.sync();
    expect(uploads, 1, reason: 'quota error code must survive controller recreation');

    uploadFailure = null;
    await sync.retry(peer.fileId);
    expect(uploads, 2);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);
  });

  test('manual sync during an upload runs next without interrupting or duplicating it', () async {
    peer.fileCount = 3;
    uploadGate = Completer<void>();
    final work = sync.sync();
    await until(() => uploads == 1);
    final requested = sync.retry(peer.fileId + 2);
    expect(sync.activeId, peer.fileId);
    expect(uploads, 1);
    uploadGate!.complete();
    await Future.wait([work, requested]);
    final downloads = peer.commands
        .where((c) => c[5] == 0x1a && c[6] == 7)
        .map((c) => c[13] | (c[14] << 8) | (c[15] << 16) | (c[16] << 24));
    expect(downloads, [peer.fileId, peer.fileId + 2, peer.fileId + 1]);
    expect(uploads, 3);
    expect(sync.busy, isFalse);
  });

  test('manual sync waits for recording to end and resumes without a second tap', () async {
    peer.recording = true;
    await sync.sync();
    expect(sync.waitReason(peer.fileId), SoundcoreSyncWaitReason.recording);
    await sync.retry(peer.fileId);
    expect(sync.isSyncRequested(peer.fileId), isTrue);
    expect(uploads, 0);
    peer.recording = false;
    await sync.sync();
    expect(uploads, 1);
    expect(sync.isSyncRequested(peer.fileId), isFalse);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);
  });

  test('historical duration rejection is separate from pending recordings and does not stop their sync', () async {
    peer.fileCount = 3;
    final recordings = await session.listRecordings();
    final oldRecording = recordings.last;
    final downloaded = await session.download(oldRecording);
    addTearDown(downloaded.dispose);
    await expectLater(
      store.importRecording(oldRecording,
          download: () async => SoundcoreDownload(await downloaded.readBytes(), const Duration(milliseconds: 300))),
      throwsA(isA<SoundcoreImportException>()),
    );
    peer.recording = true;
    await sync.sync();
    expect(uploads, 0);
    expect(sync.failures.keys, [oldRecording.id]);
    final snapshot = sync.diagnostics;
    expect(snapshot, contains('Pending row=1 stage=queued active=false wait=recording rejected=false'));
    expect(snapshot, contains('Pending row=3 stage=downloaded active=false wait=queued rejected=true'));
    expect(snapshot, contains('estimatedMs=48000 cachedMs=300 failure=issue=duration source=local'));
    for (final file in recordings) {
      expect(snapshot, isNot(contains(file.id.toString())));
    }
    expect(snapshot, isNot(contains(owner)));
    peer.recording = false;
    await sync.sync();
    expect(uploads, 2);
    expect(sync.failures.keys, [oldRecording.id]);
    expect(sync.stages.values.where((stage) => stage == SoundcoreImportStage.uploaded), hasLength(2));
  });

  test('manual oversized retry does not re-upload every paused recording', () async {
    peer.fileCount = 2;
    time = DateTime.utc(2026, 9, 21);
    uploadFailure = const AudioUploadFailure(
      AudioUploadIssue.quota,
      statusCode: 429,
      errorCode: 'monthly_cloud_transcription_upload_exceeds_remaining',
    );
    await sync.sync();
    expect(uploads, 2);
    expect(sync.failures, hasLength(2));

    uploadFailure = null;
    await sync.retry(peer.fileId);

    expect(uploads, 3, reason: 'manual retry must bypass only the selected oversized recording');
    expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);
  });

  test('subscription upgrade clears persisted monthly quota pause', () async {
    time = DateTime.utc(2026, 9, 21);
    uploadFailure = const AudioUploadFailure(
      AudioUploadIssue.quota,
      statusCode: 429,
      errorCode: 'monthly_cloud_transcription_allowance_exceeded',
    );
    await sync.sync();
    expect(uploads, 1);

    uploadFailure = null;
    expect(await sync.resumeAfterSubscriptionUpgrade(), isTrue);
    expect(uploads, 2);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);
  });

  test('subscription upgrade resumes persisted quota pause after recorder reconnects', () async {
    time = DateTime.utc(2026, 9, 21);
    uploadFailure = const AudioUploadFailure(
      AudioUploadIssue.quota,
      statusCode: 429,
      errorCode: 'monthly_cloud_transcription_allowance_exceeded',
    );
    await sync.sync();
    expect(uploads, 1);

    BtDevice? paired;
    final devices = _Devices();
    final service = SoundcoreSyncService(
      devices: devices,
      pairedDevice: () => paired,
      currentOwner: () => owner,
      createController: (_, __) => sync,
    );
    service.start();
    expect(await service.resumeAfterSubscriptionUpgrade(), isTrue);

    uploadFailure = null;
    paired = device;
    await service.checkNow();
    expect(uploads, 2);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);

    service.stop();
    sync = SoundcoreSyncController(
        openStore: () async => store, openSession: () async => null, isCurrentOwner: () => false);
  });

  test('failed disconnected upgrade resume is consumed once', () async {
    time = DateTime.utc(2026, 9, 21);
    uploadFailure = const AudioUploadFailure(
      AudioUploadIssue.quota,
      statusCode: 429,
      errorCode: 'monthly_cloud_transcription_allowance_exceeded',
    );
    await sync.sync();
    expect(uploads, 1);

    BtDevice? paired;
    final devices = _Devices();
    final service = SoundcoreSyncService(
      devices: devices,
      pairedDevice: () => paired,
      currentOwner: () => owner,
      createController: (_, __) => sync,
    );
    service.start();
    expect(await service.resumeAfterSubscriptionUpgrade(), isTrue);

    paired = device;
    await service.checkNow();
    expect(uploads, 2, reason: 'the deferred Pro wake-up gets one attempt');
    await service.checkNow();
    expect(uploads, 2, reason: 'a failed wake-up must restore normal monthly backoff');

    service.stop();
    sync = SoundcoreSyncController(
        openStore: () async => store, openSession: () async => null, isCurrentOwner: () => false);
  });

  test('restart restores pending uploads and persisted permanent rejection is not auto-retried', () async {
    uploadError = 400;
    await sync.sync();
    expect(uploads, 1);
    sync.dispose();
    sync = SoundcoreSyncController(
      openStore: () async => store,
      openSession: () async => null,
      isCurrentOwner: () => owner == 'owner-a',
    );
    await sync.sync();
    expect(uploads, 1);
    expect(sync.failures[peer.fileId], isA<SoundcoreImportException>());
    uploadError = null;
    await sync.retry(peer.fileId);
    expect(uploads, 2);
    expect(await store.rejectionStatus(peer.fileId), isNull);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);
  });

  test('transient cached upload resumes automatically after controller recreation', () async {
    uploadError = 503;
    await sync.sync();
    sync.dispose();
    uploadError = null;
    sync = SoundcoreSyncController(
      openStore: () async => store,
      openSession: () async => null,
      isCurrentOwner: () => owner == 'owner-a',
    );
    await sync.sync();
    expect(uploads, 2);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);
    expect(peer.commands.where((c) => c[5] == 0x1a && c[6] == 7), hasLength(1));
  });

  test('account changes during download prevent uploading to the next account', () async {
    final gate = Completer<void>();
    peer.downloadGate = gate.future;
    final work = sync.sync();
    await until(() => peer.commands.any((c) => c[5] == 0x1a && c[6] == 7));
    owner = 'owner-b';
    gate.complete();
    await work;
    expect(uploads, 0);
    expect(sync.activeId, isNull);
    expect(sync.busy, isFalse);
    await sync.sync();
    expect(uploads, 0);
  });

  test('incomplete BLE download retries automatically with a fresh connection', () async {
    peer.missingSlice = true;
    await sync.sync();
    expect(uploads, 0);
    expect(session.isClosed, isTrue);
    expect(sync.activeId, isNull);
    session.close();
    await peer.inbound.close();
    peer = FakeSoundcoreDevice(peer.fileId);
    session = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
    time = time.add(const Duration(minutes: 1));
    await sync.sync();
    expect(uploads, 1);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.uploaded);
  });

  test('an in-flight recording does not prevent the rest of the queue from uploading', () async {
    peer.fileCount = 3;
    uploadError = 409;
    await sync.sync();
    expect(uploads, 3);
    expect(sync.diagnostics, contains('http=409'));
    expect((await store.lastUploadFailure(peer.fileId))!.statusCode, 409);
    // 409 is not acceptance. The idempotent server returns a receipt once the
    // original upload completes; receiving it stops all further re-uploads.
    uploadError = null;
    time = time.add(const Duration(minutes: 1));
    await sync.sync();
    expect(uploads, 6);
    await sync.sync();
    expect(uploads, 6);
  });

  test('one server failure pauses the backlog rather than uploading every file', () async {
    peer.fileCount = 3;
    uploadError = 503;
    await sync.sync();
    expect(uploads, 1);
    expect(sync.activeId, isNull);
    await sync.sync();
    expect(uploads, 1);
    time = time.add(const Duration(minutes: 1));
    uploadError = null;
    await sync.sync();
    expect(uploads, 4);
    expect(sync.stages.values.every((stage) => stage == SoundcoreImportStage.uploaded), isTrue);
  });

  test('packet bursts preserve every audio byte without notifying the UI for every packet', () async {
    peer.stall = true;
    final work = sync.sync();
    await until(() => session.transferStep == SoundcoreTransferStep.receiving);
    var updates = 0;
    var displayedBytes = 0;
    sync.addListener(() {
      updates++;
      displayedBytes = sync.bytes;
    });
    try {
      for (var i = 0; i < 500; i++) {
        peer.emit(response(0x1a, 8, peer.slice(i)));
      }
      expect(sync.bytes, 80000, reason: 'Throttling UI updates must not drop audio or progress samples');
      expect(updates, lessThanOrEqualTo(1), reason: 'A packet burst must not cause hundreds of page refreshes');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(updates, inInclusiveRange(1, 2));
      expect(displayedBytes, 80000, reason: 'Visible progress should catch up within 300 ms');
    } finally {
      peer.emit(response(0x1a, 0x0a));
      await work;
    }
    expect(uploads, 1);
    expect(await store.status(peer.fileId), SoundcoreImportStage.uploaded);
    final afterCompletion = updates;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(updates, afterCompletion, reason: 'No progress timer should survive completion');
  });

  for (final phase in [SoundcoreImportStage.downloading, SoundcoreImportStage.uploading]) {
    testWidgets('back navigation during $phase preserves App-owned sync and reopening progress', (tester) async {
      final gate = Completer<void>();
      if (phase == SoundcoreImportStage.downloading) {
        peer.downloadGate = gate.future;
      } else {
        uploadGate = gate;
      }
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        locale: const Locale('zh'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: const Scaffold(body: Text('Parent page')),
      ));
      await tester.runAsync(() async {
        unawaited(sync.sync()); // no page is needed to start the transfer
        await until(() => sync.stages[peer.fileId] == phase);
        if (phase == SoundcoreImportStage.downloading) {
          // File creation is real async I/O. Enter fake widget time only after
          // the download is actually waiting at the synthetic device gate.
          await until(() => session.transferStep == SoundcoreTransferStep.receiving);
        }
      });
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => SoundcoreRecordingsPage(device: device, controller: sync),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(sync.activeId, peer.fileId);
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Parent page'), findsOneWidget);
      expect(sync.activeId, peer.fileId);
      // Reopening while still transferring attaches to the very same task.
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => SoundcoreRecordingsPage(device: device, controller: sync),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(sync.activeId, peer.fileId);
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(() async {
        gate.complete();
        await until(() => !sync.busy);
      });
      expect(uploads, 1);
      expect(await tester.runAsync(() => store.status(peer.fileId)), SoundcoreImportStage.uploaded);
      expect(tester.takeException(), isNull);
    });
  }
}
