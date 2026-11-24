import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/cipher.dart';
import 'package:memorion/services/devices/plaud/identity.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/wifi_protocol.dart';

void main() {
  final fixture = jsonDecode(File('test/plaud/fixtures/synthetic.json').readAsStringSync());
  PlaudSessionCipher cipher() => PlaudSessionCipher.unlock(
      base64.decode(fixture['secret']), PlaudIdentity.fromJson(jsonEncode(fixture['identity'])));
  Uint8List content() => PlaudWifiPacket(13, {'session': 1793512345, 'offset': 0, 'length': 70000, 'last': 0},
      Uint8List.fromList(List.generate(70000, (i) => i % 251))).encode();

  test('large Wi-Fi AEAD matches independent Python vector after BLE sequence', () {
    final sender = cipher(), receiver = cipher();
    receiver.open(sender.seal(plaudCommand(3)));
    final encrypted = sender.sealWifi(content());
    expect(encrypted.length, 70085);
    // Python cryptography ChaCha20Poly1305, synthetic.json key, sequence 3.
    expect(sha256.convert(encrypted).toString(), '958eec7d1f42574e91765ccdab6a5d4c6c3bdde031e9cb8d62e30265146a494e');
    expect(receiver.openWifi(encrypted), content());
    expect(() => receiver.openWifi(encrypted), throwsA(isA<PlaudException>()));
  });

  test('Wi-Fi size allowance does not relax BLE and verifies the final tag', () {
    final encrypted = cipher().sealWifi(content());
    expect(() => cipher().seal(content()), throwsA(isA<PlaudException>()));
    expect(() => cipher().open(encrypted), throwsA(isA<PlaudException>()));
    for (final at in [0, encrypted.length ~/ 2, encrypted.length - 1]) {
      final corrupt = Uint8List.fromList(encrypted)..[at] ^= 1;
      expect(() => cipher().openWifi(corrupt), throwsA(isA<PlaudException>()));
    }
    expect(() => cipher().openWifi(content()), throwsA(isA<PlaudException>()));
    expect(() => cipher().openWifi(Uint8List(plaudWifiMaxPduBytes + 21)), throwsA(isA<PlaudException>()));
    expect(() => cipher().sealWifi(Uint8List(plaudWifiMaxPduBytes + 1)), throwsA(isA<PlaudException>()));
  });
}
