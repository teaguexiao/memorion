import 'dart:convert';
import 'dart:typed_data';

// Protocol layouts: roopen219/plaude-archiver (MIT). See THIRD_PARTY_LICENSE.txt.
const plaudService = '00001910-0000-1000-8000-00805f9b34fb';
const plaudWrite = '00002bb1-0000-1000-8000-00805f9b34fb';
const plaudNotify = '00002bb0-0000-1000-8000-00805f9b34fb';
const plaudMaxFileBytes = 8 * 3600 * 4000 + 512;

enum PlaudIssue { identityRequired, protocol, authentication, unsupportedAudio, disconnected, timeout, busy }

class PlaudException implements Exception {
  final PlaudIssue issue;
  final int? frameIndex;
  const PlaudException(this.issue, {this.frameIndex});
  @override
  String toString() => 'PlaudException(${issue.name})';
}

/// The original Note advertises its name and manufacturer data, without UUIDs.
/// A matching GATT service alone is not enough to identify this device family.
class PlaudAdvertisement {
  final String serial;
  final int protocol;
  const PlaudAdvertisement._(this.serial, this.protocol);

  static PlaudAdvertisement? parse(String name, Map<int, List<int>> manufacturer) {
    if (!name.toUpperCase().startsWith('PLAUD')) return null;
    for (final entry in manufacturer.entries) {
      if (!{0x59, 0x5d}.contains(entry.key)) continue;
      final bytes = entry.value;
      var offset = 0;
      final fields = <List<int>>[];
      for (final bounds in [(2, 2), (4, 4), (8, 10)]) {
        if (offset >= bytes.length) break;
        final length = bytes[offset++];
        if (length < bounds.$1 || length > bounds.$2 || offset + length > bytes.length) break;
        fields.add(bytes.sublist(offset, offset + length));
        offset += length;
      }
      if (fields.length != 3 || offset + 2 > bytes.length) continue;
      final serial = fields[2].map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
      if (fields[0][0] + (fields[0][1] << 8) != 888 || !serial.startsWith('888')) continue;
      return PlaudAdvertisement._(serial, bytes[offset] + (bytes[offset + 1] << 8));
    }
    return null;
  }

  bool get supported => protocol == 20;
  @override
  String toString() => 'PlaudAdvertisement(protocol=$protocol)';
}

Uint8List plaudCommand(int code, [List<int> body = const []]) {
  // 30 is a delete REQUEST although it is also the response to transfer stop.
  if (!{1, 3, 6, 9, 19, 26, 28, 29}.contains(code) || (code == 29 && body.isNotEmpty)) {
    throw const PlaudException(PlaudIssue.protocol);
  }
  return Uint8List.fromList([1, code & 255, code >> 8, ...body]);
}

int? plaudCommandId(List<int> packet) => packet.length >= 3 && packet[0] == 1 ? packet[1] + (packet[2] << 8) : null;

/// AP control only. Profile writes, reset and deletion are unavailable.
Uint8List plaudWifiCommand(int code, [List<int> body = const []]) {
  final open = code == 10 &&
      (body.length == 1 || body.length == 9) &&
      (body[0] == 0 || body[0] == 1) &&
      body.skip(1).every((b) => b >= 0x21 && b <= 0x7e);
  if (!open && !(code == 13 && body.isEmpty)) throw const PlaudException(PlaudIssue.protocol);
  return Uint8List.fromList([1, code, 0, ...body]);
}

/// A version is ['V', patch, minor, major], not an ASCII version string.
/// Confirmed against the original Note's official-app version 2.2.8.
String? plaudFirmwareVersion(List<int> bytes) {
  if (bytes.length != 4 || bytes[0] != 0x56 || bytes.any((b) => b < 0 || b > 255)) return null;
  return '${bytes[3]}.${bytes[2]}.${bytes[1]}';
}

Uint8List plaudHandshake(String token, {bool second = false}) {
  if (!RegExp(r'^[\x21-\x7e]{1,32}$').hasMatch(token)) throw const PlaudException(PlaudIssue.identityRequired);
  return plaudCommand(1, [2, 0, second ? 1 : 0, ...ascii.encode(token.padRight(32, '0'))]);
}

List<Uint8List> plaudUnlockParts(int code, List<int> bytes) {
  if (!{0xfe10, 0xfe12}.contains(code) || bytes.isEmpty || bytes.length > 1600) {
    throw const PlaudException(PlaudIssue.protocol);
  }
  final total = (bytes.length + 99) ~/ 100;
  return [
    for (var i = 0; i < total; i++)
      Uint8List.fromList(
          [code & 255, code >> 8, total, i, ...bytes.sublist(i * 100, ((i + 1) * 100).clamp(0, bytes.length))])
  ];
}

class PlaudSecretParts {
  int? _total;
  final _parts = <int, Uint8List>{};
  void add(Uint8List packet) {
    if (packet.length < 5 || packet.length > 244 || packet[0] != 0x12 || packet[1] != 0xfe) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    final total = packet[2], index = packet[3];
    if (total == 0 || total > 16 || index >= total || (_total != null && total != _total)) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    final part = Uint8List.sublistView(packet, 4);
    if (_parts.containsKey(index) && !_equal(part, _parts[index]!)) throw const PlaudException(PlaudIssue.protocol);
    _total = total;
    _parts[index] = Uint8List.fromList(part);
    if (_parts.values.fold(0, (s, p) => s + p.length) > 256) throw const PlaudException(PlaudIssue.protocol);
  }

  bool get complete => _total != null && _parts.length == _total;
  Uint8List ciphertext() {
    if (!complete) throw const PlaudException(PlaudIssue.protocol);
    final result = Uint8List.fromList([for (var i = 0; i < _total!; i++) ..._parts[i]!]);
    if (result.length != 256) throw const PlaudException(PlaudIssue.protocol);
    return result;
  }
}

bool _equal(List<int> a, List<int> b) =>
    a.length == b.length && List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);

class PlaudRecording {
  final int id, byteSize;
  const PlaudRecording(this.id, this.byteSize);
  @override
  String toString() => 'PlaudRecording(bytes=$byteSize)';
}

(int, int, List<PlaudRecording>) plaudListPage(Uint8List packet) {
  if (plaudCommandId(packet) != 26 || packet.length < 11 || (packet.length - 11) % 10 != 0) {
    throw const PlaudException(PlaudIssue.protocol);
  }
  final data = ByteData.sublistView(packet);
  final total = data.getUint16(7, Endian.little), index = data.getUint16(9, Endian.little);
  final entries = [
    for (var at = 11; at < packet.length; at += 10)
      PlaudRecording(data.getUint32(at, Endian.little), data.getUint32(at + 4, Endian.little))
  ];
  if (total > 10000 || index + entries.length > total) throw const PlaudException(PlaudIssue.protocol);
  return (total, index, entries);
}

(int, Uint8List) plaudFileData(Uint8List packet, int recordingId) {
  if (packet.length < 10 || packet[0] != 2) throw const PlaudException(PlaudIssue.protocol);
  final data = ByteData.sublistView(packet);
  if (data.getUint32(1, Endian.little) != recordingId || packet.length != 10 + packet[9]) {
    throw const PlaudException(PlaudIssue.protocol);
  }
  return (data.getUint32(5, Endian.little), Uint8List.sublistView(packet, 10));
}
