import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices/models.dart';
import 'package:memorion/services/devices/soundcore/crypto.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';

import 'fake_device.dart';

void main() {
  test('D3200 discovery uses UUID, including unnamed advertisements', () {
    final device = BtDevice.fromAdvertisement(
        id: 'test-d3200', name: '', serviceUuids: [soundcoreServiceUuid.toUpperCase()], rssi: -55);
    expect(device.type, DeviceType.soundcore);
    expect(device.displayName, 'SOUNDCORE');
    expect(device.displayModelNumber, 'Soundcore Work');
    expect(device.usesOfflineImport, isTrue);
    expect(BtDevice.typeFromServices(['0000180f-0000-1000-8000-00805f9b34fb']), isNull);
    expect(BtDevice.typeFromServices([memorionServiceUuid]), DeviceType.memorion);
    expect(BtDevice.typeFromServices([frameServiceUuid]), DeviceType.frame);
  });

  test('device persistence keeps all previous enum indexes', () {
    expect(DeviceType.memorion.index, 0);
    expect(DeviceType.openglass.index, 1);
    expect(DeviceType.frame.index, 2);
    final device = BtDevice(name: 'soundcore', id: 'test', type: DeviceType.soundcore, rssi: -70);
    expect(BtDevice.fromJson(device.toJson()).type, DeviceType.soundcore);
  });

  test('read-only command matches wire bytes', () {
    expect(soundcoreCommand(1, 1), [8, 238, 0, 0, 0, 1, 1, 10, 0, 2]);
    expect(soundcoreCommand(0x1b, 0x0e, [0, 0]), [8, 238, 0, 0, 0, 27, 14, 12, 0, 0, 0, 43]);
  });

  test('parser handles every fragmentation boundary, coalescing and partial headers', () {
    final frame = response(1, 1, deviceInfo());
    for (var boundary = 0; boundary <= frame.length; boundary++) {
      final parser = SoundcorePacketBuffer();
      final packets = [
        ...parser.add([99, 98, ...frame.sublist(0, boundary)]),
        ...parser.add([
          ...frame.sublist(boundary),
          ...response(1, 3, [7, 9])
        ]),
      ];
      expect(packets, hasLength(2), reason: 'boundary $boundary');
      expect(packets.first.payload, deviceInfo());
    }
  });

  test('parser rejects corrupt checksums and recovers invalid lengths', () {
    final bad = response(1, 3, [7])..last ^= 1;
    expect(() => SoundcorePacketBuffer().add(bad), throwsFormatException);
    final packets = SoundcorePacketBuffer().add([
      9,
      255,
      0,
      0,
      0,
      1,
      1,
      1,
      0,
      0,
      ...response(1, 3, [7])
    ]);
    expect(packets, hasLength(1));
  });

  test('info separates recorder and case batteries, firmware and recording state', () {
    final info = SoundcoreInfo.parse(deviceInfo(recording: true));
    expect(info.battery, 80);
    expect(info.caseBattery, 100);
    expect(info.caseCharging, isTrue);
    expect(info.firmware, '04.92');
    expect(info.totalStorageKb, 8000000);
    expect(info.recording, isTrue);
    expect(soundcoreBattery(0xff), -1);
    expect(() => SoundcoreInfo.parse(Uint8List(5)), throwsFormatException);
  });

  test('recording list requires every declared entry and validates real time', () {
    const id = 1789344000;
    final recording = SoundcoreRecording.parseList(fileList(id)).single;
    expect(recording.startedAt, DateTime.utc(2026, 9, 14));
    expect(recording.hasValidTimestamp(DateTime.utc(2026, 9, 15)), isTrue);
    expect(const SoundcoreRecording(1, 2, 100).hasValidTimestamp(DateTime.now()), isFalse);
    expect(() => SoundcoreRecording.parseList(fileList(id).sublist(0, 13)), throwsFormatException);
  });

  test('both file-list layouts accept the documented 8-byte trailer and still reject truncation', () {
    for (final withEndTime in [true, false]) {
      final bare = fileList(1789344000, withEndTime: withEndTime);
      final payload = Uint8List.fromList([...bare, 0x04, 0x03, 0x02, 0x01, 20, 0, 0, 0]);
      final parsed = SoundcoreRecordingList.parse(payload, withEndTime: withEndTime);
      expect(parsed.files.single.id, 1789344000);
      expect(parsed.files.single.reportedSize, 48000);
      expect(parsed.currentTransferTimestamp, 0x01020304);
      expect(parsed.currentTransferDuration, 20);
      for (var length = 2; length < payload.length; length++) {
        if (length == bare.length) continue;
        expect(() => SoundcoreRecordingList.parse(payload.sublist(0, length), withEndTime: withEndTime),
            throwsFormatException,
            reason: 'length=$length withEndTime=$withEndTime');
      }
    }
  });

  test('empty lists with a trailer and zero-size entries are not silently discarded', () {
    expect(SoundcoreRecording.parseList(fileList(0, count: 0, trailer: true)), isEmpty);
    expect(SoundcoreRecording.parseList(fileList(1789344000, zeroSize: true)), hasLength(1));
  });

  test('local ECDH/HKDF session decrypts per-file AES key and slice counter', () {
    final crypto = SoundcoreCrypto();
    final peer = FakeSoundcoreDevice(1789344000);
    crypto.completeHandshake(peer.handshake(crypto.publicKey));
    expect(crypto.hasSession, isTrue);
    crypto.prepareFile(peer.fileHeader(peer.fileId), peer.fileId);
    final decrypted = crypto.decryptChunk(7, peer.slice(7).sublist(5, 165));
    expect(decrypted.take(3), [0xf8, 0xff, 0xfe]);
    expect(decrypted.skip(3).every((b) => b == 0), isTrue);
    crypto.clear();
    expect(crypto.hasSession, isFalse);
    expect(() => crypto.decryptChunk(7, Uint8List(160)), throwsStateError);
  });

  test('handshake and file-key errors do not produce playable garbage', () {
    final crypto = SoundcoreCrypto();
    final peer = FakeSoundcoreDevice(1789344000);
    final handshake = peer.handshake(crypto.publicKey)..last ^= 1;
    expect(() => crypto.completeHandshake(handshake), throwsFormatException);
    crypto.completeHandshake(peer.handshake(crypto.publicKey));
    peer.corruptKey = true;
    expect(() => crypto.prepareFile(peer.fileHeader(peer.fileId), peer.fileId), throwsFormatException);
    peer.corruptKey = false;
    expect(() => crypto.prepareFile(peer.fileHeader(peer.fileId), peer.fileId + 1), throwsFormatException);
  });
}
