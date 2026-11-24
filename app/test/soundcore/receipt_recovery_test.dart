import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/services/devices/soundcore/import_store.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore/sync_controller.dart';

import 'fake_device.dart';
import 'fake_wifi.dart';

AudioRecordingUploadState remote(SoundcoreRecording file, {String? status = 'completed', bool discarded = false}) =>
    AudioRecordingUploadState.fromJson({
      'can_upload': status == null,
      if (status != null) ...{
        'conversation_id': 'cloud-${file.id}',
        'processing': status != 'completed',
        'duration_seconds': 2280,
        'job': {
          'id': 'cloud-${file.id}',
          'conversation_id': 'cloud-${file.id}',
          'status': status,
          'stage': 'summarize',
          'started_at': file.startedAt.toIso8601String(),
          'discarded': discarded,
          'can_retry': status == 'failed',
        },
      },
    });

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
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
  late DateTime time;

  SoundcoreImportStore newStore() => SoundcoreImportStore(
        root: root,
        ownerId: 'owner',
        deviceId: 'new-install-device',
        currentOwner: () => owner,
        now: () => time,
        upload: (_, __) async {
          uploads++;
          return const SoundcoreImportReceipt('new-upload', processing: true);
        },
      );

  void configure(Future<Map<int, AudioRecordingUploadState>> Function(List<SoundcoreRecording>) lookup,
      {FakeSoundcoreWifi? wifi}) {
    sync = SoundcoreSyncController(
      openStore: () async => store,
      openSession: () async => session,
      isCurrentOwner: () => owner == 'owner',
      lookupRecordings: lookup,
      now: () => time,
      stopDelay: Duration.zero,
      openWifi: (ble, _) async {
        if (wifi != null) return openFakeSoundcoreWifi(ble, wifi);
        throw StateError('Must not open hotspot before cloud reconciliation');
      },
    );
  }

  int downloads() => peer.commands.where((frame) => frame[5] == 0x1a && frame[6] == 7).length;

  setUp(() {
    root = Directory.systemTemp.createTempSync('soundcore_reinstall_');
    time = DateTime.utc(2026, 9, 22);
    owner = 'owner';
    uploads = 0;
    peer = FakeSoundcoreDevice(time.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000);
    session = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
    store = newStore();
  });
  tearDown(() async {
    sync.dispose();
    session.close();
    await peer.inbound.close();
    root.deleteSync(recursive: true);
  });

  for (final status in ['completed', 'queued', 'failed']) {
    test('fresh install restores $status receipt and never transfers the recording', () async {
      configure((files) async => {for (final file in files) file.id: remote(file, status: status, discarded: true)});
      await sync.sync();
      expect(uploads, 0);
      expect(downloads(), 0);
      expect(sync.processingJobs[peer.fileId]!.status, status);
      expect(sync.processingJobs[peer.fileId]!.discarded, isTrue);
      expect(sync.needsCloudCheck(peer.fileId), isFalse);
      await sync.retry(peer.fileId);
      expect(uploads, 0);
      // Durable metadata can be restored even though the reinstall has no audio.
      final restarted = newStore();
      expect(await restarted.conversationId(peer.fileId), 'cloud-${peer.fileId}');
      expect(await restarted.status(peer.fileId),
          status == 'completed' ? SoundcoreImportStage.processed : SoundcoreImportStage.uploaded);
      expect((await restarted.recordingDetails(peer.fileId))!.duration, const Duration(minutes: 38));
      expect((await restarted.recordingDetails(peer.fileId))!.sizeBytes, isNull);
      final file = (await restarted.cachedRecordings()).single;
      await restarted.importRecording(file, download: () async => throw StateError('Receipt must skip downloading'));
      expect(uploads, 0);
    });
  }

  test('a pending cloud request gates automatic and manual transfers', () async {
    final gate = Completer<Map<int, AudioRecordingUploadState>>();
    List<SoundcoreRecording>? requested;
    configure((files) {
      requested = files;
      return gate.future;
    });
    final work = sync.sync();
    await until(() => requested != null);
    expect(sync.loading, isTrue);
    expect(sync.waitReason(peer.fileId), SoundcoreSyncWaitReason.checkingCloud);
    final manual = sync.retry(peer.fileId);
    expect(downloads(), 0);
    expect(uploads, 0);
    gate.complete({for (final file in requested!) file.id: remote(file)});
    await Future.wait([work, manual]);
    expect(downloads(), 0);
    expect(uploads, 0);
  });

  test('lookup failure blocks BLE and Wi-Fi until a retry restores the receipt', () async {
    var online = false;
    configure((files) async {
      if (!online) throw const SocketException('Offline');
      return {for (final file in files) file.id: remote(file)};
    });
    await sync.sync();
    expect(sync.cloudLookupError, isA<SocketException>());
    await sync.syncOverWifi();
    expect(sync.wifiState, isNull);
    expect(sync.wifiAwaitingCloudCheck, isTrue);
    expect(sync.wifiNothingToDownload, isFalse);
    expect(sync.wifiError, isNull);
    expect(downloads(), 0);
    expect(uploads, 0);
    online = true;
    await sync.retry(peer.fileId);
    expect(sync.cloudLookupError, isNull);
    expect(sync.wifiAwaitingCloudCheck, isFalse);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.processed);
    expect(uploads, 0);
  });

  test('only a cloud-confirmed new file is downloaded and uploaded', () async {
    peer.fileCount = 2;
    configure((files) async =>
        {for (final file in files) file.id: remote(file, status: file.id == peer.fileId ? 'completed' : null)});
    await sync.sync();
    expect(uploads, 1);
    expect(downloads(), 1);
    expect(sync.stages[peer.fileId], SoundcoreImportStage.processed);
    expect(sync.stages[peer.fileId + 1], SoundcoreImportStage.uploaded);
  });

  test('an unresolved file does not block Wi-Fi for a cloud-confirmed new file', () async {
    peer.fileCount = 2;
    final wifi = FakeSoundcoreWifi(peer);
    addTearDown(wifi.close);
    configure(
        (files) async => {
              for (final file in files)
                file.id: file.id == peer.fileId
                    ? AudioRecordingUploadState.fromJson({'can_upload': false})
                    : remote(file, status: null),
            },
        wifi: wifi);
    await sync.syncOverWifi();
    expect(wifi.requested, [peer.fileId + 1]);
    expect(wifi.closed, isTrue);
    expect(sync.wifiError, isNull);
    expect(sync.wifiAwaitingCloudCheck, isTrue);
    expect(sync.wifiNothingToDownload, isFalse);
    expect(sync.needsCloudCheck(peer.fileId), isTrue);
    expect(uploads, 1);
    expect(downloads(), 0);
  });

  test('all device records are checked in bounded batches beyond the displayed page', () async {
    peer.fileCount = 45;
    final batches = <int>[];
    configure((files) async {
      batches.add(files.length);
      return {for (final file in files) file.id: remote(file)};
    });
    await sync.sync();
    expect(batches, [20, 20, 5]);
    expect(sync.stages.values.where((stage) => stage == SoundcoreImportStage.processed), hasLength(45));
    expect(downloads(), 0);
    expect(uploads, 0);
  });

  test('late cloud response after logout cannot write a receipt', () async {
    final gate = Completer<Map<int, AudioRecordingUploadState>>();
    List<SoundcoreRecording>? requested;
    configure((files) {
      requested = files;
      return gate.future;
    });
    final work = sync.sync();
    await until(() => requested != null);
    owner = 'other-owner';
    gate.complete({for (final file in requested!) file.id: remote(file)});
    await work;
    owner = 'owner';
    expect(await store.conversationId(peer.fileId), isNull);
    expect(uploads, 0);
  });

  test('an ambiguous or incomplete lookup never authorizes upload', () async {
    var incomplete = true;
    configure((files) async => incomplete
        ? {}
        : {
            for (final file in files) file.id: AudioRecordingUploadState.fromJson({'can_upload': false})
          });
    await sync.sync();
    expect(sync.cloudLookupError, isA<FormatException>());
    incomplete = false;
    await sync.retry(peer.fileId);
    expect(sync.needsCloudCheck(peer.fileId), isTrue);
    expect(downloads(), 0);
    expect(uploads, 0);
  });

  test('a queued new file is checked again after the negative cache expires', () async {
    peer.recording = true; // The recorder cannot transfer yet.
    var alreadyUploaded = false;
    configure((files) async =>
        {for (final file in files) file.id: remote(file, status: alreadyUploaded ? 'completed' : null)});
    await sync.sync();
    expect(sync.needsCloudCheck(peer.fileId), isFalse);
    expect(uploads, 0);
    time = time.add(const Duration(minutes: 6));
    expect(sync.isCheckingCloud(peer.fileId), isFalse);
    expect(sync.waitReason(peer.fileId), SoundcoreSyncWaitReason.cloudCheckRequired);
    alreadyUploaded = true;
    peer.recording = false;
    await sync.sync();
    expect(sync.stages[peer.fileId], SoundcoreImportStage.processed);
    expect(downloads(), 0);
    expect(uploads, 0);
  });
}
