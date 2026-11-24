import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/providers/timeline_provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/widgets/jxb_toast.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P-11 章节详情页：编辑入口的存在条件。
///
/// 两条规则，各自防一类回归：
///
/// 1. **正文本身不是编辑入口**。「它的回忆」以只读 SelectableText 展示，点它只会
///    起选区（进而弹「复制 / 修正 / 加入词库」工具条），不能直接变成输入框——正文
///    动辄上千字，误触进编辑态又误碰键盘就会静默改写 AI 摘要。
///
/// 2. 合并章节也可编辑，但修正必须属于章节，不可写入任何一条源会话。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });
  ServerConversation buildConversation({String id = 'test-conversation-id', int hour = 10}) {
    final structured = Structured(
      '一段记录',
      '这是一段用来阅读和选中的正文内容，点击它不应该进入编辑态。',
    );
    return ServerConversation(
      id: id,
      createdAt: DateTime(2026, 7, 25, hour, 0),
      startedAt: DateTime(2026, 7, 25, hour, 0),
      finishedAt: DateTime(2026, 7, 25, hour, 30),
      structured: structured,
    );
  }

  TimelineChapter buildChapter(List<ServerConversation> sources) => TimelineChapter(
        start: sources.first.startedAt!,
        end: sources.last.finishedAt!,
        durationSeconds: 3600,
        speechSeconds: 1800,
        sourceConversationIds: sources.map((c) => c.id).toList(),
        title: '归纳出来的章节标题',
        overview: '归纳出来的章节正文，它不属于任何单条会话。',
        emoji: '🧠',
        firstPersonObservation: '',
        rolledUp: true,
      );

  // 用默认 en locale（app 未接入 flutter_localizations 的全局 delegate）。
  // 本测试只关心编辑触发行为，与文案语言无关。
  Widget feedbackHost(BuildContext context, Widget? child) => ChangeNotifierProvider(
        create: (_) => UndoDeleteController(),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(bottom: 34)),
          child: UndoDeleteHost(child: child!),
        ),
      );

  Widget wrap(ServerConversation conversation, {List<ServerConversation>? sources, TimelineChapter? chapter}) {
    return MaterialApp(
      builder: feedbackHost,
      home: ChapterDetailPage(conversation: conversation, sources: sources, chapter: chapter),
    );
  }

  testWidgets('点击正文 body 不进入编辑态', (tester) async {
    await tester.pumpWidget(wrap(buildConversation()));
    await tester.pump();

    // 正文以只读的 SelectableText 展示，且没有编辑用的 TextField。
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // 点击正文本身。
    await tester.tap(find.byType(SelectableText));
    await tester.pump();

    // 仍然没有进入编辑态（不出现 TextField）。
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('单条章节：点铅笔进入标题编辑态', (tester) async {
    await tester.pumpWidget(wrap(buildConversation()));
    await tester.pump();

    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byKey(const Key('title-edit-pencil')));
    await tester.pump(); // 触发 setState
    await tester.pump(); // 处理 addPostFrameCallback 里的 requestFocus

    // 进入标题编辑态：出现可编辑的 TextField（正文仍是只读 SelectableText）。
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('合并章节：标题铅笔可编辑，预填归纳标题而非锚点标题', (tester) async {
    final sources = [
      buildConversation(id: 'a', hour: 9),
      buildConversation(id: 'b', hour: 10),
    ];
    final chapter = buildChapter(sources);
    await tester.pumpWidget(wrap(sources.first, sources: sources, chapter: chapter));
    await tester.pump();

    expect(find.byKey(const Key('title-edit-pencil')), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // 显示的是后端归纳的标题与正文，不是锚点那条会话自己的。
    expect(find.text(chapter.title), findsOneWidget);
    expect(find.text(sources.first.structured.title), findsNothing);
    expect(find.text(chapter.plainOverview(chinese: true)), findsOneWidget);
    await tester.tap(find.byKey(const Key('title-edit-pencil')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, chapter.title);
  });

  for (final succeeds in [true, false]) {
    testWidgets('合并章节标题保存 ${succeeds ? '成功同步缓存' : '失败保留原文'}，不改源录音', (tester) async {
      final sources = [buildConversation(id: 'a', hour: 9), buildConversation(id: 'b')];
      final chapter = buildChapter(sources);
      final requests = <String?>[];
      final provider = TimelineProvider(updateChapter: ({required chapter, title, overview}) async {
        requests.add(title);
        return succeeds ? TimelineChapter.fromJson({...chapter.toJson(), 'title': title}) : null;
      });
      addTearDown(provider.dispose);
      provider.seedDay(TimelineDay(
          date: '2026-07-25',
          timezone: 'Asia/Shanghai',
          chapters: [chapter],
          sourceConversationIds: ['a', 'b'],
          cache: 'hit',
          computedAt: null));
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: provider, child: wrap(sources.first, sources: sources, chapter: chapter)));
      await tester.tap(find.byKey(const Key('title-edit-pencil')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '修正标题 & A+B?');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(requests, ['修正标题 & A+B?']);
      final expected = succeeds ? '修正标题 & A+B?' : chapter.title;
      expect(find.text(expected), findsOneWidget);
      expect(provider.chaptersFor('2026-07-25').single.title, expected);
      for (final source in sources) {
        expect(source.structured.title, '一段记录');
      }
      if (succeeds) {
        final reopened = TimelineProvider();
        addTearDown(reopened.dispose);
        expect(reopened.chaptersFor('2026-07-25').single.title, expected);
      } else {
        expect(find.text('Failed to save, please retry', findRichText: true), findsOneWidget);
      }
    });
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform 合并正文长按后可修正所选片段，复制和词库入口保留', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final sources = [buildConversation(id: 'a', hour: 9), buildConversation(id: 'b')];
      final chapter = buildChapter(sources);
      String? savedOverview;
      final provider = TimelineProvider(updateChapter: ({required chapter, title, overview}) async {
        savedOverview = overview;
        return TimelineChapter.fromJson({...chapter.toJson(), 'overview': overview});
      });
      addTearDown(provider.dispose);
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            builder: feedbackHost,
            theme: ThemeData(platform: platform),
            home: ChapterDetailPage(conversation: sources.first, sources: sources, chapter: chapter),
          )));
      await tester.longPress(find.byType(SelectableText));
      await tester.pumpAndSettle();
      expect(find.text('Correct'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Add to Vocabulary'), findsOneWidget);
      final value = tester.widget<EditableText>(find.byType(EditableText)).controller.value;
      final selected = value.selection;
      expect(selected.isCollapsed, isFalse);
      await tester.tap(find.text('Correct'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          chapter.plainOverview(chinese: true).substring(selected.start, selected.end));
      await tester.enterText(find.byType(TextField), '修正片段');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final expected = chapter.plainOverview(chinese: true).replaceRange(selected.start, selected.end, '修正片段');
      expect(savedOverview, expected);
      expect(find.text(expected), findsOneWidget);
      expect(sources.first.structured.overview, isNot(expected));
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(JxbToast), findsOneWidget);
      expect(find.text('Saved', findRichText: true), findsOneWidget);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pump();
      final feedback = find.byKey(const ValueKey('feedback_toast'));
      expect(tester.widget<Material>(feedback).color, JxbToast.background);
      expect(tester.getSize(feedback).height, 44);
      expect(tester.getRect(feedback).center.dx, 195);
      expect(tester.getTopLeft(feedback).dy, 700);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(JxbToast), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('取消正文修正不提交也不改变显示', (tester) async {
    final sources = [buildConversation(id: 'a', hour: 9), buildConversation(id: 'b')];
    final chapter = buildChapter(sources);
    var writes = 0;
    final provider = TimelineProvider(updateChapter: ({required chapter, title, overview}) async {
      writes++;
      return chapter;
    });
    addTearDown(provider.dispose);
    await tester.pumpWidget(
        ChangeNotifierProvider.value(value: provider, child: wrap(sources.first, sources: sources, chapter: chapter)));
    await tester.longPress(find.byType(SelectableText));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Correct'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '不应保存');
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text(chapter.plainOverview(chinese: true)), findsOneWidget);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform Markdown正文渲染后仍可长按修正，仅更新合并章节', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final sources = [buildConversation(id: 'a', hour: 9), buildConversation(id: 'b')];
      const markdown = '### 技术评审\n\n决定采用 **ALPHA**，下周验证。\n\n- 保留录音\n- 回归检查';
      final chapter = TimelineChapter.fromJson({...buildChapter(sources).toJson(), 'overview': markdown});
      String? savedOverview;
      final provider = TimelineProvider(updateChapter: ({required chapter, title, overview}) async {
        savedOverview = overview;
        return TimelineChapter.fromJson({...chapter.toJson(), 'overview': overview});
      });
      addTearDown(provider.dispose);
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            builder: feedbackHost,
            theme: ThemeData(platform: platform),
            home: ChapterDetailPage(conversation: sources.first, sources: sources, chapter: chapter),
          )));
      final paragraph = find.byWidgetPredicate((w) => w is Text && w.textSpan?.toPlainText() == '决定采用 ALPHA，下周验证。');
      await tester.pumpAndSettle();
      expect(paragraph, findsOneWidget);
      expect(find.text(markdown), findsNothing);
      final richText = find.descendant(of: paragraph, matching: find.byType(RichText));
      final render = tester.renderObject<RenderParagraph>(richText);
      final box = render.getBoxesForSelection(const TextSelection(baseOffset: 7, extentOffset: 8)).single;
      await tester.longPressAt(render.localToGlobal(box.toRect().center));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Correct'), findsOneWidget);
      expect(find.text('Add to Vocabulary'), findsOneWidget);
      await tester.tap(find.text('Correct'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'ALPHA');
      await tester.enterText(find.byType(TextField), 'BETA');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedOverview, markdown.replaceFirst('ALPHA', 'BETA'));
      expect(sources.first.structured.overview, isNot(savedOverview));
      expect(
          find.byWidgetPredicate((w) => w is Text && w.textSpan?.toPlainText() == '决定采用 BETA，下周验证。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('小屏键盘弹出时长正文修正可滚动保存，失败后保留原文', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final sources = [buildConversation(id: 'a', hour: 9), buildConversation(id: 'b')];
    final chapter = buildChapter(sources);
    var writes = 0;
    final provider = TimelineProvider(updateChapter: ({required chapter, title, overview}) async {
      writes++;
      return null;
    });
    addTearDown(provider.dispose);
    await tester.pumpWidget(
        ChangeNotifierProvider.value(value: provider, child: wrap(sources.first, sources: sources, chapter: chapter)));
    await tester.longPressAt(tester.getTopLeft(find.byType(SelectableText)) + const Offset(16, 12));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Correct'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), List.filled(30, '修正后的长正文').join('\n'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text(chapter.plainOverview(chinese: true)), findsOneWidget);
    expect(find.text('Failed to save, please retry', findRichText: true), findsOneWidget);
  });
}
