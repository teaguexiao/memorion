import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/backend/schema/chat_session.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/utils/logger.dart';
import 'package:memorion/utils/other/string_utils.dart';
import 'package:http/http.dart' as http;

Future<List<ServerMessage>> getMessagesServer({
  String? chatSessionId,
}) async {
  var url = '${Env.apiBaseUrl}v2/messages';
  if (chatSessionId != null) {
    url += '?chat_session_id=$chatSessionId';
  }

  var response = await makeApiCall(
    url: url,
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) throw Exception('Failed to load chat');
  if (response.statusCode == 200) {
    var body = utf8.decode(response.bodyBytes);
    var decodedBody = jsonDecode(body) as List<dynamic>;
    if (decodedBody.isEmpty) {
      return [];
    }
    var messages = decodedBody.map((conversation) => ServerMessage.fromJson(conversation)).toList();
    debugPrint('getMessages length: ${messages.length}');
    return messages;
  }
  throw Exception('Failed to load chat');
}

Future<List<ServerMessage>> clearChatServer({String? chatSessionId}) async {
  var url = '${Env.apiBaseUrl}v2/messages';
  if (chatSessionId != null) {
    url += '?chat_session_id=$chatSessionId';
  }

  var response = await makeApiCall(
    url: url,
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) throw Exception('Failed to delete chat');
  if (response.statusCode == 200) {
    return [ServerMessage.fromJson(jsonDecode(response.body))];
  } else {
    throw Exception('Failed to delete chat');
  }
}

ServerMessageChunk? parseMessageChunk(String line, String messageId) {
  if (line.startsWith('think: ')) {
    return ServerMessageChunk(messageId, line.substring(7).replaceAll("__CRLF__", "\n"), MessageChunkType.think);
  }

  if (line.startsWith('data: ')) {
    return ServerMessageChunk(messageId, line.substring(6).replaceAll("__CRLF__", "\n"), MessageChunkType.data);
  }

  if (line.startsWith('done: ')) {
    var text = decodeBase64(line.substring(6));
    return ServerMessageChunk(messageId, text, MessageChunkType.done,
        message: ServerMessage.fromJson(json.decode(text)));
  }

  if (line.startsWith('message: ')) {
    var text = decodeBase64(line.substring(9));
    return ServerMessageChunk(messageId, text, MessageChunkType.message,
        message: ServerMessage.fromJson(json.decode(text)));
  }

  return null;
}

Stream<ServerMessageChunk> sendMessageStreamServer(String text,
    {String? chatSessionId, List<String> contextConversationIds = const []}) {
  final uri = Uri.parse(appendExternalUserId('${Env.apiBaseUrl}v2/messages')).replace(
    queryParameters: {
      ...Uri.parse(appendExternalUserId('${Env.apiBaseUrl}v2/messages')).queryParameters,
      if (chatSessionId != null) 'chat_session_id': chatSessionId,
    },
  );
  return streamChatMessage(
      url: uri, authorization: getAuthHeader(), text: text, contextConversationIds: contextConversationIds);
}

// This backend frames events with LF and encodes content LF as __CRLF__.
// A literal CR inside model output is content, not an event delimiter.
StreamTransformer<String, String> _chatEventLines() {
  var pending = '';
  return StreamTransformer.fromHandlers(handleData: (data, sink) {
    pending += data;
    var newline = pending.indexOf('\n');
    while (newline >= 0) {
      sink.add(pending.substring(0, newline));
      pending = pending.substring(newline + 1);
      newline = pending.indexOf('\n');
    }
  }, handleDone: (sink) {
    if (pending.isNotEmpty) sink.add(pending);
    sink.close();
  });
}

/// Cancelling closes the socket immediately, including while awaiting headers.
/// The injectable URL also allows real HTTP transport checks on a loopback server.
Stream<ServerMessageChunk> streamChatMessage({
  required Uri url,
  required String authorization,
  required String text,
  List<String> contextConversationIds = const [],
}) {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  late final StreamController<ServerMessageChunk> events;
  StreamSubscription<String>? lines;
  var stopped = false;
  void stop() {
    if (stopped) return;
    stopped = true;
    client.close(force: true);
    unawaited(lines?.cancel());
    unawaited(events.close());
  }

  void fail() {
    if (stopped) return;
    events.add(ServerMessageChunk.failedMessage());
    stop();
  }

  Future<void> connect() async {
    try {
      final request = await client.postUrl(url);
      if (stopped) return;
      request.headers.set('Authorization', authorization);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'text': text,
        if (contextConversationIds.isNotEmpty) 'context_conversation_ids': contextConversationIds,
      }));
      final response = await request.close();
      if (stopped) return;
      if (response.statusCode != 200) {
        Logger.error('Failed to send message: ${response.statusCode}');
        fail();
        return;
      }
      // Tool calls can take time without producing text. Preserve the existing
      // global Ask behavior: no new idle timeout. Explicit cancellation still
      // closes the socket immediately. UTF-8 and large final events can split
      // across arbitrary TCP packets, so decode and buffer LF frames first.
      lines = response.transform(utf8.decoder).transform(_chatEventLines()).listen((line) {
        if (stopped) return;
        try {
          final chunk = parseMessageChunk(line, '1000');
          if (chunk != null) {
            events.add(chunk);
            if (chunk.type == MessageChunkType.done) stop();
          }
        } catch (_) {
          fail();
        }
      }, onError: (_) => fail(), onDone: stop);
      if (stopped) unawaited(lines?.cancel());
    } catch (error) {
      if (!stopped) Logger.error('Chat stream failed (${error.runtimeType})');
      fail();
    }
  }

  events = StreamController<ServerMessageChunk>(onListen: connect, onCancel: stop);
  return events.stream;
}

