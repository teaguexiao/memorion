import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../offline_recordings/models.dart';
import 'protocol.dart';
import 'protocol_error.dart';

enum SoundcoreWifiPhase {
  openingHotspot,
  waitingForHotspot,
  joining,
  verifyingNetwork,
  connecting,
  downloading,
  restoring
}

/// Only numeric transport diagnostics: exception messages can contain secrets.
String soundcoreWifiErrorCode(Object error) {
  // i18n-ignore: Stable diagnostics also in obfuscated release builds.
  if (error is OfflineRecordingTooLong) return 'duration=too_long measuredMs=${error.duration.inMilliseconds}';
  if (error is SoundcoreProtocolException) return error.diagnostic;
  if (error is SoundcoreWifiFailure) return soundcoreWifiErrorCode(error.cause);
  // i18n-ignore: Numeric technical diagnostics, never product copy.
  if (error is SocketException) return 'socket errno=${error.osError?.errorCode}';
  // i18n-ignore: Numeric technical diagnostics, never product copy.
  if (error is HandshakeException) return 'tls errno=${error.osError?.errorCode}';
  // i18n-ignore: Numeric technical diagnostics, never product copy.
  if (error is WebSocketException) return 'websocket http=${error.httpStatusCode}';
  if (error is TimeoutException) return 'timeout';
  return error.runtimeType.toString();
}

class SoundcoreWifiFailure implements Exception {
  final SoundcoreWifiPhase phase;
  final Object cause;
  final Future<void> Function()? cleanup;
  const SoundcoreWifiFailure(this.phase, this.cause, {this.cleanup});
}

class SoundcoreWifiDisconnected implements Exception {}

/// The device keeps BLE for control/key exchange; bulk frames arrive here.
abstract class SoundcoreFileTransport {
  Stream<List<int>> get notifications;
  Future<void> requestFile(int id);
  Future<void> acknowledgeFile();
  Future<void> close();
}

class SoundcoreWifiEndpoint {
  final String host;
  final int port;
  const SoundcoreWifiEndpoint(this.host, this.port);

  factory SoundcoreWifiEndpoint.fromPacket(SoundcorePacket packet) {
    if (packet.type != 0x1a || packet.id != 5 || (packet.status & 15) != 1 || packet.payload.length < 6) {
      throw const FormatException('D3200 did not enable its Wi-Fi hotspot');
    }
    final bytes = packet.payload.take(4).toList().reversed.toList();
    // Never accept public/loopback destinations or disable TLS for other hosts.
    final private =
        bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) || (bytes[0] == 192 && bytes[1] == 168);
    final port = ByteData.sublistView(packet.payload).getUint16(4, Endian.little);
    if (!private || port == 0) throw const FormatException('Invalid D3200 local Wi-Fi endpoint');
    return SoundcoreWifiEndpoint(bytes.join('.'), port);
  }
}

/// Wi-Fi uses text hex commands. Its file request has no trailing checksum and
/// selects Wi-Fi with the final 0x1b byte (distinct from the BLE command).
String soundcoreWifiFileRequest(int id) {
  final bytes = Uint8List(18)..setAll(0, [8, 0xee, 0, 0, 0, 0x1a, 7, 18, 0]);
  ByteData.sublistView(bytes).setUint32(13, id, Endian.little);
  bytes[17] = 0x1b;
  return soundcoreHex(bytes);
}

String soundcoreHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class SoundcoreWifiTransport implements SoundcoreFileTransport {
  final WebSocket _socket;
  final HttpClient _client;
  final RawDatagramSocket _udp;
  final Future<void> Function() _leave;
  final _frames = StreamController<List<int>>.broadcast();
  late final StreamSubscription<dynamic> _subscription;
  late final Timer _keepalive;
  StreamSubscription<RawSocketEvent>? _udpSubscription;
  bool _completedFile = false;
  bool _networkLeft = false;
  bool _closed = false;

  SoundcoreWifiTransport._(this._socket, this._client, this._udp, SoundcoreWifiEndpoint endpoint, this._leave,
      void Function(String)? diagnostic) {
    _subscription = _socket.listen((data) {
      if (diagnostic != null) {
        // i18n-ignore: Structural diagnostics for the local hardware probe.
        diagnostic(data is List<int>
            ? 'binary bytes=${data.length}'
            : 'text chars=${(data as String).length} control=${const [
                'ACK',
                'OK',
                'PONG'
              ].contains(data.trim().toUpperCase())}');
      }
      if (data is List<int>) _frames.add(data);
      // ACK/OK text is not audio and must never enter the binary parser.
    }, onError: (Object error) {
      // i18n-ignore: Structural diagnostics for the local hardware probe.
      diagnostic?.call('socket error ${soundcoreWifiErrorCode(error)}');
      if (!_closed) _frames.addError(error);
    }, onDone: () {
      // i18n-ignore: Structural diagnostics for the local hardware probe.
      diagnostic?.call('socket done code=${_socket.closeCode}');
      if (!_closed) unawaited(_frames.close());
    });
    void ping() {
      if (_closed || _socket.readyState != WebSocket.open) return;
      try {
        // Firmware 04.92 corrupts/stalls bulk frames when text "ping" replies
        // overlap audio. Its dedicated UDP heartbeat keeps the AP alive without
        // additional WebSocket writes. Do not set WebSocket.pingInterval either.
        _udp.send(ascii.encode('soundcore-keep-alive-unicast'), InternetAddress(endpoint.host), 32003);
      } catch (error) {
        // i18n-ignore: Structural diagnostics without user data.
        diagnostic?.call('UDP keepalive ${soundcoreWifiErrorCode(error)}');
      }
    }

    // Drain recorder replies; never let its UDP receive queue fill during a
    // long transfer. Payloads are control traffic and are not audio frames.
    _udp.writeEventsEnabled = false;
    _udpSubscription = _udp.listen((event) {
      if (event == RawSocketEvent.read) {
        while (_udp.receive() != null) {}
      }
    }, onError: (Object error) {
      // UDP is best-effort; WebSocket errors and transfer timeouts detect an
      // actual broken audio connection without discarding healthy bulk data.
      // i18n-ignore: Structural diagnostics without user data.
      if (!_closed) diagnostic?.call('UDP keepalive ${soundcoreWifiErrorCode(error)}');
    });
    _keepalive = Timer.periodic(const Duration(seconds: 2), (_) => ping());
    ping();
  }

  static Future<SoundcoreWifiTransport> connect(
    SoundcoreWifiEndpoint endpoint, {
    required Future<void> Function() leave,
    // Structural probe metadata only; never payloads, credentials or messages.
    void Function(String)? diagnostic,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      // D3200 uses a local self-signed certificate. This exception belongs only
      // to this generated hotspot's reported private IP and port.
      client.badCertificateCallback = (_, host, port) => host == endpoint.host && port == endpoint.port;
      WebSocket? socket;
      RawDatagramSocket? udp;
      try {
        try {
          socket = await _upgrade(Uri.parse('wss://${endpoint.host}:${endpoint.port}'), client)
              .timeout(const Duration(seconds: 7));
        } on HandshakeException {
          // Older D3200 firmware serves plain WS on the same WPA-protected AP.
          // A TLS endpoint on 443 must not receive a subsequent plaintext probe.
          if (endpoint.port == 443) rethrow;
          socket = await _upgrade(Uri.parse('ws://${endpoint.host}:${endpoint.port}'), client)
              .timeout(const Duration(seconds: 7));
        }
        udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        return SoundcoreWifiTransport._(socket, client, udp, endpoint, leave, diagnostic);
      } catch (error) {
        lastError = error;
        udp?.close();
        if (socket != null) unawaited(socket.close());
        client.close(force: true);
        if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    throw lastError ??
        StateError(
            'D3200 Wi-Fi connection failed'); // i18n-ignore: Internal diagnostic; localized by the recording page.
  }

  /// Some embedded HTTP parsers require conventional header casing instead of
  /// dart:io WebSocket.connect's lowercase headers. Keep the RFC 6455 handshake
  /// explicit and still validate the server's nonce-derived accept value.
  static Future<WebSocket> _upgrade(Uri uri, HttpClient client) async {
    final random = Random.secure();
    final key = base64Encode(List.generate(16, (_) => random.nextInt(256)));
    client.autoUncompress = false;
    final request = await client.openUrl('GET', uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http'));
    request.followRedirects = false;
    request.headers.removeAll(HttpHeaders.cacheControlHeader);
    final headers = {
      'Host': '${uri.host}:${uri.port}',
      'Upgrade': 'websocket',
      'Connection': 'Upgrade',
      'Sec-WebSocket-Key': key,
      'Sec-WebSocket-Version': '13',
      'Accept-Encoding': 'gzip',
    };
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value, preserveHeaderCase: true);
    }
    final response = await request.close();
    final expected = base64Encode(sha1.convert(ascii.encode('$key' '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes);
    final upgrade = response.headers.value(HttpHeaders.upgradeHeader)?.toLowerCase();
    final connection = response.headers[HttpHeaders.connectionHeader] ?? [];
    if (response.statusCode != HttpStatus.switchingProtocols ||
        upgrade != 'websocket' ||
        !connection.expand((v) => v.toLowerCase().split(',')).any((v) => v.trim() == 'upgrade') ||
        response.headers.value('sec-websocket-accept') != expected) {
      throw WebSocketException('Recorder WebSocket handshake rejected', response.statusCode);
    }
    return WebSocket.fromUpgradedSocket(await response.detachSocket(), serverSide: false);
  }

  @override
  Stream<List<int>> get notifications => _frames.stream;
  @override
  Future<void> requestFile(int id) async {
    if (_closed || _socket.readyState != WebSocket.open) throw SoundcoreWifiDisconnected();
    _socket.add(soundcoreWifiFileRequest(id));
  }

  @override
  Future<void> acknowledgeFile() async {
    // 1A0A is the Wi-Fi batch finalizer. Sending it between files can produce
    // a late done reply during the next request, or end the device stream.
    // Record completion locally; send the command only when leaving the batch.
    _completedFile = true;
  }

  @override
  Future<void> close({bool leaveNetwork = true}) async {
    if (_closed) {
      if (leaveNetwork && !_networkLeft) {
        await _leave();
        _networkLeft = true;
      }
      return;
    }
    _closed = true;
    _keepalive.cancel();
    await _udpSubscription?.cancel();
    _udp.close();
    try {
      if (leaveNetwork && _socket.readyState == WebSocket.open) {
        _socket.add('FINISH');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (_completedFile && _socket.readyState == WebSocket.open) {
          _socket.add(soundcoreHex(soundcoreCommand(0x1a, 0x0a, [1])));
        }
      }
      await _socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Network teardown still has to run after a lost Wi-Fi connection.
    } finally {
      _client.close(force: true);
      await _subscription.cancel();
      unawaited(_frames.close());
      if (leaveNetwork) {
        await _leave();
        _networkLeft = true;
      }
    }
  }
}
