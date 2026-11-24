import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/services/devices/dingtalk_a1/identity.dart';
import 'package:memorion/services/devices/dingtalk_a1/import_store.dart';
import 'package:memorion/services/devices/dingtalk_a1/protocol.dart';
import 'package:memorion/services/devices/dingtalk_a1/session.dart';
import 'package:memorion/services/devices/dingtalk_a1/sync_controller.dart';
import 'package:memorion/services/devices/offline_recordings/import_store.dart';
import 'package:memorion/services/devices/offline_recordings/models.dart';
import 'fake_device.dart';
import 'native_opus.dart';

void main() {
  late Directory root;
  late String owner;
  late FakeA1 peer;
  late A1Session session;
  late A1ImportStore store;
  late A1SyncController sync;
  bool online = true, enabled = false;
  int uploads = 0;
  int? reject;
  setUpAll(loadTestOpus);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('memorion_a1_test_');
    owner = 'owner-a';
    online = true;
    enabled = false;
    uploads = 0;
    reject = null;
    peer = FakeA1(File('test/dingtalk_a1/fixtures/synthetic_tone.dtyj').readAsBytesSync());
    session = A1Session(
        identity: A1Identity('test-did', 'test-corp', '0123456789abcdef0123456789abcdef'),
        send: peer.send,
        notifications: peer.inbound.stream);
    await session.authenticate();
    store = A1ImportStore(
        root: root,
        ownerId: 'owner-a',
        deviceId: 'a1',
        currentOwner: () => owner,
        upload: (file, time) async {
          uploads++;
          expect(time, DateTime.fromMillisecondsSinceEpoch(peer.fid * 1000, isUtc: true));
          expect(file.path.endsWith('.ogg'), isTrue);
          expect(file.readAsBytesSync().take(4), [79, 103, 103, 83]);
          if (reject != null) throw OfflineImportException(reject);
          return const OfflineImportReceipt('test-conversation', processing: true);
        });
    sync = A1SyncController(
        openStore: () async => store,
        openSession: () async => online ? session : null,
        isCurrentOwner: () => owner == 'owner-a',
        readAutoSync: () async => enabled,
        writeAutoSync: (value) async => enabled = value);
  });
  tearDown(() async {
    sync.dispose();
    session.close();
    await peer.close();
    await root.delete(recursive: true);
  });
  test('default connection only lists; explicit import completes BLE to Ogg to receipt', () async {
    await sync.refresh();
    expect(sync.recordings.length, 1);
    expect(uploads, 0);
    expect(peer.commands, isNot(contains(0x0111)));
    await sync.importOne(sync.recordings.single);
    expect(uploads, 1);
    expect(sync.stages[peer.fid], OfflineImportStage.uploaded);
    expect(await File('${store.directory.path}/${peer.fid}.dtyj').exists(), isTrue);
    final playable = await sync.playable(peer.fid);
    expect(playable, isNotNull);
    expect(playable!.path.endsWith('.wav'), isTrue);
    final wav = playable.readAsBytesSync();
    expect(wav.take(4), [82, 73, 70, 70]);
    expect(ByteData.sublistView(wav).getUint32(24, Endian.little), 16000);
    expect(ByteData.sublistView(wav).getUint32(40, Endian.little), 192000);
    expect(wav.length, 192044);
    await sync.importOne(sync.recordings.single);
    expect(uploads, 1);
  });
  test('failed upload retries from durable cache after disconnect', () async {
    await sync.refresh();
    reject = 503;
    await sync.importOne(sync.recordings.single);
    expect(sync.stages[peer.fid], OfflineImportStage.downloaded);
    online = false;
    reject = null;
    await sync.importOne(sync.recordings.single, retry: true);
    expect(uploads, 2);
    expect(sync.stages[peer.fid], OfflineImportStage.uploaded);
  });
  test('encrypted recordings stay local and survive restart without re-downloading', () async {
    peer.audio[58] = 1;
    await sync.refresh();
    await sync.importOne(sync.recordings.single);
    expect(uploads, 0);
    expect((sync.errors[peer.fid] as A1Exception).issue, A1Issue.encryptedAudio);
    expect(await store.audioIssue(peer.fid), A1Issue.encryptedAudio);
    expect((await store.cachedRecordings()).single.id, peer.fid);
    final before = peer.commands.where((c) => c == 0x0111).length;
    online = false;
    await sync.importOne(sync.recordings.single, retry: true);
    expect(peer.commands.where((c) => c == 0x0111).length, before);
    expect(uploads, 0);
  });
  test('account switch during download cannot cache or upload the previous account audio', () async {
    await sync.refresh();
    final gate = Completer<void>();
    peer.downloadGate = gate.future;
    final importing = sync.importOne(sync.recordings.single);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    owner = 'owner-b';
    sync.retire();
    gate.complete();
    await importing;
    expect(uploads, 0);
    expect(sync.recordings, isEmpty);
    expect(sync.ownerActive, isFalse);
    await expectLater(store.cachedRecordings(), throwsA(isA<StateError>()));
  });
  test('processing acceptance is not completion; completion is durable', () async {
    await sync.refresh();
    await sync.importOne(sync.recordings.single);
    expect(sync.stages[peer.fid], OfflineImportStage.uploaded);
    final polls = A1SyncController(
        openStore: () async => store,
        openSession: () async => null,
        isCurrentOwner: () => true,
        readAutoSync: () async => false,
        writeAutoSync: (_) async {},
        fetchJob: (id) async => AudioProcessingJob.fromJson({
              'id': id,
              'conversation_id': id,
              'status': 'completed',
              'stage': 'publish',
              'started_at': '2026-09-20T00:00:00Z'
            }));
    polls.recordings = [OfflineRecording(peer.fid, 0, 6000)];
    polls.stages[peer.fid] = OfflineImportStage.uploaded;
    await polls.refreshProcessing();
    expect(polls.stages[peer.fid], OfflineImportStage.processed);
    expect(await store.status(peer.fid), OfflineImportStage.processed);
    polls.dispose();
  });
  test('opted-in automatic import runs without opening the recordings page', () async {
    enabled = true;
    await sync.refresh();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (sync.stages[peer.fid] != OfflineImportStage.uploaded && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(sync.stages[peer.fid], OfflineImportStage.uploaded);
    expect(uploads, 1);
    await sync.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(uploads, 1);
  });
  test('cache restores even if the connected protocol session is already closed', () async {
    await sync.refresh();
    reject = 503;
    await sync.importOne(sync.recordings.single);
    session.close();
    final restored = A1SyncController(
        openStore: () async => store,
        openSession: () async => throw const A1Exception(A1Issue.disconnected),
        isCurrentOwner: () => true,
        readAutoSync: () async => false,
        writeAutoSync: (_) async {});
    await restored.refresh();
    expect(restored.recordings.single.id, peer.fid);
    expect(restored.stages[peer.fid], OfflineImportStage.downloaded);
    expect(restored.connected, isFalse);
    expect(restored.error, isA<A1Exception>());
    restored.dispose();
  });
}
