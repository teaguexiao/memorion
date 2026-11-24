import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/utils/platform/platform_manager.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/utils/audio/transcript_audio_alignment.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';

// 止血 fix (配合后端幂等 PR)：HTTP 层第二道防线。即便某条触发路径绕过了
// CaptureProvider 的 in-flight 守卫，同一 session_id 也只允许一个 POST
// /v1/conversations/process 在途，避免后端 TOCTOU 竞态落库两条 conversation。
final Set<String> _inFlightProcessSessionIds = <String>{};

Future<CreateConversationResponse?> processInProgressConversation({
  List<TranscriptSegment>? segments,
  String? language,
  String? sessionId,
}) async {
  // Stopping without a transcript must not create an unfinished server record.
  if (segments == null || segments.isEmpty) return null;

  // 同一 session_id 已有请求在途时直接跳过，避免重复提交。
  if (sessionId != null && _inFlightProcessSessionIds.contains(sessionId)) {
    debugPrint('processInProgressConversation: session $sessionId already in-flight, skipping duplicate POST');
    return null;
  }
  if (sessionId != null) {
    _inFlightProcessSessionIds.add(sessionId);
  }
  try {
    return await _processInProgressConversation(
      segments: segments,
      language: language,
      sessionId: sessionId,
    );
  } finally {
    if (sessionId != null) {
      _inFlightProcessSessionIds.remove(sessionId);
    }
  }
}

Future<CreateConversationResponse?> _processInProgressConversation({
  required List<TranscriptSegment> segments,
  String? language,
  String? sessionId,
}) async {
  final body = {
    'external_user_id': ApiConfig().externalUserId,
    'segments': segments.map((s) => {
      'text': s.text,
      'speaker_id': s.speakerId,
      'start': s.start,
      'end': s.end,
      if (s.originalStart != null) 'original_start': s.originalStart,
      if (s.originalEnd != null) 'original_end': s.originalEnd,
      if (s.timestampAxis != null) 'timestamp_axis': s.timestampAxis,
      'is_user': s.isUser,
      'person_id': s.personId,
    }).toList(),
    'language': language ?? 'zh',
    'source': 'app',
  };
  // Include session_id if provided (for linking audio from listen session)
  if (sessionId != null) {
    body['session_id'] = sessionId;
  }
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/process',
    headers: {},
    method: 'POST',
    body: jsonEncode(body),
  );
  if (response == null) return null;
  debugPrint('processConversationServer: ${response.body}');
  if (response.statusCode == 201 || response.statusCode == 200) {
    return CreateConversationResponse.fromJson(jsonDecode(response.body));
  } else {
    debugPrint('Failed to process conversation: ${response.statusCode} ${response.body}');
    PlatformManager.instance.instabug.reportCrash(
      Exception('Failed to process conversation'), // i18n-ignore: Internal crash-report message.
      StackTrace.current,
      userAttributes: {'response': response.body},
    );
  }
  return null;
}

/// 首页显式包含已过滤的录音，供用户查看原文和音频；其他调用方按需选择。
Future<List<ServerConversation>> getConversations(
    {int limit = 50,
    int offset = 0,
    List<ConversationStatus> statuses = const [],
    bool includeDiscarded = false,
    bool throwOnError = false}) async {
  var response = await makeApiCall(
      url:
          '${Env.apiBaseUrl}v1/conversations?include_discarded=$includeDiscarded&limit=$limit&offset=$offset&statuses=${statuses.map((val) => val.toString().split(".").last).join(",")}',
      headers: {},
      method: 'GET',
      body: '');
  if (response == null) {
    if (throwOnError) throw StateError('Conversation request failed'); // i18n-ignore: Internal API error.
    return [];
  }
  if (response.statusCode == 200) {
    // decode body bytes to utf8 string and then parse json so as to avoid utf8 char issues
    var body = utf8.decode(response.bodyBytes);
    var memories =
        (jsonDecode(body) as List<dynamic>).map((conversation) => ServerConversation.fromJson(conversation)).toList();
    debugPrint('getConversations length: ${memories.length}');
    return memories;
  } else {
    debugPrint('getConversations error ${response.statusCode}');
    if (throwOnError) {
      throw StateError('Conversation request failed: ${response.statusCode}'); // i18n-ignore: Internal API error.
    }
  }
  return [];
}

