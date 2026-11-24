import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/models/stt_result.dart';
import 'package:memorion/services/sockets/pure_socket.dart';
import 'package:memorion/services/sockets/pure_polling.dart';
import 'package:memorion/services/sockets/composite_transcription_socket.dart';

// ─── Mock STT Provider ───────────────────────────────────────────────────────

class MockSttProvider implements ISttProvider {
  int transcribeCallCount = 0;
  SttTranscriptionResult? nextResult;

  @override
  Future<SttTranscriptionResult?> transcribe(
    Uint8List audioData, {
    double audioOffsetSeconds = 0,
  }) async {
    transcribeCallCount++;
    return nextResult;
  }

  @override
  void dispose() {}
}

// ─── Mock PureSocket (records sends, simulates connect/message) ──────────────

class MockPureSocket implements IPureSocket {
  PureSocketStatus _status = PureSocketStatus.notConnected;
  IPureSocketListener? _listener;

  final List<dynamic> sentMessages = [];
  bool connectResult = true;
  int stopCount = 0;

  @override
  PureSocketStatus get status => _status;

  @override
  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() async {
    if (connectResult) {
      _status = PureSocketStatus.connected;
      _listener?.onConnected();
    }
    return connectResult;
  }

  @override
  Future disconnect() async {
    _status = PureSocketStatus.disconnected;
    _listener?.onClosed();
  }

  @override
  Future stop() async {
    stopCount++;
    await disconnect();
  }

  @override
  void send(dynamic message) {
    sentMessages.add(message);
  }

  @override
  void onConnected() => _listener?.onConnected();

  @override
  void onMessage(dynamic message) => _listener?.onMessage(message);

  @override
  void onClosed([int? closeCode]) => _listener?.onClosed(closeCode);

  @override
  void onError(Object err, StackTrace trace) => _listener?.onError(err, trace);

  @override
  void onInternetSatusChanged(InternetStatus status) {}

  /// Simulate receiving a message from "server"
  void simulateMessage(dynamic msg) {
    _listener?.onMessage(msg);
  }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('SttTranscriptionResult', () {
    test('isNotEmpty returns true when has segments and text', () {
      final result = SttTranscriptionResult(
        segments: [SttSegment(text: 'hello', start: 0, end: 1)],
        rawText: 'hello',
      );
      expect(result.isNotEmpty, isTrue);
    });

    test('isNotEmpty returns false for empty segments', () {
      final result = SttTranscriptionResult(segments: [], rawText: '');
      expect(result.isNotEmpty, isFalse);
    });

    test('SttSegment stores fields correctly', () {
      final seg = SttSegment(text: 'test', start: 1.5, end: 3.0, speakerId: 2);
      expect(seg.text, 'test');
      expect(seg.start, 1.5);
      expect(seg.end, 3.0);
      expect(seg.speakerId, 2);
    });

    test('SttSegment defaults speakerId to 0', () {
      final seg = SttSegment(text: 'x', start: 0, end: 1);
      expect(seg.speakerId, 0);
    });
  });

  group('PurePollingSocket', () {
    late MockSttProvider mockProvider;
    late PurePollingSocket socket;

    setUp(() {
      mockProvider = MockSttProvider();
      socket = PurePollingSocket(
        config: const AudioPollingConfig(
          bufferDuration: Duration(milliseconds: 100), // fast for tests
          minBufferSizeBytes: 10,
          serviceId: 'TestSTT',
          codec: BleAudioCodec.pcm16,
          sampleRate: 16000,
        ),
        sttProvider: mockProvider,
      );
    });

    test('initial status is notConnected', () {
      expect(socket.status, PureSocketStatus.notConnected);
    });

    test('connect sets status to connected', () async {
      final ok = await socket.connect();
      expect(ok, isTrue);
      expect(socket.status, PureSocketStatus.connected);
    });

    test('connect notifies listener', () async {
      bool connected = false;
      socket.setListener(_SimpleListener(onConnectedFn: () => connected = true));
      await socket.connect();
      expect(connected, isTrue);
    });

    test('send buffers Uint8List frames', () async {
      await socket.connect();
      socket.send(Uint8List.fromList([1, 2, 3, 4]));
      socket.send(Uint8List.fromList([5, 6, 7, 8]));
      // No crash, frames buffered internally
    });

    test('send buffers List<int> frames', () async {
      await socket.connect();
      socket.send([1, 2, 3, 4]);
      // Converted to Uint8List internally
    });

    test('disconnect cancels timer and sets status', () async {
      await socket.connect();
      await socket.disconnect();
      expect(socket.status, PureSocketStatus.disconnected);
    });

    test('double connect returns false', () async {
      await socket.connect();
      final secondConnect = await socket.connect();
      expect(secondConnect, isFalse);
    });

    test('onInternetSatusChanged is no-op', () {
      // Should not throw
      socket.onInternetSatusChanged(InternetStatus.connected);
      socket.onInternetSatusChanged(InternetStatus.disconnected);
    });
  });

