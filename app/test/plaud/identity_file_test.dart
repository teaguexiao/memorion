import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/identity_file.dart';

class GrowingFile extends Fake implements XFile {
  bool cancelled = false;
  @override
  Future<int> length() async => 10;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    try {
      for (var i = 0; i < 100; i++) {
        yield Uint8List(8192);
      }
    } finally {
      cancelled = true;
    }
  }
}

void main() {
  test('cleanup failure does not discard a valid selected identity', () async {
    final value = jsonEncode(jsonDecode(File('test/plaud/fixtures/synthetic.json').readAsStringSync())['identity']);
    var cleanupCalled = false;
    final identity = await pickPlaudIdentityFile(
      pick: () async => XFile.fromData(Uint8List.fromList(utf8.encode(value))),
      removeCopy: (_) async {
        cleanupCalled = true;
        throw StateError('private-picker-path');
      },
    );
    expect(identity?.serial, '888000000000000001');
    expect(cleanupCalled, isTrue);
  });
  test('cleanup also runs for invalid files without replacing the safe error', () async {
    var cleanupCalled = false;
    await expectLater(
        pickPlaudIdentityFile(
          pick: () async => XFile.fromData(Uint8List.fromList([0xff])),
          removeCopy: (_) async {
            cleanupCalled = true;
            throw StateError('private-picker-path');
          },
        ),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', 'Invalid Plaud authorization file')));
    expect(cleanupCalled, isTrue);
  });
  test('picker cancellation does not run cleanup', () async {
    expect(
        await pickPlaudIdentityFile(pick: () async => null, removeCopy: (_) async => fail('nothing selected')), isNull);
  });
  test('imports the exporter JSON without manual field editing', () async {
    final value = jsonEncode(jsonDecode(File('test/plaud/fixtures/synthetic.json').readAsStringSync())['identity']);
    final identity = await readPlaudIdentityFile(XFile.fromData(Uint8List.fromList(utf8.encode(value))));
    expect(identity.serial, '888000000000000001');
  });
  for (final bytes in [
    Uint8List(16385),
    Uint8List.fromList([0xff]),
    Uint8List.fromList(utf8.encode('{"device_secret":"private-test-secret"}')),
  ]) {
    test('rejects invalid file of ${bytes.length} bytes without echoing content', () async {
      await expectLater(
          readPlaudIdentityFile(XFile.fromData(bytes)),
          throwsA(isA<FormatException>()
              .having((e) => e.toString(), 'message', 'FormatException: Invalid Plaud authorization file')));
    });
  }
  test('bounds reads even when a file grows after the size check', () async {
    final file = GrowingFile();
    await expectLater(readPlaudIdentityFile(file), throwsFormatException);
    expect(file.cancelled, isTrue);
  });
}
