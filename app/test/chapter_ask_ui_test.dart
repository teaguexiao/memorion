import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:memorion/pages/today_chapters/chapter_ask_context.dart';
import 'package:memorion/pages/today_chapters/ask_page.dart';
import 'package:memorion/providers/chapter_ask_controller.dart';
import 'package:memorion/providers/message_provider.dart';
import 'package:memorion/services/press_to_talk_service.dart';
import 'package:memorion/services/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'support/chapter_ask_fixture.dart';

class _FakeMic implements IMicRecorderService {
  int starts = 0, stops = 0;

  @override
  Future<void> start(
      {bool Function()? shouldStart,
      required Function(Uint8List bytes) onByteReceived,
      Function()? onRecording,
      Function()? onStop,
      Function()? onInitializing}) async {
    starts++;
  }

  @override
  void stop() => stops++;
}

class _FakePtt extends PressToTalkService {
  _FakePtt({Future<bool>? started}) : _started = started ?? Future.value(true);
  final Future<bool> _started;
  final ended = Completer<String?>();
  bool endCalled = false;

  @override
  Future<bool> startSession(
          {String language = 'zh', int sampleRate = 16000, String codec = 'pcm16', bool showOverlay = true}) =>
      _started;

  @override
  bool get hasAudioData => true;

