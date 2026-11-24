import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/messages.dart';
import 'package:memorion/backend/schema/message.dart';
import 'support/chapter_ask_fixture.dart';

void main() {
  test('real HTTP handles fragmented UTF-8, large final event and session query', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<Map<String, dynamic>>();
    server.listen((request) async {
      received.complete({
        'session': request.uri.queryParameters['chat_session_id'],
        'auth': request.headers.value('authorization'),
        'body': jsonDecode(await utf8.decoder.bind(request).join()),
      });
      request.response.headers.contentType = ContentType('text', 'event-stream');
      final answer = done(List.filled(400, '预算是370，没有同意涨价。').join()).message!;
      final bytes = utf8.encode('data: 预算370\r__CRLF__\n\ndata: ，没有同意涨价。\n\n'
          'done: ${base64Encode(utf8.encode(jsonEncode(answer.toJson())))}\n\n');
      for (var i = 0; i < bytes.length; i += 17) {
        request.response.add(bytes.sublist(i, (i + 17).clamp(0, bytes.length)));
        await request.response.flush();
      }
      await request.response.close();
    });
    final chunks = await streamChatMessage(
        url: Uri.parse('http://127.0.0.1:${server.port}/v2/messages?chat_session_id=linked-test'),
        authorization: 'fixture-only',
        text: '预算是多少？',
        contextConversationIds: ['source-a', 'source-b']).toList();
    expect(await received.future, {
      'session': 'linked-test',
      'auth': 'fixture-only',
      'body': {
        'text': '预算是多少？',
        'context_conversation_ids': ['source-a', 'source-b']
      }
    });
    expect(chunks.where((c) => c.type == MessageChunkType.data).map((c) => c.text).join(), '预算370\r\n，没有同意涨价。');
    expect(chunks.last.type, MessageChunkType.done);
    expect(chunks.last.message!.text.length, greaterThan(4000));
  });

  for (final sendHeaders in [false, true]) {
    test('cancellation immediately closes HTTP while ${sendHeaders ? 'streaming' : 'awaiting headers'}', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final arrived = Completer<void>();
      final disconnected = Completer<void>();
      server.listen((socket) {
        addTearDown(socket.destroy);
        unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
        socket.listen((bytes) {
          if (arrived.isCompleted) return;
          if (sendHeaders) {
            socket.write('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: first\n\n');
          }
          arrived.complete();
        }, onError: (Object _) {
          if (!disconnected.isCompleted) disconnected.complete();
        }, onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        });
      });
      final chunks = <ServerMessageChunk>[];
      final sub = streamChatMessage(
              url: Uri.parse('http://127.0.0.1:${server.port}/v2/messages'),
              authorization: 'fixture-only',
              text: 'question')
          .listen(chunks.add);
      await arrived.future;
      await sub.cancel().timeout(const Duration(seconds: 1));
      // Native socket sees the disconnect too; UI cancellation alone is insufficient.
      await disconnected.future.timeout(const Duration(seconds: 1));
      expect(chunks.any((c) => c.type == MessageChunkType.done), isFalse);
    });
  }
}
