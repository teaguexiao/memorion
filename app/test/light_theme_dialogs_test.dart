import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/widgets/confirmation_dialog.dart';
import 'package:memorion/widgets/dialog.dart';

import 'helpers/source_stripper.dart';

/// 通用弹框必须在浅底上可读。
///
/// ## 为什么这几个组件需要断言
///
/// 它们没有自带 `Theme`，配色全靠全局主题兜底——而全局主题到 2026-08-20 之前是
/// 旧深色壳留下的深色。于是弹框文字写成 `Colors.white`、底色写成 `#1F1F25` 都
/// "看起来正常"，因为当时确实弹在深色壳上。
///
/// 现在全线浅色，白字落在白底弹框上就是隐形按钮。而这类回归**没有任何报错**：
/// 布局、点击、文案全对，只是看不见。
///
/// ## 为什么不在模拟器上验
///
/// 这三个弹框在真实账号上都不可安全触达：`getDialog` 在删除账户页要勾选后才弹，
/// 而它的确认键会真删账号；`ConfirmationDialog` 要有已配对设备 + 有新固件；充电
/// 指南要有已配对设备（模拟器没有 BLE）。所以改成渲染断言。
Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('getDialog：按钮文字用品牌色/次文本色，不是白色', (tester) async {
    await tester.pumpWidget(_wrap(
      Builder(builder: (ctx) => getDialog(ctx, () {}, () {}, '标题', '内容') as Widget),
    ));
    await tester.pumpAndSettle();

    final colors = tester.widgetList<Text>(find.byType(Text)).map((t) => t.style?.color).toList();
    expect(colors, isNotEmpty, reason: '一个 Text 都没渲染出来，断言等于没跑');
    expect(colors, isNot(contains(Colors.white)), reason: '白字在白底弹框上是隐形按钮');
    expect(colors, contains(JXB.brandPrimary), reason: '确认键应是品牌色');
    expect(colors, contains(JXB.textSecondary), reason: '取消键应是次文本色');
  });

  testWidgets('ConfirmationDialog：标题/正文用浅色主题的文字色', (tester) async {
    await tester.pumpWidget(_wrap(
      ConfirmationDialog(
        title: '标题',
        description: '说明',
        onConfirm: () {},
        onCancel: () {},
      ),
    ));
    await tester.pumpAndSettle();

    final colors = tester.widgetList<Text>(find.byType(Text)).map((t) => t.style?.color).toList();
    expect(colors, contains(JXB.textPrimary), reason: '标题应是主文本色');
    expect(colors, contains(JXB.textSecondary), reason: '正文/取消键应是次文本色');
    expect(colors, isNot(contains(Colors.deepPurple)), reason: 'deepPurple 是旧深色壳的强调色');
    // 跑在 macOS 上走 Cupertino 分支；这条断言只在那一支成立，先确认平台，
    // 否则将来 CI 换 Linux 时这里会以"莫名其妙"的方式红。
    expect(Platform.isAndroid, isFalse, reason: '本测试假设走 Cupertino 分支');
  });

  test('语言选择 sheet / 充电指南弹框里不再有深色硬编码', () {
    // 这两个组件的渲染断言成本高（前者要 HomeProvider + 真实语言表，后者是
    // 私有实现），但"有没有深色残留"这件事本身是二值的，扫源码就够。
    // ⚠️ 必须剥注释：两个文件的注释里都写着改造前的旧色值（`#1C1C1E` 等），
    // 不剥的话把代码改回深色也照样绿。
    const darkLeftovers = [
      'kRedesign', // 旧深色令牌（文件已删，但 import 之外还可能有裸引用）
      '0xFF1C1C1E', // 语言 sheet 的旧底色
      '0xFF1F1F25', // 指南弹框的旧底色
      'Colors.deepPurple',
    ];
    for (final path in [
      'lib/pages/settings/language_selection_dialog.dart',
      'lib/widgets/info_dialog.dart',
    ]) {
      final code = stripCommentsAndStrings(File(path).readAsStringSync());
      expect(code, contains('JXB.'), reason: '$path 应该绑定 JXB 令牌');
      for (final bad in darkLeftovers) {
        expect(code, isNot(contains(bad)), reason: '$path 仍有深色残留：$bad');
      }
    }
  });
}
