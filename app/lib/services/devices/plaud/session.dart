import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'cipher.dart';
import 'identity.dart';
import 'protocol.dart';
import 'wifi_handoff.dart';

/// An intentional transport change, not a failed recording or an upload retry.
class PlaudBluetoothInterrupted extends PlaudException {
  const PlaudBluetoothInterrupted() : super(PlaudIssue.disconnected);
}

/// One connection generation, for an original Note already bound to this
/// account. The transport must preserve each GATT notification/write boundary.
/// A failed operation retires the session; late replies cannot satisfy a retry.
class PlaudSession {
  final PlaudIdentity identity;
  final Future<void> Function(Uint8List) send;
  final Duration timeout, transferIdleTimeout;
  late final StreamSubscription<List<int>> _subscription;
  final _parts = PlaudSecretParts();
  PlaudSessionCipher? _cipher;
  Completer<Uint8List>? _unlock, _reply;
  Set<int> _expected = {};
  _ListRequest? _listing;
  _Transfer? _transfer;
  Future<void> _writes = Future.value();
  final _closeWaiters = <Completer<void>>{};
  bool _closed = false, _busy = false, _authenticated = false;
  bool _downloading = false;
  int _queuedWrites = 0;
  PlaudException? _failure;
  String? _firmwareVersion;

  PlaudSession(
      {required this.identity,
      required this.send,
      required Stream<List<int>> notifications,
      this.timeout = const Duration(seconds: 20),
      this.transferIdleTimeout = const Duration(seconds: 20)}) {
    _subscription = notifications.listen(_receive, onError: (_) => close(), onDone: close);
  }
  bool get isClosed => _closed;
  bool get busy => _busy;
  String? get firmwareVersion => _firmwareVersion;

  /// Retire this generation before a physical BLE reconnect. Delayed blocks
  /// from the unfinished file must never reach the hotspot control session.
  bool interruptBluetoothDownload() {
    if (!_downloading || _closed) return false;
    close(const PlaudBluetoothInterrupted());
    return true;
  }

  Future<T> _downloadExclusive<T>(Future<T> Function() action) => _exclusive(() async {
        _downloading = true;
        try {
          final result = await action();
          if (_closed) throw _failure!;
          return result;
        } finally {
          _downloading = false;
        }
      });

  Future<T> _exclusive<T>(Future<T> Function() action, {bool auth = false}) async {
    if (_closed) throw const PlaudException(PlaudIssue.disconnected);
    if (_busy) throw const PlaudException(PlaudIssue.busy);
    if (!auth && !_authenticated) throw const PlaudException(PlaudIssue.authentication);
    _busy = true;
    try {
      return await action();
    } catch (error) {
      final safe = error is PlaudException ? error : const PlaudException(PlaudIssue.protocol);
      close(safe);
      throw safe;
    } finally {
      _busy = false;
    }
  }

  Future<void> authenticate(String advertisedSerial) => _exclusive(() async {
        if (_authenticated || advertisedSerial != identity.serial) {
          throw const PlaudException(PlaudIssue.authentication);
        }
        final wait = _unlock = _guarded<Uint8List>();
        for (final part in plaudUnlockParts(0xfe10, identity.signature)) {
          await _write(part, encrypted: false);
        }
        final secret = await _wait(wait.future);
        _cipher = PlaudSessionCipher.unlock(secret, identity);
        _unlock = null;
        var response = await _request(plaudHandshake(identity.bindToken), {1, 2});
        if (plaudCommandId(response) == 2) {
          response = await _request(plaudHandshake(identity.bindToken, second: true), {1});
        }
        if (response.length < 6 ||
            response[3] != 0 ||
            ByteData.sublistView(response).getUint16(4, Endian.little) != 20) {
          throw const PlaudException(PlaudIssue.authentication);
        }
        // The full handshake ends with a four-byte version after the capability
        // fields. Short legacy replies remain usable without invented metadata.
        _firmwareVersion = response.length >= 16 ? plaudFirmwareVersion(response.sublist(response.length - 4)) : null;
        _authenticated = true;
      }, auth: true);

  Future<List<PlaudRecording>> recordings() => _exclusive(() async {
        final request = _listing = _ListRequest();
        final body = Uint8List(9);
        ByteData.sublistView(body).setUint32(0, DateTime.now().millisecondsSinceEpoch ~/ 1000, Endian.little);
        try {
          await _write(plaudCommand(26, body));
          return await _wait(request.done.future);
        } finally {
          _listing = null;
        }
      });

