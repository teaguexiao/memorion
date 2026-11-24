// A1 interoperability. See THIRD_PARTY_LICENSE.txt for the MIT protocol reference.
import 'dart:convert';
import 'dart:typed_data';

import '../offline_recordings/models.dart';

const a1ServiceUuid = '0000fe3c-0000-1000-8000-00805f9b34fb';
const a1WriteUuid = '0000fe1c-0000-1000-8000-00805f9b34fb';
const a1NotifyUuid = '0000fe1b-0000-1000-8000-00805f9b34fb';

enum A1Issue {
  identityRequired,
  authentication,
  disconnected,
  timeout,
  protocol,
  encryptedAudio,
  unsupportedAudio,
  busy,
  incompleteList,
  retention
}

class A1Exception implements Exception {
  final A1Issue issue;
  final int? code;
  const A1Exception(this.issue, {this.code});
  @override
  String toString() => 'A1 ${issue.name}${code == null ? '' : ' ($code)'}';
}

class A1Frame {
  final int kind, command, sequence;
  final Uint8List payload;
  const A1Frame(this.kind, this.command, this.sequence, this.payload);
  Map<String, dynamic> json() {
    try {
      return jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
    } catch (_) {
      throw const A1Exception(A1Issue.protocol);
    }
  }
}

Uint8List a1Encode(int command, int sequence, Object body, {int kind = 0x13}) {
  final payload = body is Uint8List ? body : utf8.encode(jsonEncode(body));
  if (payload.length > 39992) throw const A1Exception(A1Issue.protocol);
  final bytes = Uint8List(8 + payload.length);
  final header = ByteData.sublistView(bytes);
  bytes[0] = kind;
  header.setUint16(1, command);
  bytes[3] = sequence & 255;
  header.setUint32(4, payload.length);
  bytes.setAll(8, payload);
  return bytes;
}

class A1Decoder {
  final List<int> _buffer = [];
  List<A1Frame> add(List<int> fragment) {
    _buffer.addAll(fragment);
    final frames = <A1Frame>[];
    while (_buffer.length >= 8) {
      if (!{0x13, 0x14, 0x31}.contains(_buffer[0])) {
        _buffer.removeAt(0);
        continue;
      }
      final size = (_buffer[4] << 24) | (_buffer[5] << 16) | (_buffer[6] << 8) | _buffer[7];
      if (size > 60000) {
        _buffer.clear();
        throw const A1Exception(A1Issue.protocol);
      }
      if (_buffer.length < size + 8) break;
      frames.add(A1Frame(
          _buffer[0], (_buffer[1] << 8) | _buffer[2], _buffer[3], Uint8List.fromList(_buffer.sublist(8, 8 + size))));
      _buffer.removeRange(0, size + 8);
    }
    return frames;
  }
}

void a1Accepted(Map<String, dynamic> body, {bool authentication = false}) {
  if (body['code'] != 200 && body['code'] != 202) {
    throw A1Exception(authentication ? A1Issue.authentication : A1Issue.protocol,
        code: body['code'] is int ? body['code'] as int : null);
  }
}

class A1Info {
  final int battery, totalStorageMb, freeStorageMb;
  final String firmware, audioStatus;
  const A1Info(
      {required this.battery,
      required this.totalStorageMb,
      required this.freeStorageMb,
      required this.firmware,
      required this.audioStatus});
  bool get recording => {'recording', 'paused', 'streaming', 'rec_streaming'}.contains(audioStatus);
  factory A1Info.parse(Map<String, dynamic> body) {
    a1Accepted(body);
    final data = body['body'] is Map<String, dynamic> ? body['body'] as Map<String, dynamic> : body;
    int number(String key) => int.tryParse('${data[key]}') ?? -1;
    final battery = number('battery_percent');
    return A1Info(
        battery: battery >= 0 && battery <= 100 ? battery : -1,
        totalStorageMb: number('storage_total_size'),
        freeStorageMb: number('storage_remain'),
        firmware: data['version'] is String ? data['version'] as String : '',
        audioStatus: data['audio_status'] is String ? data['audio_status'] as String : 'unknown');
  }
}

class A1RecordingPage {
  final List<OfflineRecording> recordings;
  final bool truncated;
  final bool hasTrailer;
  const A1RecordingPage(this.recordings, this.truncated, this.hasTrailer);
  factory A1RecordingPage.parse(Uint8List bytes) {
    if (bytes.length < 4) throw const A1Exception(A1Issue.protocol);
    final b = ByteData.sublistView(bytes);
    a1Accepted({'code': b.getUint16(0)});
    final count = b.getUint16(2);
    final end = 4 + count * 8;
    if (end > bytes.length) throw const A1Exception(A1Issue.protocol);
    final tail = bytes.sublist(end);
    final trailer =
        tail.length == 8 && tail.take(3).every((x) => x == 0) && tail[3] <= 1 && tail.skip(4).every((x) => x == 0x5a);
    if (!trailer && tail.any((x) => x != 0 && x != 0x5a)) throw const A1Exception(A1Issue.protocol);
    final result = <OfflineRecording>[];
    for (var offset = 4; offset < end; offset += 8) {
      final fid = b.getUint32(offset + 2);
      // A1 IDs are Unix seconds. The 16-bit duration is only a list hint.
      result.add(OfflineRecording(fid, 0, b.getUint16(offset + 6) * 1000));
    }
    return A1RecordingPage(result, trailer && tail[3] == 1, trailer);
  }
}

/// CRC-32/BZIP2 used by the published compatibility implementation.
int a1Crc32(List<int> bytes) => _a1Checksum(bytes, 0x04c11db7);

/// Observed on the tested stock V1.6.88 device, for both ordinary recording
/// blocks and raw reads. This nonstandard polynomial is not CRC-32/BZIP2.
int a1StockBlockChecksum(List<int> bytes) => _a1Checksum(bytes, 0x100);

int _a1Checksum(List<int> bytes, int polynomial) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc = ((crc << 1) ^ (crc & 0x80000000 != 0 ? polynomial : 0)) & 0xffffffff;
    }
  }
  return crc ^ 0xffffffff;
}

class A1FileBlock {
  final int fid, number;
  final Uint8List data;
  const A1FileBlock(this.fid, this.number, this.data);
  factory A1FileBlock.parse(Uint8List payload) {
    if (payload.length < 16) throw const A1Exception(A1Issue.protocol);
    final b = ByteData.sublistView(payload);
    final size = b.getUint32(12);
    // Stock V1.6.88 sends 48000-byte ordinary-recording blocks (0x0115).
    // The 8000-byte limit belongs to the separate raw-file interface (0x014B).
    if (size == 0 || size > 48000 || size + 16 > payload.length) throw const A1Exception(A1Issue.protocol);
    final data = Uint8List.sublistView(payload, 16, size + 16);
    final tail = payload.length - size - 16;
    if (tail != 0) {
      if (tail != 8) throw const A1Exception(A1Issue.protocol);
      final expected = b.getUint32(size + 20);
      if (expected != a1StockBlockChecksum(data) && expected != a1Crc32(data)) {
        throw const A1Exception(A1Issue.protocol);
      }
    }
    return A1FileBlock(b.getUint32(2), b.getUint32(8), data);
  }
}
