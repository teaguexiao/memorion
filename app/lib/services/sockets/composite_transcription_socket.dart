import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

import 'package:memorion/services/sockets/pure_socket.dart';

/// A composite socket that sends audio to both a local on-device STT (primary)
/// and the Memorion backend WebSocket (secondary) simultaneously.
///
/// - Audio frames are sent to BOTH sockets via [send].
/// - Primary socket results (local STT) are forwarded to the secondary socket
///   as `suggested_transcript` JSON messages.
/// - Secondary socket results (from the backend) are the final output to the UI.
class CompositeTranscriptionSocket implements IPureSocket {
  final IPureSocket primarySocket;
  final IPureSocket secondarySocket;

  PureSocketStatus _status = PureSocketStatus.notConnected;
  IPureSocketListener? _listener;

  late final _PrimarySocketListener _primaryListener;
  late final _SecondarySocketListener _secondaryListener;

  CompositeTranscriptionSocket({
    required this.primarySocket,
    required this.secondarySocket,
  }) {
    _primaryListener = _PrimarySocketListener(this);
    _secondaryListener = _SecondarySocketListener(this);

    primarySocket.setListener(_primaryListener);
    secondarySocket.setListener(_secondaryListener);
  }

  @override
  PureSocketStatus get status => _status;

  @override
  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() async {
    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      return false;
    }

    debugPrint('[Composite] Connecting both sockets...');
    _status = PureSocketStatus.connecting;

    final results = await Future.wait([
      primarySocket.connect(),
      secondarySocket.connect(),
    ]);

    final primaryOk = results[0] && primarySocket.status == PureSocketStatus.connected;
    final secondaryOk = results[1] && secondarySocket.status == PureSocketStatus.connected;

    if (primaryOk && secondaryOk) {
      _status = PureSocketStatus.connected;
      debugPrint('[Composite] Both sockets connected');
      onConnected();
      return true;
    }

    // Either failed — disconnect both and fail
    debugPrint('[Composite] Connection failed - primary: $primaryOk, secondary: $secondaryOk');
    await _disconnectBothQuietly();
    _status = PureSocketStatus.notConnected;
    return false;
  }

  Future<void> _disconnectBothQuietly() async {
    await Future.wait([
      primarySocket.disconnect(),
      secondarySocket.disconnect(),
    ]);
  }

  @override
  Future disconnect() async {
    debugPrint('[Composite] Disconnecting...');
    await _disconnectBothQuietly();
    _status = PureSocketStatus.disconnected;
    onClosed();
  }

  @override
  Future stop() async {
    debugPrint('[Composite] Stopping both sockets...');
    // 转发终态语义给两个子 socket。只 disconnect 的话 secondary（PureSocket）的
    // 重连循环还活着，录音停掉后仍会去 POST /v1/listen 建会话。
    await Future.wait([
      primarySocket.stop(),
      secondarySocket.stop(),
    ]);
    _status = PureSocketStatus.disconnected;
    onClosed();
  }

  @override
  void send(dynamic message) {
    if (_status != PureSocketStatus.connected) {
      return;
    }
    // Audio frames go to both sockets
    primarySocket.send(message);
    secondarySocket.send(message);
  }

  /// Called when the primary (local STT) produces a result.
  /// We forward it to the secondary (backend) as a suggested_transcript.
  void _onPrimaryMessage(dynamic message) {
    _forwardAsSuggestedTranscript(message);
  }

  void _forwardAsSuggestedTranscript(dynamic message) {
    if (_status != PureSocketStatus.connected) {
      return;
    }

    try {
      dynamic segments = message is String ? jsonDecode(message) : message;

      final payload = <String, dynamic>{
        'type': 'suggested_transcript',
        'segments': segments,
        'stt_provider': 'on_device_apple',
      };

      secondarySocket.send(jsonEncode(payload));
    } catch (e) {
      debugPrint('[Composite] Error forwarding transcript: $e');
    }
  }

  /// Called when the secondary (backend) sends a message — this is the final output.
  void _onSecondaryMessage(dynamic message) {
    onMessage(message);
  }

  /// Called when either socket closes unexpectedly.
  void _onSocketClosed(String name, int? closeCode) {
    if (_status != PureSocketStatus.connected) {
      return;
    }
    debugPrint('[Composite] $name socket closed (code: $closeCode), disconnecting');
    _status = PureSocketStatus.disconnected;
    _disconnectBothQuietly();
    onClosed(closeCode);
  }

  void _onSocketError(String name, Object err, StackTrace trace) {
    if (_status != PureSocketStatus.connected) {
      return;
    }
    debugPrint('[Composite] $name socket error: $err');
    _status = PureSocketStatus.disconnected;
    _disconnectBothQuietly();
    onError(err, trace);
  }

  @override
  void onConnected() {
    _listener?.onConnected();
  }

  @override
  void onMessage(dynamic message) {
    _listener?.onMessage(message);
  }

  @override
  void onClosed([int? closeCode]) {
    _listener?.onClosed(closeCode);
  }

  @override
  void onError(Object err, StackTrace trace) {
    _listener?.onError(err, trace);
  }

  @override
  void onInternetSatusChanged(InternetStatus status) {
    // Forward to secondary (backend socket) only — primary is local
    secondarySocket.onInternetSatusChanged(status);
  }
}

class _PrimarySocketListener implements IPureSocketListener {
  final CompositeTranscriptionSocket _composite;
  _PrimarySocketListener(this._composite);

  @override
  void onConnected() => debugPrint('[Composite/Primary] Connected');

  @override
  void onMessage(dynamic message) => _composite._onPrimaryMessage(message);

  @override
  void onClosed([int? closeCode]) => _composite._onSocketClosed('Primary', closeCode);

  @override
  void onError(Object err, StackTrace trace) => _composite._onSocketError('Primary', err, trace);

  @override
  void onInternetConnectionFailed() {}

  @override
  void onMaxRetriesReach() {}
}

class _SecondarySocketListener implements IPureSocketListener {
  final CompositeTranscriptionSocket _composite;
  _SecondarySocketListener(this._composite);

  @override
  void onConnected() => debugPrint('[Composite/Secondary] Connected');

  @override
  void onMessage(dynamic message) => _composite._onSecondaryMessage(message);

  @override
  void onClosed([int? closeCode]) => _composite._onSocketClosed('Secondary', closeCode);

  @override
  void onError(Object err, StackTrace trace) => _composite._onSocketError('Secondary', err, trace);

  @override
  void onInternetConnectionFailed() => _composite._listener?.onInternetConnectionFailed();

  @override
  void onMaxRetriesReach() => _composite._listener?.onMaxRetriesReach();
}