  Future<PlaudWifiHandoff> openWifi() => _exclusive(() async {
        // Preserve this exact cipher before the AP acknowledgement tears down
        // BLE. Its send/receive counters already include the handoff exchange.
        final cipher = _cipher!;
        final wait = _reply = _guarded<Uint8List>();
        _expected = {10};
        try {
          final password = identity.serial.substring(identity.serial.length - 8).codeUnits;
          try {
            await _write(plaudWifiCommand(10, [0, ...password]));
          } catch (_) {
            // A valid reply can precede a disconnect within the write callback.
            // Missing/error replies still fail; a disconnect alone is no proof.
            if (!wait.isCompleted) rethrow;
          }
          final reply = await wait.future.timeout(timeout);
          if (reply.length < 4 || reply[3] != 0) throw const PlaudException(PlaudIssue.busy);
          if (reply.length != 4 && (reply.length != 12 || !listEquals(reply.sublist(4), password))) {
            throw const PlaudException(PlaudIssue.protocol);
          }
          return PlaudWifiHandoff(identity, cipher);
        } finally {
          _reply = null;
          _expected = {};
          close();
        }
      });

  Future<Uint8List> download(PlaudRecording recording, {void Function(int, int)? onProgress}) =>
      _downloadExclusive(() => _download(recording, onProgress: onProgress));

  /// The caller owns [target], including partial data on failure. Writes are
  /// bounded by one GATT packet; no whole-recording buffer is allocated.
  Future<void> downloadTo(PlaudRecording recording, File target, {void Function(int, int)? onProgress}) =>
      _downloadExclusive(() async {
        final output = await target.open(mode: FileMode.write);
        try {
          await _download(recording, onProgress: onProgress, onData: output.writeFromSync);
          await output.flush();
        } finally {
          await output.close();
        }
      });

  Future<Uint8List> _download(PlaudRecording recording,
      {void Function(int, int)? onProgress, void Function(Uint8List)? onData}) async {
    if (_closed) throw _failure!;
    if (recording.id <= 0 ||
        recording.id > 0xffffffff ||
        recording.byteSize <= 512 ||
        recording.byteSize > plaudMaxFileBytes) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    final transfer = _transfer = _Transfer(recording, onProgress, onData);
    final body = Uint8List(12);
    ByteData.sublistView(body)
      ..setUint32(0, recording.id, Endian.little)
      ..setUint32(8, recording.byteSize, Endian.little);
    try {
      // Handler precedes request: some peers send blocks immediately after head.
      final head = await _request(plaudCommand(28, body), {28});
      if (head.length < 8 || ByteData.sublistView(head).getUint32(3, Endian.little) != recording.id || head[7] != 0) {
        throw const PlaudException(PlaudIssue.protocol);
      }
      if (!transfer.done.isCompleted) _armTransfer(transfer);
      // Progress resets the idle timer; a healthy large file has no wall-clock cap.
      final result = await transfer.done.future;
      if (_closed) throw _failure ?? const PlaudException(PlaudIssue.disconnected);
      return result;
    } finally {
      transfer.timer?.cancel();
      _transfer = null;
    }
  }

  Future<Uint8List> _request(Uint8List packet, Set<int> codes) async {
    if (_reply != null) throw const PlaudException(PlaudIssue.busy);
    final wait = _reply = _guarded<Uint8List>();
    _expected = codes;
    try {
      await _write(packet);
      return await _wait(wait.future);
    } finally {
      _reply = null;
      _expected = {};
    }
  }

  Future<T> _wait<T>(Future<T> result, [Duration? limit]) async {
    // A native write can still be waiting for its callback when Wi-Fi is
    // requested. Closing the generation must wake that wait immediately too.
    final closed = Completer<void>();
    _closeWaiters.add(closed);
    if (_closed) closed.complete();
    try {
      final value = await Future.any<T>([result, closed.future.then<T>((_) => throw _failure!)])
          .timeout(limit ?? timeout, onTimeout: () {
        throw const PlaudException(PlaudIssue.timeout);
      });
      if (_closed) throw _failure!;
      return value;
    } finally {
      _closeWaiters.remove(closed);
    }
  }

