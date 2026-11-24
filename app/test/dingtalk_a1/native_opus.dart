import 'dart:ffi';
import 'dart:io';
import 'package:opus_dart/opus_dart.dart';

void loadTestOpus() {
  final override = Platform.environment['MEMORION_TEST_LIBOPUS'];
  final names = [
    if (override != null) override,
    if (Platform.isMacOS) ...[
      '/opt/homebrew/lib/libopus.dylib',
      '/opt/homebrew/lib/libopus.0.dylib',
      '/usr/local/lib/libopus.dylib',
    ] else if (Platform.isLinux)
      'libopus.so.0'
    else
      'opus.dll'
  ];
  for (final path in names) {
    try {
      // Opus exposes a platform-conditional FFI type; this test runs on the native VM.
      final dynamic library = DynamicLibrary.open(path);
      initOpus(library);
      return;
    } catch (_) {}
  }
  throw StateError('Native Opus is required for audio validation; set MEMORION_TEST_LIBOPUS.');
}
