import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/wifi_transport.dart';

void main() {
  test('network diagnostics expose only numeric codes, never exception messages or destinations', () {
    expect(soundcoreWifiErrorCode(const SocketException('secret', osError: OSError('secret', 65))), 'socket errno=65');
    expect(soundcoreWifiErrorCode(const HandshakeException('secret', OSError('secret', -9807))), 'tls errno=-9807');
    expect(soundcoreWifiErrorCode(const WebSocketException('secret', 400)), 'websocket http=400');
    expect(soundcoreWifiErrorCode(TimeoutException('secret')), 'timeout');
    expect(soundcoreWifiErrorCode(StateError('secret')), 'StateError');
  });
  test('embedded case-sensitive handshake rejects stock Dart but accepts recorder transport', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final requests = <String>[];
    server.listen((socket) {
      sockets.add(socket);
      var buffer = '';
      var upgraded = false;
      socket.listen((bytes) {
        if (upgraded) return;
        if (bytes.first == 0x16) {
          socket.destroy(); // This fixture serves plain WS, not TLS.
          return;
        }
        buffer += ascii.decode(bytes, allowInvalid: true);
        if (!buffer.contains('\r\n\r\n')) return;
        requests.add(buffer);
        final match = RegExp(r'(?:^|\r\n)Sec-WebSocket-Key: ([^\r]+)').firstMatch(buffer);
        if (match == null || !buffer.contains('\r\nUpgrade: websocket\r\n')) {
          socket.write('HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
          unawaited(socket.flush().then((_) => socket.close()));
          return;
        }
        final accept =
            base64Encode(sha1.convert(ascii.encode('${match[1]}258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes);
        socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
            'Sec-WebSocket-Accept: $accept\r\n\r\n');
        upgraded = true;
      }, onError: (_) {});
    });
    SoundcoreWifiTransport? transport;
    try {
      await expectLater(WebSocket.connect('ws://127.0.0.1:${server.port}'), throwsA(isA<WebSocketException>()));
      transport =
          await SoundcoreWifiTransport.connect(SoundcoreWifiEndpoint('127.0.0.1', server.port), leave: () async {});
      expect(requests, hasLength(2));
      expect(requests.first, contains('\r\nupgrade: websocket\r\n'));
      expect(requests.last, contains('\r\nUpgrade: websocket\r\n'));
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
      await transport?.close();
      await server.close();
    }
  });

  test('bulk transfers use UDP heartbeats without interleaving WebSocket text pings', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 32003);
    final heartbeats = <String>[];
    final heartbeatSubscription = udp.listen((event) {
      if (event == RawSocketEvent.read) {
        final packet = udp.receive();
        if (packet != null) heartbeats.add(ascii.decode(packet.data));
      }
    });
    final commands = <String>[];
    final finished = Completer<void>();
    final serverSocket = Completer<WebSocket>();
    var leaves = 0;
    SoundcoreWifiTransport? transport;
    StreamSubscription<List<int>>? frames;
    final binary = Completer<List<int>>();
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      serverSocket.complete(socket);
      socket.listen((value) {
        expect(value, isA<String>());
        commands.add(value as String);
        if (value == soundcoreWifiFileRequest(123)) {
          socket.add('ACK');
          socket.add([9, 255, 1, 2]);
        }
        if (value == 'FINISH' && !finished.isCompleted) finished.complete();
      });
    });
    try {
      // Loopback is a synthetic endpoint; device responses cannot select it.
      transport = await SoundcoreWifiTransport.connect(
        SoundcoreWifiEndpoint('127.0.0.1', server.port),
        leave: () async => leaves++,
      );
      frames = transport.notifications.listen((value) => binary.complete(value));
      await transport.requestFile(123);
      expect(await binary.future.timeout(const Duration(seconds: 2)), [9, 255, 1, 2]);
      // Cover both the initial keepalive and a periodic tick while exporting.
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(heartbeats.length, greaterThanOrEqualTo(2));
      expect(heartbeats, everyElement('soundcore-keep-alive-unicast'));
      expect(commands, [soundcoreWifiFileRequest(123)]);
      await transport.acknowledgeFile();
      await transport.requestFile(456);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(commands, [soundcoreWifiFileRequest(123), soundcoreWifiFileRequest(456)],
          reason: 'Completing one file must not finalize the Wi-Fi batch');
      await transport.close();
      await finished.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
          commands,
          containsAllInOrder([
            soundcoreWifiFileRequest(123),
            soundcoreWifiFileRequest(456),
            'FINISH',
            soundcoreHex(soundcoreCommand(0x1a, 0x0a, [1])),
          ]));
      expect(leaves, 1);
      await transport.close();
      expect(leaves, 1);
      await expectLater(transport.requestFile(123), throwsA(isA<SoundcoreWifiDisconnected>()));
    } finally {
      await frames?.cancel();
      await transport?.close();
      if (serverSocket.isCompleted) await (await serverSocket.future).close();
      await server.close(force: true);
      await heartbeatSubscription.cancel();
      udp.close();
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}
