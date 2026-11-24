import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/cipher.dart';
import 'package:memorion/services/devices/plaud/identity.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/wifi_protocol.dart';
import 'package:memorion/services/devices/plaud/wifi_server.dart';

void main() {
  final fixture = jsonDecode(File('test/plaud/fixtures/synthetic.json').readAsStringSync());
  final identity = PlaudIdentity.fromJson(jsonEncode(fixture['identity']));
  final secret = base64.decode(fixture['secret']);
  final loopback = InternetAddress.loopbackIPv4;
  late PlaudSessionCipher deviceCipher;
  PlaudWifiServer? server;
  WebSocket? socket;
  StreamSubscription? subscription;

  // Real TCP/WebSocket traffic, isolated to loopback and synthetic identity.
  Future<PlaudWifiServer> start({Duration timeout = const Duration(seconds: 2)}) async {
    final phoneCipher = PlaudSessionCipher.unlock(secret, identity);
    deviceCipher = PlaudSessionCipher.unlock(secret, identity);
    deviceCipher.open(phoneCipher.seal(plaudCommand(3)));
    phoneCipher.open(deviceCipher.seal(plaudCommand(3, [1])));
    return server = await PlaudWifiServer.bind(
        localAddress: loopback,
        peerAddress: loopback,
        identity: identity,
        cipher: phoneCipher,
        port: 0,
        timeout: timeout);
  }

  Future<void> connect(void Function(PlaudWifiPacket) respond) async {
    final ws = socket = await WebSocket.connect('ws://127.0.0.1:${server!.port}');
    subscription = ws.listen((bytes) {
      final request = PlaudWifiPacket.decode(deviceCipher.openWifi(Uint8List.fromList(bytes as List<int>)));
      if (request.type == 1) {
        expect(request.fields['token'], identity.bindToken.padRight(32, '0'));
        ws.add(deviceCipher.sealWifi(PlaudWifiPacket(1, {'status': 0}).encode()));
      } else {
        respond(request);
      }
    });
    ws.add(deviceCipher.sealWifi(PlaudWifiPacket(2, {'sn': identity.serial, 'pVer': 20}).encode()));
  }

  tearDown(() async {
    await server?.close();
    await socket?.close();
    await subscription?.cancel();
    server = null;
    socket = null;
    subscription = null;
  });

  test('actual WebSocket delivers authenticated directory and complete recording', () async {
    final server = await start();
    final folder = Directory.systemTemp.createTempSync('plaud-ws');
    final source = Uint8List.fromList(List.generate(70000, (index) => index % 251));
    try {
      await connect((request) {
        if (request.type == 11) {
          final tail = Uint8List(10);
          ByteData.sublistView(tail)
            ..setUint32(0, 123, Endian.little)
            ..setUint32(4, source.length, Endian.little)
            ..setUint16(8, 2, Endian.little);
          socket!.add(deviceCipher
              .sealWifi(PlaudWifiPacket(11, {'status': 0, 'uid': 0, 'count': 1, 'offset': 0}, tail).encode()));
        } else if (request.type == 12) {
          socket!.add(deviceCipher.sealWifi(PlaudWifiPacket(12, {'status': 0, 'total': source.length}).encode()));
          socket!.add(deviceCipher.sealWifi(
              PlaudWifiPacket(13, {'session': 123, 'offset': 0, 'length': source.length, 'last': 1}, source).encode()));
        }
      });
      final session = await server.waitForDevice();
      final files = await session.recordings();
      final partial = File('${folder.path}/audio.partial');
      await session.downloadTo(files.single, partial);
      expect(await partial.readAsBytes(), source);
      await session.requestClose();
      await server.close();
      expect(session.isClosed, true);
    } finally {
      folder.deleteSync(recursive: true);
    }
  });

  test('rejects wildcard and public network addresses before opening listener', () async {
    for (final address in [InternetAddress.anyIPv4, InternetAddress('8.8.8.8')]) {
      await expectLater(
          PlaudWifiServer.bind(
              localAddress: address,
              peerAddress: loopback,
              identity: identity,
              cipher: PlaudSessionCipher.unlock(secret, identity)),
          throwsA(isA<PlaudException>()));
    }
  });

  test('connection deadline closes listener; the same port can be reused', () async {
    final server = await start(timeout: const Duration(milliseconds: 100));
    final port = server.port;
    await expectLater(server.waitForDevice(),
        throwsA(isA<PlaudException>().having((error) => error.issue, 'issue', PlaudIssue.timeout)));
    await server.close();
    final rebound = await HttpServer.bind(loopback, port, shared: false);
    await rebound.close(force: true);
  });

  test('rejects a second connection while preserving authenticated owner', () async {
    final server = await start();
    await connect((request) {
      if (request.type == 11) {
        socket!
            .add(deviceCipher.sealWifi(PlaudWifiPacket(11, {'status': 0, 'uid': 0, 'count': 0, 'offset': 0}).encode()));
      }
    });
    final session = await server.waitForDevice();
    await expectLater(WebSocket.connect('ws://127.0.0.1:${server.port}'), throwsA(isA<WebSocketException>()));
    expect(await session.recordings(), isEmpty);
  });

  test('text messages cannot produce readiness or keep the listener open', () async {
    final server = await start();
    socket = await WebSocket.connect('ws://127.0.0.1:${server.port}');
    subscription = socket!.listen((_) => fail('Unauthenticated device received an account message'));
    socket!.add('not an encrypted binary message');
    await expectLater(server.waitForDevice(), throwsA(isA<PlaudException>()));
    await server.close();
    final rebound = await HttpServer.bind(loopback, server.port, shared: false);
    await rebound.close(force: true);
  });

  test('remote disconnect during a request releases the listener', () async {
    final server = await start();
    await connect((request) {
      if (request.type == 11) unawaited(socket!.close());
    });
    final session = await server.waitForDevice();
    await expectLater(session.recordings(), throwsA(isA<PlaudException>()));
    await server.close();
    final rebound = await HttpServer.bind(loopback, server.port, shared: false);
    await rebound.close(force: true);
  });

  test('cancellation during handshake refuses late readiness and releases port', () async {
    final server = await start();
    socket = await WebSocket.connect('ws://127.0.0.1:${server.port}');
    subscription = socket!.listen((_) => fail('Cancelled handshake sent account data'));
    final ready = server.waitForDevice();
    final rejected = expectLater(ready, throwsA(isA<PlaudException>()));
    await server.close();
    await rejected;
    await expectLater(server.waitForDevice(), throwsA(isA<PlaudException>()));
    final rebound = await HttpServer.bind(loopback, server.port, shared: false);
    await rebound.close(force: true);
  });
}
