import 'dart:convert';
import 'dart:typed_data';

import 'protocol.dart';

// Independent implementation of the public wire-format research cited in
// docs/hardware/plaud-note-wifi-integration-research-20261102.md.
const plaudWifiMaxPduBytes = 1024 * 1024;

/// Decrypted Wi-Fi PDU. Transport authentication must precede decoding.
class PlaudWifiPacket {
  static const _types = {0, 1, 2, 3, 4, 11, 12, 13, 15};
  final int type;
  final Map<String, dynamic> fields;
  final Uint8List tail;

  PlaudWifiPacket(this.type, this.fields, [Uint8List? tail]) : tail = tail ?? Uint8List(0);

  factory PlaudWifiPacket.decode(Uint8List bytes) {
    try {
      if (bytes.length < 8 || bytes.length > plaudWifiMaxPduBytes) throw const FormatException();
      final data = ByteData.sublistView(bytes);
      final size = bytes[0] | bytes[1] << 8 | bytes[2] << 16;
      final type = data.getInt16(4, Endian.little), jsonSize = data.getInt16(6, Endian.little);
      if (size != bytes.length ||
          (bytes[3] != 1 && bytes[3] != 2) ||
          !_types.contains(type) ||
          jsonSize < 2 ||
          8 + jsonSize > size) {
        throw const FormatException();
      }
      final fields = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 8, 8 + jsonSize)));
      if (fields is! Map<String, dynamic>) throw const FormatException();
      return PlaudWifiPacket(type, fields, Uint8List.sublistView(bytes, 8 + jsonSize));
    } catch (_) {
      throw const PlaudException(PlaudIssue.protocol);
    }
  }

  Uint8List encode() {
    if (!_types.contains(type)) throw const PlaudException(PlaudIssue.protocol);
    final json = utf8.encode(jsonEncode(fields));
    final size = 8 + json.length + tail.length;
    if (json.length > 32767 || size > plaudWifiMaxPduBytes) throw const PlaudException(PlaudIssue.protocol);
    final bytes = Uint8List(size)
      ..[0] = size & 255
      ..[1] = (size >> 8) & 255
      ..[2] = size >> 16
      ..[3] = 1
      ..setAll(8, json)
      ..setAll(8 + json.length, tail);
    ByteData.sublistView(bytes)
      ..setInt16(4, type, Endian.little)
      ..setInt16(6, json.length, Endian.little);
    return bytes;
  }

  int number(String name, {int min = 0, int max = 0xffffffff}) {
    final value = fields[name];
    if (value is! int || value < min || value > max) throw const PlaudException(PlaudIssue.protocol);
    return value;
  }

  void requireType(int expected, {bool withTail = false}) {
    if (type != expected || (!withTail && tail.isNotEmpty)) throw const PlaudException(PlaudIssue.protocol);
  }

  /// Call only after authentication with the original BLE session cipher.
  /// Firmware 2.2.8 sends an opaque token without the emulator's serial field.
  void requireHello(String serial) {
    requireType(2);
    final token = fields['token'];
    if (number('pVer') != 20 ||
        (fields.containsKey('sn') && fields['sn'] != serial) ||
        (token != null &&
            (token is! String || token.length != 32 || token.codeUnits.any((c) => c < 0x21 || c > 0x7e))) ||
        (!fields.containsKey('sn') && token == null)) {
      throw const PlaudException(PlaudIssue.authentication);
    }
  }

  @override
  String toString() => 'PlaudWifiPacket(type=$type, bytes=${tail.length})';
}

class PlaudWifiRecording extends PlaudRecording {
  final int scene;
  const PlaudWifiRecording(super.id, super.byteSize, this.scene);
}

(int, int, List<PlaudWifiRecording>) plaudWifiListPage(PlaudWifiPacket packet) {
  packet.requireType(11, withTail: true);
  if (packet.number('status') != 0 || packet.number('uid') != 0 || packet.tail.length % 10 != 0) {
    throw const PlaudException(PlaudIssue.protocol);
  }
  final count = packet.number('count', max: 10000), offset = packet.number('offset', max: 10000);
  final data = ByteData.sublistView(packet.tail);
  final entries = <PlaudWifiRecording>[];
  for (var at = 0; at < packet.tail.length; at += 10) {
    final id = data.getUint32(at, Endian.little);
    final size = data.getUint32(at + 4, Endian.little);
    if (id == 0 || size <= 512 || size > plaudMaxFileBytes) throw const PlaudException(PlaudIssue.protocol);
    entries.add(PlaudWifiRecording(id, size, data.getUint16(at + 8, Endian.little)));
  }
  if (offset + entries.length > count || (entries.isEmpty && count != 0)) {
    throw const PlaudException(PlaudIssue.protocol);
  }
  return (count, offset, entries);
}

/// Validates a whole-file transfer before the caller promotes its partial file.
class PlaudWifiDownload {
  final PlaudRecording recording;
  int received = 0;
  bool _accepted = false, finished = false;

  PlaudWifiDownload(this.recording) {
    if (recording.id <= 0 ||
        recording.id > 0xffffffff ||
        recording.byteSize <= 512 ||
        recording.byteSize > plaudMaxFileBytes) {
      throw const PlaudException(PlaudIssue.protocol);
    }
  }

  void accept(PlaudWifiPacket packet) {
    packet.requireType(12);
    if (_accepted ||
        packet.number('status') != 0 ||
        (packet.fields.containsKey('total') && packet.number('total') != recording.byteSize) ||
        (packet.fields.containsKey('session') && packet.number('session') != recording.id)) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    if (!packet.fields.containsKey('total')) {
      if (packet.number('session') != recording.id) throw const PlaudException(PlaudIssue.protocol);
      packet.number('crc'); // Algorithm unverified; AEAD and directory size remain mandatory.
    }
    _accepted = true;
  }

  Uint8List add(PlaudWifiPacket packet) {
    packet.requireType(13, withTail: true);
    final last = packet.number('last', max: 1);
    final end = received + packet.tail.length;
    if (!_accepted ||
        finished ||
        packet.number('session') != recording.id ||
        packet.number('offset') != received ||
        packet.number('length') != packet.tail.length ||
        end > recording.byteSize ||
        (packet.tail.isEmpty && last == 0) ||
        (last == 1 && end != recording.byteSize)) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    received = end;
    finished = last == 1;
    return packet.tail;
  }
}
