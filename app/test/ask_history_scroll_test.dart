import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/ask_page.dart';
import 'package:memorion/pages/today_chapters/chapter_ask_context.dart';
import 'package:memorion/providers/message_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/chapter_ask_fixture.dart';

void main({bool configureTestView = true}) {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  Future<void> mount(WidgetTester tester, MessageProvider shared, {ChapterAskContext? chapter}) async {
    if (configureTestView) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: shared,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: AskPage(key: ValueKey(chapter?.title), chapterContext: chapter),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.tap(find.byType(TextField));
    await frames(tester);
    await tester.enterText(find.byType(TextField), text);
    // Native keyboards animate before the composer reaches its final position.
    await frames(tester);
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await frames(tester);
  }

  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(
          find.descendant(of: find.byKey(const Key('ask-history')), matching: find.byType(Scrollable)).first)
      .position;

  testWidgets('two short rounds start at the top and remain chronological', (tester) async {
    var round = 0;
    final shared = MessageProvider(
      fetchMessages: ({chatSessionId}) async => [],
      sendMessage: (text, {chatSessionId, contextConversationIds = const []}) => Stream.value(done('回答${++round}')),
    );
    await mount(tester, shared);
    await send(tester, '问题1');
    final firstY = tester.getTopLeft(find.text('问题1')).dy;
    expect(firstY - tester.getTopLeft(find.byKey(const Key('ask-history'))).dy, lessThan(100));
    await send(tester, '问题2');
    expect(tester.getTopLeft(find.text('问题1')).dy, firstY);
    final texts = ['问题1', '回答1', '问题2', '回答2'];
    for (var i = 0; i < texts.length - 1; i++) {
      expect(tester.getTopLeft(find.text(texts[i])).dy, lessThan(tester.getTopLeft(find.text(texts[i + 1])).dy));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('both entry points keep one history, latest reply and chapter-only request context', (tester) async {
    final requests = <List<String>>[];
    final sessions = <String?>[];
    var fetches = 0;
    final history = List.generate(
        18,
        (i) => ServerMessage(
            'old-$i', DateTime(2026, 10, 27), '历史问题$i', MessageSender.human, MessageType.text, null, false, []));
    final shared = MessageProvider(
      fetchMessages: ({chatSessionId}) async {
        fetches++;
        return history;
      },
      sendMessage: (text, {chatSessionId, contextConversationIds = const []}) {
        requests.add(contextConversationIds);
        sessions.add(chatSessionId);
        return Stream.value(done('最新回答${requests.length}'));
      },
    );
    await mount(tester, shared);
    await send(tester, '普通问题');
    expect(find.text('最新回答1').hitTestable(), findsOneWidget);
    await mount(tester, shared,
        chapter: ChapterAskContext(
            title: '预算讨论', subtitle: '', conversationIds: ['a', 'b'], sources: [source('a'), source('b')]));
    expect(find.byKey(const Key('ask-history')), findsOneWidget);
    expect(position(tester).extentAfter, lessThan(1));
    expect(find.text('最新回答2').hitTestable(), findsOneWidget);
    await send(tester, '章节问题');
    expect(find.text('最新回答3').hitTestable(), findsOneWidget);
    await mount(tester, shared);
    expect(position(tester).extentAfter, lessThan(1));
    expect(find.text('最新回答3').hitTestable(), findsOneWidget);
    await send(tester, '继续普通问题');
    expect(requests, [
      [],
      ['a', 'b'],
      ['a', 'b'],
      []
    ]);
    expect(sessions, everyElement(isNull));
    expect(fetches, 1);
    expect(shared.messages.where((m) => m.text == '普通问题'), hasLength(1));
    expect(shared.messages.where((m) => m.text == '章节问题'), hasLength(1));
    expect(shared.messages.last.text, '历史问题17');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    shared.dispose();
  });

  testWidgets('new send and streaming follow latest; reading history does not jump', (tester) async {
    final stream = StreamController<ServerMessageChunk>();
    addTearDown(stream.close);
    final history = List.generate(
        18,
        (i) => ServerMessage('old-$i', DateTime(2026, 10, 27, 12, 18 - i), '历史问题$i', MessageSender.human,
            MessageType.text, null, false, []));
    final shared = MessageProvider(
      fetchMessages: ({chatSessionId}) async => history,
      sendMessage: (text, {chatSessionId, contextConversationIds = const []}) => stream.stream,
    );
    await mount(tester, shared);
    expect(position(tester).extentAfter, lessThan(1));
    position(tester).jumpTo(0);
    await frames(tester);
    expect(position(tester).extentAfter, greaterThan(100));
    await send(tester, '新问题');
    expect(position(tester).extentAfter, lessThan(1));
    expect(find.text('新问题').hitTestable(), findsOneWidget);
    final reply = List.filled(24, '这一段是逐步收到的新回答。').join('\n\n');
    stream.add(ServerMessageChunk('stream', reply, MessageChunkType.data));
    await frames(tester);
    expect(position(tester).extentAfter, lessThan(1));
    position(tester).jumpTo(0);
    await frames(tester);
    final readingOffset = position(tester).pixels;
    stream.add(ServerMessageChunk('stream', '\n\n新的段落。', MessageChunkType.data));
    await frames(tester);
    expect(position(tester).pixels, readingOffset);
    stream.add(done('$reply\n\n新的段落。'));
    await frames(tester);
    expect(position(tester).pixels, readingOffset);
    expect(shared.messages.last.text, '历史问题17');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    shared.dispose();
  });
}
