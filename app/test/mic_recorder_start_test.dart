import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/services.dart';

class FakeSoundRecorder implements FlutterSoundRecorder {
  final opened = Completer<void>();
  final started = Completer<void>();
  int starts = 0;
  int stops = 0;

  @override
  Future<FlutterSoundRecorder?> openRecorder({dynamic isBGService = false}) async {
    await opened.future;
    return this;
  }

  @override
  Future<void> startRecorder({
    Codec codec = Codec.defaultCodec,
    String? toFile,
    StreamSink<List<Float32List>>? toStreamFloat32,
    StreamSink<List<Int16List>>? toStreamInt16,
    StreamSink<Uint8List>? toStream,
    int? sampleRate,
    int numChannels = 1,
    int bitRate = 16000,
    int bufferSize = 8192,
    bool enableVoiceProcessing = false,
    AudioSource audioSource = AudioSource.defaultSource,
  }) async {
    starts++;
    await started.future;
  }

  @override
  Future<String?> stopRecorder() async {
    stops++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recording callback follows successful native microphone startup', () async {
    final native = FakeSoundRecorder();
    final mic = MicRecorderService.forTesting(native);
    var recording = false;
    final start = mic.start(onByteReceived: (_) {}, onRecording: () => recording = true);
    expect(recording, isFalse);
    native.opened.complete();
    await Future<void>.delayed(Duration.zero);
    expect(native.starts, 1);
    expect(recording, isFalse);
    native.started.complete();
    await start;
    expect(recording, isTrue);
    expect(mic.status, RecorderServiceStatus.recording);
    mic.stop();
  });

  test('native startup failure never reports recording', () async {
    final native = FakeSoundRecorder()..opened.complete();
    final mic = MicRecorderService.forTesting(native);
    var recording = false;
    final start = mic.start(onByteReceived: (_) {}, onRecording: () => recording = true);
    final expectation = expectLater(start, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    native.started.completeError(StateError('Microphone unavailable'));
    await expectation;
    expect(recording, isFalse);
    expect(mic.status, RecorderServiceStatus.stop);
    mic.stop(); // Safe even when no stream was successfully started.
  });

  test('cancellation while opening prevents later microphone activation', () async {
    final native = FakeSoundRecorder();
    final mic = MicRecorderService.forTesting(native);
    var active = true;
    var recording = false;
    final start = mic.start(shouldStart: () => active, onByteReceived: (_) {}, onRecording: () => recording = true);
    final expectation = expectLater(start, throwsStateError);
    active = false;
    native.opened.complete();
    await expectation;
    expect(native.starts, 0);
    expect(recording, isFalse);
    mic.stop();
  });

  test('stop during native startup suppresses success and stops the microphone', () async {
    final native = FakeSoundRecorder()..opened.complete();
    final mic = MicRecorderService.forTesting(native);
    var recording = false;
    final start = mic.start(onByteReceived: (_) {}, onRecording: () => recording = true);
    final expectation = expectLater(start, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    mic.stop();
    native.started.complete();
    await expectation;
    expect(recording, isFalse);
    expect(native.stops, greaterThanOrEqualTo(1));
    expect(mic.status, RecorderServiceStatus.stop);
  });
}