  Future<void> _write(Uint8List packet, {bool encrypted = true}) {
    if (_queuedWrites >= 128) {
      close(const PlaudException(PlaudIssue.protocol));
      return Future.error(const PlaudException(PlaudIssue.protocol));
    }
    _queuedWrites++;
    final result = _writes.then((_) async {
      if (_closed) throw _failure!;
      if (encrypted && _cipher == null) throw const PlaudException(PlaudIssue.authentication);
      await _wait(send(encrypted ? _cipher!.seal(packet) : packet));
      if (_closed) throw _failure!;
    }).whenComplete(() => _queuedWrites--);
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _receive(List<int> raw) {
    if (_closed) return;
    try {
      if (raw.isEmpty || raw.length > 512) throw const PlaudException(PlaudIssue.protocol);
      final packet = Uint8List.fromList(raw);
      if (_cipher == null) {
        if (_unlock == null || _unlock!.isCompleted) throw const PlaudException(PlaudIssue.authentication);
        // No key installation/rotation. New binding must be completed through
        // the owner's official PLAUD app before importing its identity.
        if (packet.length >= 2 && packet[0] == 0x11 && packet[1] == 0xfe) {
          throw const PlaudException(PlaudIssue.identityRequired);
        }
        _parts.add(packet);
        if (_parts.complete) _unlock!.complete(_parts.ciphertext());
        return;
      }
      final plain = _cipher!.open(packet);
      final code = plaudCommandId(plain);
      if (code == 19) {
        if (plain.length < 11) throw const PlaudException(PlaudIssue.protocol);
        if (plain[7] != 0) {
          unawaited(_write(plaudCommand(19, plain.sublist(3, 7))).catchError((Object _) => close()));
        }
      } else if (code == 26 && _listing != null) {
        _listing!.add(plain);
      } else if (_transfer != null && (plain[0] == 2 || code == 29)) {
        _transfer!.add(plain);
        if (!_transfer!.done.isCompleted) _armTransfer(_transfer!);
      } else if (_reply != null && !_reply!.isCompleted && _expected.contains(code)) {
        _reply!.complete(plain);
      }
    } catch (error) {
      close(error is PlaudException ? error : const PlaudException(PlaudIssue.protocol));
    }
  }

  void _armTransfer(_Transfer transfer) {
    transfer.timer?.cancel();
    transfer.timer = Timer(transferIdleTimeout, () => close(const PlaudException(PlaudIssue.timeout)));
  }

  void close([PlaudException error = const PlaudException(PlaudIssue.disconnected)]) {
    if (_closed) return;
    _closed = true;
    _failure = error;
    for (final waiter in _closeWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _authenticated = false;
    _cipher = null;
    _transfer?.timer?.cancel();
    for (final completer in <Completer?>[_unlock, _reply, _listing?.done, _transfer?.done]) {
      if (completer != null && !completer.isCompleted) completer.completeError(error);
    }
    unawaited(_subscription.cancel());
  }
}

Completer<T> _guarded<T>() {
  final result = Completer<T>();
  unawaited(result.future.then<void>((_) {}, onError: (Object _) {}));
  return result;
}

class _ListRequest {
  final done = _guarded<List<PlaudRecording>>();
  final files = <PlaudRecording>[];
  final ids = <int>{};
  int? total;
  void add(Uint8List packet) {
    if (done.isCompleted) throw const PlaudException(PlaudIssue.protocol);
    final (count, index, entries) = plaudListPage(packet);
    if ((total != null && count != total) || index != files.length || (entries.isEmpty && count != 0)) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    total = count;
    for (final entry in entries) {
      if (!ids.add(entry.id)) throw const PlaudException(PlaudIssue.protocol);
      files.add(entry);
    }
    if (files.length == total) done.complete(List.unmodifiable(files));
  }
}

class _Transfer {
  final PlaudRecording recording;
  final void Function(int, int)? progress;
  final done = _guarded<Uint8List>();
  final out = BytesBuilder(copy: false);
  final void Function(Uint8List)? onData;
  int received = 0;
  Timer? timer;
  _Transfer(this.recording, this.progress, this.onData);
  void add(Uint8List packet) {
    if (done.isCompleted) throw const PlaudException(PlaudIssue.protocol);
    var end = false;
    if (packet[0] == 2) {
      final (offset, data) = plaudFileData(packet, recording.id);
      end = offset == 0xffffffff;
      if (!end) {
        if (offset != received || data.isEmpty || received + data.length > recording.byteSize) {
          throw const PlaudException(PlaudIssue.protocol);
        }
        if (onData == null) {
          out.add(data);
        } else {
          onData!(data);
        }
        received += data.length;
        progress?.call(received, recording.byteSize);
      }
    } else {
      if (packet.length != 9 || ByteData.sublistView(packet).getUint32(3, Endian.little) != recording.id) {
        throw const PlaudException(PlaudIssue.protocol);
      }
      // Tail CRC algorithm is not verified. Do not represent it as checked.
      end = true;
    }
    if (end) {
      if (received != recording.byteSize) throw const PlaudException(PlaudIssue.protocol);
      timer?.cancel();
      done.complete(out.takeBytes());
    }
  }
}
