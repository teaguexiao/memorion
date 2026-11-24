import 'dart:async';
import 'dart:io';

import 'cipher.dart';
import 'identity.dart';
import 'protocol.dart';
import 'wifi_protocol.dart';
import 'wifi_session.dart';

/// Original-Note transport. The Note is the WebSocket client.
/// Bind an explicitly selected hotspot address, never all network interfaces.
class PlaudWifiServer {
  final HttpServer _server;
  final InternetAddress _peerAddress;
  final PlaudIdentity _identity;
  final Duration _timeout, _idleTimeout;
  final int port;
  PlaudSessionCipher? _cipher;
  PlaudWifiSession? _session;
  WebSocket? _socket;
  late final StreamSubscription<HttpRequest> _requests;
  late final Timer _deadline;
  final _ready = Completer<PlaudWifiSession>();
  bool _accepted = false, _closed = false;
  Future<void>? _closing;

  PlaudWifiServer._(this._server, this._peerAddress, this._identity, this._cipher, this._timeout, this._idleTimeout)
      : port = _server.port {
    // Owner may cancel before waiting for the device.
    unawaited(_ready.future.then<void>((_) {}, onError: (Object _) {}));
    _server.idleTimeout = const Duration(seconds: 5);
    _requests = _server.listen((request) => unawaited(_accept(request)),
        onError: (_) => unawaited(close()), onDone: () => unawaited(close()));
    _deadline = Timer(_timeout, () => unawaited(close(const PlaudException(PlaudIssue.timeout))));
  }

  static Future<PlaudWifiServer> bind({
    required InternetAddress localAddress,
    required InternetAddress peerAddress,
    required PlaudIdentity identity,
    required PlaudSessionCipher cipher,
    int port = 8081,
    Duration timeout = const Duration(seconds: 30),
    Duration transferIdleTimeout = const Duration(seconds: 20),
  }) async {
    if (!_privateV4(localAddress) || !_privateV4(peerAddress)) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    final server = await HttpServer.bind(localAddress, port, shared: false);
    return PlaudWifiServer._(server, peerAddress, identity, cipher, timeout, transferIdleTimeout);
  }

  Future<PlaudWifiSession> waitForDevice() async {
    final session = await _ready.future;
    if (_closed || session.isClosed) throw const PlaudException(PlaudIssue.disconnected);
    return session;
  }

  Future<void> _accept(HttpRequest request) async {
    try {
      if (_closed ||
          _accepted ||
          request.connectionInfo?.remoteAddress.address != _peerAddress.address ||
          request.uri.path != '/' ||
          request.uri.hasQuery ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        try {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
        } catch (_) {
          // A rejected peer disappearing cannot retire the current owner.
        }
        return;
      }
      // Reserve before upgrade: two concurrent handshakes cannot take ownership.
      _accepted = true;
      final socket = await WebSocketTransformer.upgrade(request, compression: CompressionOptions.compressionOff);
      if (_closed) {
        await socket.close(WebSocketStatus.goingAway).timeout(const Duration(seconds: 3));
        return;
      }
      _socket = socket;
      final session = _session = PlaudWifiSession(
        identity: _identity,
        cipher: _cipher!,
        timeout: _timeout,
        transferIdleTimeout: _idleTimeout,
        send: (bytes) async {
          if (_closed || socket.readyState != WebSocket.open) throw const PlaudException(PlaudIssue.disconnected);
          socket.add(bytes);
        },
        messages: socket.map((message) {
          if (message is! List<int> || message.length > plaudWifiMaxPduBytes + 20) {
            throw const PlaudException(PlaudIssue.protocol);
          }
          return message;
        }),
      );
      _cipher = null; // The live Wi-Fi session now holds the original counters.
      unawaited(session.done.then((_) => close()));
      unawaited(socket.done.then<void>((_) => unawaited(close()), onError: (Object _) => unawaited(close())));
      await session.authenticate();
      if (_closed || session.isClosed) throw const PlaudException(PlaudIssue.disconnected);
      _deadline.cancel();
      _ready.complete(session);
    } catch (error) {
      await close(error is PlaudException ? error : const PlaudException(PlaudIssue.protocol));
    }
  }

  /// Releases only this listener/socket. The connector must separately leave
  /// the owned hotspot and restore BLE/network work, even if transport fails.
  Future<void> close([PlaudException error = const PlaudException(PlaudIssue.disconnected)]) =>
      _closing ??= _close(error);

  Future<void> _close(PlaudException error) async {
    _closed = true;
    _deadline.cancel();
    _cipher = null;
    _session?.dispose(error);
    _session = null;
    if (!_ready.isCompleted) _ready.completeError(error);
    final socket = _socket;
    _socket = null;
    try {
      await _requests.cancel();
    } finally {
      try {
        await _server.close(force: true);
      } finally {
        // A missing close acknowledgement must not hold network recovery open.
        try {
          await socket?.close(WebSocketStatus.goingAway).timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
    }
  }
}

bool _privateV4(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return b[0] == 127 || b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
}
