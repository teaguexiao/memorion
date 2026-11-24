import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/wifi_protocol.dart';

void main() {
  final rejects = throwsA(isA<PlaudException>());
  test('wire header has u24 length, version and signed little endian JSON size', () {
    // Independently constructed wire vector, not generated through the codec.
    final wire = Uint8List.fromList([10, 0, 0, 1, 3, 0, 2, 0, 123, 125]);
    expect(PlaudWifiPacket.decode(wire).type, 3);
    expect(PlaudWifiPacket(3, {}).encode(), wire);
    final large = PlaudWifiPacket(13, {'length': 70000}, Uint8List(70000)).encode();
    expect(large[2], 1);
    expect(PlaudWifiPacket.decode(large).tail.length, 70000);
    final unicode = PlaudWifiPacket(2, {'version': '测试'}).encode();
    expect(PlaudWifiPacket.decode(unicode).fields['version'], '测试');
  });

  test('reject truncated, concatenated, oversized, bad version, negative and forbidden fields', () {
    final good = PlaudWifiPacket(3, {}).encode();
    for (var end = 0; end < good.length; end++) {
      expect(() => PlaudWifiPacket.decode(good.sublist(0, end)), rejects);
    }
    for (final mutation in [(0, 9), (3, 3), (4, 14), (5, 255), (6, 255), (7, 255), (8, 255)]) {
      final bad = Uint8List.fromList(good)..[mutation.$1] = mutation.$2;
      expect(() => PlaudWifiPacket.decode(bad), rejects);
    }
    expect(() => PlaudWifiPacket.decode(Uint8List.fromList([...good, ...good])), rejects);
    expect(() => PlaudWifiPacket.decode(Uint8List(plaudWifiMaxPduBytes + 1)), rejects);
    expect(() => PlaudWifiPacket(14, {}).encode(), rejects);
    expect(() => PlaudWifiPacket(3, {'x': 'x' * 32768}).encode(), rejects);
    expect(() => PlaudWifiPacket(13, {}, Uint8List(plaudWifiMaxPduBytes)).encode(), rejects);
    expect(() => PlaudWifiPacket.decode(Uint8List.fromList([10, 0, 0, 1, 3, 0, 2, 0, 91, 93])), rejects);
  });

  test('firmware v2 hello keeps authenticated identity checks without requiring synthetic serial', () {
    final wire = Uint8List.fromList(
        [62, 0, 0, 2, 2, 0, 54, 0, ...utf8.encode('{"pVer":20,"token":"0123456789abcdef0123456789abcdef"}')]);
    final hello = PlaudWifiPacket.decode(wire);
    hello.requireHello('synthetic-serial');
    PlaudWifiPacket(2, {'pVer': 20, 'sn': 'synthetic-serial'}).requireHello('synthetic-serial');
    for (final patch in <Map<String, dynamic>>[
      {'pVer': 19},
      {'token': null},
      {'token': ''},
      {'token': 32},
      {'token': '\u0000' * 32},
      {'sn': 'wrong-device'}
    ]) {
      expect(() => PlaudWifiPacket(2, {...hello.fields, ...patch}).requireHello('synthetic-serial'), rejects);
    }
  });

  test('directory keeps Wi-Fi scene and fails on nonintegral or inconsistent metadata', () {
    final tail = Uint8List(10);
    ByteData.sublistView(tail)
      ..setUint32(0, 0xf0000001, Endian.little)
      ..setUint32(4, 33952, Endian.little)
      ..setUint16(8, 0x1234, Endian.little);
    final fields = {'uid': 0, 'status': 0, 'count': 1, 'offset': 0};
    final (count, offset, entries) = plaudWifiListPage(PlaudWifiPacket(11, fields, tail));
    expect((count, offset, entries.single.id, entries.single.scene), (1, 0, 0xf0000001, 0x1234));
    for (final patch in <Map<String, dynamic>>[
      {'count': 0},
      {'offset': 1},
      {'status': 1},
      {'uid': 1},
      {'count': true},
      {'offset': 0.0},
      {'count': 10001}
    ]) {
      expect(() => plaudWifiListPage(PlaudWifiPacket(11, {...fields, ...patch}, tail)), rejects);
    }
    expect(() => plaudWifiListPage(PlaudWifiPacket(11, fields, tail.sublist(1))), rejects);
    expect(() => plaudWifiListPage(PlaudWifiPacket(11, fields)), rejects);
    expect(plaudWifiListPage(PlaudWifiPacket(11, {...fields, 'count': 0})).$3, isEmpty);
    ByteData.sublistView(tail).setUint32(0, 0, Endian.little);
    expect(() => plaudWifiListPage(PlaudWifiPacket(11, fields, tail)), rejects);
  });

  PlaudWifiPacket content(int offset, int length, {int last = 0, int session = 123}) =>
      PlaudWifiPacket(13, {'session': session, 'offset': offset, 'length': length, 'last': last}, Uint8List(length));
  PlaudWifiDownload accepted() =>
      PlaudWifiDownload(const PlaudRecording(123, 1024))..accept(PlaudWifiPacket(12, {'status': 0, 'total': 1024}));

  test('completion requires accepted status, exact size and an explicit final flag', () {
    final transfer = accepted();
    transfer.add(content(0, 512));
    transfer.add(content(512, 512));
    expect(transfer.finished, false);
    transfer.add(content(1024, 0, last: 1));
    expect(transfer.finished, true);
    expect(() => transfer.add(content(1024, 0, last: 1)), rejects);
    expect(() => PlaudWifiDownload(const PlaudRecording(123, 1024)).add(content(0, 1024, last: 1)), rejects);
    expect(
        () => PlaudWifiDownload(const PlaudRecording(123, 1024))
            .accept(PlaudWifiPacket(12, {'status': 0, 'total': 1000})),
        rejects);
    final one = accepted()..add(content(0, 1024, last: 1));
    expect(one.finished, true);
    for (final id in [0, -1, 0x100000000]) {
      expect(() => PlaudWifiDownload(PlaudRecording(id, 1024)), rejects);
    }
  });

  test('gaps, overlaps, duplicate, other file, oversize, short final and wrong lengths fail', () {
    for (final bad in [
      content(1, 512),
      content(0, 1025),
      content(0, 512, last: 1),
      content(0, 512, session: 124),
      content(0, 512, last: 2),
      content(0, 0),
      PlaudWifiPacket(13, {'session': 123, 'offset': 0, 'length': 1024, 'last': 1}, Uint8List(1023))
    ]) {
      expect(() => accepted().add(bad), rejects);
    }
    final duplicate = accepted()..add(content(0, 512));
    expect(() => duplicate.add(content(0, 512)), rejects);
    expect(() => duplicate.add(content(500, 512)), rejects);
    expect(PlaudWifiPacket(1, {'token': 'secret'}).toString(), isNot(contains('secret')));
  });

  test('firmware transfer status uses the validated directory size and matching session', () {
    final fields = {'status': 0, 'session': 123, 'crc': 0};
    PlaudWifiDownload(const PlaudRecording(123, 1024)).accept(PlaudWifiPacket(12, fields));
    for (final patch in [
      {'status': 1},
      {'session': 124},
      {'crc': -1},
      {'total': 1000}
    ]) {
      expect(
          () => PlaudWifiDownload(const PlaudRecording(123, 1024)).accept(PlaudWifiPacket(12, {...fields, ...patch})),
          rejects);
    }
    expect(
        () => PlaudWifiDownload(const PlaudRecording(123, 1024)).accept(PlaudWifiPacket(12, {'status': 0})), rejects);
  });
}
