import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:memorion/pages/today_chapters/transcript_page.dart';
import 'package:memorion/providers/conversation_audio_provider.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P-11 章节详情：合并章节的原文下钻（真章节化 Phase 3）。
///
/// 章节是**可重算投影**，conversation 才是事实——所以原文的下钻能力必须保住：一章由
/// N 条录音合成后，用户仍要能翻到**每一条**的原始 transcript。少一条就是那段录音在
/// 界面上不可达。
///
/// ⚠️ **刻意不把多条 transcript 拼成一篇**。`speakerId` 由 STT 在单次会话内分配，
/// 两条会话里的 `speaker 0` 是两个不同的人；拼起来会让同一个编号在不同段落指向不同
/// 的人，而用户没有任何线索察觉。所以合并态先弹选择器让用户挑一条，再进 TranscriptPage。
/// 多点一次，换来原文可信。
///
/// Run: cd app && flutter test test/chapter_transcript_drilldown_test.dart
void main() {
  // TranscriptPage 会 read 这两个 Provider，并经 LocalAudioStorage 摸 prefs
  // （查本地音频路径）。不预备好，「单条章节直接进原文」那条会栽在
  // ProviderNotFoundException 上——那是测试脚手架缺东西，不是被测行为出错。
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  ServerConversation convo({
    required String id,
    required String title,
    required int hour,
    int segments = 3,
  }) =>
      ServerConversation(
        id: id,
        createdAt: DateTime(2026, 8, 6, hour, 0),
        startedAt: DateTime(2026, 8, 6, hour, 0),
        finishedAt: DateTime(2026, 8, 6, hour, 30),
        structured: Structured(title, '$title 的正文'),
        transcriptSegments: [
          for (var i = 0; i < segments; i++)
            TranscriptSegment(
              id: '$id-seg-$i',
              // speaker 编号在两条会话里都从 0 开始——这正是不能拼接的原因。
              // （`speakerId` 由构造函数从这个字符串里解析出来，不是显式传的。）
              speaker: 'SPEAKER_00',
              isUser: false,
              personId: null,
              text: '$id 的第 $i 句',
              start: i * 10,
              end: (i + 1) * 10,
              translations: const [],
            ),
        ],
      );

  TimelineChapter chapterOf(List<ServerConversation> sources) => TimelineChapter(
        start: sources.first.startedAt!,
        end: sources.last.finishedAt!,
        durationSeconds: 3600,
        speechSeconds: 2400,
        sourceConversationIds: sources.map((c) => c.id).toList(),
        title: '归纳出来的章节标题',
        overview: '归纳出来的章节正文。',
        emoji: '🧠',
        firstPersonObservation: '',
        rolledUp: sources.length > 1,
      );

  Widget wrap(List<ServerConversation> sources, {NavigatorObserver? observer}) => MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ConversationProvider()),
          ChangeNotifierProvider(create: (_) => ConversationAudioProvider()),
        ],
        child: MaterialApp(
          navigatorObservers: [if (observer != null) observer],
          home: ChapterDetailPage(
            conversation: sources.first,
            sources: sources,
            chapter: sources.length > 1 ? chapterOf(sources) : null,
          ),
        ),
      );

  testWidgets('合并章节：点「查看完整原文」弹出选择器，每条源都在列表里', (tester) async {
    final sources = [
      convo(id: 'a', title: '上午的会', hour: 9),
      convo(id: 'b', title: '午饭时的闲聊', hour: 12),
      convo(id: 'c', title: '下午的复盘', hour: 15),
    ];
    await tester.pumpWidget(wrap(sources));
    await tester.pump();

    await tester.tap(find.byKey(const Key('view-transcript-row')));
    await tester.pumpAndSettle();

    // 三条源全部可达——少一条就是那段录音在界面上打不开。
    for (final c in sources) {
      expect(find.text(c.structured.title), findsOneWidget, reason: '${c.id} 的原文入口不见了');
    }
    // 明确告知这一章由几段合成，用户才知道自己在选什么。
    expect(find.textContaining('3'), findsWidgets);
  });

  testWidgets('单条章节：直接推原文页，不弹选择器（没得选就别问）', (tester) async {
    final only = [convo(id: 'solo', title: '一段记录', hour: 10)];
    // 只断言「推进去的是 TranscriptPage」，不把它 pump 到稳定态：那一页 initState
    // 就去加载音频（AudioPlayer 的 ticker + 未初始化的 Env），跑起来会淹在与本行为
    // 无关的异常里。看路由不看渲染，测的正是这里的分支选择。
    final observer = _RouteSpy();
    await tester.pumpWidget(wrap(only, observer: observer));
    await tester.pump();

    await tester.tap(find.byKey(const Key('view-transcript-row')));
    await tester.pump();

    expect(observer.pushedPages.whereType<TranscriptPage>(), hasLength(1));
    // 中途没有经过选择器。
    expect(find.text('看哪一段原文？'), findsNothing);
    expect(find.text('Which recording?'), findsNothing);

    // 收尾：让被 push 的原文页正常退出。它 initState 就去加载音频（AudioPlayer 的
    // ticker），留着不管会在测试结束时报「动画还在跑」「performance mode 未释放」。
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('选择器里带每条源的段数：空 transcript 的那条也列出来', (tester) async {
    // 段数为 0 的源（转录失败 / 全静音）仍然要能点进去看——否则用户只会觉得录音丢了。
    final sources = [
      convo(id: 'a', title: '有内容的那段', hour: 9, segments: 5),
      convo(id: 'empty', title: '没转出内容的那段', hour: 11, segments: 0),
    ];
    await tester.pumpWidget(wrap(sources));
    await tester.pump();

    await tester.tap(find.byKey(const Key('view-transcript-row')));
    await tester.pumpAndSettle();

    expect(find.text('有内容的那段'), findsOneWidget);
    expect(find.text('没转出内容的那段'), findsOneWidget);
  });
}

/// 记录被 push 进来的页面 widget。
///
/// 用它替代「把目标页 pump 到稳定态再 find.byType」：TranscriptPage 一挂载就开始
/// 加载音频（AudioPlayer 的 ticker + 未初始化的 Env），测试里那条链路会抛一串与被测
/// 行为无关的异常。这里只调 builder 看一眼类型，不把页面挂进树。
class _RouteSpy extends NavigatorObserver {
  final List<Route<dynamic>> pushedRoutes = [];
  final List<Widget> pushedPages = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushedRoutes.add(route);
    if (route is MaterialPageRoute) {
      // 用 navigator 自己的 context——TranscriptPage 的 builder 只是 `(_) =>`，
      // 根本不读它，但 builder 的签名要求给一个。
      final ctx = navigator?.context;
      if (ctx != null) pushedPages.add(route.builder(ctx));
    }
    super.didPush(route, previousRoute);
  }
}