  group('CompositeTranscriptionSocket', () {
    late MockPureSocket primary;
    late MockPureSocket secondary;
    late CompositeTranscriptionSocket composite;

    setUp(() {
      primary = MockPureSocket();
      secondary = MockPureSocket();
      composite = CompositeTranscriptionSocket(
        primarySocket: primary,
        secondarySocket: secondary,
      );
    });

    test('initial status is notConnected', () {
      expect(composite.status, PureSocketStatus.notConnected);
    });

    test('connect succeeds when both sockets succeed', () async {
      final ok = await composite.connect();
      expect(ok, isTrue);
      expect(composite.status, PureSocketStatus.connected);
    });

    test('connect fails when primary fails', () async {
      primary.connectResult = false;
      final ok = await composite.connect();
      expect(ok, isFalse);
    });

    test('connect fails when secondary fails', () async {
      secondary.connectResult = false;
      final ok = await composite.connect();
      expect(ok, isFalse);
    });

    test('send forwards to both sockets', () async {
      await composite.connect();
      final data = Uint8List.fromList([1, 2, 3]);
      composite.send(data);
      expect(primary.sentMessages, [data]);
      expect(secondary.sentMessages, [data]);
    });

    test('send does nothing when not connected', () {
      composite.send(Uint8List.fromList([1, 2]));
      expect(primary.sentMessages, isEmpty);
      expect(secondary.sentMessages, isEmpty);
    });

    test('primary message is forwarded to secondary as suggested_transcript', () async {
      await composite.connect();

      // Simulate primary socket producing a transcript result
      final segments = jsonEncode([
        {'text': 'hello', 'speaker': 'SPEAKER_0', 'start': 0.0, 'end': 1.0}
      ]);
      primary.simulateMessage(segments);

      // The composite should have sent a suggested_transcript to secondary
      expect(secondary.sentMessages.length, 1);
      final sent = jsonDecode(secondary.sentMessages[0] as String);
      expect(sent['type'], 'suggested_transcript');
      expect(sent['stt_provider'], 'on_device_apple');
      expect(sent['segments'], isList);
    });

    test('secondary message is forwarded to listener', () async {
      String? receivedMessage;
      composite.setListener(
        _SimpleListener(onMessageFn: (msg) => receivedMessage = msg as String?),
      );
      await composite.connect();

      // Simulate backend sending a transcript
      secondary.simulateMessage('{"type":"transcript","segments":[]}');

      expect(receivedMessage, '{"type":"transcript","segments":[]}');
    });

    test('disconnect closes both sockets', () async {
      await composite.connect();
      await composite.disconnect();
      expect(composite.status, PureSocketStatus.disconnected);
      expect(primary.status, PureSocketStatus.disconnected);
      expect(secondary.status, PureSocketStatus.disconnected);
    });

    test('double connect returns false', () async {
      await composite.connect();
      final secondConnect = await composite.connect();
      expect(secondConnect, isFalse);
    });

    // stop() 必须转发给两个子 socket，不能退化成 disconnect()。
    // secondary 是 PureSocket：只 disconnect 的话它的重连循环仍然活着，录音停掉后
    // 网络一抖动就会去 POST /v1/listen 建新会话，而后端每来一条新连接就顶掉旧的
    // ——于是它会把用户**下一次**录音掀掉。
    test('stop forwards terminal shutdown to both sockets', () async {
      await composite.connect();
      await composite.stop();

      expect(primary.stopCount, 1, reason: 'primary 必须收到 stop()，否则 STT provider 不释放');
      expect(secondary.stopCount, 1, reason: 'secondary 必须收到 stop()，否则重连循环继续建会话');
      expect(composite.status, PureSocketStatus.disconnected);
      expect(primary.status, PureSocketStatus.disconnected);
      expect(secondary.status, PureSocketStatus.disconnected);
    });
  });
}

// ─── Simple listener helper ──────────────────────────────────────────────────

class _SimpleListener implements IPureSocketListener {
  final void Function()? onConnectedFn;
  final void Function(dynamic)? onMessageFn;
  final void Function([int?])? onClosedFn;
  final void Function(Object, StackTrace)? onErrorFn;

  _SimpleListener({this.onConnectedFn, this.onMessageFn, this.onClosedFn, this.onErrorFn});

  @override
  void onConnected() => onConnectedFn?.call();

  @override
  void onMessage(dynamic message) => onMessageFn?.call(message);

  @override
  void onClosed([int? closeCode]) => onClosedFn?.call(closeCode);

  @override
  void onError(Object err, StackTrace trace) => onErrorFn?.call(err, trace);

  @override
  void onInternetConnectionFailed() {}

  @override
  void onMaxRetriesReach() {}
}
