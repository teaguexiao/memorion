// Adapted from recording-bean-web (MIT). See THIRD_PARTY_LICENSE.txt.
import 'dart:convert';
import 'dart:typed_data';

/// D3200 stores 20 ms Opus packets in zero-padded 160-byte transport slots.
/// Ogg granule positions always use a 48 kHz clock, independently of STT's
/// eventual 16 kHz PCM input. Do not send these slots to the Memorion BLE parser.
Uint8List soundcoreOggOpus(List<Uint8List> slots) {
  final output = BytesBuilder(copy: false);
  final writer = SoundcoreOggWriter(output.add);
  for (final slot in slots) {
    writer.add(slot);
  }
  writer.finish();
  return output.takeBytes();
}

/// Writes at most one second of audio per page. Keep the last page until either
/// another packet or finish(), so even a full final page gets the EOS flag.
class SoundcoreOggWriter {
  final void Function(Uint8List) write;
  final _packets = <Uint8List>[];
  int _sequence = 2;
  int _count = 0;
  bool _finished = false;

  SoundcoreOggWriter(this.write) {
    final head = Uint8List(19)..setAll(0, ascii.encode('OpusHead'));
    head[8] = 1;
    head[9] = 1;
    final headerData = ByteData.sublistView(head);
    headerData.setUint16(10, 3840, Endian.little);
    headerData.setUint32(12, 48000, Endian.little);
    final vendor = ascii.encode('Memorion D3200'); // i18n-ignore: Ogg vendor metadata.
    final tags = Uint8List(16 + vendor.length)..setAll(0, ascii.encode('OpusTags'));
    ByteData.sublistView(tags).setUint32(8, vendor.length, Endian.little);
    tags.setAll(12, vendor);
    write(_page([head], 0, 0, 2));
    write(_page([tags], 1, 0, 0));
  }

  void add(Uint8List slot) {
    if (_finished) throw StateError('Ogg stream already finished');
    if (slot.length != 160) throw const FormatException('Incomplete D3200 audio');
    if (_packets.length == 50) _flush(false);
    var length = slot.length;
    while (length > 0 && slot[length - 1] == 0) {
      length--;
    }
    _packets.add(length == 0 ? Uint8List.fromList([0]) : Uint8List.fromList(slot.sublist(0, length)));
    _count++;
  }

  void _flush(bool last) {
    write(_page(_packets, _sequence++, _count * 960, last ? 4 : 0));
    _packets.clear();
  }

  void finish() {
    if (_finished) throw StateError('Ogg stream already finished');
    if (_count == 0) throw const FormatException('Incomplete D3200 audio');
    _flush(true);
    _finished = true;
  }
}

Uint8List _page(List<Uint8List> packets, int sequence, int granule, int flags) {
  final lacing = <int>[];
  for (final packet in packets) {
    var remaining = packet.length;
    while (remaining >= 255) {
      lacing.add(255);
      remaining -= 255;
    }
    lacing.add(remaining);
  }
  final headerSize = 27 + lacing.length;
  final page = Uint8List(headerSize + packets.fold<int>(0, (total, packet) => total + packet.length));
  page.setAll(0, ascii.encode('OggS'));
  page[5] = flags;
  final data = ByteData.sublistView(page);
  data.setUint64(6, granule, Endian.little);
  data.setUint32(14, 0x41524b52, Endian.little);
  data.setUint32(18, sequence, Endian.little);
  page[26] = lacing.length;
  page.setAll(27, lacing);
  var offset = headerSize;
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
