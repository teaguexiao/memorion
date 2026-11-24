import 'dart:convert';
import 'dart:typed_data';

import '../offline_recordings/models.dart';
import 'protocol.dart';

/// Fixed offsets are part of DTYJ, which is not a RIFF chunk stream.
class A1Audio {
  final int sampleRate, channels;
  final List<Uint8List> packets;
  const A1Audio(this.sampleRate, this.channels, this.packets);

  factory A1Audio.parse(Uint8List bytes) {
    if (bytes.length < 80) throw const A1Exception(A1Issue.unsupportedAudio);
    bool tag(int at, String text) => ascii.decode(bytes.sublist(at, at + text.length), allowInvalid: true) == text;
    if (!tag(0, 'BABA') ||
        !tag(8, 'DTYJ') ||
        !tag(12, 'ver ') ||
        !tag(20, 'fmt ') ||
        !tag(52, 'extr') ||
        !tag(68, 'data') ||
        !(tag(16, 'v1.6') || tag(16, 'v1.7'))) {
      throw const A1Exception(A1Issue.unsupportedAudio);
    }
    if (bytes[58] != 0) throw const A1Exception(A1Issue.encryptedAudio);
    final header = ByteData.sublistView(bytes);
    final rate = header.getUint32(36, Endian.little);
    final size = header.getUint16(44, Endian.little);
    final prefix = header.getUint16(46, Endian.little);
    final payload = header.getUint32(72, Endian.little);
    if (header.getUint32(4, Endian.little) + 8 != bytes.length ||
        payload + 80 != bytes.length ||
        !{16000, 24000, 32000, 48000}.contains(rate) ||
        bytes[42] != 1 ||
        !{0, 4}.contains(prefix) ||
        !{80, 160}.contains(size - prefix) ||
        payload == 0 ||
        payload % size != 0) {
      throw const A1Exception(A1Issue.unsupportedAudio);
    }
    final packets = <Uint8List>[];
    for (var offset = 80; offset < bytes.length; offset += size) {
      // Prefix is an opaque flag; trailing zero bytes belong to the Opus packet.
      packets.add(Uint8List.sublistView(bytes, offset + prefix, offset + size));
    }
    return A1Audio(rate, bytes[42], packets);
  }

  /// validatePacket must fully decode locally and return the sample count at
  /// 48 kHz. Framing alone cannot prove that payload bytes are valid Opus.
  Future<OfflineDownload> toOgg({required int Function(Uint8List) validatePacket}) async {
    final head = Uint8List(19)..setAll(0, ascii.encode('OpusHead'));
    head[8] = 1;
    head[9] = channels;
    ByteData.sublistView(head).setUint32(12, sampleRate, Endian.little);
    final vendor = ascii.encode('Memorion A1'); // i18n-ignore: Ogg metadata.
    final tags = Uint8List(16 + vendor.length)..setAll(0, ascii.encode('OpusTags'));
    ByteData.sublistView(tags).setUint32(8, vendor.length, Endian.little);
    tags.setAll(12, vendor);
    final out = BytesBuilder(copy: false)
      ..add(_page([head], 0, 0, 2))
      ..add(_page([tags], 1, 0, 0));
    var granule = 0;
    var sequence = 2;
    for (var start = 0; start < packets.length; start += 50) {
      final end = (start + 50).clamp(0, packets.length);
      for (final packet in packets.sublist(start, end)) {
        final samples = a1OpusSamples(packet);
        try {
          if (validatePacket(packet) != samples) throw const A1Exception(A1Issue.unsupportedAudio);
        } catch (_) {
          throw const A1Exception(A1Issue.unsupportedAudio);
        }
        granule += samples;
      }
      out.add(_page(packets.sublist(start, end), sequence++, granule, end == packets.length ? 4 : 0));
      if (start % 500 == 0) await Future<void>.delayed(Duration.zero);
    }
    return OfflineDownload(out.takeBytes(), Duration(microseconds: granule * 1000000 ~/ 48000));
  }
}

int a1OpusSamples(Uint8List packet) {
  if (packet.isEmpty) throw const A1Exception(A1Issue.unsupportedAudio);
  final config = packet[0] >> 3;
  final code = packet[0] & 3;
  final samples = config < 12
      ? [480, 960, 1920, 2880][config % 4]
      : config < 16
          ? [480, 960][config % 2]
          : [120, 240, 480, 960][config % 4];
  if (code == 3 && packet.length < 2) throw const A1Exception(A1Issue.unsupportedAudio);
  final count = code == 0
      ? 1
      : code == 3
          ? packet[1] & 63
          : 2;
  if (count == 0 || count * samples > 5760) throw const A1Exception(A1Issue.unsupportedAudio);
  return count * samples;
}

Uint8List _page(List<Uint8List> packets, int sequence, int granule, int flags) {
  final lacing = <int>[];
  for (final p in packets) {
    lacing.addAll(List.filled(p.length ~/ 255, 255));
    lacing.add(p.length % 255);
  }
  if (lacing.length > 255) throw const A1Exception(A1Issue.unsupportedAudio);
  final page = Uint8List(27 + lacing.length + packets.fold<int>(0, (s, p) => s + p.length));
  page.setAll(0, ascii.encode('OggS'));
  page[5] = flags;
  final b = ByteData.sublistView(page);
  b.setUint64(6, granule, Endian.little);
  b.setUint32(14, 0xa1d1a1d1, Endian.little);
  b.setUint32(18, sequence, Endian.little);
  page[26] = lacing.length;
  page.setAll(27, lacing);
  var at = 27 + lacing.length;
  for (final p in packets) {
    page.setAll(at, p);
    at += p.length;
  }
  var crc = 0;
  for (final byte in page) {
    crc ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc = ((crc << 1) ^ ((crc & 0x80000000) != 0 ? 0x04c11db7 : 0)) & 0xffffffff;
    }
  }
  b.setUint32(22, crc, Endian.little);
  return page;
}
