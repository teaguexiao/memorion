import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/utils/markdown_summary_selection.dart';
import 'package:memorion/widgets/summary_markdown.dart';

void main() {
  Widget wrap(String data, {bool selectable = true}) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: SummaryMarkdown(data: data, selectable: selectable))),
      );

  String visibleText(WidgetTester tester) =>
      tester.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? w.textSpan?.toPlainText() ?? '').join('\n');

  List<TextSpan> textSpans(WidgetTester tester) {
    final spans = <TextSpan>[];
    for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
      richText.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) spans.add(span);
        return true;
      });
    }
    return spans;
  }

  testWidgets('ordinary links never make following prose clickable', (tester) async {
    await tester.pumpWidget(wrap('前文 [资料](https://example.com) 普通尾文 **加粗尾文**。'));
    final spans = textSpans(tester);
    expect(spans.singleWhere((s) => s.text == '资料').recognizer, isA<TapGestureRecognizer>());
    for (final text in ['前文', '普通尾文', '加粗尾文']) {
      expect(spans.where((s) => s.text!.contains(text)), isNotEmpty);
      expect(spans.where((s) => s.text!.contains(text)).every((s) => s.recognizer == null), isTrue);
    }
  });

  testWidgets('speaker and web links keep separate tap targets and escaped names', (tester) async {
    const first = 'e0123456789abcdef';
    const second = 'efedcba9876543210';
    final tapped = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SummaryMarkdown(
          data: r'[A\[乙\]\*](speaker:e0123456789abcdef "confirmed") 普通尾文 '
              '[资料](https://example.com) 链接尾文 '
              '[说话人 B](speaker:$second "unconfirmed") 最后尾文',
          onSpeakerTap: (id, _) => tapped.add(id),
        ),
      ),
    ));
    final spans = textSpans(tester);
    final firstName = spans.singleWhere((s) => s.text == 'A[乙]*');
    final secondName = spans.singleWhere((s) => s.text == '说话人 B');
    expect(firstName.style?.decoration, TextDecoration.none);
    expect(secondName.style?.decorationStyle, TextDecorationStyle.dotted);
    (firstName.recognizer as TapGestureRecognizer).onTap!();
    (secondName.recognizer as TapGestureRecognizer).onTap!();
    expect(tapped, [first, second]);
    expect(spans.singleWhere((s) => s.text == '资料').recognizer, isA<TapGestureRecognizer>());
    for (final text in ['普通尾文', '链接尾文', '最后尾文']) {
      expect(spans.where((s) => s.text!.contains(text)), isNotEmpty);
      expect(spans.where((s) => s.text!.contains(text)).every((s) => s.recognizer == null), isTrue);
    }
    await tester.pumpWidget(wrap('更新后 **普通正文**'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('work notes render headings, bold, lists, quotes, code and tables', (tester) async {
    await tester.pumpWidget(wrap('''## 工作会议纪要

### 结论
采用 **方案 A**，保留 *技术假设*。

- 验证吞吐
- 复核成本

1. 完成评测
2. 检查权限

> 尚未明确负责人。

调用 `query()`。

| 事项 | 状态 |
| --- | --- |
| 评测 | 待验证 |
'''));
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    final text = visibleText(tester);
    expect(text, contains('工作会议纪要'));
    expect(text, contains('验证吞吐'));
    expect(text, contains('1.'));
    expect(text, contains('query()'));
    expect(text, isNot(contains('##')));
    expect(text, isNot(contains('**')));
    expect(text, isNot(contains('| --- |')));
    final spans = <TextSpan>[];
    for (final w in tester.widgetList<Text>(find.byType(Text))) {
      w.textSpan?.visitChildren((span) {
        if (span is TextSpan) spans.add(span);
        return true;
      });
    }
    expect(spans.where((s) => s.style?.fontWeight == FontWeight.w700).map((s) => s.text).join(), contains('方案 A'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain life summaries keep selection behavior and literal hashtags', (tester) async {
    const data = '一起散步，聊了今天的安排。C# 和 #标签 是正文。';
    await tester.pumpWidget(wrap(data));
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text(data), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
  });

  testWidgets('share capture renders formatting without selection handles', (tester) async {
    await tester.pumpWidget(wrap('### 分享重点\n\n**实质结论**', selectable: false));
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(SelectionArea), findsNothing);
    expect(visibleText(tester), isNot(contains('**')));
  });

  testWidgets('long notes fit a small screen at increased text scale', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(1.5)),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SummaryMarkdown(
                data: List.filled(12,
                        '## 议题\n\n- **技术方案**与验证结果\n\n```sql\nSELECT a_very_long_column_name FROM a_very_long_table_name;\n```\n')
                    .join('\n')),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  String? replaceSelection(String source, String selected, String replacement, {bool last = false}) {
    final document = MarkdownSummarySource(source);
    final start = last ? document.text.lastIndexOf(selected) : document.text.indexOf(selected);
    return document.selection(start, start + selected.length, selected)?.replaceWith(replacement);
  }

  test('correcting a repeated phrase changes only the selected occurrence', () {
    const source = '## 决策\n\n预算 **100** 万；调整后预算 100 万。';
    expect(replaceSelection(source, '100', '120', last: true), '## 决策\n\n预算 **100** 万；调整后预算 120 万。');
  });

  test('correction inside bold preserves surrounding Markdown', () {
    const source = '### 决策\n\n采用 **ALPHA**，后续验证。';
    expect(replaceSelection(source, 'ALPHA', 'BETA'), '### 决策\n\n采用 **BETA**，后续验证。');
  });

  test('correction spanning formatting leaves valid text and untouched remainder', () {
    const source = '## 结论\n\n前文 **预算**与范围后文。';
    expect(replaceSelection(source, '预算与范围', '新结论'), '## 结论\n\n前文 新结论后文。');
  });

  test('link destinations cannot steal offsets from repeated visible text', () {
    const source = '## 来源\n\n[ALPHA](https://example.com/ALPHA) ALPHA';
    expect(replaceSelection(source, 'ALPHA', 'BETA', last: true), '## 来源\n\n[ALPHA](https://example.com/ALPHA) BETA');
  });

  test('Unicode and decoded entity corrections preserve other source text', () {
    expect(replaceSelection('## 进展\n\n**🧠AI** 评审', 'AI', '模型'), '## 进展\n\n**🧠模型** 评审');
    expect(replaceSelection('## 权限\n\n预算 &amp; 权限', '&', '与'), '## 权限\n\n预算 与 权限');
  });

  test('stale rendered offsets are rejected', () {
    final doc = MarkdownSummarySource('## 决策\n\n**ALPHA**');
    expect(doc.selection(0, 5, 'ALPHA'), isNull);
    expect(doc.selection(-1, 2, '决策'), isNull);
  });

  test('backwards selection edits the same rendered fragment', () {
    const source = '## 决策\n\n采用 **ALPHA**。';
    final doc = MarkdownSummarySource(source);
    final start = doc.text.indexOf('ALPHA');
    expect(doc.selection(start + 5, start, 'ALPHA')?.replaceWith('BETA'), source.replaceFirst('ALPHA', 'BETA'));
  });
}
