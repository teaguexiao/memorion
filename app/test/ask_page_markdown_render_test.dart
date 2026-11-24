import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// 回想页（ask_page）AI 回复必须走 markdown 渲染。
///
/// 后端 agent 的答复带 `**加粗**`/`###` 标题/`-` 列表/`[来源](url)`，早先气泡用纯
/// [Text] 渲染，用户看到的是字面上的 `**` 和 `###`。这里锁两件事：markdown 的
/// 语义确实生效（不是把符号当正文），以及气泡不会被改回纯 Text。
void main() {
  /// 与 _AskPageState._markdownBody 保持一致的样式，测的是同一套渲染契约。
  const base = TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.6, color: JXB.textPrimary);

  Widget wrap(String data) => MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data: data,
            selectable: true,
            styleSheet: MarkdownStyleSheet(
              p: base,
              strong: base.copyWith(fontWeight: FontWeight.w700),
              em: base.copyWith(fontStyle: FontStyle.italic),
              listBullet: base,
              h3: base.copyWith(fontSize: 15, fontWeight: FontWeight.w700, height: 1.4),
              pPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );

  /// selectable: true 时 MarkdownBody 用 SelectableText.rich 渲染每个块（树里没有
  /// RichText），这里把各块渲染后的纯文字拼起来，用于断言「标记符号没有出现在
  /// 可见文字里」。
  String visibleText(WidgetTester tester) {
    final buffer = StringBuffer();
    for (final st in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
      buffer.write(st.textSpan?.toPlainText() ?? st.data ?? '');
      buffer.write('\n');
    }
    return buffer.toString();
  }

  /// 收集所有渲染出的 TextSpan，用于断言某片段拿到了预期样式。
  List<TextSpan> spansOf(WidgetTester tester) {
    final spans = <TextSpan>[];
    for (final st in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
      st.textSpan?.visitChildren((span) {
        if (span is TextSpan) spans.add(span);
        return true;
      });
    }
    return spans;
  }

  testWidgets('**加粗** 渲染成粗体，不显示星号', (tester) async {
    await tester.pumpWidget(wrap('英伟达股价 **220 美元**，市值 5.3 万亿。'));

    final text = visibleText(tester);
    expect(text, contains('220 美元'));
    expect(text, isNot(contains('**')), reason: '星号应被解析掉，而不是当正文显示');

    // 粗体片段确实拿到了 w700
    final bold = spansOf(tester).where((s) => s.style?.fontWeight == FontWeight.w700).toList();
    expect(bold, isNotEmpty, reason: '应有加粗片段');
    expect(bold.map((s) => s.text ?? '').join(), contains('220 美元'));
  });

  testWidgets('### 标题渲染成标题样式，不显示井号', (tester) async {
    await tester.pumpWidget(wrap('### 本周要点\n正文一句。'));

    final text = visibleText(tester);
    expect(text, contains('本周要点'));
    expect(text, isNot(contains('###')));
  });

  testWidgets('- 列表渲染成项目符号，不显示连字符前缀', (tester) async {
    await tester.pumpWidget(wrap('- 第一项\n- 第二项'));

    final text = visibleText(tester);
    expect(text, contains('第一项'));
    expect(text, contains('第二项'));
    // 连字符被解析成列表结构（bullet 由 listBullet 单独渲染），不再是正文里的 "- "
    expect(text, isNot(contains('-')), reason: '连字符应被解析掉，而不是当正文显示');
  });

  testWidgets('[来源](url) 渲染成链接文字，不显示中括号与地址', (tester) async {
    await tester.pumpWidget(wrap('数据来自 [Yahoo Finance](https://finance.yahoo.com)。'));

    final text = visibleText(tester);
    expect(text, contains('Yahoo Finance'));
    expect(text, isNot(contains('https://finance.yahoo.com')));
    expect(text, isNot(contains('](')));
  });

  test('ask_page 的 AI 气泡走 _markdownBody，未回退成纯 Text', () {
    final src = File('lib/pages/today_chapters/ask_page.dart').readAsStringSync();

    expect(src, contains('_markdownBody('), reason: 'markdown 渲染方法应存在且被调用');
    expect(
      src,
      contains("_markdownBody(text.isEmpty ? '…' : text)"),
      reason: 'AI 气泡应把答复交给 markdown 渲染，而不是 Text(...)',
    );
    // 用户输入不该按 markdown 解析，_userBubble 保持纯 Text。
    expect(src, contains('Widget _userBubble('), reason: '用户气泡应仍是纯 Text 渲染');
  });
}