Future<ServerConversation?> reProcessConversationServer(String conversationId, {String? appId}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/reprocess${appId != null ? '?app_id=$appId' : ''}',
    headers: {},
    method: 'POST',
    body: '',
  );
  if (response == null) return null;
  debugPrint('reProcessConversationServer: ${response.body}');
  if (response.statusCode == 200) {
    return ServerConversation.fromJson(jsonDecode(response.body));
  }
  return null;
}

Future<bool> deleteConversationServer(String conversationId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deleteConversation: ${response.statusCode}');
  return response.statusCode == 204;
}

Future reportConversationServer(String conversationId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/report',
    headers: {},
    method: 'POST',
    body: '',
  );
  if (response == null) throw Exception('Failed to report conversation');
  if (response.statusCode != 200) {
    throw Exception('Failed to report conversation');
  }
}

Future<ServerConversation?> getConversationById(String conversationId, {bool throwOnError = false}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) {
    if (throwOnError) throw StateError('Conversation request failed'); // i18n-ignore: Internal API error.
    return null;
  }
  if (response.statusCode == 200) {
    return ServerConversation.fromJson(jsonDecode(response.body));
  }
  if (throwOnError && response.statusCode != 404) {
    throw StateError('Conversation request failed: ${response.statusCode}'); // i18n-ignore: Internal API error.
  }
  return null;
}

/// Get a short-lived signed URL for downloading conversation audio.
/// The URL is valid for 15 minutes.
/// Returns null if no audio is available for this conversation.
Future<String?> getConversationAudioSignedUrl(String conversationId) async {
  debugPrint('getConversationAudioSignedUrl: Fetching for $conversationId');
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/audio-url',
    headers: {},
    method: 'GET',
    body: '',
  );
  debugPrint('getConversationAudioSignedUrl: response=${response?.statusCode}, body=${response?.body}');
  if (response == null) return null;
  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data['audio_url'];
  }
  return null;
}

/// 每段转写在音频文件里的位置，用于「点一句从这句开始播」。
/// 对不齐（老录音没有时间来源）或请求失败时返回 null——此时不提供按句播放，而不是拿显示时间去猜。
Future<TranscriptAudioAlignment?> getConversationAudioAlignment(String conversationId) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/audio-alignment',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null || response.statusCode != 200) return null;
  try {
    return TranscriptAudioAlignment.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  } catch (e) {
    debugPrint('getConversationAudioAlignment: bad payload: $e');
    return null;
  }
}

Future<bool> togglePinConversationServer(String conversationId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/pin',
    headers: {},
    method: 'PATCH',
    body: '',
  );
  if (response == null) return false;
  debugPrint('togglePinConversation: ${response.statusCode}');
  return response.statusCode == 200;
}

Future<bool> updateConversationTitle(String conversationId, String title) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/title?title=${Uri.encodeQueryComponent(title)}',
    headers: {},
    method: 'PATCH',
    body: '',
  );
  if (response == null) return false;
  debugPrint('updateConversationTitle: ${response.body}');
  return response.statusCode == 200;
}

/// 更新会话正文（structured.overview）——走 Developer API PATCH /v1/conversations/{id}。
/// makeApiCall 对 Env.apiBaseUrl 请求自动注入 Authorization key + external_user_id。
/// P-11 章节详情正文「它的回忆」inline 编辑用此回写。
Future<bool> updateConversationOverview(String conversationId, String overview) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({'overview': overview}),
  );
  if (response == null) return false;
  debugPrint('updateConversationOverview: ${response.statusCode}');
  return response.statusCode == 200;
}

Future<List<ConversationPhoto>> getConversationPhotos(String conversationId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/photos',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return [];
  debugPrint('getConversationPhotos: ${response.body}');
  if (response.statusCode == 200) {
    return (jsonDecode(response.body) as List<dynamic>).map((photo) => ConversationPhoto.fromJson(photo)).toList();
  }
  return [];
}

class TranscriptsResponse {
  List<TranscriptSegment> deepgram;
  List<TranscriptSegment> soniox;
  List<TranscriptSegment> whisperx;
  List<TranscriptSegment> speechmatics;

  TranscriptsResponse({
    this.deepgram = const [],
    this.soniox = const [],
    this.whisperx = const [],
    this.speechmatics = const [],
  });

  factory TranscriptsResponse.fromJson(Map<String, dynamic> json) {
    return TranscriptsResponse(
      deepgram: (json['deepgram'] as List<dynamic>).map((segment) => TranscriptSegment.fromJson(segment)).toList(),
      soniox: (json['soniox'] as List<dynamic>).map((segment) => TranscriptSegment.fromJson(segment)).toList(),
      whisperx: (json['whisperx'] as List<dynamic>).map((segment) => TranscriptSegment.fromJson(segment)).toList(),
      speechmatics:
          (json['speechmatics'] as List<dynamic>).map((segment) => TranscriptSegment.fromJson(segment)).toList(),
    );
  }
}

