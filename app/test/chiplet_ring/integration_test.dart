import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/services/devices/device_connection.dart';
import 'package:memorion/services/devices/chiplet_ring_connection.dart';
import 'package:memorion/services/devices/chiplet_ring/bridge.dart';
import 'package:memorion/services/devices/chiplet_ring/import_store.dart';
import 'package:memorion/services/devices/chiplet_ring/models.dart';
import 'fake_ring.dart';

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(done(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RingHarness h;
  setUp(() {
    h = RingHarness(Directory.systemTemp.createTempSync('ring-test-'));
  });
  tearDown(() async {
    await h.close();
  });
  test('device enum indices remain compatible and raw-audio guards include ring', () {
    expect(DeviceType.values.map((v) => v.name),
        ['memorion', 'openglass', 'frame', 'soundcore', 'dingtalkA1', 'plaudNote', 'chipletRing']);
    final d = BtDevice(id: 'ring-fixture', name: '', type: DeviceType.chipletRing, rssi: -40);
    expect(d.usesOfflineImport, isTrue);
    expect(DeviceConnectionFactory.create(d, BluetoothDevice.fromId(d.id)), isA<RingDeviceConnection>());
    expect(BtDevice.fromJson(d.toJson()).type, DeviceType.chipletRing);
  });
  test('ambiguous dates require confirmation; explicit zones accepted; identity stays stable', () {
    final raw = {'name': '../record', 'size': 24000, 'type': 'b', 'date': '2026-11-01 12:00:00'};
    final r = RingRecording.fromNative(raw);
    expect(r.startedAt, isNull);
    expect(r.type, 'B');
    expect(r.withTime(DateTime.utc(2026, 11, 1)).id, r.id);
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(r.id), isTrue);
    expect(RingRecording.fromNative({...raw, 'date': '2026-11-01T12:00:00+08:00'}).startedAt,
        DateTime.utc(2026, 11, 1, 4));
    expect(RingRecording.fromNative({...raw, 'date': '2099-01-01T00:00:00Z'}).startedAt, isNull);
  });
  test('empty directory is valid and does not upload', () async {
    await h.sync.sync();
    expect(h.sync.recordings, isEmpty);
    expect(h.uploads, 0);
    expect(h.sync.readError, isNull);
  });
  test('device calendar is display-only and rejects normalized invalid dates', () async {
    RingRecording fromDate(String date) =>
        RingRecording.fromNative({'name': 'offline.bin', 'size': 24000, 'type': '8', 'date': date});
    final r = fromDate('2025_12_06:15:04:55');
    expect(r.unverifiedDeviceTime, DateTime.utc(2025, 12, 6, 15, 4, 55));
    expect(r.startedAt, isNull);
    for (final date in ['2026_02_30:12:00:00', '2026_13_01:12:00:00', '2026_01_01:24:00:00', 'garbage']) {
      expect(fromDate(date).unverifiedDeviceTime, isNull);
    }
    h.peer.directory = [r];
    await h.sync.sync();
    expect(h.sync.stages[r.id], RingStage.needsTime);
    expect(h.uploads, 0);
  });
  test('complete download validates, uploads once, restores receipt after refresh', () async {
    h.peer.directory = [fixtureRecording(0)];
    await h.sync.sync();
    await h.sync.sync();
    expect(h.peer.downloads, 1);
    expect(h.uploads, 1);
    expect(h.sync.stages.values, [RingStage.completed]);
    expect((await h.store.cached()).length, 1);
    expect(await RingImportStore.validateWave(h.store.audio(h.peer.directory.first.id)), const Duration(seconds: 6));
  });
  test('unknown Opus format is visible and never downloaded or uploaded', () async {
    h.peer.directory = [fixtureRecording(0, type: '9')];
    await h.sync.sync();
    expect(h.sync.stages.values, [RingStage.unsupported]);
    expect(h.peer.downloads, 0);
    expect(h.uploads, 0);
  });
  test('unknown time is downloaded but not uploaded until user confirms it', () async {
    final r = fixtureRecording(0, dated: false);
    h.peer.directory = [r];
    await h.sync.sync();
    expect(h.sync.stages[r.id], RingStage.needsTime);
    expect(h.uploads, 0);
    await h.sync.confirmTime(r, DateTime.utc(2026, 11, 1));
    expect(h.uploads, 1);
    expect(h.peer.downloads, 1);
    expect(h.sync.recordings.first.id, r.id);
  });
  test('failed cloud lookup blocks transfer and upload, then recovers', () async {
    h.failLookup = true;
    h.peer.directory = [fixtureRecording(0)];
    await h.sync.sync();
    expect(h.peer.downloads, 0);
    expect(h.uploads, 0);
    expect(h.sync.readError, isNotNull);
    h.failLookup = false;
    await h.sync.sync();
    expect(h.uploads, 1);
  });
  test('cloud reservation blocks upload and existing receipt avoids download', () async {
    final r = fixtureRecording(0);
    h.peer.directory = [r];
    h.blockUpload = true;
    await h.sync.sync();
    expect(h.uploads, 0);
    expect(h.peer.downloads, 0);
    h.cloud[r.id] = RingHarness.state(conversation: 'already-uploaded');
    await h.sync.sync();
    expect(h.sync.stages[r.id], RingStage.completed);
    expect(h.peer.downloads, 0);
  });
  test('transfer failure can retry and does not suppress subsequent files', () async {
    h.peer.directory = [fixtureRecording(0), fixtureRecording(1)];
    h.peer.failures = 1;
    await h.sync.sync();
    expect(h.uploads, 1);
    expect(h.sync.stages[h.peer.directory.first.id], RingStage.failed);
    await h.sync.retry(h.peer.directory.first.id);
    expect(h.uploads, 2);
    expect(h.peer.downloads, 3);
  });
  test('quota retains downloaded audio and subscription upgrade resumes without download', () async {
    h.peer.directory = [fixtureRecording(0)];
    h.quotaFailures = 1;
    await h.sync.sync();
    expect(h.sync.stages.values, [RingStage.failed]);
    expect(h.peer.downloads, 1);
    await h.sync.resumeAfterSubscriptionUpgrade();
    expect(h.uploads, 2);
    expect(h.peer.downloads, 1);
  });
  test('ambiguous successful upload is recovered through cloud receipt, never sent twice', () async {
    final r = fixtureRecording(0);
    h.peer.directory = [r];
    h.owner = 'bob';
    await h.sync.sync();
    expect(h.uploads, 0);
    h.owner = 'alice';
    h.cloud[r.id] = RingHarness.state(conversation: 'server-recovered', processing: true);
    await h.sync.sync();
    expect(h.uploads, 0);
    expect(h.sync.stages[r.id], RingStage.processing);
    h.cloud[r.id] = RingHarness.state(conversation: 'server-recovered');
    await h.sync.refreshProcessing();
    expect(h.sync.stages[r.id], RingStage.completed);
    expect(h.sync.jobs.containsKey(r.id), isFalse);
  });
  test('failed cloud processing retries the job without a second transfer or upload', () async {
    final r = fixtureRecording(0);
    h.peer.directory = [r];
    h.processing = true;
    await h.sync.sync();
    h.cloud[r.id] = RingHarness.state(
        conversation: 'cloud-conversation',
        processing: true,
        job: AudioProcessingJob.fromJson({
          'id': 'cloud-job',
          'conversation_id': 'cloud-conversation',
          'status': 'failed',
          'stage': 'transcribe',
          'can_retry': true,
          'started_at': r.startedAt!.toIso8601String()
        }));
    await h.sync.refreshProcessing();
    expect(h.sync.stages[r.id], RingStage.failed);
    await h.sync.retry(r.id);
    expect(h.retries, 1);
    expect(h.uploads, 1);
    expect(h.peer.downloads, 1);
    h.cloud[r.id] = RingHarness.state(conversation: 'cloud-conversation');
    await h.sync.refreshProcessing();
    expect(h.sync.stages[r.id], RingStage.completed);
  });
  test('checksum corruption is redownloaded on retry rather than uploaded', () async {
    final r = fixtureRecording(0);
    h.peer.directory = [r];
    h.quotaFailures = 1;
    await h.sync.sync();
    final f = h.store.audio(r.id);
    final bytes = await f.readAsBytes();
    bytes[100] ^= 0xff;
    await f.writeAsBytes(bytes);
    await h.sync.retry(r.id);
    expect(h.peer.downloads, 2);
    expect(h.uploads, 2);
  });
  test('short, truncated and part files are rejected', () async {
    final r = fixtureRecording(0);
    await expectLater(h.store.cache(r, await syntheticWave(h.root, seconds: 2)), throwsFormatException);
    final f = await syntheticWave(h.root);
    final bytes = await f.readAsBytes();
    await f.writeAsBytes(bytes.sublist(0, bytes.length - 2));
    await expectLater(h.store.cache(r, f), throwsFormatException);
    await expectLater(h.store.cache(r, await syntheticWave(h.root, name: 'audio.wav.part')), throwsFormatException);
    expect(h.uploads, 0);
  });
  test('cache ids cannot escape account directory and owner switches block all access', () async {
    expect(() => h.store.audio('../other-account'), throwsFormatException);
    final r = fixtureRecording(0);
    await h.store.cache(r, await syntheticWave(h.root));
    h.owner = 'bob';
    await expectLater(h.store.cached(), throwsStateError);
    await expectLater(h.store.import(r), throwsStateError);
    expect(h.uploads, 0);
  });
  test('undo reservation prevents sync; cancel restores; committed removal persists', () async {
    final r = fixtureRecording(0);
    h.peer.directory = [r];
    expect(h.sync.reserveRemoval(r.id), isTrue);
    await h.sync.sync();
    expect(h.uploads, 0);
    h.sync.cancelRemoval(r.id);
    await h.sync.sync();
    expect(h.uploads, 1);
    expect(h.sync.reserveRemoval(r.id), isTrue);
    expect(await h.sync.commitRemoval(r.id), isTrue);
    await h.sync.sync();
    expect(h.sync.recordings, isEmpty);
    expect(await h.store.removed(r.id), isTrue);
    expect(await h.store.audio(r.id).exists(), isFalse);
    expect(h.peer.directory.length, 1);
  });
  test('active download cannot be removed and leaving UI does not end app-lifetime queue', () async {
    final r = fixtureRecording(0);
    h.peer.directory = [r];
    h.peer.downloadGate = Completer<void>();
    final work = h.sync.sync();
    await until(() => h.sync.activeId == r.id);
    expect(h.sync.reserveRemoval(r.id), isFalse);
    h.peer.downloadGate!.complete();
    await work;
    expect(h.uploads, 1);
  });
  test('account change cancels in-flight download before any upload', () async {
    h.peer.directory = [fixtureRecording(0)];
    h.peer.downloadGate = Completer<void>();
    final work = h.sync.sync();
    await until(() => h.sync.activeId != null);
    h.owner = 'bob';
    await h.sync.cancelForAccount();
    h.peer.downloadGate!.complete();
    await work;
    expect(h.peer.disconnects, 1);
    expect(h.uploads, 0);
  });
  test('record start-stop uses local validated file then standard import', () async {
    await h.sync.sync();
    await h.sync.startRecording();
    expect(h.sync.recording, isTrue);
    await h.sync.stopRecording();
    expect(h.sync.recording, isFalse);
    expect(h.uploads, 1);
    expect(h.peer.downloads, 0);
    expect(h.sync.recordings.single.type, 'LOCAL');
  });
  test('too short live capture is not uploaded and can start again', () async {
    await h.sync.sync();
    h.peer.shortRecording = true;
    await h.sync.startRecording();
    await h.sync.stopRecording();
    expect(h.uploads, 0);
    expect(h.sync.recordingError, isNotNull);
    h.peer.shortRecording = false;
    await h.sync.startRecording();
    await h.sync.stopRecording();
    expect(h.uploads, 1);
  });
  test('capture disconnect ends recording without producing partial upload', () async {
    await h.sync.sync();
    await h.sync.startRecording();
    await h.peer.disconnect();
    expect(h.sync.recording, isFalse);
    expect(h.sync.recordingError, isNotNull);
    expect(h.uploads, 0);
  });
  test('disconnected view preserves local history and reconnect resumes', () async {
    h.peer.directory = [fixtureRecording(0)];
    await h.sync.sync();
    h.connected = false;
    await h.sync.sync();
    expect(h.sync.connected, isFalse);
    expect(h.sync.recordings.length, 1);
    await h.sync.reconnect();
    expect(h.sync.connected, isTrue);
    expect(h.uploads, 1);
  });
  test('45 files are looked up and synchronized without loss', () async {
    h.peer.directory = List.generate(45, fixtureRecording);
    await h.sync.sync();
    expect(h.uploads, 45);
    expect(h.sync.recordings.length, 45);
    expect(h.sync.stages.values.every((v) => v == RingStage.completed), isTrue);
  });
  test('disconnection during metadata cannot publish a ready connection', () async {
    final device = BtDevice(id: 'ring-fixture', name: 'Ring', type: DeviceType.chipletRing, rssi: -50);
    final c = RingDeviceConnection(device, BluetoothDevice.fromId(device.id), transport: h.peer);
    h.peer.metadataGate = Completer<void>();
    final connect = c.connect();
    await Future<void>.delayed(Duration.zero);
    await h.peer.disconnect();
    h.peer.metadataGate!.complete();
    await expectLater(connect, throwsA(isA<DeviceConnectionException>()));
    expect(await c.isConnected(), isFalse);
    await c.retire();
  });
  test('unknown battery preserves a healthy ring connection', () async {
    final device = BtDevice(id: 'ring-fixture', name: 'Ring', type: DeviceType.chipletRing, rssi: -50);
    final c = RingDeviceConnection(device, BluetoothDevice.fromId(device.id), transport: h.peer);
    await c.connect();
    h.peer.batteryLevel = -1;
    expect(await c.ping(), isTrue);
    expect(await c.retrieveBatteryLevel(), -1);
    await h.peer.disconnect();
    expect(await c.ping(), isFalse);
    await c.retire();
  });
  test('native bridge serializes commands and rejects queued work after disconnect', () async {
    const channel = MethodChannel('test/ring');
    final methods = <String>[];
    final gate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'firmware') {
        await gate.future;
        return 'version';
      }
      if (call.method == 'battery') return 76;
      return null;
    });
    final transport = NativeRingTransport(channel: channel, eventStream: const Stream.empty());
    final firmware = transport.firmware();
    final battery = transport.battery();
    final expectations = Future.wait([expectLater(firmware, throwsStateError), expectLater(battery, throwsStateError)]);
    await Future<void>.delayed(Duration.zero);
    await transport.disconnect();
    gate.complete();
    await expectations;
    expect(methods, ['firmware', 'disconnect']);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });
}
