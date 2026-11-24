import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/services/devices/soundcore/import_store.dart';
import 'package:memorion/services/devices/soundcore/ogg_opus.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore/sync_controller.dart';

import 'fake_device.dart';
import 'fake_wifi.dart';

Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

class _UnreadableStore extends Fake implements SoundcoreImportStore {
  @override
  Future<Set<int>> removedRecordingIds() async => throw const FileSystemException('Unreadable history');
}

void main() {
  late Directory root;
  late String owner;
  late FakeSoundcoreDevice peer;
  late SoundcoreSession session;
  late SoundcoreImportStore store;
  late SoundcoreSyncController sync;
  late int uploads;

  SoundcoreImportStore newStore({String account = 'owner', String device = 'bean'}) => SoundcoreImportStore(
        root: root,
        ownerId: account,
        deviceId: device,
        currentOwner: () => owner,
        upload: (_, __) async {
          uploads++;
          return const SoundcoreImportReceipt('job', processing: true);
        },
      );
  SoundcoreSyncController newSync() => SoundcoreSyncController(
        openStore: () async => newStore(),
        openSession: () async => session,
        isCurrentOwner: () => owner == 'owner',
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('soundcore_removal_');
    owner = 'owner';
    uploads = 0;
    peer = FakeSoundcoreDevice(DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000);
    session = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
    store = newStore();
    sync = newSync();
  });
  tearDown(() async {
    sync.dispose();
    session.close();
    await peer.inbound.close();
    await root.delete(recursive: true);
  });

  test('Undo reservation keeps cache and history intact and blocks transfer', () async {
    final recording = SoundcoreRecording(peer.fileId, peer.fileId + 1, 0);
    await store.cacheRecording(recording,
        download: () async => SoundcoreDownload(
            soundcoreOggOpus([
              Uint8List(160)..setAll(0, [0xf8, 0xff, 0xfe])
            ]),
            const Duration(seconds: 1)));
    await sync.sync();
    expect(sync.reserveRemoval(recording.id), isTrue);
    expect(sync.canRemove(recording.id), isFalse);
    await sync.sync();
    expect(uploads, 0);
    expect(await store.removedRecordingIds(), isEmpty);
    expect(await File('${store.directory.path}/${recording.id}.ogg').exists(), isTrue);
    sync.cancelRemoval(recording.id);
    expect(sync.isRemoving(recording.id), isFalse);
    expect(sync.recordings.single.id, recording.id);
    expect(await store.removedRecordingIds(), isEmpty);
    expect(await File('${store.directory.path}/${recording.id}.ogg').exists(), isTrue);
  });

  test('short recording removal survives restart and device rediscovery without uploading or deleting originals',
      () async {
    final recording = SoundcoreRecording(peer.fileId, peer.fileId + 1, 0);
    await store.cacheRecording(recording,
        download: () async => SoundcoreDownload(
            soundcoreOggOpus([
              Uint8List(160)..setAll(0, [0xf8, 0xff, 0xfe])
            ]),
            const Duration(seconds: 1)));
    await sync.sync();
    expect(sync.failures[recording.id], isA<SoundcoreImportException>());
    await sync.removeRecording(recording.id);
    expect(sync.recordings, isEmpty);
    expect(await File('${store.directory.path}/${recording.id}.ogg').exists(), isFalse);
    expect(await newStore().cachedRecordings(), isEmpty);
    sync.dispose();
    sync = newSync();
    await sync.sync();
    await sync.retry(recording.id);
    expect(sync.recordings, isEmpty);
    expect(uploads, 0);
    expect(peer.commands.where((c) => c[5] == 0x1a && (c[6] == 7 || c[6] == 0x10)), isEmpty);
    expect(await newStore(device: 'other-bean').removedRecordingIds(), isEmpty);
    owner = 'other-owner';
    expect(await newStore(account: owner).removedRecordingIds(), isEmpty);
    await expectLater(store.removeRecording(recording.id), throwsStateError);
  });

  for (final wifi in [false, true]) {
    test('removal skips a queued ${wifi ? 'Wi-Fi' : 'BLE'} file and rejects deletion of the active transfer', () async {
      peer.fileCount = 2;
      final gate = Completer<void>();
      final transport = FakeSoundcoreWifi(peer)..gate = gate.future;
      peer.downloadGate = gate.future;
      if (wifi) {
        sync.dispose();
        sync = SoundcoreSyncController(
          openStore: () async => store,
          openSession: () async => session,
          isCurrentOwner: () => true,
          openWifi: (ble, _) => openFakeSoundcoreWifi(ble, transport),
        );
      }
      final running = wifi ? sync.syncOverWifi() : sync.sync();
      await until(() => sync.activeId == peer.fileId);
      try {
        expect(sync.canRemove(peer.fileId), isFalse);
        await expectLater(sync.removeRecording(peer.fileId), throwsStateError);
        await sync.removeRecording(peer.fileId + 1);
      } finally {
        gate.complete();
        await running;
      }
      expect(sync.recordings.map((r) => r.id), [peer.fileId]);
      if (wifi) {
        expect(transport.requested, [peer.fileId]);
      } else {
        final requested = peer.commands
            .where((c) => c[5] == 0x1a && c[6] == 7)
            .map((c) => ByteData.sublistView(c).getUint32(13, Endian.little));
        expect(requested, [peer.fileId]);
      }
      expect(uploads, 1);
      await transport.close();
    });
  }

  test('late cloud result cannot restore a removed no-speech row', () async {
    final recording = SoundcoreRecording(peer.fileId, peer.fileId + 6, 48000);
    await store.restoreReceipt(recording, const SoundcoreImportReceipt('job', processing: true));
    final gate = Completer<AudioProcessingJob>();
    final requested = Completer<void>();
    sync.dispose();
    sync = SoundcoreSyncController(
      openStore: () async => store,
      openSession: () async => null,
      isCurrentOwner: () => true,
      fetchProcessingJob: (_) {
        requested.complete();
        return gate.future;
      },
    );
    await sync.sync();
    final polling = sync.refreshProcessing();
    await requested.future;
    await sync.removeRecording(recording.id);
    gate.complete(AudioProcessingJob.fromJson({
      'id': 'job',
      'status': 'failed',
      'error_code': 'no_speech',
      'conversation_id': 'conversation',
      'stage': 'failed',
      'started_at': '2026-10-15T10:00:00Z'
    }));
    await polling;
    expect(sync.processingJobs, isEmpty);
    expect(sync.recordings, isEmpty);
    expect(await store.conversationId(recording.id), isNull);
  });

  test('failed tombstone commit leaves the row and its receipt available', () async {
    final recording = SoundcoreRecording(peer.fileId, peer.fileId + 6, 48000);
    await store.restoreReceipt(recording, const SoundcoreImportReceipt('job', processing: true));
    await sync.sync();
    final marker = Directory('${store.directory.path}/${recording.id}.removed');
    await marker.create();
    await expectLater(sync.removeRecording(recording.id), throwsA(isA<FileSystemException>()));
    expect(sync.recordings.map((r) => r.id), [recording.id]);
    expect(sync.canRemove(recording.id), isTrue);
    expect(await store.conversationId(recording.id), 'job');
  });

  test('unreadable removal history blocks device discovery and imports', () async {
    var opened = false;
    sync.dispose();
    sync = SoundcoreSyncController(
      openStore: () async => _UnreadableStore(),
      openSession: () async {
        opened = true;
        return session;
      },
      isCurrentOwner: () => true,
    );
    await sync.sync();
    expect(opened, isFalse);
    expect(sync.cacheError, isA<FileSystemException>());
    expect(uploads, 0);
  });

  test('concurrent removals retain both tombstones', () async {
    await Future.wait([store.removeRecording(peer.fileId), newStore().removeRecording(peer.fileId + 1)]);
    expect(await newStore().removedRecordingIds(), {peer.fileId, peer.fileId + 1});
  });
}