Future<ServerMessage> getInitialAppMessage() {
  return makeApiCall(
    url: '${Env.apiBaseUrl}v2/initial-message',
    headers: {},
    method: 'POST',
    body: '',
  ).then((response) {
    if (response == null) throw Exception('Failed to send message');
    if (response.statusCode == 200) {
      return ServerMessage.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Failed to send message');
    }
  });
}

Stream<ServerMessageChunk> sendVoiceMessageStreamServer(List<File> files) async* {
  var url = appendExternalUserId('${Env.apiBaseUrl}v2/voice-messages');
  var request = http.MultipartRequest(
    'POST',
    Uri.parse(url),
  );
  for (var file in files) {
    request.files.add(await http.MultipartFile.fromPath('files', file.path, filename: file.path.split('/').last));
  }
  request.headers.addAll({'Authorization': getAuthHeader()});

  try {
    var response = await request.send();
    if (response.statusCode != 200) {
      Logger.error('Failed to send message: ${response.statusCode}');
      yield ServerMessageChunk.failedMessage();
      return;
    }

    var buffers = <String>[];
    var messageId = "1000"; // Default new message
    await for (var data in response.stream.transform(utf8.decoder)) {
      var lines = data.split('\n\n');
      for (var line in lines.where((line) => line.isNotEmpty)) {
        // Dealing w/ the package spliting by 1024 bytes in dart
        // Waiting for the next package
        if (line.length >= 1024) {
          buffers.add(line);
          continue;
        }

        // Merge package if needed
        if (buffers.isNotEmpty) {
          buffers.add(line);
          line = buffers.join();
          buffers.clear();
        }

        var messageChunk = parseMessageChunk(line, messageId);
        if (messageChunk != null) {
          yield messageChunk;
        }
      }
    }

    // Flush remainings
    if (buffers.isNotEmpty) {
      var messageChunk = parseMessageChunk(buffers.join(), messageId);
      if (messageChunk != null) {
        yield messageChunk;
      }
    }
  } catch (e) {
    Logger.error('Error sending message: $e');
    yield ServerMessageChunk.failedMessage();
  }
}

Future reportMessageServer(String messageId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/messages/$messageId/report',
    headers: {},
    method: 'POST',
    body: '',
  );
  if (response == null) throw Exception('Failed to report message');
  if (response.statusCode != 200) {
    throw Exception('Failed to report message');
  }
}

Future<String> transcribeVoiceMessage(File audioFile) async {
  try {
    var url = appendExternalUserId('${Env.apiBaseUrl}v2/voice-message/transcribe');
    var request = http.MultipartRequest(
      'POST',
      Uri.parse(url),
    );

    request.headers.addAll({'Authorization': getAuthHeader()});
    request.files.add(await http.MultipartFile.fromPath('files', audioFile.path));

    var streamedResponse = await request.send();
    var response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['transcript'] ?? '';
    } else {
      debugPrint('Failed to transcribe voice message: ${response.statusCode} ${response.body}');
      throw Exception('Failed to transcribe voice message');
    }
  } catch (e) {
    debugPrint('Error transcribing voice message: $e');
    throw Exception('Error transcribing voice message: $e');
  }
}

Future<List<ChatSession>> getV2ChatSessions() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/chat/sessions',
    headers: {},
    method: 'GET',
    body: '',
  );

  if (response == null) return [];
  if (response.statusCode == 200) {
    var body = utf8.decode(response.bodyBytes);
    var decodedBody = jsonDecode(body) as List<dynamic>;
    return decodedBody.map((session) => ChatSession.fromJson(session)).toList();
  }
  return [];
}

Future<ChatSession?> createV2ChatSession({String? title, List<String> contextConversationIds = const []}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/chat/sessions',
    headers: {'Content-Type': 'application/json'},
    method: 'POST',
    body: jsonEncode({
      if (title != null && title.isNotEmpty) 'title': title,
      if (contextConversationIds.isNotEmpty) 'context_conversation_ids': contextConversationIds,
    }),
  );

  if (response == null) return null;
  if (response.statusCode == 200 || response.statusCode == 201) {
    var body = utf8.decode(response.bodyBytes);
    return ChatSession.fromJson(jsonDecode(body));
  }
  return null;
}

Future<ChatSession?> getV2ChatSessionById(String sessionId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/chat/sessions/$sessionId',
    headers: {},
    method: 'GET',
    body: '',
  );

  if (response == null) return null;
  if (response.statusCode == 200) {
    var body = utf8.decode(response.bodyBytes);
    return ChatSession.fromJson(jsonDecode(body));
  }
  return null;
}

Future<bool> updateV2ChatSessionTitle(String sessionId, String title) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/chat/sessions/$sessionId/title',
    headers: {},
    method: 'PUT',
    body: jsonEncode({'title': title}),
  );

  return response?.statusCode == 200;
}

Future<bool> deleteV2ChatSession(String sessionId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/chat/sessions/$sessionId',
    headers: {},
    method: 'DELETE',
    body: '',
  );

  return response?.statusCode == 200;
}

Future<ServerMessage?> createInitialMessage({String? chatSessionId}) async {
  var url = '${Env.apiBaseUrl}v2/initial-message';
  if (chatSessionId != null) {
    url += '?chat_session_id=$chatSessionId';
  }

  var response = await makeApiCall(
    url: url,
    headers: {},
    method: 'POST',
    body: '',
  );

  if (response == null) return null;
  if (response.statusCode == 200) {
    return ServerMessage.fromJson(jsonDecode(response.body));
  }
  return null;
}
