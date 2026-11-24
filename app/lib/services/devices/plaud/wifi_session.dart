import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'cipher.dart';
import 'identity.dart';
import 'protocol.dart';
import 'wifi_protocol.dart';

/// Protocol-20 Wi-Fi session, isolated from BLE connection teardown.
/// The caller supplies the original cipher, never a clone with reset counters.
class PlaudWifiSession {
  final PlaudIdentity identity;
  PlaudSessionCipher? _cipher;
  final Future<void> Function(Uint8List) send;
  final Duration timeout, transferIdleTimeout;
  late final StreamSubscription<List<int>> _subscription;
  final _ready = _pending<void>();
  final _ended = Completer<void>();
  Future<void> _writes = Future.value();
  bool _closed = false, _authenticated = false, _hello = false, _busy = false;
  int _queuedWrites = 0;
  PlaudException? _failure;
  _Listing? _listing;
  _Download? _download;

  PlaudWifiSession({
    required this.identity,
    required PlaudSessionCipher cipher,
    required this.send,
    required Stream<List<int>> messages,
    this.timeout = const Duration(seconds: 20),
    this.transferIdleTimeout = const Duration(seconds: 20),
  }) : _cipher = cipher {
    _subscription = messages.listen(_receive, onError: (_) => dispose(), onDone: dispose);
  }

  bool get isClosed => _closed;
  Future<void> get done => _ended.future;

