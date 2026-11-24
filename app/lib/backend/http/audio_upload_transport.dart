import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

enum AudioUploadIssue {
  network,
  timeout,
  server,
  inFlight,
  auth,
  quota,
  tooLarge,
  duration,
  format,
  noSpeech,
  invalidResponse,
  unknown
}

class AudioUploadFailure implements Exception {
  final AudioUploadIssue issue;
  final int? statusCode;
  final bool awaitingResponse;
  final String? errorCode;
  const AudioUploadFailure(this.issue, {this.statusCode, this.awaitingResponse = false, this.errorCode});
  String get diagnostic =>
      'issue=${issue.name} http=${statusCode ?? "none"} phase=${awaitingResponse ? "confirming" : "sending"}';

  factory AudioUploadFailure.http(int status, String body) {
    var detail = '';
    String? errorCode;
    try {
      final value = jsonDecode(body);
      if (value is Map && value['detail'] is String) detail = (value['detail'] as String).toLowerCase();
      if (value is Map && value['detail'] is Map) {
        final payload = value['detail'] as Map;
        if (payload['message'] is String) detail = (payload['message'] as String).toLowerCase();
        if (payload['code'] is String) errorCode = payload['code'] as String;
      }
    } catch (_) {}
    final issue = switch (status) {
      401 || 403 => AudioUploadIssue.auth,
      409 => AudioUploadIssue.inFlight,
      402 || 429 => AudioUploadIssue.quota,
      413 => AudioUploadIssue.tooLarge,
      415 || 422 => AudioUploadIssue.format,
      400 when detail.contains('too short') || detail.contains('too long') => AudioUploadIssue.duration,
      400 when detail.contains('no detectable speech') || detail.contains('no speech') => AudioUploadIssue.noSpeech,
      400 when detail.contains('convert') || detail.contains('decode') || detail.contains('invalid audio') =>
        AudioUploadIssue.format,
      >= 500 => AudioUploadIssue.server,
      _ => AudioUploadIssue.unknown,
    };
    return AudioUploadFailure(issue, statusCode: status, awaitingResponse: true, errorCode: errorCode);
  }
}

typedef AudioUploadProgress = void Function(int sent, int total);

/// Counts the streamed multipart body without loading the recording into RAM.
/// Bytes handed to HTTP are an estimate, not an acknowledgement from the server.
class ProgressAudioRequest extends http.MultipartRequest {
  AudioUploadProgress? onProgress;
  void Function()? onBodySent;
  ProgressAudioRequest(super.method, super.url);

  @override
  http.ByteStream finalize() {
    final stream = super.finalize();
    final total = contentLength;
    var sent = 0;
    Stream<List<int>> tracked() async* {
      onProgress?.call(0, total);
      await for (final chunk in stream) {
        sent += chunk.length;
        onProgress?.call(sent, total);
        yield chunk;
      }
      onBodySent?.call();
    }

    return http.ByteStream(tracked());
  }
}

Future<http.Response> sendAudioUpload(
  ProgressAudioRequest request, {
  AudioUploadProgress? onProgress,
  http.Client? client,
  Duration idleTimeout = const Duration(seconds: 90),
  Duration responseTimeout = const Duration(minutes: 12),
  Duration totalTimeout = const Duration(minutes: 30),
}) async {
  final connection = client ?? http.Client();
  var awaitingResponse = false;
  var finished = false;
  Timer? idle;
  final failure = Completer<http.Response>();
  void expire() {
    if (!failure.isCompleted) {
      failure.completeError(AudioUploadFailure(AudioUploadIssue.timeout, awaitingResponse: awaitingResponse));
      connection.close();
    }
  }

  void arm(Duration duration) {
    if (finished) return;
    idle?.cancel();
    idle = Timer(duration, expire);
  }

  request.onProgress = (sent, total) {
    if (finished) return;
    arm(idleTimeout);
    onProgress?.call(sent, total);
  };
  request.onBodySent = () {
    awaitingResponse = true;
    arm(responseTimeout);
  };
  arm(idleTimeout);
  final deadline = Timer(totalTimeout, expire);
  try {
    final response = connection.send(request).then(http.Response.fromStream);
    // Future.any registers error handlers on every input, including a response
    // that fails after the timeout wins. The late-error regression covers this.
    return await Future.any([response, failure.future]);
  } on AudioUploadFailure {
    rethrow;
  } on SocketException {
    throw AudioUploadFailure(AudioUploadIssue.network, awaitingResponse: awaitingResponse);
  } on http.ClientException {
    throw AudioUploadFailure(AudioUploadIssue.network, awaitingResponse: awaitingResponse);
  } finally {
    finished = true;
    idle?.cancel();
    deadline.cancel();
    connection.close();
  }
}
