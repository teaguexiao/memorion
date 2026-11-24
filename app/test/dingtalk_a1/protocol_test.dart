import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices/dingtalk_a1/identity.dart';
import 'package:memorion/services/devices/dingtalk_a1/protocol.dart';
import 'fake_device.dart';

void main() {
  test('recognition uses service identity and keeps stored enum indexes stable', () {
    expect(DeviceType.soundcore.index, 3);
    expect(DeviceType.dingtalkA1.index, 4);
    expect(BtDevice.typeFromServices([a1ServiceUuid.toUpperCase()]), DeviceType.dingtalkA1);
    final device = BtDevice.fromAdvertisement(id: 'test-a1', name: '', serviceUuids: [a1ServiceUuid], rssi: -45);
    expect(device.displayName, 'DingTalk A1');
    expect(device.usesOfflineImport, isTrue);
    expect(BtDevice.fromJson(device.toJson()).type, DeviceType.dingtalkA1);
    expect(BtDevice.typeFromServices([]), isNull);
  });
  test('AES authentication matches independently generated Python cryptography vector', () {
    final identity = A1Identity('test-did', 'test-corp', '0123456789abcdef0123456789abcdef');
    expect(identity.token('abcdefghijklmnopqrstuvwxyz012345'),
        '5f72aaf7acfbedde6274dda512510ee2bce64fd1af90ba54becb644e023bcb6a');
    expect(identity.toString(), isNot(contains('0123456789abcdef')));
    expect(() => identity.token('short'), throwsFormatException);
    try {
      A1Identity.fromJson('secret-private-json');
      fail('Expected rejection');
    } catch (error) {
      expect(error.toString(), isNot(contains('secret-private-json')));
    }
  });
  test('ASCII credentials only; accepted camelcase aliases', () {
    final identity = A1Identity.fromJson(jsonEncode({'deviceId': 'did', 'corpId': 'corp', 'deviceSecret': 'a' * 32}));
    expect(identity.did, 'did');
    expect(() => A1Identity('did', 'corp', 'é' * 32), throwsFormatException);
  });
  test('fragmented and coalesced packets preserve kind, sequence and body', () {
    final one = frame(0x0132, 5, {'code': 200});
    final two = frame(0x0115, 17, Uint8List.fromList([1, 2, 3]), kind: 0x13);
    final decoder = A1Decoder();
    expect(decoder.add(one.sublist(0, 7)), isEmpty);
    final result = decoder.add([...one.sublist(7), ...two]);
    expect(result.map((e) => e.command), [0x0132, 0x0115]);
    expect(result.last.kind, 0x13);
    expect(result.last.sequence, 17);
    expect(result.last.payload, [1, 2, 3]);
    expect(result.first.json()['code'], 200);
    final oversized = Uint8List(8)..[0] = 0x31;
    ByteData.sublistView(oversized).setUint32(4, 0xffffffff);
    expect(() => decoder.add(oversized), throwsA(isA<A1Exception>()));
  });
  test('BZIP2 CRC uses the published check value and rejects corrupt block tails', () {
    expect(a1Crc32(ascii.encode('123456789')), 0xfc891918);
    final payload = Uint8List(33);
    final b = ByteData.sublistView(payload)
      ..setUint32(2, 1700000000)
      ..setUint32(8, 1)
      ..setUint32(12, 9);
    payload.setAll(16, ascii.encode('123456789'));
    b.setUint32(29, 0xfc891918);
    expect(A1FileBlock.parse(payload).data, ascii.encode('123456789'));
    payload[17] ^= 1;
    expect(() => A1FileBlock.parse(payload), throwsA(isA<A1Exception>()));
  });
  test('normal recordings accept stock 48000-byte blocks with intact CRC', () {
    final audio = Uint8List.fromList(List.generate(48000, (i) => i % 251));
    final payload = Uint8List(audio.length + 24)..setAll(16, audio);
    final header = ByteData.sublistView(payload)
      ..setUint32(2, 1700000000)
      ..setUint32(8, 1)
      ..setUint32(12, audio.length)
      ..setUint32(audio.length + 20, a1Crc32(audio));
    expect(A1FileBlock.parse(payload).data, audio);
    payload[20000] ^= 1;
    expect(() => A1FileBlock.parse(payload), throwsA(isA<A1Exception>()));
    payload[20000] ^= 1;
    header.setUint32(12, 48001);
    expect(() => A1FileBlock.parse(payload), throwsA(isA<A1Exception>()));
  });
  test('stock checksum matches independent vectors and still rejects changed data', () {
    expect(a1StockBlockChecksum(ascii.encode('123456789')), 0xcd3f3cff);
    final data = Uint8List.fromList(List.generate(48000, (i) => i % 251));
    expect(a1StockBlockChecksum(data), 0x7fc080ff);
    final payload = Uint8List(data.length + 24)..setAll(16, data);
    ByteData.sublistView(payload)
      ..setUint32(2, 1700000000)
      ..setUint32(8, 1)
      ..setUint32(12, data.length)
      ..setUint32(data.length + 20, 0x7fc080ff);
    expect(A1FileBlock.parse(payload).data, data);
    payload[20000] ^= 1;
    expect(() => A1FileBlock.parse(payload), throwsA(isA<A1Exception>()));
  });
  test('directory count, truncated flag and duration hint are bounded', () {
    final page = A1RecordingPage.parse(index([1700000000, 1699999999], truncated: true));
    expect(page.truncated, isTrue);
    expect(page.recordings.first.reportedSize, 6000);
    expect(page.recordings.first.estimatedDuration, const Duration(seconds: 6));
    expect(() => A1RecordingPage.parse(Uint8List.fromList([0, 200, 0, 2])), throwsA(isA<A1Exception>()));
  });
  test('Android backup rules exclude credentials without disabling other backups', () {
    final text = File('android/app/src/main/res/xml/backup_rules.xml').readAsStringSync();
    final transfer = File('android/app/src/main/res/xml/data_extraction_rules.xml').readAsStringSync();
    expect(text, contains('MemorionA1Credentials.xml'));
    expect(transfer.split('MemorionA1Credentials.xml').length - 1, 2);
  });
}
