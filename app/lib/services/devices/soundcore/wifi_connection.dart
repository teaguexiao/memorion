import 'dart:async';
import 'dart:io';

import 'protocol.dart';
import 'protocol_error.dart';
import 'session.dart';
import 'wifi_transport.dart';

bool soundcoreWifiCanRetry(Object error) =>
    error is SoundcoreWifiDisconnected ||
    error is TimeoutException ||
    error is SocketException ||
    error is WebSocketException ||
    (error is SoundcoreProtocolException && error.issue == SoundcoreProtocolIssue.incompleteFile);

/// Owns the authenticated download context until the whole Wi-Fi batch ends.
/// A Bluetooth disconnect/reconnect cannot replace or clear this context.
class SoundcoreWifiConnection {
  SoundcoreSession session;
  SoundcoreFileTransport transport;
  final Future<SoundcoreFileTransport> Function(SoundcoreFileTransport)? reconnect;
  final void Function()? onRetry;
  final List<String> _previousDiagnostics = [];
  String get diagnostics => [..._previousDiagnostics, session.diagnostics].join('\n');
  Future<void>? _closing;

  SoundcoreWifiConnection(this.session, this.transport, {this.reconnect, this.onRetry});

  Future<SoundcoreDownload> download(SoundcoreRecording file, {void Function(int)? onProgress}) async {
    final spare = reconnect == null ? null : session.forkWifiSession();
    var usingSpare = false;
    try {
      try {
        return await session.download(file, transport: transport, onProgress: onProgress);
      } catch (error) {
        if (_closing != null || spare == null || !soundcoreWifiCanRetry(error)) rethrow;
        _previousDiagnostics.add(session.diagnostics);
        _previousDiagnostics.add(
            'Wi-Fi fresh socket retry ${soundcoreWifiErrorCode(error)}'); // i18n-ignore: Sanitized technical diagnostic.
        onRetry?.call();
        transport = await reconnect!(transport);
        if (_closing != null) {
          await transport.close();
          throw StateError('Wi-Fi batch closed during retry');
        }
        final previous = session;
        session = spare;
        usingSpare = true;
        previous.close();
        onProgress?.call(0);
        return await session.download(file, transport: transport, onProgress: onProgress);
      }
    } finally {
      if (!usingSpare) spare?.close();
    }
  }

  Future<void> close() => _closing ??= _close().catchError((Object error) {
        _closing = null;
        throw error;
      });

  Future<void> _close() async {
    session.close();
    await transport.close();
  }
}
