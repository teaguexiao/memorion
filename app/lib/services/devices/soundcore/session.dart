import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../offline_recordings/models.dart';

import 'crypto.dart';
import 'ogg_opus.dart';
import 'protocol.dart';
import 'protocol_error.dart';
import 'wifi_transport.dart';

typedef SoundcoreDownload = OfflineDownload;

/// Intentional transport change; partial audio must never be cached/uploaded.
class SoundcoreBluetoothInterrupted implements Exception {
  const SoundcoreBluetoothInterrupted();
}

enum SoundcoreTransferStep { checkingRecorder, requestingFile, receiving, finishing }

/// Transport-independent protocol session. Only reads/exports are exposed:
/// no binding, device deletion, reset, firmware update or recording commands.
class SoundcoreSession {
  final Future<void> Function(Uint8List) send;
  final Duration commandTimeout;
  final Duration transferIdleTimeout;
  final Duration hotspotTimeout;
  final _parser = SoundcorePacketBuffer();
  final SoundcoreCrypto _crypto;
  final bool _wifiOnly;
  bool _wifiActive = false;
  final _pending = <int, Completer<SoundcorePacket>>{};
  final _battery = StreamController<List<int>>.broadcast();
  final _charging = StreamController<int>.broadcast();
  final _infoEvents = StreamController<SoundcoreInfo>.broadcast();
  final _recordStatusEvents = StreamController<int>.broadcast();
  final List<String> _diagnostics = [];
  StreamSubscription<List<int>>? _subscription;
  SoundcoreInfo? info;
  bool _closed = false;
  bool _busy = false;
  _Transfer? _transfer;
  Timer? _idleTimer;
  int? _recordStatus;
  bool _downloadingOverBle = false;
  bool _bluetoothInterrupted = false;
  SoundcoreTransferStep? transferStep;

  SoundcoreSession({
    required Stream<List<int>> notifications,
    required this.send,
    this.commandTimeout = const Duration(seconds: 10),
    this.transferIdleTimeout = const Duration(seconds: 30),
    this.hotspotTimeout = const Duration(seconds: 45),
  })  : _crypto = SoundcoreCrypto(),
        _wifiOnly = false {
    _subscription = notifications.listen(_receive, onError: _fail, onDone: close);
  }

  /// No BLE subscription or writer: this session belongs to the Wi-Fi batch.
  SoundcoreSession._wifi(SoundcoreSession source)
      : _crypto = source._crypto.forkSession(),
        _wifiOnly = true,
        info = source.info,
        commandTimeout = source.commandTimeout,
        hotspotTimeout = source.hotspotTimeout,
        transferIdleTimeout = source.transferIdleTimeout,
        send = _noBluetooth {
    _trace('independent Wi-Fi decryption session prepared');
  }

  static Future<void> _noBluetooth(Uint8List _) async => throw StateError('Wi-Fi session has no BLE writer');

  Stream<List<int>> get batteryEvents => _battery.stream;
  Stream<int> get chargingEvents => _charging.stream;
  Stream<SoundcoreInfo> get infoEvents => _infoEvents.stream;
  Stream<int> get recordStatusEvents => _recordStatusEvents.stream;
  int? get recordStatus => _recordStatus ?? (info?.recording == null ? null : (info!.recording! ? 1 : 0));
  // i18n-ignore: Technical diagnostics; never shown as product copy.
  String get diagnostics => ['Soundcore Work', 'firmware=${info?.firmware ?? "unknown"}', ..._diagnostics].join('\n');
  bool get busy => _busy;
  bool get isClosed => _closed;
  bool get wifiActive => _wifiActive;

  /// Preserve only the authenticated context for a fresh socket retry. File
  /// buffers and file keys are never carried over from an incomplete download.
  SoundcoreSession forkWifiSession() {
    if (_closed || !_crypto.hasSession) throw StateError('Wi-Fi key context is unavailable');
    return SoundcoreSession._wifi(this);
  }

  /// Discard this protocol generation immediately. The controller reconnects
  /// BLE before creating the hotspot, so queued slices/done notifications from
  /// the interrupted file cannot corrupt the next transfer.
  bool interruptBluetoothDownload() {
    if (!_downloadingOverBle || _closed) return false;
    _bluetoothInterrupted = true;
    _trace('BLE download interrupted for Wi-Fi');
    _fail(const SoundcoreBluetoothInterrupted());
    close();
    return true;
  }

