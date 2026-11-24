import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/soundcore/ogg_opus.dart';

void main() {
  for (final count in [1, 49, 50, 51, 100, 101]) {
    test('incremental Ogg closes exactly $count packets with correct timestamps and page sequence', () {
      final pages = <Uint8List>[];
      final writer = SoundcoreOggWriter(pages.add);
      final packet = Uint8List(160)..setAll(0, [0xf8, 0xff, 0xfe]);
      for (var i = 0; i < count; i++) {
        writer.add(packet);
      }
      writer.finish();
      expect(pages.length, 2 + (count + 49) ~/ 50);
      expect(pages.last[5], 4);
      expect(ByteData.sublistView(pages.last).getUint64(6, Endian.little), count * 960);
      for (var i = 0; i < pages.length; i++) {
        final page = pages[i];
        expect(ByteData.sublistView(page).getUint32(18, Endian.little), i);
      }
    });
  }

  test('pages are emitted during reception and copied before caller reuses a slot', () {
    final pages = <Uint8List>[];
    final writer = SoundcoreOggWriter(pages.add);
    final packet = Uint8List(160)..setAll(0, [0xf8, 0xff, 0xfe]);
    for (var i = 0; i < 50; i++) {
      writer.add(packet);
    }
    expect(pages.length, 2);
    packet[0] = 0xfc;
    writer.add(packet);
    expect(pages.length, 3);
    expect(pages[2][77], 0xf8);
    expect(pages[2][5], 0);
    writer.finish();
    expect(pages.last[28], 0xfc);
  });
}
