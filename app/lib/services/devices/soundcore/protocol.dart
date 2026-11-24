// D3200 interoperability implementation. See THIRD_PARTY_LICENSE.txt.
import 'dart:convert';
import 'dart:typed_data';

import 'protocol_error.dart';
import '../offline_recordings/models.dart';

const soundcoreServiceUuid = '020cf5da-0000-1000-8000-00805f9b34fb';
const soundcoreWriteUuid = '00007777-0000-1000-8000-00805f9b34fb';
const soundcoreNotifyUuid = '00008888-0000-1000-8000-00805f9b34fb';

Uint8List soundcoreCommand(int type, int id, [List<int> payload = const []]) {
  final bytes = Uint8List(10 + payload.length);
  if (bytes.length > 65535) throw ArgumentError('D3200 command too large');
  bytes.setAll(0, [0x08, 0xee, 0, 0, 0, type, id]);
  ByteData.sublistView(bytes).setUint16(7, bytes.length, Endian.little);
  bytes.setAll(9, payload);
  bytes.last = soundcoreChecksum(bytes.take(bytes.length - 1));
  return bytes;
}

int soundcoreChecksum(Iterable<int> bytes) => bytes.fold(0, (sum, byte) => (sum + byte) & 0xff);

class SoundcorePacket {
  final int type;
  final int id;
  final int status;
  final Uint8List payload;

  SoundcorePacket(this.type, this.id, this.payload, {this.status = 0});
}

/// Notifications may contain fragments or multiple frames. Preserve partial
/// headers and reject corrupt frames rather than passing them to the decryptor.
class SoundcorePacketBuffer {
  final List<int> _buffer = [];

  List<SoundcorePacket> add(List<int> fragment) {
    _buffer.addAll(fragment);
    final packets = <SoundcorePacket>[];
    while (_buffer.length >= 4) {
      if (_buffer[0] != 0x09 || _buffer[1] != 0xff || _buffer[2] != 0 || _buffer[3] != 0) {
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < 10) break;
      final length = _buffer[7] | (_buffer[8] << 8);
      if (length < 10) {
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < length) break;
      final bytes = Uint8List.fromList(_buffer.take(length).toList());
      _buffer.removeRange(0, length);
      if (soundcoreChecksum(bytes.take(length - 1)) != bytes.last) {
        throw SoundcoreProtocolException(SoundcoreProtocolIssue.checksum,
            expected: soundcoreChecksum(bytes.take(length - 1)),
            actual: bytes.last,
            packetType: bytes[5],
            packetId: bytes[6],
            payloadBytes: length - 10);
      }
      packets.add(SoundcorePacket(bytes[5], bytes[6], Uint8List.sublistView(bytes, 9, length - 1), status: bytes[4]));
    }
    return packets;
  }

  void clear() => _buffer.clear();
}

int soundcoreBattery(int value) {
  final bucket = value & 0x7f;
  return bucket <= 9 ? (bucket + 1) * 10 : (bucket <= 100 ? bucket : -1);
}

class SoundcoreInfo {
  final int battery;
  final bool charging;
  final String firmware;
  final String serial;
  final int totalStorageKb;
  final int freeStorageKb;
  final int? caseBattery;
  final bool? caseCharging;
  final bool? recording;

  const SoundcoreInfo({
    required this.battery,
    required this.charging,
    required this.firmware,
    required this.serial,
    required this.totalStorageKb,
    required this.freeStorageKb,
    this.caseBattery,
    this.caseCharging,
    this.recording,
  });

  factory SoundcoreInfo.parse(Uint8List payload) {
    if (payload.length < 32) {
      throw const FormatException(
          'Incomplete D3200 device info'); // i18n-ignore: Internal diagnostic; the import page shows localized errors.
    }
    final data = ByteData.sublistView(payload);
    String text(int offset, int length) => ascii
        .decode(payload.sublist(offset, offset + length).takeWhile((b) => b != 0).toList(), allowInvalid: true)
        .trim();
    return SoundcoreInfo(
      battery: soundcoreBattery(payload[1]),
      charging: payload[2] == 1,
      firmware: text(3, 5),
      serial: text(8, 16).toLowerCase(),
      totalStorageKb: data.getUint32(24, Endian.little),
      freeStorageKb: data.getUint32(28, Endian.little),
      caseBattery: payload.length > 38 ? soundcoreBattery(payload[38]) : null,
      caseCharging: payload.length > 32 ? payload[32] == 1 : null,
      recording: payload.length > 50 ? payload[50] == 1 : null,
    );
  }

  SoundcoreInfo copyWith({int? battery, bool? charging, int? caseBattery, bool? caseCharging, bool? recording}) =>
      SoundcoreInfo(
        battery: battery ?? this.battery,
        charging: charging ?? this.charging,
        firmware: firmware,
        serial: serial,
        totalStorageKb: totalStorageKb,
        freeStorageKb: freeStorageKb,
        caseBattery: caseBattery ?? this.caseBattery,
        caseCharging: caseCharging ?? this.caseCharging,
        recording: recording ?? this.recording,
      );
}

class SoundcoreRecording extends OfflineRecording {
  const SoundcoreRecording(super.id, super.endTime, super.reportedSize);
  static List<SoundcoreRecording> parseList(Uint8List payload, {bool withEndTime = true}) =>
      SoundcoreRecordingList.parse(payload, withEndTime: withEndTime).files;
}

/// Both list commands can append an 8-byte current-transfer timestamp/duration
/// after the declared entries (D3200 protocol sections 6.2/6.3).
class SoundcoreRecordingList {
  final List<SoundcoreRecording> files;
  final int? currentTransferTimestamp;
  final int? currentTransferDuration;
  const SoundcoreRecordingList(this.files, this.currentTransferTimestamp, this.currentTransferDuration);

  factory SoundcoreRecordingList.parse(Uint8List payload, {bool withEndTime = true}) {
    if (payload.length < 2) {
      throw const FormatException(
          'Incomplete D3200 recording list'); // i18n-ignore: Internal diagnostic; the import page shows localized errors.
    }
    final data = ByteData.sublistView(payload);
    final count = data.getUint16(0, Endian.little);
    final entrySize = withEndTime ? 12 : 8;
    final entriesEnd = 2 + count * entrySize;
    if (payload.length != entriesEnd && payload.length != entriesEnd + 8) {
      throw const FormatException('Truncated or unsupported D3200 file list');
    }
    final files = List.generate(count, (i) {
      final offset = 2 + i * entrySize;
      return SoundcoreRecording(
          data.getUint32(offset, Endian.little),
          withEndTime ? data.getUint32(offset + 4, Endian.little) : 0,
          data.getUint32(offset + entrySize - 4, Endian.little));
    });
    final hasTrailer = payload.length == entriesEnd + 8;
    return SoundcoreRecordingList(files, hasTrailer ? data.getUint32(entriesEnd, Endian.little) : null,
        hasTrailer ? data.getInt32(entriesEnd + 4, Endian.little) : null);
  }
}
