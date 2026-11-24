import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/import_store.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/sync_controller.dart';
import 'package:memorion/services/devices/offline_recordings/import_store.dart';
import 'fake_device.dart';
import '../dingtalk_a1/native_opus.dart';

void main() {
  const id = 1700000000;
  late Peer peer;
  late Directory root;
  late PlaudImportStore store;
  late PlaudSyncController sync;
  late Uint8List raw;
  var owner = 'a', online = true;
  late Completer<void> downloadStarted;
  var uploads = 0, downloads = 0;
  int? reject;
  Future<void>? gate;
  setUpAll(loadTestOpus);
  setUp(() async {
    owner = 'a';
    FlutterSecureStorage.setMockInitialValues({});
    downloadStarted = Completer<void>();
    online = true;
    uploads = 0;
    downloads = 0;
    reject = null;
    gate = null;
    root = await Directory.systemTemp.createTemp('plaud-mobile-');
    peer = Peer();
    raw = Uint8List.fromList([
      ...base64.decode(peer.data['header']),
      for (var i = 0; i < peer.data['frameCount']; i++) ...base64.decode(peer.data['encryptedFrame'])
    ]);
    await peer.connect();
    peer.handle = (p) {
      if (plaudCommandId(p) == 26) {
        final page = base64.decode(peer.data['listPage']);
        // One directory entry: id then byte size at offsets 11 and 15.
        ByteData.sublistView(page)
          ..setUint32(11, id, Endian.little)
          ..setUint32(15, raw.length, Endian.little);
        peer.emit(page);
      } else if (plaudCommandId(p) == 28) {
        downloads++;
        if (!downloadStarted.isCompleted) downloadStarted.complete();
        unawaited(() async {
          if (gate != null) await gate;
          final header = Uint8List(5);
          ByteData.sublistView(header).setUint32(0, id, Endian.little);
          peer.emit(plaudCommand(28, header));
          for (var i = 0; i < raw.length; i += 200) {
            peer.emit(block(id, i, raw.sublist(i, (i + 200).clamp(0, raw.length))));
          }
          peer.emit(block(id, 0xffffffff, []));
        }());
      }
    };
    store = PlaudImportStore(
        root: root,
        ownerId: 'a',
        deviceId: 'note',
        currentOwner: () => owner,
        upload: (file, time) async {
          uploads++;
          expect(time, DateTime.fromMillisecondsSinceEpoch(id * 1000, isUtc: true));
          expect(file.readAsBytesSync().take(4), [79, 103, 103, 83]);
          if (reject != null) throw OfflineImportException(reject);
          return const OfflineImportReceipt('test-conversation', processing: true);
        });
    sync = PlaudSyncController(
        openStore: () async => store,
        openSession: () async => online ? peer.session : null,
        readIdentity: () async => peer.identity,
        isCurrentOwner: () => owner == 'a');
  });
  tearDown(() async {
    sync.dispose();
    await peer.dispose();
    await root.delete(recursive: true);
  });

  Future<void> waitForAutomaticImport() async {
    // Observe a real BLE download before awaiting the queue. This fails if
    // discovery stops triggering imports, even though importAll is callable.
    await downloadStarted.future.timeout(const Duration(seconds: 2));
    await sync.importAll();
  }

  for (final legacyDisabled in [false, true]) {
    test('discovery automatically imports encrypted audio and deduplicates (legacy off: $legacyDisabled)', () async {
      if (legacyDisabled) {
        final key = sha256.convert(utf8.encode(jsonEncode(['a', 'note'])));
        FlutterSecureStorage.setMockInitialValues({'memorion.plaud.$key.auto': 'false'});
      }
      await sync.refresh();
      expect(sync.recordings.single.id, id);
      await waitForAutomaticImport();
      expect(sync.errors, isEmpty);
      expect(uploads, 1);
      expect(downloads, 1);
      expect(sync.stages[id], OfflineImportStage.uploaded);
      expect(await File('${store.directory.path}/$id.plaud').readAsBytes(), raw);
      final wav = (await sync.playable(id))!.readAsBytesSync();
      expect(wav.take(4), [82, 73, 70, 70]);
      expect(ByteData.sublistView(wav).getUint32(40, Endian.little), (300 * 320 - 104) * 2);
      expect(wav.length, 44 + (300 * 320 - 104) * 2);
      await sync.refresh();
      await sync.importAll();
      expect(uploads, 1);
      expect(downloads, 1);
    });
  }
  test('upload retry works from validated local cache with BLE disconnected', () async {
    reject = 503;
    await sync.refresh();
    await waitForAutomaticImport();
    expect(sync.stages[id], OfflineImportStage.downloaded);
    online = false;
    reject = null;
    await sync.importOne(sync.recordings.single, retry: true);
    expect(uploads, 2);
    expect(downloads, 1);
    expect(sync.stages[id], OfflineImportStage.uploaded);
  });
  test('unsupported marked frame retains raw, rejects upload and survives refresh without auto retry', () async {
    raw[512 + 220 * 80] ^= 1;
    await sync.refresh();
    await waitForAutomaticImport();
    expect(uploads, 0);
    expect(downloads, 1);
    expect((sync.errors[id] as PlaudException).frameIndex, 220);
    expect(await store.audioIssue(id), PlaudIssue.unsupportedAudio);
    expect(await File('${store.directory.path}/$id.plaud').readAsBytes(), raw);
    online = false;
    await sync.refresh();
    await sync.importAll();
    expect(uploads, 0);
    expect(downloads, 1);
    expect(await sync.playable(id), null);
  });
  test('modified durable raw cache cannot be retried or uploaded', () async {
    raw[512 + 220 * 80] ^= 1;
    await sync.refresh();
    await waitForAutomaticImport();
    final stored = File('${store.directory.path}/$id.plaud');
    await stored.writeAsBytes(Uint8List.fromList(raw)..[600] ^= 1);
    await sync.importOne(sync.recordings.single, retry: true);
    expect((sync.errors[id] as PlaudException).issue, PlaudIssue.protocol);
    expect(uploads, 0);
    expect(downloads, 1);
  });
  test('account switch during file download stops all later cache and upload stages', () async {
    final waiter = Completer<void>();
    gate = waiter.future;
    await sync.refresh();
    await downloadStarted.future.timeout(const Duration(seconds: 2));
    final importing = sync.importAll();
    owner = 'b';
    sync.retire();
    waiter.complete();
    await importing;
    expect(uploads, 0);
    expect(sync.recordings, isEmpty);
    expect(sync.ownerActive, false);
    expect(await File('${store.directory.path}/$id.ogg').exists(), false);
    expect(await File('${store.directory.path}/$id.plaud.json').exists(), false);
  });

  test('overlapping automatic sync requests share one import queue', () async {
    final waiter = Completer<void>();
    gate = waiter.future;
    await sync.refresh();
    final first = sync.importAll();
    final second = sync.importAll();
    expect(identical(first, second), isTrue);
    await downloadStarted.future.timeout(const Duration(seconds: 2));
    await sync.refresh();
    expect(downloads, 1);
    await expectLater(sync.updateAuthorization(() async => fail('Credentials must stay stable during a transfer')),
        throwsA(isA<PlaudException>().having((e) => e.issue, 'issue', PlaudIssue.busy)));
    waiter.complete();
    await Future.wait([first, second]);
    expect(uploads, 1);
  });

  for (final fails in [false, true]) {
    test('authorization update pauses imports and resumes on return (failure: $fails)', () async {
      final waiter = Completer<void>();
      final updating = sync.updateAuthorization(() async {
        await waiter.future;
        if (fails) throw const FormatException('Invalid authorization');
      });
      await sync.refresh();
      await sync.importAll();
      expect(sync.recordings, isEmpty);
      expect(downloads, 0);
      waiter.complete();
      if (fails) {
        await expectLater(updating, throwsFormatException);
      } else {
        await updating;
      }
      await waitForAutomaticImport();
      expect(uploads, 1);
    });
  }

  test('account change during authorization never resumes the old import queue', () async {
    final waiter = Completer<void>();
    final updating = sync.updateAuthorization(() => waiter.future);
    owner = 'b';
    sync.retire();
    waiter.complete();
    await updating;
    await sync.refresh();
    await sync.importAll();
    expect(downloads, 0);
    expect(uploads, 0);
    expect(sync.ownerActive, isFalse);
  });
}
