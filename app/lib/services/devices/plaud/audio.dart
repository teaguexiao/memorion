import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import '../offline_recordings/models.dart';
import 'identity.dart';
import 'protocol.dart';

/// Original Note's segmented ChaCha20 file. The source cipher has no MAC, so
/// successful decryption alone is insufficient: every packet must decode.
class PlaudAudio {
  /// Converts a retained raw file using one page (50 frames) of working memory.
  /// Callback must fully decode with a fresh 16 kHz mono Opus decoder, preserving
  /// its state across packets. The callback must not retain the reusable packet.
  /// Failure removes the partial output, never the caller-owned source.
  static Future<OfflineDownload> toOgg(File source, PlaudIdentity identity,
      {required int Function(Uint8List) validatePacket, Directory? temporaryParent}) async {
    final input = await source.open();
    Directory? owned;
    RandomAccessFile? output;
    Uint8List? stream;
    var complete = false;
    try {
      final length = await input.length();
      if (length <= 512 || length > plaudMaxFileBytes) {
        throw const PlaudException(PlaudIssue.unsupportedAudio);
      }
      final bytes = await input.read(512);
      if (bytes.length != 512 || ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != 'PLAUD.AI') {
        throw const PlaudException(PlaudIssue.unsupportedAudio);
      }
      final header = ByteData.sublistView(bytes);
      final size = header.getUint16(10, Endian.little);
      if (header.getUint16(8, Endian.little) != 1 ||
          size < 512 ||
          size >= length ||
          header.getUint32(144, Endian.little) != 80 ||
          (length - size) % 80 != 0) {
        throw const PlaudException(PlaudIssue.unsupportedAudio);
      }
      final key = identity.decrypt(Uint8List.sublistView(bytes, 256, 512));
      try {
        if (key.length != 32) throw const PlaudException(PlaudIssue.authentication);
        final cipher = ChaCha7539Engine()
          ..init(false, ParametersWithIV(KeyParameter(key), Uint8List.sublistView(bytes, 132, 144)));
        // Stock Note restarts at counter zero for every 80-byte segment.
        stream = cipher.process(Uint8List(80));
      } finally {
        key.fillRange(0, key.length, 0);
      }
      await input.setPosition(size);
      final frameCount = (length - size) ~/ 80;
      owned = await (temporaryParent ?? Directory.systemTemp)
          .createTemp('memorion-plaud-'); // i18n-ignore: Temporary directory prefix.
      final target = File('${owned.path}/audio.ogg');
      output = await target.open(mode: FileMode.write);
      final head = Uint8List(19)..setAll(0, ascii.encode('OpusHead'));
      head[8] = 1;
      head[9] = 1;
      ByteData.sublistView(head)
        ..setUint16(10, 312, Endian.little)
        ..setUint32(12, 16000, Endian.little);
      final vendor = ascii.encode('Memorion'); // i18n-ignore: Ogg vendor metadata.
      final tags = Uint8List(16 + vendor.length)..setAll(0, ascii.encode('OpusTags'));
      ByteData.sublistView(tags).setUint32(8, vendor.length, Endian.little);
      tags.setAll(12, vendor);
      await output.writeFrom(_page([head], 0, 0, 2));
      await output.writeFrom(_page([tags], 1, 0, 0));
      for (var start = 0; start < frameCount; start += 50) {
        final end = (start + 50).clamp(0, frameCount);
        final page = await input.read((end - start) * 80);
        if (page.length != (end - start) * 80) throw const PlaudException(PlaudIssue.unsupportedAudio);
        final packets = <Uint8List>[];
        for (var i = 0; i < end - start; i++) {
          final packet = Uint8List.sublistView(page, i * 80, (i + 1) * 80);
          for (var j = 0; j < 80; j++) {
            packet[j] ^= stream[j];
          }
          try {
            if (packet[0] != 0xb8 || validatePacket(packet) != 320) throw const FormatException();
          } on PlaudException {
            rethrow;
          } catch (_) {
            // B9 is observed in a real Note file; its meaning is not established.
            // Never rewrite the TOC, conceal a failure, or drop an audio segment.
            throw PlaudException(PlaudIssue.unsupportedAudio, frameIndex: start + i);
          }
          packets.add(packet);
        }
        await output.writeFrom(_page(packets, start ~/ 50 + 2, end * 960, end == frameCount ? 4 : 0));
      }
      if (await input.length() != length) throw const PlaudException(PlaudIssue.unsupportedAudio);
      await output.flush();
      await output.close();
      output = null;
      complete = true;
      return OfflineDownload.temporaryFile(target, Duration(microseconds: (frameCount * 960 - 312) * 1000000 ~/ 48000));
    } finally {
      stream?.fillRange(0, stream.length, 0);
      try {
        await input.close();
      } finally {
        try {
          await output?.close();
        } finally {
          if (!complete && owned != null) await owned.delete(recursive: true);
        }
      }
    }
  }
}

Uint8List _page(List<Uint8List> packets, int sequence, int granule, int flags) {
  final lacing = <int>[];
  for (final packet in packets) {
    lacing.addAll(List.filled(packet.length ~/ 255, 255));
    lacing.add(packet.length % 255);
  }
  if (lacing.length > 255) throw const PlaudException(PlaudIssue.unsupportedAudio);
  final page = Uint8List(27 + lacing.length + packets.fold<int>(0, (sum, p) => sum + p.length));
  page.setAll(0, ascii.encode('OggS'));
  page[5] = flags;
  final data = ByteData.sublistView(page);
  data.setUint64(6, granule, Endian.little);
  data.setUint32(14, 0x504c4144, Endian.little);
  data.setUint32(18, sequence, Endian.little);
  page[26] = lacing.length;
  page.setAll(27, lacing);
  var offset = 27 + lacing.length;
  for (final packet in packets) {
    page.setAll(offset, packet);
    offset += packet.length;
  }
  var crc = 0;
  for (final byte in page) {
    crc ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc = ((crc << 1) ^ ((crc & 0x80000000) != 0 ? 0x04c11db7 : 0)) & 0xffffffff;
    }
  }
  data.setUint32(22, crc, Endian.little);
  return page;
}
