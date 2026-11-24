import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:memorion/services/devices/plaud/cipher.dart';
import 'package:memorion/services/devices/plaud/identity.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/session.dart';

class Peer {
  final Duration timeout, transferIdleTimeout;
  Peer(
      {this.timeout = const Duration(milliseconds: 150), this.transferIdleTimeout = const Duration(milliseconds: 100)});
  final data = jsonDecode(File('test/plaud/fixtures/synthetic.json').readAsStringSync());
  final notifications = StreamController<List<int>>(sync: true);
  final sent = <Uint8List>[];
  late final identity = PlaudIdentity.fromJson(jsonEncode(data['identity']));
  late final cipher = PlaudSessionCipher.unlock(base64.decode(data['secret']), identity);
  late final session = PlaudSession(
      identity: identity,
      send: receive,
      notifications: notifications.stream,
      timeout: timeout,
      transferIdleTimeout: transferIdleTimeout);
  FutureOr<void> Function(Uint8List)? handle;
  bool firstBinding = false;
  List<int> handshakeBody = [0, 20, 0];
  Future<void> receive(Uint8List raw) async {
    sent.add(raw);
    if (raw[0] == 0x10 && raw[1] == 0xfe) {
      if (raw[3] == raw[2] - 1) {
        if (firstBinding) {
          notifications.add([0x11, 0xfe]);
        } else {
          for (final chunk in plaudUnlockParts(0xfe12, base64.decode(data['secret']))) {
            notifications.add(chunk);
          }
        }
      }
      return;
    }
    final plain = cipher.open(raw);
    if (plaudCommandId(plain) == 1) {
      emit(plaudCommand(1, handshakeBody));
    } else {
      await handle?.call(plain);
    }
  }

  void emit(Uint8List plain) => notifications.add(cipher.seal(plain));
  Future<void> connect() => session.authenticate(identity.serial);
  Future<void> dispose() async {
    session.close();
    await notifications.close();
  }
}

Uint8List block(int id, int offset, List<int> payload) {
  final result = Uint8List(10 + payload.length);
  result[0] = 2;
  ByteData.sublistView(result)
    ..setUint32(1, id, Endian.little)
    ..setUint32(5, offset, Endian.little);
  result[9] = payload.length;
  result.setAll(10, payload);
  return result;
}