  Future<void> authenticate() async {
    try {
      await _ready.future.timeout(timeout);
      _checkOpen();
    } catch (error) {
      final failure = _safe(error);
      dispose(failure);
      throw failure;
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    _checkOpen();
    if (!_authenticated) throw const PlaudException(PlaudIssue.authentication);
    if (_busy) throw const PlaudException(PlaudIssue.busy);
    _busy = true;
    try {
      final result = await action();
      _checkOpen();
      return result;
    } catch (error) {
      final failure = _safe(error);
      dispose(failure);
      throw failure;
    } finally {
      _busy = false;
    }
  }

  Future<List<PlaudWifiRecording>> recordings() => _exclusive(() async {
        final listing = _listing = _Listing();
        try {
          await _send(PlaudWifiPacket(11, {'uid': 0, 'start': 0, 'single': 0}));
          return await listing.done.future.timeout(timeout);
        } finally {
          _listing = null;
        }
      });

  /// Writes only to the caller's partial file. Promotion/upload is permitted
  /// only after this returns and the caller checks its persisted size/hash.
  Future<void> downloadTo(PlaudWifiRecording recording, File target, {void Function(int, int)? onProgress}) =>
      _exclusive(() async {
        final validator = PlaudWifiDownload(recording);
        if (recording.scene < 0 || recording.scene > 0xffff) throw const PlaudException(PlaudIssue.protocol);
        final file = await target.open(mode: FileMode.write);
        final transfer = _Download(validator, file, onProgress);
        try {
          _checkOpen();
          _download = transfer;
          _armTransfer(transfer);
          await _send(PlaudWifiPacket(12, {
            'session': recording.id,
            'scene': recording.scene,
            'start': 0,
            'end': recording.byteSize,
          }));
          await transfer.done.future;
          _checkOpen();
          await file.flush();
        } finally {
          transfer.timer?.cancel();
          _download = null;
          await file.close();
        }
      });

  Future<void> _send(PlaudWifiPacket packet) {
    if (_queuedWrites >= 128) {
      dispose(const PlaudException(PlaudIssue.protocol));
      return Future.error(const PlaudException(PlaudIssue.protocol));
    }
    _queuedWrites++;
    final result = _writes.then((_) async {
      _checkOpen();
      await send(_cipher!.sealWifi(packet.encode())).timeout(timeout);
      _checkOpen();
    }).whenComplete(() => _queuedWrites--);
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _receive(List<int> bytes) {
    if (_closed) return;
    try {
      if (bytes.length > plaudWifiMaxPduBytes + 20) throw const PlaudException(PlaudIssue.protocol);
      final packet = PlaudWifiPacket.decode(_cipher!.openWifi(Uint8List.fromList(bytes)));
      if (packet.type == 3) {
        packet.requireType(3);
        unawaited(_send(PlaudWifiPacket(3, {'stamp': DateTime.now().millisecondsSinceEpoch ~/ 1000}))
            .catchError((Object error) => dispose(_safe(error))));
      } else if (!_authenticated) {
        if (!_hello && packet.type == 2) {
          packet.requireHello(identity.serial);
          _hello = true;
          unawaited(_send(PlaudWifiPacket(1, {
            'token': identity.bindToken.padRight(32, '0'),
            'stamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          })).catchError((Object error) => dispose(_safe(error))));
        } else if (_hello && packet.type == 1) {
          packet.requireType(1);
          if (packet.number('status') != 0) throw const PlaudException(PlaudIssue.authentication);
          _authenticated = true;
          _ready.complete();
        } else {
          throw const PlaudException(PlaudIssue.authentication);
        }
      } else if (packet.type == 11 && _listing != null) {
        _listing!.add(packet);
      } else if ((packet.type == 12 || packet.type == 13) && _download != null) {
        final transfer = _download!;
        if (packet.type == 12) {
          transfer.validator.accept(packet);
        } else {
          final data = transfer.validator.add(packet);
          transfer.file.writeFromSync(data);
          transfer.progress?.call(transfer.validator.received, transfer.validator.recording.byteSize);
          if (transfer.validator.finished) transfer.done.complete();
        }
        if (transfer.done.isCompleted) {
          transfer.timer?.cancel();
        } else {
          _armTransfer(transfer);
        }
      } else if (packet.type == 4) {
        dispose();
      } else {
        throw const PlaudException(PlaudIssue.protocol);
      }
    } catch (error) {
      dispose(_safe(error));
    }
  }

  void _armTransfer(_Download transfer) {
    transfer.timer?.cancel();
    transfer.timer = Timer(transferIdleTimeout, () => dispose(const PlaudException(PlaudIssue.timeout)));
  }

  /// Sends the protocol's close request. Network cleanup belongs to the owner
  /// and is still required if this fails or the device disconnects first.
  Future<void> requestClose() async {
    try {
      if (!_closed && _authenticated) await _send(PlaudWifiPacket(4, {}));
    } finally {
      dispose();
    }
  }

  void _checkOpen() {
    if (_closed) throw _failure ?? const PlaudException(PlaudIssue.disconnected);
  }

  void dispose([PlaudException error = const PlaudException(PlaudIssue.disconnected)]) {
    if (_closed) return;
    _closed = true;
    _failure = error;
    _cipher = null;
    _ended.complete();
    _download?.timer?.cancel();
    for (final pending in <Completer?>[_ready, _listing?.done, _download?.done]) {
      if (pending != null && !pending.isCompleted) pending.completeError(error);
    }
    unawaited(_subscription.cancel());
  }
}

PlaudException _safe(Object error) => error is PlaudException
    ? error
    : PlaudException(error is TimeoutException ? PlaudIssue.timeout : PlaudIssue.protocol);

Completer<T> _pending<T>() {
  final completer = Completer<T>();
  unawaited(completer.future.then<void>((_) {}, onError: (Object _) {}));
  return completer;
}

class _Listing {
  final done = _pending<List<PlaudWifiRecording>>();
  final files = <PlaudWifiRecording>[];
  final ids = <int>{};
  int? total;
  void add(PlaudWifiPacket packet) {
    final (count, offset, entries) = plaudWifiListPage(packet);
    if (done.isCompleted || offset != files.length || (total != null && total != count)) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    total = count;
    for (final entry in entries) {
      if (!ids.add(entry.id)) throw const PlaudException(PlaudIssue.protocol);
      files.add(entry);
    }
    if (files.length == count) done.complete(List.unmodifiable(files));
  }
}

class _Download {
  final PlaudWifiDownload validator;
  final RandomAccessFile file;
  final void Function(int, int)? progress;
  final done = _pending<void>();
  Timer? timer;
  _Download(this.validator, this.file, this.progress);
}
