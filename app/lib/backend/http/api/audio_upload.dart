import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/env/env.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';

/// Response from audio upload API
class UploadAudioResponse {
  final String conversationId;
  final String status;
  final List<TranscriptSegment> transcriptSegments;
  final double durationSeconds;
  final String? language;

  UploadAudioResponse({
    required this.conversationId,
    required this.status,
    required this.transcriptSegments,
    required this.durationSeconds,
    this.language,
  });

  factory UploadAudioResponse.fromJson(Map<String, dynamic> json) {
    return UploadAudioResponse(
      conversationId: json['conversation_id'] ?? '',
      status: json['status'] ?? '',
      transcriptSegments:
          (json['transcript_segments'] as List<dynamic>?)?.map((s) => TranscriptSegment.fromJson(s)).toList() ?? [],
      durationSeconds: (json['duration_seconds'] as num?)?.toDouble() ?? 0,
      language: json['language'],
    );
  }
}

/// Upload an audio file for transcription and conversation creation.
///
/// [audioFile] - WAV or Opus binary file to upload
/// [language] - Language hint for transcription. ISO 639-1（`zh` / `en`），或 `auto`
///   表示让后端自己判。
///   🚨 **不要传 `multi`。** 它是**实时**链路的 Soniox 模型名，不是语言码 —— 离线 API 会
///   回 400 "Invalid language hint" 让整次转录失败，而后端把它映射成 502，客户端（正确地）
///   不把 5xx 当永久失败于是无限重试。用户看到的是「同步失败」，日志里要挖三层才见到真正
///   的原因（2026-08-15，手表同步）。后端现在两头都堵住了（默认值 + 认不出的值一律降级），
///   这条注释是为了别再有人从别处传进来。
/// [startedAt] - Recording start timestamp. Required: it is the time anchor for
///   every transcript segment (segments carry only offsets), so omitting it puts
///   the whole recording at the wrong point on the user's timeline. The backend
///   rejects the upload with 400 rather than defaulting it to the upload moment.
/// [saveRecording] - Whether to save original audio to cloud storage
/// [autoProcess] - Whether to automatically process conversation after transcription
///
/// [deferProcessing] - 让后端**验完就返回**，转录和摘要在服务端后台跑。
///   🚨 **返回值里没有转录稿**（`transcriptSegments` 为空、`language` 为 null、`status`
///   是 `processing`），所以任何「拿返回的 segments 用」的调用方都不能开它 ——
///   `uploadAudioAndCreateConversation` 就是这样一个（它 5 秒后去 fetch 对话），刻意没开。
///   为什么需要它：这个端点原来把 ffmpeg + VAD + Soniox + LLM 全塞在一个请求里，
///   2026-08-16 实测 **p50 69.3s、25 次里 4 次跑满 600s 被砍成 504**，而队列是串行的、
///   `syncNow` 每次回前台都触发 —— 用户看到的就是「同步转圈转到最后一段处理完」。
///   ⚠️ **后端要求 `saveRecording=true` 才认这个开关**（没有云端副本就不能提前答应，
///   否则手机删掉唯一那一份之后服务端一崩录音就没了）；不满足时它会**静默降级成同步**并
///   照旧返回完整转录稿 —— 所以判「走的是哪条路」要看 `status`，不能假设。
///   ⚠️ 老后端不认这个 query 参数（FastAPI 忽略未知参数）⇒ 行为等同同步，也是安全的。
///
/// [onHttpError] - Called with the HTTP status code when the server answers with
///   something other than 200. Needed because a bare `null` cannot tell a
///   *permanent* rejection (400 no detectable speech / bad duration) from a
///   *transient* one (network, 5xx): a caller that keeps a retry queue would
///   otherwise re-upload a permanently rejected file on every app launch,
///   forever — and offline transcription draws on an account-level Soniox
///   budget that is shared with the live streaming path.
///   Not called for network/parse exceptions (there is no status code then).
///
/// Returns [UploadAudioResponse] on success, null on failure.
Future<UploadAudioResponse?> uploadAudioForConversation({
  required File audioFile,
  required DateTime startedAt,
  String language = 'auto',
  bool saveRecording = false,
  bool autoProcess = true,
  bool deferProcessing = false,
  bool allowShortRecording = false,
  String? recordingKey,
  void Function(int statusCode, String body)? onHttpError,
  AudioUploadProgress? onProgress,
  void Function(AudioUploadFailure)? onFailure,
}) async {
  try {
    // Build URL with query parameters
    var url = Uri.parse('${Env.apiBaseUrl}v1/conversations/upload-audio').replace(
      queryParameters: {
        'language': language,
        'save_recording': saveRecording.toString(),
        'auto_process': autoProcess.toString(),
        'defer_processing': deferProcessing.toString(),
        if (allowShortRecording) 'allow_short_recording': 'true',
        'external_user_id': getExternalUserId(),
        'started_at': startedAt.toUtc().toIso8601String(),
        if (recordingKey != null) 'recording_key': recordingKey,
      },
    );

    var request = ProgressAudioRequest('POST', url);
    request.headers.addAll({'Authorization': getAuthHeader()});

    // Add the audio file
    var stream = http.ByteStream(audioFile.openRead());
    var length = await audioFile.length();
    var multipartFile = http.MultipartFile(
      'file',
      stream,
      length,
      filename: basename(audioFile.path),
    );
    request.files.add(multipartFile);

    debugPrint('uploadAudioForConversation: Uploading ${audioFile.path} ($length bytes)');

    var response = await sendAudioUpload(request, onProgress: onProgress);

    // ⚠️ **只认 200，所以后端的异步路径也必须回 200**（`status: "processing"` 写在 body 里，
    // 不在状态码里）。202 Accepted 才是 HTTP 上正确的那个码，但这里会把它当失败 → 调用
    // `onHttpError(202)` → 202 不在 `_isPermanentRejection` 里 ⇒ 那段录音被**永久重传**。
    // 已装机的版本改不了，所以这条契约是后端迁就客户端，不是反过来。
    if (response.statusCode == 200) {
      debugPrint('uploadAudioForConversation: Success');
      final json = jsonDecode(response.body);
      return UploadAudioResponse.fromJson(json);
    } else {
      debugPrint('uploadAudioForConversation: Failed with status ${response.statusCode}');
      onHttpError?.call(response.statusCode, response.body);
      onFailure?.call(AudioUploadFailure.http(response.statusCode, response.body));
      return null;
    }
  } catch (e) {
    final failure = e is AudioUploadFailure
        ? e
        : AudioUploadFailure(e is FormatException ? AudioUploadIssue.invalidResponse : AudioUploadIssue.unknown);
    debugPrint('uploadAudioForConversation: ${failure.diagnostic}');
    onFailure?.call(failure);
    return null;
  }
}