Future<TranscriptsResponse> getConversationTranscripts(String conversationId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/transcripts',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return TranscriptsResponse();
  debugPrint('getConversationTranscripts: ${response.body}');
  if (response.statusCode == 200) {
    var transcripts = (jsonDecode(response.body) as Map<String, dynamic>);
    return TranscriptsResponse.fromJson(transcripts);
  }
  return TranscriptsResponse();
}

Future<bool> hasConversationRecording(String conversationId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/recording',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return false;
  debugPrint('hasConversationRecording: ${response.body}');
  if (response.statusCode == 200) {
    return jsonDecode(response.body)['has_recording'] ?? false;
  }
  return false;
}

Future<bool> assignBulkConversationTranscriptSegments(
  String conversationId,
  List<String> segmentIds, {
  bool? isUser,
  String? personId,
}) async {
  String assignType;
  String? value;
  if (isUser == true) {
    assignType = 'is_user';
    value = 'true';
  } else {
    assignType = 'person_id';
    value = personId; // can be null for un-assign
  }

  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/segments/assign-bulk',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({
      'segment_ids': segmentIds,
      'assign_type': assignType,
      'value': value,
    }),
  );
  if (response == null) return false;
  debugPrint('assignBulkConversationTranscriptSegments: ${response.body}');
  return response.statusCode == 200;
}

Future<bool> setConversationEventsState(
  String conversationId,
  List<int> eventsIdx,
  List<bool> values,
) async {
  print(jsonEncode({
    'events_idx': eventsIdx,
    'values': values,
  }));
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/events',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({
      'events_idx': eventsIdx,
      'values': values,
    }),
  );
  if (response == null) return false;
  debugPrint('setConversationEventsState: ${response.body}');
  return response.statusCode == 200;
}

Future<bool> setConversationActionItemState(
  String conversationId,
  List<int> actionItemsIdx,
  List<bool> values,
) async {
  assert(actionItemsIdx.length == values.length);
  final updates = <Map<String, dynamic>>[];
  for (int i = 0; i < actionItemsIdx.length; i++) {
    updates.add({
      'idx': actionItemsIdx[i],
      'completed': values[i],
    });
  }
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/action-items',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({'updates': updates}),
  );
  if (response == null) return false;
  debugPrint('setConversationActionItemState: ${response.body}');
  return response.statusCode == 200;
}

Future<bool> updateActionItemDescription(
    String conversationId, String oldDescription, String newDescription, int idx) async {
  var body = {
    'old_description': oldDescription,
    'description': newDescription,
  };
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/action-items/$idx',
    headers: {},
    method: 'PATCH',
    body: jsonEncode(body),
  );
  if (response == null) return false;
  debugPrint('updateActionItemDescription: ${response.body}');
  return response.statusCode == 200;
}

/// 对单条待办做增改删的三种结局。
///
/// ⚠️ **必须是三态，不能是 bool。** `gone`（服务端 404）的正确处置和 `failed` 正好
/// **相反**：404 的含义是「服务端已经没有这条了」⇒ 本地要跟着删掉；真失败才该保留
/// 着等重试。混成一个 false 的代价是 2026-08-24 那张按不掉的幽灵卡片：后端的待办
/// 门禁在待办**下发给 App 之后 46 秒**撤销了它（conv 56313829，12:50:40 写入、
/// 12:51:26 撤销），App 缓存里那条于是指向一个不存在的对象；用户点「不是待办」，
/// DELETE 404 被当成失败 ⇒ 本地不删 ⇒ 卡片赖着不走，连点 9 次都是 404。
enum ActionItemMutation {
  /// 服务端接受了这次改动。
  ok,

  /// 服务端已经没有这条待办了（404）。**不是错误** —— 本地跟着对齐即可。
  gone,

  /// 网络错误、超时、5xx。改动没发生，本地状态要回滚。
  failed;

  /// 由状态码判定结局。`statusCode == null` 表示请求压根没发出去。
  ///
  /// 成功码按方法不同：PATCH 是 200，DELETE 是 **204**。写成 200 会让每一次成功的
  /// 删除都被判成失败。
  static ActionItemMutation fromStatus(int? statusCode, {required int successCode}) {
    if (statusCode == null) return failed;
    if (statusCode == successCode) return ok;
    if (statusCode == 404) return gone;
    return failed;
  }
}

