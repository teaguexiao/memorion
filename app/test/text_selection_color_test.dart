import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/theme/jxb_tokens.dart';

import 'helpers/source_stripper.dart';

/// 全局主题（选区高亮 + 浅色兜底）的不变式。
///
/// ## 为什么需要它们
///
/// 全局主题曾是不透明的 `Colors.deepPurple`。**它不只影响深色壳**——页面级
/// `Theme(data: ThemeData.light(...).copyWith(...))` 只要不声明 `textSelectionTheme`，
/// `Theme` 注入 `DefaultSelectionStyle` 时取的就是
/// `data.textSelectionTheme.selectionColor ?? 外层值`（Flutter `material/theme.dart`），
/// 于是**所有**浅色页面静默继承那个紫色，选中后正文被色块糊住。
///
/// 而 `SelectableText`（`flutter_markdown` 的 `selectable: true` 内部就是它）读的是
/// `DefaultSelectionStyle`，**不是** `TextSelectionTheme`——所以「在页面里写一句
/// `textSelectionTheme`」这种直觉修法只对 `TextField` 成立，对正文选区无效的话会
/// 表现成「改了没效果」。
void main() {
  test('全局兜底主题是浅色——深色兜底会从各种缝里漏到浅色页面上', () {
    // 2026-08-20 之前全局是 `ColorScheme.dark` + `themeMode: ThemeMode.dark`，
    // 留自旧深色壳。旧壳早就没有入口了，但主题不是"壳的一部分"——它是兜底，
    // 漏进浅色页面的形式包括：不透明紫选区、白光标（白底上隐形）、深色 SnackBar、
    // 以及 getDialog / ConfirmationDialog / 充电指南这些没有自带 Theme 的通用弹框。
    //
    // ⚠️ 这条断言必须剥注释后再扫：上面这段话本身就含 `ColorScheme.dark` 字样，
    // 不剥的话把 main.dart 改回深色也照样绿（source_stripper 的文档里有同类教训）。
    final code = stripCommentsAndStrings(File('lib/main.dart').readAsStringSync());
    expect(code, contains('ColorScheme.light'));
    expect(code, isNot(contains('ColorScheme.dark')));
    expect(code, contains('ThemeMode.light'));
    expect(code, isNot(contains('ThemeMode.dark')));
  });

  test('选区色本身必须半透明——不透明色会把选中的文字糊住', () {
    // 判据是 alpha，不是「颜色好不好看」：只有半透明才保证文字仍然可读。
    expect(JXB.textSelection.a, lessThan(1.0));
    expect(JXB.textSelection.a, greaterThan(0.0), reason: '全透明等于没有选区反馈');
  });

  test('整个 lib 里 selectionColor 只在全局主题绑定一次，且值是 JXB.textSelection', () {
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(dartFiles, isNotEmpty, reason: '扫描器一个文件都没扫到，断言等于没跑');

    // 注释里出现 `selectionColor: Colors.deepPurple` 这种举例文字，本身就能满足
    // 断言——所以先剥注释和字符串（见 source_stripper 的文档）。
    final pattern = RegExp(r'selectionColor:\s*([A-Za-z0-9_.]+)');
    final hits = <String, List<String>>{};
    for (final f in dartFiles) {
      final code = stripCommentsAndStrings(f.readAsStringSync());
      for (final m in pattern.allMatches(code)) {
        hits.putIfAbsent(f.path, () => []).add(m.group(1)!);
      }
    }

    expect(hits.keys, ['lib/main.dart'],
        reason: '页面级 Theme 不该再声明选区色（它一定会继承全局值），多一处就是多一份要同步的真相源');
    expect(hits['lib/main.dart'], ['JXB.textSelection'],
        reason: '全局选区色必须绑定到 token，硬编码色值会绕开上面那条半透明断言');
  });

  testWidgets('页面级 light Theme 不声明时，正文选区继承全局值', (tester) async {
    // 这条钉的是继承链本身：SelectableText 走 DefaultSelectionStyle，而页面级 Theme
    // 会把它重新注入成 `本层值 ?? 外层值`。链路一旦变了（Flutter 升级、或有人给页面
    // 塞了别的 textSelectionTheme），全局那一处的修复就会静默失效。
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textSelectionTheme: const TextSelectionThemeData(selectionColor: JXB.textSelection),
        ),
        home: Theme(
          // 与 today_chapters 各页面同形状：只 copyWith 配色，不碰 textSelectionTheme。
          data: ThemeData.light(useMaterial3: false).copyWith(
            colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
          ),
          child: const Scaffold(body: SelectableText('选我')),
        ),
      ),
    );

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.selectionColor, JXB.textSelection);
  });
}
