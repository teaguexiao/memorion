import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:memorion/backend/http/audio_upload_transport.dart';

class UploadClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  bool closed = false;
  UploadClient(this.handle);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handle(request);
  @override
  void close() => closed = true;
}

ProgressAudioRequest request() => ProgressAudioRequest('POST', Uri.parse('https://example.invalid/upload'))
  ..files.add(http.MultipartFile.fromBytes('file', List.filled(256000, 7), filename: 'audio.ogg'));

void main() {
  test('multipart progress reaches full body but still waits for server confirmation', () async {
    final gate = Completer<void>();
    final sent = Completer<void>();
    final progress = <(int, int)>[];
    final client = UploadClient((request) async {
      final bytes = await request.finalize().toBytes();
      expect(bytes.length, request.contentLength);
      sent.complete();
      await gate.future;
      return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
    });
    var accepted = false;
    final work =
        sendAudioUpload(request(), client: client, onProgress: (n, total) => progress.add((n, total))).then((value) {
      accepted = true;
      return value;
    });
    await sent.future;
    expect(progress.first.$1, 0);
    expect(progress.last.$1, progress.last.$2);
    expect(accepted, isFalse);
    gate.complete();
    expect((await work).statusCode, 200);
    expect(client.closed, isTrue);
  });

  test('server response timeout cancels the connection with a precise phase', () async {
    final never = Completer<http.StreamedResponse>();
    final client = UploadClient((request) async {
      await request.finalize().drain<void>();
      return never.future;
    });
    await expectLater(
        sendAudioUpload(request(), client: client, responseTimeout: const Duration(milliseconds: 20)),
        throwsA(isA<AudioUploadFailure>()
            .having((e) => e.issue, 'issue', AudioUploadIssue.timeout)
            .having((e) => e.awaitingResponse, 'server phase', isTrue)));
    expect(client.closed, isTrue);
    never.completeError(http.ClientException('Connection closed after timeout'));
    await Future<void>.delayed(Duration.zero);
  });

  test('network errors are distinct from server and file rejection errors', () async {
    final client = UploadClient((_) async => throw const SocketException('private URL and token'));
    await expectLater(sendAudioUpload(request(), client: client),
        throwsA(isA<AudioUploadFailure>().having((e) => e.issue, 'issue', AudioUploadIssue.network)));
    expect(client.closed, isTrue);
    for (final entry
        in {409: AudioUploadIssue.inFlight, 413: AudioUploadIssue.tooLarge, 504: AudioUploadIssue.server}.entries) {
      final error = AudioUploadFailure.http(entry.key, '{"detail":"private source content"}');
      expect(error.issue, entry.value);
      expect(error.diagnostic, isNot(contains('private')));
    }
    expect(AudioUploadFailure.http(400, '{"detail":"Audio duration is too long"}').issue, AudioUploadIssue.duration);
  });
}
