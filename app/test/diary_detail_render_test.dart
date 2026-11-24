import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/pages/today_chapters/diary_detail_page.dart';

/// 日记详情页真的把段落 / 加粗 / 引语 / 便签画出来了，而不是解析对了却仍按纯 Text 渲染。
///
/// 只测无配图的日记：有配图时 hero 会碰 `DiaryImageCache.instance`，单测没有 path_provider
/// 原生侧（见 diary_share_hero_and_image_actions_test 的说明）。正文渲染与配图无关。
///
/// Run: cd app && flutter test test/diary_detail_render_test.dart
void main() {
  ServerMessage diary(String text) => ServerMessage(
        'd1',
        DateTime(2026, 10, 20),
        text,
        MessageSender.ai,
        MessageType.daySummary,
        null,
        false,
        [],
        emotionTitle: '标题',
      );

  Widget app(ServerMessage m, {double textScale = 1}) => MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: DiaryDetailPage(moment: m, gradientIndex: 0),
      );

  /// 页面上所有 RichText 的可见文字（Text 与 Text.rich 最终都落到 RichText）。
  String visible(WidgetTester tester) =>
      tester.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).join('\n');

  const journal = '和小林把发布时间定在了**周五**，拖了两周的事总算落地。\n\n'
      '晚上妈妈打电话来，说的第一句是：\n\n'
      '> "别太晚睡"\n\n'
      '### 明天记得\n\n'
      '- 把发布说明发给小林';

  const legacy = '### 今日亮点\n\n今天把方向收拢了。\n\n'
      '### 关键跟进事项\n\n1. 明天把纪要发出去。\n2. 跟进演示反馈。\n\n'
      '### 今日决定\n\n定了先做 iOS。';

  testWidgets('journal：加粗是真加粗、引语与明日便签可见、没有 markdown 记号', (tester) async {
    await tester.pumpWidget(app(diary(journal)));
    await tester.pumpAndSettle();

    final text = visible(tester);
    expect(text, contains('"别太晚睡"'));
    expect(text, contains('明天记得'));
    expect(text, contains('把发布说明发给小林'));
    for (final marker in ['**', '### ', '> ']) {
      expect(text, isNot(contains(marker)), reason: '「$marker」以字面量出现在页面上');
    }
    expect(text, isNot(contains('这天你还提到')), reason: '列表不再被统一抽到文末');

    final boldSpans = <String>[];
    for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
      r.text.visitChildren((span) {
        if (span is TextSpan && span.style?.fontWeight == FontWeight.w600 && span.text == '周五') {
          boldSpans.add(span.text!);
        }
        return true;
      });
    }
    expect(boldSpans, ['周五'], reason: '加粗必须落成独立的粗体 span，而不是把 ** 去掉了事');
  });

  testWidgets('legacy：小标题保留，跟进事项留在自己的标题下且带编号', (tester) async {
    await tester.pumpWidget(app(diary(legacy)));
    await tester.pumpAndSettle();

    final text = visible(tester);
    for (final s in ['今日亮点', '关键跟进事项', '今日决定', '明天把纪要发出去。', '跟进演示反馈。', '定了先做 iOS。']) {
      expect(text, contains(s));
    }
    expect(text, contains('1.'));
    expect(text.indexOf('关键跟进事项'), lessThan(text.indexOf('明天把纪要发出去。')));
    expect(text.indexOf('明天把纪要发出去。'), lessThan(text.indexOf('今日决定')),
        reason: '条目必须在自己的标题下面，而不是被搬到页尾');
  });

  testWidgets('窄屏 + 两倍大字不溢出', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    for (final text in [journal, legacy]) {
      await tester.pumpWidget(app(diary(text), textScale: 2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 滚到底，确保下方的便签 / 列表也真的 layout 过。
      await tester.drag(find.byType(ListView), const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}
