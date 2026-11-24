import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../offline_recordings/models.dart';
import 'identity.dart';
import 'protocol.dart';

/// Factory-firmware A1 session. Device pushes cannot complete client requests.
/// Command timeouts retire the generation so late replies cannot contaminate a retry.
class A1Session {
  final A1Identity identity;
  final Future<void> Function(Uint8List) send;
  final Duration commandTimeout, transferTimeout;
  final _decoder = A1Decoder();
  final _pending = <int, Completer<A1Frame>>{};
  final _infoEvents = StreamController<A1Info>.broadcast();
  late final StreamSubscription<List<int>> _subscription;
  Future<void> _writes = Future.value();
  Future<void> _events = Future.value();
  int _sequence = 15, _queuedEvents = 0;
  bool _closed = false, _busy = false, _authenticated = false;
  _A1Transfer? _transfer;
  A1Info? info;

  A1Session(
      {required this.identity,
      required this.send,
      required Stream<List<int>> notifications,
      this.commandTimeout = const Duration(seconds: 20),
      this.transferTimeout = const Duration(seconds: 45)}) {
    _subscription = notifications.listen(_receive, onError: (_) => close(), onDone: close);
  }
  bool get isClosed => _closed;
  bool get busy => _busy;
  Stream<A1Info> get infoEvents => _infoEvents.stream;

  Future<T> _exclusive<T>(Future<T> Function() work, {bool authenticating = false}) async {
    if (_closed) throw const A1Exception(A1Issue.disconnected);
    if (!authenticating && !_authenticated) throw const A1Exception(A1Issue.authentication);
    if (_busy) throw const A1Exception(A1Issue.busy);
    _busy = true;
    try {
      return await work();
    } finally {
      _busy = false;
    }
  }