  Future<SoundcoreInfo> readInfo() async {
    if (_closed) throw StateError('D3200 session is closed');
    // Use the status checked immediately before starting the hotspot. Status
    // polling must not write to GATT while firmware hands off to Wi-Fi.
    if ((_wifiActive || _wifiOnly) && info != null) return info!;
    await _request(0x01, 0x01);
    return info!;
  }

  void _publishInfo(SoundcoreInfo? value) {
    if (value == null || _closed) return;
    info = value;
    _infoEvents.add(value);
  }

  void _trace(String message) {
    _diagnostics.add(message);
    if (_diagnostics.length > 40) _diagnostics.removeAt(0);
  }

  Future<SoundcoreWifiEndpoint> openWifi(String ssid, String password,
      {void Function(SoundcoreSession)? onDownloadSession}) async {
    final name = utf8.encode(ssid), secret = utf8.encode(password);
    if (name.isEmpty || name.length > 32 || secret.length < 8 || secret.length > 63) {
      throw ArgumentError('Invalid D3200 hotspot credentials');
    }
    _beginOperation();
    SoundcoreSession? downloadSession;
    try {
      final current = await readInfo();
      if (current.recording == true || recordStatus == 1 || recordStatus == 2) {
        throw StateError('Finish recording before starting Wi-Fi transfer');
      }
      // Establish the shared file-decryption key on BLE before joining the AP.
      if (!_crypto.hasSession) {
        final reply = await _request(0x2e, 1, _crypto.publicKey);
        _crypto.completeHandshake(reply.payload);
      }
      // Capture the key before 1A05: GATT may close immediately after its reply.
      if (onDownloadSession != null) {
        downloadSession = SoundcoreSession._wifi(this);
        onDownloadSession(downloadSession);
      }
      _wifiActive = true;
      return SoundcoreWifiEndpoint.fromPacket(
          await _request(0x1a, 5, [name.length, ...name, secret.length, ...secret], hotspotTimeout));
    } catch (_) {
      _wifiActive = false;
      downloadSession?.close();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<void> closeWifi() async {
    // Also permit best-effort AP teardown after a failed transfer invalidated
    // the protocol session; the underlying BLE writer checks connectivity.
    _wifiActive = false;
    await send(soundcoreCommand(0x1a, 2));
  }

  Future<List<SoundcoreRecording>> listRecordings() async {
    _beginOperation();
    try {
      try {
        final files = await _readRecordingPages(withEndTime: true);
        if (files.isNotEmpty) return files;
      } on TimeoutException {
        _trace('extended list timed out; trying legacy list');
      } on FormatException {
        _trace('extended list format unsupported; trying legacy list');
      }
      return await _readRecordingPages(withEndTime: false);
    } finally {
      _busy = false;
    }
  }

  Future<List<SoundcoreRecording>> _readRecordingPages({required bool withEndTime}) async {
    final files = <int, SoundcoreRecording>{};
    for (var page = 0; page < 500; page++) {
      final response = await _request(withEndTime ? 0x1b : 0x1a, 0x0e, [page & 255, page >> 8]);
      final list = SoundcoreRecordingList.parse(response.payload, withEndTime: withEndTime);
      final entries = list.files;
      _trace('list=${withEndTime ? "extended" : "legacy"} page=$page files=${entries.length} '
          'trailer=${list.currentTransferTimestamp != null}');
      var added = 0;
      for (final file in entries) {
        if (!files.containsKey(file.id)) added++;
        files[file.id] = file;
      }
      if (entries.length < 10) {
        return files.values.toList()..sort((a, b) => b.id.compareTo(a.id));
      }
      if (added == 0) {
        throw const FormatException(
            'D3200 repeated a recording-list page'); // i18n-ignore: Internal diagnostic; the import page shows localized errors.
      }
    }
    throw const FormatException(
        'D3200 recording-list page limit exceeded'); // i18n-ignore: Internal diagnostic; the import page shows localized errors.
  }

  Future<SoundcoreDownload> download(SoundcoreRecording recording,
      {void Function(int bytes)? onProgress, SoundcoreFileTransport? transport}) async {
    _beginOperation(wifiTransfer: transport != null);
    _downloadingOverBle = transport == null;
    StreamSubscription<List<int>>? wifiSubscription;
    Directory? temporary;
    RandomAccessFile? output;
    var handedOff = false;
    try {
      transferStep = SoundcoreTransferStep.checkingRecorder;
      _trace('download transport=${transport == null ? "ble" : "wifi"} checking recorder');
      if (!recording.hasValidTimestamp(DateTime.now())) {
        throw const FormatException(
            'D3200 recording timestamp is invalid'); // i18n-ignore: Internal diagnostic; the import page shows localized errors.
      }
      final current = await readInfo();
      if (_bluetoothInterrupted) throw const SoundcoreBluetoothInterrupted();
      if (current.recording == true || _recordStatus == 1 || _recordStatus == 2) {
        throw StateError('Finish recording on the device before importing');
      }
      if (!_crypto.hasSession) {
        final response = await _request(0x2e, 0x01, _crypto.publicKey);
        _crypto.completeHandshake(response.payload);
      }
      if (_bluetoothInterrupted) throw const SoundcoreBluetoothInterrupted();
      temporary = await Directory.systemTemp.createTemp('memorion-soundcore-'); // i18n-ignore: Private temporary path.
      if (_bluetoothInterrupted) throw const SoundcoreBluetoothInterrupted();
      if (_closed) throw StateError('D3200 session is closed; reconnect the device');
      final file = File('${temporary.path}/audio.ogg');
      output = file.openSync(mode: FileMode.write);
      final writer = SoundcoreOggWriter(output.writeFromSync);
      final transfer = _Transfer(recording.id, onProgress, writer);
      _transfer = transfer;
      transferStep = SoundcoreTransferStep.requestingFile;
      _trace('download requesting file');
      final payload = Uint8List(9);
      ByteData.sublistView(payload).setUint32(4, recording.id, Endian.little);
      _armIdleTimer();
      // Attach error handling before writing: notifications can arrive during
      // send(), and a disconnect must never produce an unhandled future.
      final result = transfer.done.future;
      if (transport != null) {
        final wifiParser = SoundcorePacketBuffer();
        // i18n-ignore: Transport diagnostic; the recording page supplies localized errors.
        wifiSubscription = transport.notifications.listen((bytes) => _receive(bytes, parser: wifiParser),
            onError: _fail, onDone: () => _fail(SoundcoreWifiDisconnected()));
      }
      unawaited((transport?.requestFile(recording.id) ?? send(soundcoreCommand(0x1a, 0x07, payload)))
          .catchError((Object error) {
        _fail(error);
      }));
      await result;
      transferStep = SoundcoreTransferStep.finishing;
      writer.finish();
      output.flushSync();
      output.closeSync();
      output = null;
      _trace('download complete bytes=${transfer.sliceCount * 160}');
      await transport?.acknowledgeFile();
      handedOff = true;
      return SoundcoreDownload.temporaryFile(file, Duration(milliseconds: transfer.sliceCount * 20));
    } catch (error) {
      // i18n-ignore: Sanitized technical diagnostic; localized separately by the page.
      _trace('download failed step=${transferStep?.name} ${soundcoreWifiErrorCode(error)}');
      // A late completion from a failed transfer has no request ID. Require a
      // fresh connection, so it cannot accidentally complete the next file.
      // A duration rejection arrives only after draining a verified completion.
      if (error is! OfflineRecordingTooLong) close();
      if (_bluetoothInterrupted) throw const SoundcoreBluetoothInterrupted();
      rethrow;
    } finally {
      output?.closeSync();
      if (!handedOff && temporary != null) await temporary.delete(recursive: true);
      await wifiSubscription?.cancel();
      _idleTimer?.cancel();
      final transfer = _transfer;
      if (transfer != null) {
        // i18n-ignore: Sanitized transfer diagnostics, not product copy.
        _trace('transfer metrics transport=${transport == null ? "ble" : "wifi"} ${transfer.metrics}');
      }
      _transfer = null;
      _crypto.clearFile();
      _busy = false;
      _downloadingOverBle = false;
    }
  }

  void _beginOperation({bool wifiTransfer = false}) {
    if (_closed) throw StateError('D3200 session is closed; reconnect the device');
    if (_busy) throw StateError('D3200 transfer is already in progress');
    if ((_wifiActive || _wifiOnly) && !wifiTransfer) throw StateError('D3200 Wi-Fi batch owns the transfer');
    _busy = true;
  }

  Future<SoundcorePacket> _request(int type, int id, [List<int> payload = const [], Duration? timeout]) async {
    if (_closed) throw StateError('D3200 session is closed; reconnect the device');
    final key = type << 8 | id;
    final existing = _pending[key];
    if (existing != null) return existing.future;
    final completer = Completer<SoundcorePacket>();
    _pending[key] = completer;
    final timer = Timer(timeout ?? commandTimeout, () {
      _trace('timeout ${type.toRadixString(16)}/${id.toRadixString(16)}');
      if (!completer.isCompleted) completer.completeError(TimeoutException('D3200 command timed out'));
    });
    try {
      _trace('request ${type.toRadixString(16)}/${id.toRadixString(16)}');
      unawaited(send(soundcoreCommand(type, id, payload)).catchError((Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      }));
      return await completer.future;
    } finally {
      timer.cancel();
      if (identical(_pending[key], completer)) _pending.remove(key);
    }
  }

  void _receive(List<int> bytes, {SoundcorePacketBuffer? parser}) {
    if (_closed) return;
    try {
      for (final packet in (parser ?? _parser).add(bytes)) {
        // No raw payloads: diagnostics must not contain audio, keys, serials or file IDs.
        if ((packet.type == 1 && packet.id == 1) || packet.id == 0x0e || (packet.type == 0x1a && packet.id == 5)) {
          _trace('reply ${packet.type.toRadixString(16)}/${packet.id.toRadixString(16)} '
              'bytes=${packet.payload.length} status=${packet.status}');
        }
        if (packet.type == 1 && packet.id == 1) {
          _publishInfo(SoundcoreInfo.parse(packet.payload));
        } else if (packet.type == 1 && packet.id == 3 && packet.payload.isNotEmpty) {
          _publishInfo(info?.copyWith(
              battery: soundcoreBattery(packet.payload[0]),
              caseBattery: packet.payload.length > 1 ? soundcoreBattery(packet.payload[1]) : null));
          _battery.add([soundcoreBattery(packet.payload[0])]);
        } else if (packet.type == 1 && packet.id == 4 && packet.payload.isNotEmpty) {
          _publishInfo(info?.copyWith(
              charging: packet.payload[0] == 1,
              caseCharging: packet.payload.length > 1 ? packet.payload[1] == 1 : null));
          _charging.add(packet.payload[0] == 1 ? 1 : 0);
        } else if (packet.type == 0x18 && packet.id == 0x82 && packet.payload.isNotEmpty) {
          _recordStatus = packet.payload[0];
          _recordStatusEvents.add(_recordStatus!);
        }
        final pending = _pending[packet.type << 8 | packet.id];
        if (pending != null && !pending.isCompleted) pending.complete(packet);
        final transfer = _transfer;
        if (transfer == null || transfer.done.isCompleted || (packet.type != 0x1a && packet.type != 0x1b)) continue;
        if (packet.id == 7) {
          _trace('file header bytes=${packet.payload.length} status=${packet.status}'
              '${packet.payload.length >= 87 ? " result=${packet.payload[86]}" : ""}');
          if (transfer.hasHeader) throw const SoundcoreProtocolException(SoundcoreProtocolIssue.duplicateHeader);
          _crypto.prepareFile(packet.payload, transfer.id);
          transfer.hasHeader = true;
          transferStep = SoundcoreTransferStep.receiving;
          _armIdleTimer();
        } else if (packet.id == 8 || packet.id == 0x12) {
          if (!transfer.hasHeader) throw const SoundcoreProtocolException(SoundcoreProtocolIssue.audioBeforeHeader);
          if (transfer.sliceCount == 0) _trace('first audio slices received');
          try {
            transfer.addSlices(packet.payload, _crypto);
          } on SoundcoreProtocolException {
            _trace('audio frame type=${packet.type} id=${packet.id} status=${packet.status} '
                'payloadBytes=${packet.payload.length} acceptedSlices=${transfer.sliceCount}');
            rethrow;
          }
          _armIdleTimer();
        } else if (packet.id == 0x0a) {
          if (!transfer.hasHeader || transfer.sliceCount == 0) {
            throw const SoundcoreProtocolException(SoundcoreProtocolIssue.incompleteFile);
          }
          _idleTimer?.cancel();
          if (!transfer.done.isCompleted) {
            if (transfer.durationExceeded) {
              transfer.done.completeError(OfflineRecordingTooLong(Duration(milliseconds: transfer.sliceCount * 20)));
            } else {
              transfer.done.complete();
            }
          }
        }
      }
    } catch (error) {
      _fail(error);
    }
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(transferIdleTimeout, () => _fail(TimeoutException('D3200 file transfer stalled')));
  }

  void _fail(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    final transfer = _transfer;
    if (transfer != null && !transfer.done.isCompleted) transfer.done.completeError(error);
  }

  void close() {
    if (_closed) return;
    _trace('session closed busy=$_busy step=${transferStep?.name}');
    _closed = true;
    _fail(StateError(
        'D3200 disconnected; reconnect and retry')); // i18n-ignore: Internal diagnostic; the import page shows localized errors.
    _idleTimer?.cancel();
    _subscription?.cancel();
    _battery.close();
    _charging.close();
    _infoEvents.close();
    _recordStatusEvents.close();
    _parser.clear();
    _crypto.clear();
  }
}

class _Transfer {
  final int id;
  final void Function(int)? onProgress;
  final done = Completer<void>();
  final SoundcoreOggWriter writer;
  static final maxSlices = maxOfflineRecordingDuration.inMilliseconds ~/ 20;
  int sliceCount = 0;
  bool get durationExceeded => sliceCount > maxSlices;
  bool hasHeader = false;
  int? nextSequence;
  final _audioClock = Stopwatch();
  int _lastAudioUs = 0;
  int _audioFrames = 0;
  int _maxPayloadBytes = 0;

  _Transfer(this.id, this.onProgress, this.writer);

  // Measure the receive window only: idle time after a stall, Ogg wrapping and
  // uploading must not make the radio appear slower. Count protocol frames,
  // not platform notifications, which can be fragmented or aggregated.
  String get metrics {
    final audioBytes = sliceCount * 160;
    final rate =
        _audioFrames > 1 && _lastAudioUs > 0 ? (audioBytes * 1000000 / _lastAudioUs / 1024).toStringAsFixed(1) : 'n/a';
    return 'audioBytes=$audioBytes receiveMs=${_lastAudioUs ~/ 1000} audioKiBps=$rate '
        'frames=$_audioFrames maxPayloadBytes=$_maxPayloadBytes';
  }

  void addSlices(Uint8List payload, SoundcoreCrypto crypto) {
    if (!_audioClock.isRunning) _audioClock.start();
    // Most firmware sends 166-byte units; the final padding byte can be omitted.
    if (payload.isEmpty || (payload.length % 166 != 0 && payload.length % 166 != 165)) {
      throw SoundcoreProtocolException(SoundcoreProtocolIssue.sliceLength, actual: payload.length);
    }
    final data = ByteData.sublistView(payload);
    for (var offset = 0; offset + 165 <= payload.length; offset += 166) {
      final sequence = data.getUint32(offset, Endian.little);
      if (nextSequence == null && sequence != 0 && sequence != 1) {
        throw SoundcoreProtocolException(SoundcoreProtocolIssue.missingBeginning, actual: sequence);
      }
      if (nextSequence != null && sequence != nextSequence) {
        throw SoundcoreProtocolException(
            sequence < nextSequence! ? SoundcoreProtocolIssue.sequenceDuplicate : SoundcoreProtocolIssue.sequenceGap,
            expected: nextSequence,
            actual: sequence,
            payloadBytes: payload.length);
      }
      sliceCount++;
      if (durationExceeded) {
        // Drain and validate through the completion frame so this one file
        // cannot poison the next request in a Wi-Fi batch. Bound memory and
        // never wrap/upload the retained beginning as a complete recording.
        // The temporary prefix is discarded when completion reports the limit.
      } else {
        writer.add(crypto.decryptChunk(sequence, payload.sublist(offset + 5, offset + 165)));
      }
      nextSequence = sequence + 1;
    }
    _lastAudioUs = _audioClock.elapsedMicroseconds;
    _audioFrames++;
    if (payload.length > _maxPayloadBytes) _maxPayloadBytes = payload.length;
    onProgress?.call(sliceCount * 160);
  }
}
