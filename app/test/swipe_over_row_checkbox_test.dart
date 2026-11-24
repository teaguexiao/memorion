import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/pages/today_chapters/widgets/promise_row_content.dart';
import 'package:memorion/pages/today_chapters/widgets/swipe_action_row.dart';

/// 在**勾选圈上**起手横滑，得能滑开这一行，而且不能顺手把待办勾成已完成。
///
/// 勾选圈是行里唯一的常驻命中区（34×32，见 `PromiseRowContent`），又正好在行的最左边——
/// 从左往右扫视的手指起手左滑很容易落在它上面。滑动被判成点击的话，用户想露出删除键，
/// 结果把一件没做完的事标成做完了。
///
/// ⚠️ **两条断言的分量不一样，别把「没被误勾」那条当护栏。** 变异验证（2026-08-13）实测：
/// 把勾选圈换成 `onTapDown`（按下即触发）**抓不到** —— tap recognizer 横向位移过 slop 后
/// 就被判负，`onTapDown` 压根不 fire，「横滑不误点」这件事是 Flutter 手势竞技自己保证的，
/// 我们的代码想破坏都难。真正有分量的是 `changes == [true]`：给行内任何控件加一个
/// `onHorizontalDragUpdate` 就能让它失败（内层赢下 arena → 整行再也滑不开）。所以这条
/// 测试防的是「往行里塞了个自己抢横滑的控件」，不是防误点。
///
/// ⚠️ 这条不变式**不能靠 maestro 验**：合成手势注入不走真手指那套 down + 多个 move + up
/// 的事件序列，2026-08-13 用 maestro CLI 从行内按钮上起手 `swipe` 时行滑开了、那个按钮
/// 同时也被触发，看着像缺陷，其实是注入产物。`tester.drag` 发的才是真序列。
void main() {
  Widget host({
    required VoidCallback onToggle,
    required ValueChanged<bool> onOpenChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SwipeActionRow(
          actions: [
            SwipeAction(
              icon: Icons.delete_outline_rounded,
              iconColor: Colors.red,
              background: Colors.red.shade50,
              semanticLabel: '删除',
              onTap: () async {},
            ),
          ],
          open: false,
          onOpenChanged: onOpenChanged,
          child: PromiseRowContent(
            description: '去看医生',
            dueDate: null,
            dueHint: '',
            completed: false,
            onToggle: onToggle,
          ),
        ),
      ),
    );
  }

  /// 勾选圈没有文字可以 find，按那个 34×32 的命中区定位。
  Finder checkbox() => find.descendant(
        of: find.byType(PromiseRowContent),
        matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == 34 && w.height == 32,
        ),
      );

  testWidgets('从勾选圈上起手左滑：行滑开，待办没被勾掉', (tester) async {
    var toggles = 0;
    final changes = <bool>[];
    await tester.pumpWidget(host(
      onToggle: () => toggles++,
      onOpenChanged: changes.add,
    ));

    await tester.drag(checkbox(), const Offset(-100, 0));
    await tester.pumpAndSettle();

    expect(toggles, 0, reason: '横滑被判成点击 → 用户想露出删除键，却把没做完的事标成做完了');
    expect(changes, [true], reason: '起手点落在勾选圈上也要能滑开这一行');
  });

  /// 起手点落在**藏着的动作键那一片**上（行还没滑开，键被不透明的行内容盖着）。
  ///
  /// 2026-08-13 在模拟器上用 maestro 从 x=72%（≈281pt，正好压在藏着的删除键 273~309pt 上）
  /// 起手左滑，行滑开了、铃铛同时变成「已加入」——真往「提醒事项」写了一条，而这个动作
  /// 没有撤销入口。这条测试就是判它到底是我们的缺陷还是注入产物：真手指的事件序列里
  /// 命中测试在 down 那一刻就定了（那时盖在上面的是行内容），后续 move/up 只会发给同一批
  /// recognizer，所以藏着的键压根收不到这次手势。
  testWidgets('起手点压在藏着的动作键上：只滑开，不触发那个动作', (tester) async {
    var fired = 0;
    final changes = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SwipeActionRow(
          actions: [
            SwipeAction(
              icon: Icons.delete_outline_rounded,
              iconColor: Colors.red,
              background: Colors.red.shade50,
              semanticLabel: '删除',
              onTap: () async => fired++,
            ),
            SwipeAction(
              icon: Icons.notifications_none_rounded,
              iconColor: Colors.blue,
              background: Colors.blue.shade50,
              semanticLabel: '加入提醒事项',
              onTap: () async => fired++,
            ),
          ],
          open: false,
          onOpenChanged: changes.add,
          child: PromiseRowContent(
            description: '去看医生',
            dueDate: null,
            dueHint: '',
            completed: false,
            onToggle: () {},
          ),
        ),
      ),
    ));

    // 藏着的两个键贴在行的右端，从右边缘往里量一段起手，正好压在它们上面。
    final row = tester.getRect(find.byType(SwipeActionRow));
    final start = Offset(row.right - 30, row.center.dy);
    await tester.dragFrom(start, const Offset(-120, 0));
    await tester.pumpAndSettle();

    expect(fired, 0, reason: '横滑触发了藏在下面的键 —— 加提醒事项没有撤销入口，误写就是脏数据');
    expect(changes, [true], reason: '压在藏着的键上起手也要能滑开这一行');
  });

  testWidgets('对照：真的点勾选圈，勾选照常生效', (tester) async {
    var toggles = 0;
    final changes = <bool>[];
    await tester.pumpWidget(host(
      onToggle: () => toggles++,
      onOpenChanged: changes.add,
    ));

    await tester.tap(checkbox());
    await tester.pumpAndSettle();

    expect(toggles, 1, reason: '别为了防误触把正常勾选也挡掉了');
    expect(changes, isEmpty);
  });
}
