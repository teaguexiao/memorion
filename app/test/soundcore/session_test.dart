import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/session.dart';

import 'fake_device.dart';

void main() {
  late FakeSoundcoreDevice device;
  late SoundcoreSession session;
  setUp(() {
    device =
        FakeSoundcoreDevice(DateTime.now().toUtc().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000);
    session = SoundcoreSession(
      notifications: device.inbound.stream,
      send: device.send,
      commandTimeout: const Duration(milliseconds: 100),
      transferIdleTimeout: const Duration(milliseconds: 100),
    );
  });
  tearDown(() {
    session.close();
    unawaited(device.inbound.close());
  });

  test('fragmented encrypted file downloads into valid Ogg pages without any destructive commands', () async {
    device.fragmented = true;
    final recordings = await session.listRecordings();
    var progress = 0;
    final result = await session.download(recordings.single, onProgress: (bytes) => progress = bytes);
    expect(progress, 48000);
    expect(result.duration, const Duration(seconds: 6));
    addTearDown(result.dispose);
    expect(result.ogg, isNull);
    final pages = _parseOgg(await result.readBytes());
    expect(pages, hasLength(8));
    expect(ascii.decode(pages.first.sublist(28, 36)), 'OpusHead');
    expect(pages.first[5], 2);
    expect(pages.last[5], 4);
    expect(ByteData.sublistView(pages.last).getUint64(6, Endian.little), 288000);
    final operations = device.commands.map((cmd) => cmd[5] << 8 | cmd[6]).toSet();
    expect(operations, {0x0101, 0x1b0e, 0x2e01, 0x1a07});
    expect(session.diagnostics, contains('transfer metrics transport=ble audioBytes=48000'));
    expect(session.diagnostics, contains('frames=300 maxPayloadBytes=166'));
    expect(session.diagnostics, isNot(contains('D3200-TEST-000001')));
  });

  test('legacy list fallback works when extended list times out', () async {
    device.extendedListTimeout = true;
    final files = await session.listRecordings();
    expect(files.single.id, device.fileId);
    expect(files.single.endTime, 0);
    expect(session.diagnostics, contains('legacy'));
    expect(session.diagnostics, isNot(contains(device.fileId.toString())));
    expect(session.isClosed, isFalse);
  });

  test('refresh discovers a new recording after an empty response and retains zero-size entries', () async {
    device.fileCount = 0;
    expect(await session.listRecordings(), isEmpty);
    device.fileCount = 1;
    device.zeroSize = true;
    expect(await session.listRecordings(), hasLength(1));
  });

  test('info snapshots stay current for both batteries, charging pushes and polling', () async {
    await session.readInfo();
    final updates = <SoundcoreInfo>[];
    final subscription = session.infoEvents.listen(updates.add);
    device.emit(response(1, 3, [5, 7]));
    device.emit(response(1, 4, [1, 0]));
    await Future<void>.delayed(Duration.zero);
    expect(session.info!.battery, 60);
    expect(session.info!.caseBattery, 80);
    expect(session.info!.charging, isTrue);
    expect(session.info!.caseCharging, isFalse);
    device.emit(response(1, 3, [4]));
    expect(session.info!.caseBattery, 80);
    await session.readInfo();
    expect(session.info!.battery, 80);
    expect(session.info!.caseBattery, 100);
    expect(updates, isNotEmpty);
    await subscription.cancel();
  });

  test('sequence gaps fail the import and invalidate the session', () async {
    device.missingSlice = true;
    final recording = (await session.listRecordings()).single;
    await expectLater(session.download(recording), throwsFormatException);
    expect(session.isClosed, isTrue);
    await expectLater(session.download(recording), throwsStateError);
  });

  test('wrong file and bad keys are rejected before upload', () async {
    device.wrongFile = true;
    await expectLater(
        session.download(SoundcoreRecording(device.fileId, device.fileId + 6, 48000)), throwsFormatException);
  });

  test('disconnect while pulling a recording completes the future with an error', () async {
    device.disconnectDuringDownload = true;
    await expectLater(session.download(SoundcoreRecording(device.fileId, device.fileId + 6, 48000)), throwsStateError);
  });

  test('stalled transfers time out instead of holding the UI forever', () async {
    device.stall = true;
    await expectLater(session.download(SoundcoreRecording(device.fileId, device.fileId + 6, 48000)),
        throwsA(isA<TimeoutException>()));
  });

  test('interrupt during BLE setup prevents starting a file and reports intentional switch', () async {
    final stream = StreamController<List<int>>();
    final started = Completer<void>();
    final pending = SoundcoreSession(
      notifications: stream.stream,
      send: (_) async {
        if (!started.isCompleted) started.complete();
      },
    );
    final result = expectLater(pending.download(SoundcoreRecording(device.fileId, device.fileId + 6, 48000)),
        throwsA(isA<SoundcoreBluetoothInterrupted>()));
    await started.future;
    expect(pending.interruptBluetoothDownload(), isTrue);
    await result;
    expect(pending.isClosed, isTrue);
    expect(pending.busy, isFalse);
    expect(pending.interruptBluetoothDownload(), isFalse);
    await stream.close();
  });

  test('active recording is not downloaded as a completed file', () async {
    device.recording = true;
    await expectLater(session.download(SoundcoreRecording(device.fileId, device.fileId + 6, 48000)), throwsStateError);
    expect(device.commands.any((cmd) => cmd[5] == 0x1a), isFalse);
  });

  test('repeated pagination is an error, not a false complete list', () async {
    device.repeatPage = true;
    await expectLater(session.listRecordings(), throwsFormatException);
  });

  test('pending request fails promptly on transport loss', () async {
    session.close();
    final stream = StreamController<List<int>>();
    final disconnected = SoundcoreSession(notifications: stream.stream, send: (_) async {});
    final waiting = expectLater(disconnected.readInfo(), throwsStateError);
    await stream.close();
    await waiting;
  });
}

List<Uint8List> _parseOgg(Uint8List bytes) {
  final pages = <Uint8List>[];
  var offset = 0;
  while (offset < bytes.length) {
    expect(ascii.decode(bytes.sublist(offset, offset + 4)), 'OggS');
    final count = bytes[offset + 26];
    final length = 27 + count + bytes.sublist(offset + 27, offset + 27 + count).fold<int>(0, (a, b) => a + b);
    final page = bytes.sublist(offset, offset + length);
    final data = ByteData.sublistView(page);
    final expected = data.getUint32(22, Endian.little);
    data.setUint32(22, 0, Endian.little);
    var crc = 0;
    for (final b in page) {
      crc ^= b << 24;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc << 1) ^ (crc & 0x80000000 == 0 ? 0 : 0x04c11db7);
        crc &= 0xffffffff;
      }
    }
    expect(crc, expected);
    pages.add(page);
    offset += length;
  }
  expect(offset, bytes.length);
  return pages;
}