ActionItemMutation _mutationFrom(http.Response? response, int successCode, String tag) {
  debugPrint('$tag: ${response?.statusCode}');
  return ActionItemMutation.fromStatus(response?.statusCode, successCode: successCode);
}

/// 「加入待办」：把 LLM 提取的待确认待办确认为真待办（confirmed=true）。
Future<ActionItemMutation> confirmConversationActionItem(String conversationId, int idx) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/action-items/$idx',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({'confirmed': true}),
  );
  return _mutationFrom(response, 200, 'confirmConversationActionItem');
}

/// 「不是待办」：直接从会话里删掉，不留痕（后端 DELETE 需要 item_idx）。
Future<ActionItemMutation> rejectConversationActionItem(String conversationId, int idx) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/action-items/$idx',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  return _mutationFrom(response, 204, 'rejectConversationActionItem');
}

Future<bool> deleteConversationActionItem(String conversationId, ActionItem item) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/action-items',
    headers: {},
    method: 'DELETE',
    body: jsonEncode({
      'completed': item.completed,
      'description': item.description,
    }),
  );
  if (response == null) return false;
  debugPrint('deleteConversationActionItem: ${response.body}');
  return response.statusCode == 204;
}

//this is expected to return complete memories
Future<List<ServerConversation>> sendStorageToBackend(File file, String sdCardDateTimeString) async {
  var url = appendExternalUserId('${Env.apiBaseUrl}sdcard_memory?date_time=$sdCardDateTimeString');
  var request = http.MultipartRequest(
    'POST',
    Uri.parse(url),
  );
  request.headers.addAll({'Authorization': getAuthHeader()});
  request.files.add(await http.MultipartFile.fromPath('file', file.path, filename: basename(file.path)));
  try {
    var streamedResponse = await request.send();
    var response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200) {
      debugPrint('storageSend Response body: ${jsonDecode(response.body)}');
    } else {
      debugPrint('Failed to storageSend. Status code: ${response.statusCode}');
      return [];
    }

    var memories = (jsonDecode(response.body) as List<dynamic>)
        .map((conversation) => ServerConversation.fromJson(conversation))
        .toList();
    debugPrint('getMemories length: ${memories.length}');

    return memories;
  } catch (e) {
    debugPrint('An error occurred storageSend: $e');
    return [];
  }
}

Future<SyncLocalFilesResponse> syncLocalFiles(List<File> files) async {
  var url = appendExternalUserId('${Env.apiBaseUrl}v1/sync-local-files');
  var request = http.MultipartRequest(
    'POST',
    Uri.parse(url),
  );
  for (var file in files) {
    request.files.add(await http.MultipartFile.fromPath('files', file.path, filename: basename(file.path)));
  }
  request.headers.addAll({'Authorization': getAuthHeader()});

  try {
    var streamedResponse = await request.send();
    var response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200) {
      debugPrint('syncLocalFile Response body: ${jsonDecode(response.body)}');
      return SyncLocalFilesResponse.fromJson(jsonDecode(response.body));
    } else {
      debugPrint('Failed to upload sample. Status code: ${response.statusCode}');
      throw Exception('Failed to upload sample. Status code: ${response.statusCode}');
    }
  } catch (e) {
    debugPrint('An error occurred uploadSample: $e');
    throw Exception('An error occurred uploadSample: $e');
  }
}

Future<(List<ServerConversation>, int, int)> searchConversationsServer(
  String query, {
  int? page,
  int? limit,
  bool includeDiscarded = true,
}) async {
  debugPrint(Env.apiBaseUrl);
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/search',
    headers: {},
    method: 'POST',
    body:
        jsonEncode({'query': query, 'page': page ?? 1, 'per_page': limit ?? 10, 'include_discarded': includeDiscarded}),
  );
  if (response == null) return (<ServerConversation>[], 0, 0);
  if (response.statusCode == 200) {
    List<dynamic> items = (jsonDecode(response.body))['items'];
    int currentPage = (jsonDecode(response.body))['current_page'];
    int totalPages = (jsonDecode(response.body))['total_pages'];
    var convos = items.map<ServerConversation>((item) => ServerConversation.fromJson(item)).toList();
    return (convos, currentPage, totalPages);
  }
  return (<ServerConversation>[], 0, 0);
}
