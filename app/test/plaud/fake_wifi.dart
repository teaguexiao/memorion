import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/cipher.dart';
import 'package:memorion/services/devices/plaud/identity.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/wifi_protocol.dart';
import 'package:memorion/services/devices/plaud/wifi_session.dart';

class WifiPeer {
  final fixture = jsonDecode(File('test/plaud/fixtures/synthetic.json').readAsStringSync());
  final messages = StreamController<List<int>>(sync: true);
  late final identity = PlaudIdentity.fromJson(jsonEncode(fixture['identity']));
  late final deviceCipher = PlaudSessionCipher.unlock(base64.decode(fixture['secret']), identity);
  late final phoneCipher = PlaudSessionCipher.unlock(base64.decode(fixture['secret']), identity);
  final requests = <PlaudWifiPacket>[];
  void Function(PlaudWifiPacket)? handle;
  int handshakeStatus = 0;
  late final session = PlaudWifiSession(
      identity: identity,
      cipher: phoneCipher,
      messages: messages.stream,
      timeout: const Duration(milliseconds: 150),
      transferIdleTimeout: const Duration(milliseconds: 100),
      send: (bytes) async {
        final packet = PlaudWifiPacket.decode(deviceCipher.openWifi(bytes));
        requests.add(packet);
        if (packet.type == 1) {
          expect(packet.fields['token'], identity.bindToken.padRight(32, '0'));
          emit(PlaudWifiPacket(1, {'status': handshakeStatus}));
        } else {
          handle?.call(packet);
        }
      });
  void emit(PlaudWifiPacket packet) => messages.add(deviceCipher.sealWifi(packet.encode()..[3] = 2));
  Future<void> connect({bool hello = true}) async {
    deviceCipher.open(phoneCipher.seal(plaudCommand(3)));
    phoneCipher.open(deviceCipher.seal(plaudCommand(3, [1])));
    final ready = session.authenticate();
    if (hello) emit(PlaudWifiPacket(2, {'pVer': 20, 'token': '0123456789abcdef0123456789abcdef'}));
    await ready;
  }

  void status() => emit(PlaudWifiPacket(12, {'status': 0, 'session': 123, 'crc': 0}));
  void chunk(int offset, int length, int last) => emit(PlaudWifiPacket(13,
      {'session': 123, 'offset': offset, 'length': length, 'last': last}, Uint8List(length)..fillRange(0, length, 7)));
  Future<void> dispose() async {
    session.dispose();
    await messages.close();
  }
}