  Future<void> authenticate() => _exclusive(() async {
        final challenge = (await _request(0x0008, {'corp_id': identity.corpId})).json();
        // Stock A1 replies to getRandom with only the challenge, without code.
        // An explicit error still rejects; this exception is not used for auth.
        if (challenge.containsKey('code')) a1Accepted(challenge, authentication: true);
        final random = challenge['random'];
        if (random is! String || random.length != 32 || random.codeUnits.any((c) => c > 127)) {
          throw const A1Exception(A1Issue.authentication);
        }
        final response = (await _request(0x0133, {
          'corp_id': identity.corpId,
          'token': identity.token(random),
          'model': 'Memorion_A1',
          'sdk_ver': 'V2.1.3',
          'timestamp': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}'
        }))
            .json();
        a1Accepted(response, authentication: true);
        _authenticated = true;
      }, authenticating: true);

  Future<A1Info> readInfo() => _exclusive(_readInfo);
  Future<A1Info> _readInfo() async {
    final current = A1Info.parse((await _request(0x0132)).json());
    if (!_closed) {
      info = current;
      _infoEvents.add(current);
    }
    return current;
  }

  Future<List<OfflineRecording>> recordings() => _exclusive(() async {
        final result = <int, OfflineRecording>{};
        var until = 0;
        for (var page = 0; page < 100; page++) {
          final response = await _request(0x0110, {'s_fid': '0', 'e_fid': '$until', 'recently': 100});
          final parsed = A1RecordingPage.parse(response.payload);
          final oldCount = result.length;
          for (final r in parsed.recordings) {
            result[r.id] = r;
          }
          // An older peer without a truncation trailer is complete only below limit.
          if (!parsed.truncated && (parsed.hasTrailer || parsed.recordings.length < 100)) {
            return result.values.toList()..sort((a, b) => b.id.compareTo(a.id));
          }
          if (result.length == oldCount || parsed.recordings.isEmpty) throw const A1Exception(A1Issue.incompleteList);
          final oldest = parsed.recordings.map((r) => r.id).reduce((a, b) => a < b ? a : b);
          if (oldest <= 1 || (until > 0 && oldest >= until)) throw const A1Exception(A1Issue.incompleteList);
          until = oldest - 1;
        }
        throw const A1Exception(A1Issue.incompleteList);
      });

  Future<A1Info> recordingControl(String action) => _exclusive(() async {
        if (!{'start', 'stop', 'pause', 'resume'}.contains(action)) throw ArgumentError.value(action);
        a1Accepted((await _request(0x0100, {'action': action})).json());
        return _readInfo();
      });

  Future<Uint8List> download(int fid, {void Function(int received, int total)? onProgress}) => _exclusive(() async {
        final status = await _readInfo();
        if (status.audioStatus != 'idle') throw const A1Exception(A1Issue.busy);
        // Stock firmware can erase a file after transfer. Never start a transfer
        // unless the owner's existing setting explicitly keeps device originals.
        final settings = (await _request(0x0100, {'action': 'get'})).json();
        a1Accepted(settings);
        final params = settings['params'];
        final deletion =
            params is List ? params.whereType<Map>().where((p) => p['key'] == 'delete_after_upload').toList() : <Map>[];
        if (deletion.length != 1 || deletion.single['val'] != 0) {
          throw const A1Exception(A1Issue.retention);
        }
        final transfer = _A1Transfer(fid, onProgress);
        _transfer = transfer;
        // Install the handler before requesting: attributes can precede the reply.
        final completed = transfer.done.future;
        unawaited(completed.then<void>((_) {}, onError: (Object _) {}));
        _armTransfer(transfer);
        try {
          a1Accepted((await _request(0x0111, {'fid': '$fid', 'offset': 0, 'progress': 65537})).json());
          return await completed;
        } catch (_) {
          // A new session is required after an incomplete file; no late blocks reused.
          if (!_closed) {
            try {
              await _write(0x0112, {'did': identity.did, 'fid': '$fid'});
            } catch (_) {}
          }
          close();
          rethrow;
        } finally {
          transfer.timer?.cancel();
          _transfer = null;
        }
      });

  void _armTransfer(_A1Transfer transfer) {
    transfer.timer?.cancel();
    transfer.timer = Timer(transferTimeout, () => _fail(const A1Exception(A1Issue.timeout)));
  }

  Future<A1Frame> _request(int command, [Map<String, dynamic> fields = const {}]) async {
    if (_closed) throw const A1Exception(A1Issue.disconnected);
    final result = Completer<A1Frame>();
    _pending[command] = result;
    final response = result.future.timeout(commandTimeout, onTimeout: () {
      _fail(const A1Exception(A1Issue.timeout));
      throw const A1Exception(A1Issue.timeout);
    });
    // Observe failures even if a synchronous transport error occurs during write.
    unawaited(response.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _write(command, {'did': identity.did, ...fields});
      return await response;
    } finally {
      _pending.remove(command);
    }
  }

  Future<void> _write(int command, Object body, {int kind = 0x13, int? sequence}) {
    final bytes = a1Encode(command, sequence ?? (++_sequence & 255), body, kind: kind);
    final operation = _writes.then((_) async {
      if (_closed) throw const A1Exception(A1Issue.disconnected);
      await send(bytes);
    });
    _writes = operation.catchError((Object _) {
      _fail(const A1Exception(A1Issue.disconnected));
    });
    return operation;
  }

  void _receive(List<int> bytes) {
    if (_closed) return;
    try {
      for (final frame in _decoder.add(bytes)) {
        final pending = _pending[frame.command];
        if (frame.kind == 0x31 && pending != null && !pending.isCompleted) {
          pending.complete(frame);
        } else if (frame.command == 0x0132) {
          final body = frame.json();
          if (body['code'] == 200) {
            info = A1Info.parse(body);
            _infoEvents.add(info!);
          }
        }
        if (_transfer != null && {0x0114, 0x0115}.contains(frame.command) && frame.kind != 0x31) {
          if (++_queuedEvents > 256) throw const A1Exception(A1Issue.protocol);
          final transfer = _transfer!;
          _events = _events.then((_) => _fileEvent(transfer, frame)).catchError((Object _) {
            _fail(const A1Exception(A1Issue.protocol));
          }).whenComplete(() {
            _queuedEvents--;
          });
        }
      }
    } catch (error) {
      _fail(error is A1Exception ? error : const A1Exception(A1Issue.protocol));
    }
  }

  Future<void> _fileEvent(_A1Transfer t, A1Frame frame) async {
    if (_closed || _transfer != t || t.done.isCompleted) return;
    _armTransfer(t);
    if (frame.command == 0x0114) {
      if (t.attributes != null && !const ListEquality<int>().equals(t.attributes, frame.payload)) {
        throw const A1Exception(A1Issue.protocol);
      }
      t.attributes = frame.payload;
      // Older firmware has binary attributes. File header supplies its size.
      try {
        t.expected ??= _findSize(frame.json());
      } on A1Exception {/* Binary attributes. */}
      if (t.expected != null && (t.expected! < 80 || t.expected! > 64 * 1024 * 1024)) {
        throw const A1Exception(A1Issue.protocol);
      }
    } else {
      if (t.attributes == null) throw const A1Exception(A1Issue.protocol);
      final block = A1FileBlock.parse(frame.payload);
      if (block.fid != t.fid) throw const A1Exception(A1Issue.protocol);
      final duplicate = block.number == t.lastNumber;
      if (duplicate) {
        if (!const ListEquality<int>().equals(block.data, t.lastData)) throw const A1Exception(A1Issue.protocol);
      } else {
        if (t.lastNumber != null && block.number != t.lastNumber! + 1) throw const A1Exception(A1Issue.protocol);
        if (t.received == 0) {
          if (block.data.length < 12 ||
              ascii.decode(block.data.sublist(0, 4), allowInvalid: true) != 'BABA' ||
              ascii.decode(block.data.sublist(8, 12), allowInvalid: true) != 'DTYJ') {
            throw const A1Exception(A1Issue.unsupportedAudio);
          }
          final length = ByteData.sublistView(block.data).getUint32(4, Endian.little) + 8;
          if ((t.expected != null && t.expected != length) || length < 80 || length > 64 * 1024 * 1024) {
            throw const A1Exception(A1Issue.protocol);
          }
          t.expected = length;
        }
        if (t.received + block.data.length > t.expected!) throw const A1Exception(A1Issue.protocol);
        t.bytes.add(block.data);
        t.received += block.data.length;
        t.lastNumber = block.number;
        t.lastData = block.data;
        t.onProgress?.call(t.received, t.expected!);
      }
    }
    await _write(frame.command, {'code': 200}, kind: 0x31, sequence: frame.sequence);
    if (!_closed && !t.done.isCompleted && t.expected != null && t.received == t.expected) {
      t.timer?.cancel();
      t.done.complete(t.bytes.takeBytes());
    }
  }

  static int? _findSize(Object? body) {
    if (body is Map) {
      for (final key in ['size', 'file_size', 'fileSize', 'total_size', 'totalSize']) {
        final value = int.tryParse('${body[key]}');
        if (value != null) return value;
      }
      for (final value in body.values) {
        final size = _findSize(value);
        if (size != null) return size;
      }
    }
    return null;
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    _authenticated = false;
    for (final value in _pending.values) {
      if (!value.isCompleted) value.completeError(error);
    }
    final t = _transfer;
    t?.timer?.cancel();
    if (t != null && !t.done.isCompleted) t.done.completeError(error);
    unawaited(_subscription.cancel());
    unawaited(_infoEvents.close());
  }

  void close() => _fail(const A1Exception(A1Issue.disconnected));
}

class _A1Transfer {
  final int fid;
  final void Function(int, int)? onProgress;
  final done = Completer<Uint8List>();
  final bytes = BytesBuilder(copy: false);
  int received = 0;
  int? expected, lastNumber;
  Uint8List? lastData, attributes;
  Timer? timer;
  _A1Transfer(this.fid, this.onProgress);
}
