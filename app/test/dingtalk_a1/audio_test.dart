import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:memorion/services/devices/dingtalk_a1/audio.dart';
import 'package:memorion/services/devices/dingtalk_a1/protocol.dart';
import 'native_opus.dart';

void main() {
  late Uint8List fixture;
  setUpAll(loadTestOpus);
  setUp(() => fixture = File('test/dingtalk_a1/fixtures/synthetic_tone.dtyj').readAsBytesSync());
  test('full native decode matches Opus timeline and preserves every packet byte', () async {
    final audio = A1Audio.parse(fixture);
    expect(audio.sampleRate, 16000); // Not the 32000 bit rate at offset 32.
    expect(audio.packets.length, 300);
    final decoder = SimpleOpusDecoder(sampleRate: 48000, channels: 1);
    var samples = 0;
    final result = await audio.toOgg(validatePacket: (packet) {
      final decoded = decoder.decode(input: packet);
      samples += decoded.length;
      return decoded.length;
    });
    decoder.destroy();
    expect(samples, 288000);
    expect(result.duration, const Duration(seconds: 6));
    final ogg = result.ogg!;
    var pos = 0, audioPages = 0, packetIndex = 0;
    while (pos < ogg.length) {
      expect(ascii.decode(ogg.sublist(pos, pos + 4)), 'OggS');
      final count = ogg[pos + 26];
      var start = pos + 27 + count;
      for (final size in ogg.sublist(pos + 27, pos + 27 + count)) {
        if (audioPages >= 2) {
          expect(ogg.sublist(start, start + size), audio.packets[packetIndex++]);
        }
        start += size;
      }
      if (start == ogg.length) {
        expect(ogg[pos + 5] & 4, 4);
        expect(ByteData.sublistView(ogg).getUint64(pos + 6, Endian.little), 288000);
      }
      pos = start;
      audioPages++;
    }
    expect(packetIndex, 300);
    // Artifact also decoded independently with FFmpeg during local validation.
    final out = File('build/a1-validation/synthetic_tone.ogg');
    await out.parent.create(recursive: true);
    await out.writeAsBytes(ogg);
  });
  test('v1.6 without a prefix retains all 80 Opus bytes', () {
    final prefixed = A1Audio.parse(fixture);
    final bytes = Uint8List(80 + 300 * 80)..setAll(0, fixture.sublist(0, 80));
    bytes.setAll(16, ascii.encode('v1.6'));
    final header = ByteData.sublistView(bytes)
      ..setUint32(4, bytes.length - 8, Endian.little)
      ..setUint16(44, 80, Endian.little)
      ..setUint16(46, 0, Endian.little)
      ..setUint32(72, 24000, Endian.little);
    expect(header.getUint16(46, Endian.little), 0);
    for (var i = 0; i < 300; i++) {
      bytes.setAll(80 + i * 80, prefixed.packets[i]);
    }
    expect(A1Audio.parse(bytes).packets.first, prefixed.packets.first);
    expect(A1Audio.parse(bytes).packets.first.length, 80);
  });
  test('encrypted, truncated and unsupported layouts never become playable Ogg', () {
    fixture[58] = 1;
    expect(() => A1Audio.parse(fixture),
        throwsA(isA<A1Exception>().having((e) => e.issue, 'issue', A1Issue.encryptedAudio)));
    fixture[58] = 0;
    expect(() => A1Audio.parse(Uint8List.sublistView(fixture, 0, fixture.length - 1)), throwsA(isA<A1Exception>()));
    fixture[46] = 2;
    expect(() => A1Audio.parse(fixture), throwsA(isA<A1Exception>()));
  });
  test('decode failure and sample-count mismatch fail conversion', () async {
    final audio = A1Audio.parse(fixture);
    await expectLater(audio.toOgg(validatePacket: (_) => 123), throwsA(isA<A1Exception>()));
    await expectLater(
        audio.toOgg(validatePacket: (_) => throw StateError('invalid codec payload')), throwsA(isA<A1Exception>()));
  });
  test('variable Opus frame durations use the 48 kHz clock', () {
    expect(a1OpusSamples(Uint8List.fromList([0x80])), 120);
    expect(a1OpusSamples(Uint8List.fromList([0x98])), 960);
    expect(a1OpusSamples(Uint8List.fromList([0x9b, 3])), 2880);
    expect(() => a1OpusSamples(Uint8List.fromList([0x9b, 0])), throwsA(isA<A1Exception>()));
    expect(() => a1OpusSamples(Uint8List.fromList([0x9b, 7])), throwsA(isA<A1Exception>()));
  });
}
