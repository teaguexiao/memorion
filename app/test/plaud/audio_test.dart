import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:memorion/services/devices/plaud/audio.dart';
import 'package:memorion/services/devices/plaud/identity.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import '../dingtalk_a1/native_opus.dart';

void main() {
  final data = jsonDecode(File('test/plaud/fixtures/synthetic.json').readAsStringSync()) as Map<String, dynamic>;
  final identity = PlaudIdentity.fromJson(jsonEncode(data['identity']));
  Uint8List fixture() => Uint8List.fromList([
        ...base64.decode(data['header']),
        for (var i = 0; i < data['frameCount']; i++) ...base64.decode(data['encryptedFrame'])
      ]);
  late Directory root;
  late File source;
  setUpAll(loadTestOpus);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plaud-audio-test-');
    source = await File('${root.path}/source.plaud').writeAsBytes(fixture());
  });
  tearDown(() => root.delete(recursive: true));
  test('Python fixture streams into owned Ogg file with native validation and identical output', () async {
    final decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
    try {
      var count = 0;
      final result = await PlaudAudio.toOgg(source, identity, temporaryParent: root, validatePacket: (packet) {
        count++;
        expect(packet, base64.decode(data['opusFrame']));
        return decoder.decode(input: packet).length;
      });
      expect(count, 300);
      expect(result.ogg, isNull);
      expect(result.file, isNotNull);
      expect(result.duration, const Duration(microseconds: 5993500));
      expect(sha256.convert(await result.readBytes()).toString(), data['oggSha256']);
      final output = File('build/plaud-validation/synthetic.ogg');
      await output.parent.create(recursive: true);
      await result.writeTo(output);
      await result.dispose();
      expect(await result.file!.parent.exists(), false);
      expect(await source.readAsBytes(), fixture());
    } finally {
      decoder.destroy();
    }
  });
  test('truncation, unsupported layout and wrong account fail before packaging', () async {
    final bytes = fixture();
    for (final size in [0, 7, 511, 512, bytes.length - 1]) {
      await source.writeAsBytes(bytes.sublist(0, size));
      await expectLater(PlaudAudio.toOgg(source, identity, validatePacket: (_) => 320), throwsA(isA<PlaudException>()));
    }
    bytes[144] = 81;
    await source.writeAsBytes(bytes);
    await expectLater(PlaudAudio.toOgg(source, identity, validatePacket: (_) => 320), throwsA(isA<PlaudException>()));
    await source.writeAsBytes(fixture());
    await expectLater(
        PlaudAudio.toOgg(source, PlaudIdentity.fromJson(jsonEncode(data['otherIdentity'])), validatePacket: (_) => 320),
        throwsA(isA<PlaudException>()));
  });
  test('B9 in a later page is rejected at exact index, partial output removed and source retained', () async {
    final bytes = fixture()..[512 + 220 * 80] ^= 1;
    await source.writeAsBytes(bytes);
    await expectLater(PlaudAudio.toOgg(source, identity, temporaryParent: root, validatePacket: (_) => 320),
        throwsA(isA<PlaudException>().having((e) => e.frameIndex, 'frame index', 220)));
    expect(await source.readAsBytes(), bytes);
    expect(await root.list().length, 1);
  });
  test('owner cancellation remains distinct from unsupported audio and cleans partial output', () async {
    await expectLater(
        PlaudAudio.toOgg(source, identity,
            temporaryParent: root, validatePacket: (_) => throw const PlaudException(PlaudIssue.identityRequired)),
        throwsA(isA<PlaudException>().having((e) => e.issue, 'issue', PlaudIssue.identityRequired)));
    expect(await root.list().length, 1);
  });
  test('native failure or wrong duration cannot be marked playable or leave partial output', () async {
    await expectLater(PlaudAudio.toOgg(source, identity, temporaryParent: root, validatePacket: (_) => 640),
        throwsA(isA<PlaudException>()));
    await expectLater(
        PlaudAudio.toOgg(source, identity,
            temporaryParent: root, validatePacket: (_) => throw StateError('sensitive payload')),
        throwsA(isA<PlaudException>().having((e) => e.toString(), 'safe error', 'PlaudException(unsupportedAudio)')));
    expect(await root.list().length, 1);
  });
}
