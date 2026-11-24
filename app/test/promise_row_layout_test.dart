import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/pages/today_chapters/widgets/promise_row_content.dart';

/// P-03「你答应过的事」一条待办的行布局（设计稿 node 1130:2509）。
///
/// 这里钉的是**几行**：有截止时间两行，没有就只有一行。后端 `ActionItem.due_date` 只在
/// 能确定到具体某天时才填，所以「没有截止时间」是常态而不是边角情况——那种条目要是照样
/// 渲染两行，第二行整个是空的，每条待办看着都比内容高一截。
///
/// 判据落在**真实的屏幕坐标**上而不是 widget 树形状：竖直区间重叠 = 用户眼里的同一行。
/// 树里的 Row/Column 嵌套怎么改都行，只要看起来对。
///
/// 「加入提醒事项」不在这个 widget 里（它待在左滑区，见 `promises_swipe_delete_test.dart`），
/// 所以这里没有它的断言。曾经把它做成第二行右侧一颗常驻胶囊，那版已撤回。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required String description,
    DateTime? dueDate,
    String dueHint = '',
    bool completed = false,
    double width = 320,
  }) async {
    await tester.pumpWidget(MaterialApp(
      // 不显式给中文的话 revampText 会取英文，断言里的中文时间文案就找不到。
      locale: const Locale('zh'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh'), Locale('en')],
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: PromiseRowContent(
              description: description,
              dueDate: dueDate,
              dueHint: dueHint,
              completed: completed,
              onToggle: () {},
            ),
          ),
        ),
      ),
    ));
  }

  /// 两个矩形在竖直方向有交集 —— 也就是用户看着「在同一行」。
  bool sameLine(Rect a, Rect b) => a.top < b.bottom && b.top < a.bottom;

  const long = '等待并查看AWS提供的三版服务器方案及对应报价，然后在群里同步给大家';

  testWidgets('没有截止时间：只有一行，不留空的第二行', (tester) async {
    await pump(tester, description: long);

    // 行高由 34×32 的勾选圈命中区撑住，所以「只有一行」= 32 而不是 20。
    expect(tester.getRect(find.byType(PromiseRowContent)).height, 32);
  });

  testWidgets('有截止时间：描述独占第一行，时间在它下面的第二行', (tester) async {
    final d = DateTime.now().add(const Duration(days: 3));
    await pump(tester, description: long, dueDate: DateTime(d.year, d.month, d.day, 10, 0));

    final desc = tester.getRect(find.text(long));
    final due = tester.getRect(find.textContaining('10:00'));

    expect(sameLine(desc, due), isFalse, reason: '时间该独占第二行，不跟描述抢宽度');
    expect(due.top, greaterThanOrEqualTo(desc.bottom - 1), reason: '第二行在第一行下面');
    expect(due.left, lessThan(desc.right), reason: '时间贴左，跟描述左对齐');
    // 20（描述）+ 18（时间）= 38，比一行的 32 高。
    expect(tester.getRect(find.byType(PromiseRowContent)).height, 38);
  });

  testWidgets('只有模糊说法（没有 dueDate）也算有时间，走两行', (tester) async {
    await pump(tester, description: long, dueHint: '本周内');

    final desc = tester.getRect(find.text(long));
    final hint = tester.getRect(find.text('本周内'));
    expect(sameLine(desc, hint), isFalse);
    expect(hint.top, greaterThanOrEqualTo(desc.bottom - 1));
  });

  testWidgets('已完成：不显示时间，且行高不缩（分隔线会压到文字上）', (tester) async {
    final d = DateTime.now().add(const Duration(days: 3));
    await pump(
      tester,
      description: '删除转录界面顶部的转写摘要任务',
      dueDate: DateTime(d.year, d.month, d.day, 10, 0),
      completed: true,
    );

    expect(find.textContaining('10:00'), findsNothing, reason: '时间对做完的事没有意义');

    // 行高一旦跟着内容缩到 20，已完成卡里行与行会贴到一起、0.5px 分隔线压在文字上
    // （2026-08-13 调这块布局时真踩过一次）。
    expect(tester.getRect(find.byType(PromiseRowContent)).height, 32);
  });

  testWidgets('窄屏：长描述用省略号截掉，不 overflow 也不换行', (tester) async {
    await pump(tester, description: long, width: 200);

    expect(tester.getRect(find.byType(PromiseRowContent)).height, 32);
    expect(tester.takeException(), isNull, reason: '不该有 overflow');
  });
}