  @override
  Future<String?> endSession() {
    endCalled = true;
    return ended.future;
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });
  Future<void> mount(WidgetTester tester, ChapterAskController Function() factory,
      {double width = 390,
      double height = 844,
      double scale = 1,
      bool reduced = false,
      bool longChapter = true,
      Locale locale = const Locale('zh')}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);
    final sources = [source('a', long: longChapter), source('b')];
    await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: reduced),
            child: child!),
        home: ChapterDetailPage(
            conversation: sources.first,
            sources: sources,
            chapter: TimelineChapter(
                start: sources.first.startedAt!,
                end: sources.last.finishedAt!,
                durationSeconds: 5400,
                speechSeconds: 5400,
                sourceConversationIds: const ['a', 'b', 'c'],
                title: '上午和团队的固件拉锯战',
                overview: sources.first.structured.overview,
                emoji: '',
                firstPersonObservation: '',
                rolledUp: true),
            askControllerFactory: factory)));
    await tester.pump();
  }

  testWidgets('chapter answer appears in main Chat and manual clear resets both entries', (tester) async {
    final shared = MessageProvider(
        fetchMessages: ({chatSessionId}) async => [],
        sendMessage: (text, {chatSessionId, contextConversationIds = const []}) => Stream.value(done('预算370元，共享回答')),
        clearMessages: ({chatSessionId}) async => []);
    final sources = [source('a')];
    Widget page(Widget child) => ChangeNotifierProvider.value(
        value: shared,
        child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: child));
    await tester.pumpWidget(page(AskPage(
        chapterContext: ChapterAskContext(title: '预算讨论', subtitle: '', conversationIds: ['a'], sources: sources))));
    await tester.pumpAndSettle();
    expect(find.text('预算370元，共享回答'), findsOneWidget);
    await tester.pumpWidget(page(const AskPage(key: Key('main-chat'))));
    await tester.pumpAndSettle();
    expect(find.text('预算370元，共享回答'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(shared.messages, isEmpty);
    expect(find.text('预算370元，共享回答'), findsNothing);
    expect(SharedPreferencesUtil().getCachedMessagesForSession(null), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fast first send waits for stored shared history', (tester) async {
    final history = Completer<List<ServerMessage>>();
    var sends = 0;
    final shared = MessageProvider(
        fetchMessages: ({chatSessionId}) => history.future,
        sendMessage: (text, {chatSessionId, contextConversationIds = const []}) {
          sends++;
          return Stream.value(done('新回答'));
        });
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: shared,
        child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: AskPage())));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '新问题');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(sends, 0);
    history
        .complete([ServerMessage('old', DateTime(2026), '之前的回答', MessageSender.ai, MessageType.text, null, false, [])]);
    await tester.pumpAndSettle();
    expect(sends, 1);
    expect(find.text('之前的回答'), findsOneWidget);
    expect(find.text('新回答'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('current reading shrinks into exact button anchor, card lands before buffered reply, back keeps scroll',
      (tester) async {
    int creations = 0;
    List<String>? ids;
    await mount(
        tester,
        () => ChapterAskController(MessageProvider(fetchMessages: ({chatSessionId}) async {
              creations++;
              return [];
            }, sendMessage: (text, {chatSessionId, contextConversationIds = const []}) {
              ids = contextConversationIds;
              return Stream.value(done('BUFFERED_REPLY'));
            })));
    final button = find.byKey(const Key('continue-chat'));
    expect(tester.getRect(button), const Rect.fromLTWH(312, 732, 60, 60));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -420));
    await tester.pumpAndSettle();
    final offset = scroll.position.pixels;
    expect(offset, greaterThan(100));
    final detailRoute = ModalRoute.of(tester.element(find.byType(ChapterDetailPage)))!;
    final entryCenter = tester.getCenter(button);
    await tester.tap(button);
    // A second tap before the next frame must not stack another Ask; later taps hit the handoff's blocker.
    tester.widget<InkWell>(button).onTap!();
    await tester.pump();
    await tester.tapAt(entryCenter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    // The real entry hides while the route draws its lifting cloud in the same place.
    expect(button, findsNothing);
    expect(tester.getCenter(find.byKey(const Key('continue-chat-handoff'))), entryCenter);
    final mountedReading = tester.state<ScrollableState>(
        find.descendant(of: find.byKey(const Key('continue-source-layer')), matching: find.byType(Scrollable)).first);
    expect(identical(mountedReading, scroll), isTrue);
    expect(mountedReading.position.pixels, offset);
    expect(tester.widget<Transform>(find.byKey(const Key('continue-detail-transform'))).transform.storage[0],
        closeTo(.95, .001));
    await tester.pump(const Duration(milliseconds: 580));
    expect(tester.widget<Transform>(find.byKey(const Key('continue-detail-transform'))).transform.storage[0],
        closeTo(.055, .001));
    expect(tester.getCenter(find.byKey(const Key('continue-detail-transform'))), const Offset(342, 762));
    expect(find.text('BUFFERED_REPLY'), findsNothing);
    await tester.pump(const Duration(milliseconds: 350));
    final flying = tester.getTopLeft(find.byKey(const Key('chapter-context-card'))).dy;
    expect(flying, greaterThan(300));
    expect(find.text('BUFFERED_REPLY'), findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(tester.getRect(find.byKey(const Key('chapter-context-card'))), const Rect.fromLTWH(148, 120, 226, 96));
    expect(find.text('BUFFERED_REPLY'), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('chapter-context-strip'))), const Rect.fromLTWH(16, 724, 358, 26));
    expect(tester.getRect(find.byKey(const Key('chapter-composer'))), const Rect.fromLTWH(16, 760, 358, 48));
    expect(find.byKey(const Key('continue-chat-handoff')), findsNothing);
    expect(creations, 1);
    expect(ids, ['a', 'b', 'c']);
    expect(find.text('已关联这次对话'), findsOneWidget);
    // The duration text carries its own separator; the card must not show a doubled one.
    final subtitle = tester
        .widgetList<Text>(
            find.descendant(of: find.byKey(const Key('chapter-context-card')), matching: find.byType(Text)))
        .last
        .data!;
    expect(subtitle, contains(' · '));
    expect(subtitle, isNot(contains('· ·')));
    // Same level as the main-menu entry: Ask is its own page above the chapter, not a layer inside it.
    final askRoute = ModalRoute.of(tester.element(find.byType(AskPage)))!;
    expect(askRoute, isNot(same(detailRoute)));
    expect(askRoute.isCurrent, isTrue);
    expect(find.byType(AskPage, skipOffstage: false), findsOneWidget);
    await tester.tap(find.byKey(const Key('back-to-chapter')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await tester.pump();
    expect(find.byType(AskPage, skipOffstage: false), findsNothing);
    expect(scroll.position.pixels, offset);
    expect(identical(tester.state<ScrollableState>(find.byType(Scrollable).first), scroll), isTrue);
    expect(button, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS edge swipe returns to the chapter like any other page and shows its entry underneath',
      (tester) async {
    await mount(
        tester,
        () => ChapterAskController(MessageProvider(
            fetchMessages: ({chatSessionId}) async => [],
            sendMessage: (text, {chatSessionId, contextConversationIds = const []}) => Stream.value(done('ANSWER')))));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    final offset = scroll.position.pixels;
    await tester.tap(find.byKey(const Key('continue-chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1900));
    await tester.pumpAndSettle();
    expect(find.text('ANSWER'), findsOneWidget);
    final swipe = await tester.startGesture(const Offset(5, 400));
    await swipe.moveBy(const Offset(40, 0));
    await swipe.moveBy(const Offset(120, 0));
    await tester.pump();
    // Mid-swipe the chapter is revealed in its normal state (no shrink), entry included.
    expect(find.byKey(const Key('continue-detail-transform')), findsNothing);
    expect(find.byKey(const Key('continue-chat')), findsOneWidget);
    await swipe.moveBy(const Offset(180, 0));
    await swipe.up();
    await tester.pumpAndSettle();
    expect(find.byType(AskPage, skipOffstage: false), findsNothing);
    expect(scroll.position.pixels, offset);
    expect(identical(tester.state<ScrollableState>(find.byType(Scrollable).first), scroll), isTrue);
    expect(find.byKey(const Key('continue-chat')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('any visible invitation hides the floating entry; leaving the viewport restores it', (tester) async {
    await mount(tester, () => ChapterAskController(MessageProvider()));
    final invitation = find.byKey(const Key('chapter-ask-invitation'));
    final floating = find.byKey(const Key('continue-chat'));
    final reader = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final viewport = tester.getRect(find.byType(SingleChildScrollView).first);
    final firstVisibleOffset = tester.getTopLeft(invitation).dy - viewport.bottom;
    expect(floating, findsOneWidget);

    // One pixel outside / inside the real clipped viewport, without debounce.
    reader.position.jumpTo(firstVisibleOffset - 1);
    await tester.pump();
    await tester.pump();
    expect(floating, findsOneWidget);
    reader.position.jumpTo(firstVisibleOffset + 1);
    await tester.pump();
    await tester.pump();
    expect(floating, findsNothing);
    reader.position.jumpTo(firstVisibleOffset - 1);
    await tester.pump();
    await tester.pump();
    expect(floating, findsOneWidget);
    reader.position.jumpTo(reader.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(floating, findsNothing);
    expect(tester.getSize(invitation), const Size(358, 72));
    expect(tester.takeException(), isNull);
  });

  testWidgets('invitation shrinks straight down, uses complete context and preserves bottom reading', (tester) async {
    int creations = 0;
    List<String>? ids;
    final calls = <String>[];
    await mount(
        tester,
        () => ChapterAskController(MessageProvider(
              fetchMessages: ({chatSessionId}) async {
                creations++;
                return [];
              },
              sendMessage: (text, {chatSessionId, contextConversationIds = const []}) {
                ids = contextConversationIds;
                calls.add('$chatSessionId:$text');
                return Stream.value(done('INVITATION_REPLY'));
              },
            )));
    final reader = tester.state<ScrollableState>(find.byType(Scrollable).first);
    reader.position.jumpTo(reader.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final offset = reader.position.pixels;
    final invitation = find.byKey(const Key('chapter-ask-invitation'));
    final rect = tester.getRect(invitation);
    // The handoff transform only wraps the chapter while Ask is on its way in or out.
    final detail = find.byKey(const Key('continue-detail-transform'));
    expect(detail, findsNothing);
    final readingCenter = tester.getCenter(find.byType(ChapterDetailPage));
    expect(rect.center.dx, readingCenter.dx);
    expect(rect.center.dy, greaterThan(readingCenter.dy));
    expect(find.byKey(const Key('continue-chat')), findsNothing);
    await tester.tap(invitation);
    await tester.pump();
    await tester.tap(invitation, warnIfMissed: false); // Reading ignores further taps during the handoff.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 420));
    final shrinkingCenter = tester.getCenter(detail);
    expect(shrinkingCenter.dx, closeTo(readingCenter.dx, .01));
    expect(shrinkingCenter.dy, greaterThan(readingCenter.dy));
    expect(shrinkingCenter.dy, lessThan(rect.center.dy));
    await tester.pump(const Duration(milliseconds: 340));
    expect(find.byKey(const Key('continue-chat')), findsNothing);
    expect(tester.getCenter(detail), rect.center);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(creations, 1);
    expect(ids, ['a', 'b', 'c']);
    expect(find.text('已关联这次对话'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ask-input')), '这段对话还有哪些细节？');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(calls.length, 2);
    expect(calls.every((call) => call.startsWith('null:')), isTrue);
    await tester.tap(find.byKey(const Key('back-to-chapter')));
    await tester.pumpAndSettle();
    expect(reader.position.pixels, offset);
    expect(identical(tester.state<ScrollableState>(find.byType(Scrollable).first), reader), isTrue);
    expect(find.byKey(const Key('continue-chat')), findsNothing);
    reader.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue-chat')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short chapter shows invitation immediately and hides the floating entry', (tester) async {
    await mount(tester, () => ChapterAskController(MessageProvider()), longChapter: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chapter-ask-invitation')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('continue-chat')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resized English invitation wraps at large text and recalculates entry visibility', (tester) async {
    await mount(tester, () => ChapterAskController(MessageProvider()),
        locale: const Locale('en'), scale: 1.8, height: 1000);
    await tester.pumpAndSettle();
    final invitation = find.byKey(const Key('chapter-ask-invitation'));
    final reader = tester.state<ScrollableState>(find.byType(Scrollable).first);
    reader.position.jumpTo(reader.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue-chat')), findsNothing);
    expect(tester.getSize(invitation).height, greaterThanOrEqualTo(72));
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    reader.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue-chat')), findsOneWidget);
    reader.position.jumpTo(reader.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue-chat')), findsNothing);
    expect(tester.getSize(invitation).width, 288);
    expect(tester.takeException(), isNull);
  });

  testWidgets('link failure shows retry and never shows linked; retry confirms context', (tester) async {
    int attempts = 0;
    await mount(
        tester,
        () => ChapterAskController(MessageProvider(
            fetchMessages: ({chatSessionId}) async {
              if (++attempts == 1) throw StateError('offline');
              return [];
            },
            sendMessage: (text, {chatSessionId, contextConversationIds = const []}) =>
                Stream.value(done('RECOVERED')))));
    await tester.tap(find.byKey(const Key('continue-chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1900));
    await tester.pump();
    expect(find.text('已关联这次对话'), findsNothing);
    expect(find.byKey(const Key('retry-chapter-chat')), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry-chapter-chat')));
    await tester.pump();
    await tester.pump();
    expect(find.text('已关联这次对话'), findsOneWidget);
    expect(find.text('RECOVERED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching apps keeps the same Ask page, its unsent draft and the in-flight reply', (tester) async {
    int creations = 0, cancels = 0;
    final streams = <StreamController<ServerMessageChunk>>[];
    final shared = MessageProvider(fetchMessages: ({chatSessionId}) async {
      creations++;
      return [];
    }, sendMessage: (text, {chatSessionId, contextConversationIds = const []}) {
      final stream = StreamController<ServerMessageChunk>(onCancel: () {
        cancels++;
      });
      streams.add(stream);
      return stream.stream;
    });
    await mount(tester, () => ChapterAskController(shared));
    await tester.tap(find.byKey(const Key('continue-chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1900));
    final ask = tester.state(find.byType(AskPage));
    await tester.enterText(find.byKey(const Key('ask-input')), '还没发出去的草稿');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(identical(tester.state(find.byType(AskPage)), ask), isTrue);
    expect(tester.widget<TextField>(find.byKey(const Key('ask-input'))).controller!.text, '还没发出去的草稿');
    expect(cancels, 0);
    expect(creations, 1);
    expect(streams.length, 1);
    streams.single.add(done("BACKGROUND_REPLY"));
    await tester.pump();
    expect(find.text('BACKGROUND_REPLY'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    for (final stream in streams) {
      unawaited(stream.close());
    }
  });

  testWidgets('small screen, large text, keyboard and reduced motion stay within layout', (tester) async {
    await mount(
        tester,
        () => ChapterAskController(MessageProvider(
            fetchMessages: ({chatSessionId}) async => [],
            sendMessage: (text, {chatSessionId, contextConversationIds = const []}) => Stream.value(done('ANSWER')))),
        width: 320,
        height: 640,
        scale: 1.8,
        reduced: true);
    await tester.tap(find.byKey(const Key('continue-chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.widget<Transform>(find.byKey(const Key('continue-detail-transform'))).transform.storage[0], 1);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('ANSWER'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byKey(const Key('ask-input')), '这是一条足够长的多行问题。\n请解释上下文。');
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();
    expect(tester.getRect(find.byKey(const Key('chapter-composer'))).bottom, greaterThan(300));
    expect(tester.getRect(find.byKey(const Key('chapter-composer'))).bottom, lessThanOrEqualTo(380));
    expect(tester.takeException(), isNull);
  });

  group('voice input follows the app to the background', () {
    const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          permissions, (call) async => call.method == 'requestPermissions' ? {7: 1} : 1); // microphone → granted
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(permissions, null);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    Future<void> mountAsk(WidgetTester tester, _FakeMic mic, _FakePtt ptt) async {
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: MessageProvider(fetchMessages: ({chatSessionId}) async => [])),
            ChangeNotifierProvider<PressToTalkService>.value(value: ptt),
          ],
          child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: AskPage(mic: mic))));
      await tester.pumpAndSettle();
    }

    testWidgets('leaving the app stops listening and keeps what was heard as the draft', (tester) async {
      final mic = _FakeMic();
      final ptt = _FakePtt();
      await mountAsk(tester, mic, ptt);
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await tester.pump();
      expect(mic.starts, 1);
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
      // Control Center or an incoming-call banner only makes the app inactive: keep listening.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(mic.stops, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(mic.stops, 1);
      expect(ptt.endCalled, isTrue);
      ptt.ended.complete('刚才说到一半的话');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const Key('ask-input'))).controller!.text, '刚才说到一半的话');
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('leaving while voice input is still connecting stops it as soon as it starts', (tester) async {
      final mic = _FakeMic();
      final connected = Completer<bool>();
      final ptt = _FakePtt(started: connected.future);
      await mountAsk(tester, mic, ptt);
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await tester.pump();
      expect(mic.starts, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(mic.stops, 0); // still connecting: the start path closes it
      connected.complete(true);
      await tester.pump();
      expect(mic.stops, 1);
      expect(ptt.endCalled, isTrue);
      ptt.ended.complete(null);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  test('quote must be verbatim in a single recording segment', () {
    final c = source('a');
    c.structured.highlights = ['不存在的原话'];
    final scope = ChapterAskContext(title: 't', subtitle: 's', conversationIds: ['a'], sources: [c]);
    expect(scope.verifiedQuote, isNull);
    c.structured.highlights = ['我们慢一点没关系，别让用户升级变砖。'];
    expect(scope.verifiedQuote?.conversationId, 'a');
  });
}