/// Upload audio and create a full conversation with processing.
/// This is a convenience wrapper that uploads audio and returns the created conversation.
Future<ServerConversation?> uploadAudioAndCreateConversation({
  required File audioFile,
  required DateTime startedAt,
  String language = 'auto',
  bool saveRecording = false,
}) async {
  final response = await uploadAudioForConversation(
    audioFile: audioFile,
    language: language,
    startedAt: startedAt,
    saveRecording: saveRecording,
    autoProcess: true,
  );

  if (response == null || response.conversationId.isEmpty) {
    debugPrint('uploadAudioAndCreateConversation: No conversation ID returned');
    return null;
  }

  debugPrint('uploadAudioAndCreateConversation: Fetching full conversation ${response.conversationId}');

  // Wait for backend processing to complete (LLM summarization takes time)
  debugPrint('uploadAudioAndCreateConversation: Waiting for backend processing...');
  await Future.delayed(const Duration(seconds: 5));

  // Fetch the complete conversation from the backend
  final conversation = await getConversationById(response.conversationId);

  if (conversation != null) {
    debugPrint('uploadAudioAndCreateConversation: Got conversation with title: ${conversation.structured.title}');
    return conversation;
  }

  // Fallback: return basic conversation if fetch fails
  debugPrint('uploadAudioAndCreateConversation: Failed to fetch, returning basic conversation');
  return ServerConversation(
    id: response.conversationId,
    createdAt: DateTime.now(),
    structured: Structured('Audio Recording', ''),
    startedAt: startedAt,
    finishedAt: DateTime.now(),
    source: ConversationSource.audio_upload,
    language: response.language ?? language,
    transcriptSegments: response.transcriptSegments,
  );
}
