import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

Uint8List response(int type, int id, [List<int> payload = const []]) {
  final frame = Uint8List.fromList([9, 255, 0, 0, 0, type, id, 0, 0, ...payload, 0]);
  ByteData.sublistView(frame).setUint16(7, frame.length, Endian.little);
  frame.last = frame.take(frame.length - 1).fold(0, (sum, b) => (sum + b) & 255);
  return frame;
}

Uint8List deviceInfo({bool recording = false, bool charging = false, bool caseCharging = true}) {
  final bytes = Uint8List(51);
  bytes.setAll(0, [1, 7, charging ? 1 : 0]);
  bytes.setAll(3, ascii.encode('04.92'));
  bytes.setAll(8, ascii.encode('D3200-TEST-000001'));
  ByteData.sublistView(bytes).setUint32(24, 8000000, Endian.little);
  ByteData.sublistView(bytes).setUint32(28, 7000000, Endian.little);
  bytes[32] = caseCharging ? 1 : 0;
  bytes[38] = 9;
  bytes[50] = recording ? 1 : 0;
  return bytes;
}

Uint8List fileList(int id, {int count = 1, bool withEndTime = true, bool trailer = false, bool zeroSize = false}) {
  final entrySize = withEndTime ? 12 : 8;
  final bytes = Uint8List(2 + count * entrySize + (trailer ? 8 : 0));
  final view = ByteData.sublistView(bytes)..setUint16(0, count, Endian.little);
  for (var i = 0; i < count; i++) {
    final offset = 2 + i * entrySize;
    view.setUint32(offset, id + i, Endian.little);
    if (withEndTime) view.setUint32(offset + 4, id + i + 6, Endian.little);
    view.setUint32(offset + entrySize - 4, zeroSize ? 0 : 48000, Endian.little);
  }
  return bytes;
}

/// Synthetic peer with private scalar 1: its ECDH secret is the client's
/// public X coordinate. HKDF is independently expressed with package:crypto.
class FakeSoundcoreDevice {
  final inbound = StreamController<List<int>>(sync: true);
  final commands = <Uint8List>[];
  late Uint8List sessionKey;
  final fileKey = Uint8List.fromList(List.generate(32, (i) => i + 1));
  final nonce = Uint8List.fromList(List.generate(16, (i) => i + 16));
  final sessionNonce = Uint8List.fromList(List.generate(16, (i) => i + 32));
  bool recording = false;
  bool charging = false;
  bool caseCharging = true;
  bool bleDisconnected = false;
  bool missingSlice = false;
  bool corruptKey = false;
  bool wrongFile = false;
  bool disconnectDuringDownload = false;
  bool stall = false;
  bool repeatPage = false;
  bool fragmented = false;
  bool listTrailer = true;
  bool extendedListTimeout = false;
  bool listTimeout = false;
  bool malformedList = false;
  bool zeroSize = false;
  int fileCount = 1;
  final durations = <int, int>{};
  Future<void>? downloadGate;
  final int fileId;

  FakeSoundcoreDevice(this.fileId);

  void emit(Uint8List bytes) {
    if (fragmented) {
      for (var i = 0; i < bytes.length; i += 7) {
        inbound.add(bytes.sublist(i, (i + 7).clamp(0, bytes.length)));
      }
    } else {
      inbound.add(bytes);
    }
  }

  Uint8List handshake(List<int> clientPublicKey) {
    final shared = clientPublicKey.sublist(1, 33);
    final prk = Hmac(sha256, [1, 2, 3]).convert(shared).bytes;
    sessionKey = Uint8List.fromList(Hmac(sha256, prk).convert([1, 2, 3, 1]).bytes);
    final generator = ECDomainParameters('prime256v1').G.getEncoded(false);
    return Uint8List.fromList([...generator, ...shared]);
  }

  Uint8List crypt(List<int> data, Uint8List key, Uint8List counter) =>
      (SICStreamCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(key), counter)))
          .process(Uint8List.fromList(data));

  Uint8List fileHeader(int id) {
    final bytes = Uint8List(87);
    final view = ByteData.sublistView(bytes);
    view.setUint32(0, wrongFile ? id + 1 : id, Endian.little);
    view.setUint32(4, 48000, Endian.little);
    bytes.setAll(8, nonce);
    final material = [...ascii.encode('soundcored3200'), ...fileKey];
    if (corruptKey) material[0] ^= 0xff;
    bytes.setAll(24, crypt(material, sessionKey, sessionNonce));
    bytes.setAll(70, sessionNonce);
    return bytes;
  }

  Uint8List slice(int seq) {
    final slot = Uint8List(160)..setAll(0, [0xf8, 0xff, 0xfe]); // valid Opus silence packet + padding
    final counter = Uint8List(16)..setAll(0, nonce.sublist(0, 12));
    ByteData.sublistView(counter).setUint32(12, seq * 10, Endian.big);
    final bytes = Uint8List(166);
    ByteData.sublistView(bytes).setUint32(0, seq, Endian.little);
    bytes.setAll(5, crypt(slot, fileKey, counter));
    return bytes;
  }

  Future<void> send(Uint8List bytes) async {
    if (bleDisconnected) throw StateError('Synthetic BLE disconnected');
    commands.add(bytes);
    if (bytes[5] == 0x1a && bytes[6] == 5) {
      final frame = response(0x1a, 5, [1, 43, 168, 192, 187, 1]);
      frame[4] = 1;
      frame.last = frame.take(frame.length - 1).fold(0, (a, b) => (a + b) & 255);
      emit(frame);
      return;
    }
    final type = bytes[5], id = bytes[6];
    if (type == 1 && id == 1) {
      emit(response(type, id, deviceInfo(recording: recording, charging: charging, caseCharging: caseCharging)));
    } else if ((type == 0x1b || type == 0x1a) && id == 0x0e) {
      if (listTimeout || (type == 0x1b && extendedListTimeout)) return;
      final page = bytes[9] | (bytes[10] << 8);
      var payload = fileList(fileId,
          count: repeatPage ? 10 : (page == 0 ? fileCount : 0),
          withEndTime: type == 0x1b,
          trailer: listTrailer,
          zeroSize: zeroSize);
      final entrySize = type == 0x1b ? 12 : 8;
      final view = ByteData.sublistView(payload);
      for (var i = 0; i < view.getUint16(0, Endian.little); i++) {
        final offset = 2 + i * entrySize;
        final id = view.getUint32(offset, Endian.little);
        final duration = durations[id];
        if (duration == null) continue;
        if (type == 0x1b) view.setUint32(offset + 4, id + duration ~/ 1000, Endian.little);
        view.setUint32(offset + entrySize - 4, duration, Endian.little);
      }
      if (malformedList) payload = payload.sublist(0, payload.length - 1);
      emit(response(type, id, payload));
    } else if (type == 0x2e && id == 1) {
      emit(response(type, id, handshake(bytes.sublist(9, bytes.length - 1))));
    } else if (type == 0x1a && id == 7) {
      if (disconnectDuringDownload) {
        unawaited(inbound.close());
        return;
      }
      final requestedFileId = ByteData.sublistView(bytes).getUint32(13, Endian.little);
      emit(response(type, id, fileHeader(requestedFileId)));
      if (stall) return;
      if (downloadGate != null) await downloadGate;
      for (var i = 0; i < 300; i++) {
        if (missingSlice && i == 5) continue;
        emit(response(0x1a, 8, slice(i)));
      }
      emit(response(0x1a, 0x0a));
    }
  }
}
