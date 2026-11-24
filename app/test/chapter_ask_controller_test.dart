import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/providers/chapter_ask_controller.dart';
import 'package:memorion/providers/message_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/chapter_ask_fixture.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  test('chapter, main Chat, and another chapter share history; restart reloads it', () async {
    final stored = <ServerMessage>[];
    final calls = <({String? session, List<String> ids, String text})>[];
    Future<List<ServerMessage>> fetch({String? chatSessionId}) async => stored.toList();
    Stream<ServerMessageChunk> send(String text,
        {String? chatSessionId, List<String> contextConversationIds = const []}) async* {
      calls.add((session: chatSessionId, ids: contextConversationIds, text: text));
      stored.insert(
          0,
          ServerMessage(
              'human-${calls.length}', DateTime.now(), text, MessageSender.human, MessageType.text, null, false, []));
      final answer = done('reply-${calls.length}').message!;
      answer.id = 'ai-${calls.length}';
      stored.insert(0, answer);
      yield ServerMessageChunk(answer.id, '', MessageChunkType.done, message: answer);
    }

    final shared = MessageProvider(fetchMessages: fetch, sendMessage: send);
    final chapter = ChapterAskController(shared);
    await chapter.initialize(title: 'First chapter', ids: ['a', 'b'], opening: 'Recap');
    await Future<void>.delayed(Duration.zero);
    chapter.send('What was the budget?');
    await Future<void>.delayed(Duration.zero);
    chapter.dispose();
    expect(shared.messages.map((m) => m.text), containsAll(['reply-1', 'reply-2', 'What was the budget?']));
    shared.addMessageLocally('Continue from the chapter');
    await shared.sendMessageStreamToServer('Continue from the chapter');
    final another = ChapterAskController(shared);
    await another.initialize(title: 'Second chapter', ids: ['c'], opening: 'Recap');
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.session), everyElement(isNull));
    expect(calls.map((c) => c.ids), [
      ['a', 'b'],
      ['a', 'b'],
      [],
      ['c']
    ]);
    expect(another.messages.map((m) => m.text), containsAll(['reply-1', 'reply-2', 'reply-3', 'reply-4']));
    final restarted = MessageProvider(fetchMessages: fetch);
    await restarted.ensureSharedHistory();
    expect(restarted.messages.map((m) => m.text), shared.messages.map((m) => m.text));
    final reopened = ChapterAskController(restarted);
    await reopened.initialize(title: 'First chapter', ids: ['a', 'b'], opening: 'Recap');
    expect(restarted.sendingMessage, isFalse);
    expect(calls.length, 4);
    reopened.dispose();
    another.dispose();
  });

  test('leaving chapter during stream preserves reply and blocks concurrent sends', () async {
    final stream = StreamController<ServerMessageChunk>();
    var sends = 0;
    final shared = MessageProvider(
        fetchMessages: ({chatSessionId}) async => [],
        sendMessage: (text, {chatSessionId, contextConversationIds = const []}) {
          sends++;
          return stream.stream;
        });
    final chapter = ChapterAskController(shared);
    await chapter.initialize(title: 'chapter', ids: ['a'], opening: 'opening');
    chapter.dispose();
    expect(await shared.sendMessageStreamToServer('duplicate'), isFalse);
    stream.add(done('reply after leaving'));
    await stream.close();
    await Future<void>.delayed(Duration.zero);
    expect(sends, 1);
    expect(shared.messages.first.text, 'reply after leaving');
    expect(shared.sendingMessage, isFalse);
    expect(SharedPreferencesUtil().getCachedMessagesForSession(null).first.text, 'reply after leaving');
  });

  test('manual clear cancels an active reply and cannot resurrect it', () async {
    var cancelled = false;
    final stream = StreamController<ServerMessageChunk>(onCancel: () {
      cancelled = true;
    });
    final shared = MessageProvider(
        fetchMessages: ({chatSessionId}) async => [],
        sendMessage: (text, {chatSessionId, contextConversationIds = const []}) => stream.stream,
        clearMessages: ({chatSessionId}) async => []);
    final chapter = ChapterAskController(shared);
    await chapter.initialize(title: 'chapter', ids: ['a'], opening: 'opening');
    await chapter.clear(title: 'chapter', ids: ['a'], opening: 'opening');
    stream.add(done('late answer'));
    await stream.close();
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    expect(shared.messages, isEmpty);
    expect(shared.sendingMessage, isFalse);
    expect(chapter.failed, isFalse);
    expect(SharedPreferencesUtil().getCachedMessagesForSession(null), isEmpty);
    chapter.dispose();
  });

  test('failed clear during streaming removes the interrupted placeholder', () async {
    final stream = StreamController<ServerMessageChunk>();
    final shared = MessageProvider(
        fetchMessages: ({chatSessionId}) async => [],
        sendMessage: (text, {chatSessionId, contextConversationIds = const []}) => stream.stream,
        clearMessages: ({chatSessionId}) async => throw StateError('offline'));
    final chapter = ChapterAskController(shared);
    await chapter.initialize(title: 'chapter', ids: ['a'], opening: 'opening');
    await chapter.clear(title: 'chapter', ids: ['a'], opening: 'opening');
    expect(chapter.clearFailed, isTrue);
    expect(shared.messages.length, 1);
    expect(shared.messages.single.sender, MessageSender.human);
    expect(shared.sendingMessage, isFalse);
    await stream.close();
    chapter.dispose();
  });

  test('clear from either entry clears the shared cache and survives restart', () async {
    var clears = 0;
    var failClear = true;
    final shared = MessageProvider(
        fetchMessages: ({chatSessionId}) async => [],
        sendMessage: (text, {chatSessionId, contextConversationIds = const []}) => Stream.value(done('answer')),
        clearMessages: ({chatSessionId}) async {
          expect(chatSessionId, isNull);
          clears++;
          if (failClear) throw StateError('offline');
          return [];
        });
    final chapter = ChapterAskController(shared);
    await chapter.initialize(title: 'chapter', ids: ['a'], opening: 'opening');
    await Future<void>.delayed(Duration.zero);
    await chapter.clear(title: 'chapter', ids: ['a'], opening: 'opening');
    expect(chapter.clearFailed, isTrue);
    expect(shared.messages, isNotEmpty);
    expect(shared.isClearingChat, isFalse);
    failClear = false;
    await chapter.clear(title: 'chapter', ids: ['a'], opening: 'opening');
    expect(clears, 2);
    expect(shared.messages, isEmpty);
    expect(SharedPreferencesUtil().getCachedMessagesForSession(null), isEmpty);
    chapter.send('new turn');
    await Future<void>.delayed(Duration.zero);
    await shared.clearChat();
    expect(chapter.messages, isEmpty);
    final restarted = MessageProvider();
    restarted.setMessagesFromCache();
    expect(restarted.messages, isEmpty);
    chapter.dispose();
  });

  test('slow refresh cannot overwrite a newer turn', () async {
    final fetch = Completer<List<ServerMessage>>();
    final shared = MessageProvider(
        fetchMessages: ({chatSessionId}) => fetch.future,
        sendMessage: (text, {chatSessionId, contextConversationIds = const []}) => Stream.value(done('new answer')));
    final pending = shared.refreshMessages();
    shared.addMessageLocally('new question');
    await shared.sendMessageStreamToServer('new question');
    fetch.complete([done('stale answer').message!]);
    await pending;
    expect(shared.messages.first.text, 'new answer');
    expect(shared.isLoadingMessages, isFalse);
  });

  test('failed send remains retryable without duplicating the human turn', () async {
    var fail = true;
    final shared = MessageProvider(
        fetchMessages: ({chatSessionId}) async => [],
        sendMessage: (text, {chatSessionId, contextConversationIds = const []}) {
          if (fail) throw StateError('offline');
          return Stream.value(done('recovered'));
        });
    final chapter = ChapterAskController(shared);
    await chapter.initialize(title: 'chapter', ids: ['a'], opening: 'opening');
    await Future<void>.delayed(Duration.zero);
    expect(chapter.failed, isTrue);
    expect(chapter.sending, isFalse);
    fail = false;
    chapter.retry();
    await Future<void>.delayed(Duration.zero);
    expect(chapter.failed, isFalse);
    expect(shared.messages.first.text, 'recovered');
    expect(shared.messages.where((m) => m.sender == MessageSender.ai).length, 1);
    expect(shared.messages.where((m) => m.sender == MessageSender.human).length, 1);
    chapter.dispose();
  });
}
