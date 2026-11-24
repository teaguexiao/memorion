import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/pages/today_chapters/widgets/swipe_action_row.dart';
import 'package:memorion/providers/discover_provider.dart';

/// 「你答应过的事」左滑删除 + 清空已完成。
///
/// 这里钉的核心不变式是**下标左移**：后端删一条待办做的是
/// `structured.action_items.pop(item_idx)`（`backend/database/developer_data.py`
/// `delete_action_item`），删掉第 1 条之后，原来的第 2 条就变成了第 1 条。
///
/// 所以只要本地缓存里还留着旧下标，接下来的勾选 / 删除就会**静默打到隔壁那条待办
/// 上**——两次请求各自都返回 200，错位只有重新拉一遍列表才看得见。这类「两个函数
/// 各自正确、接起来是错的」缺陷单测提取函数逮不到，只能按后端的 pop 语义整体走一遍。
void main() {
  DiscoverActionItem item(String conv, int idx, {bool completed = false, String? desc}) {
    return DiscoverActionItem(
      description: desc ?? '$conv-$idx',
      completed: completed,
      conversationId: conv,
      conversationTitle: conv,
      itemIdx: idx,
    );
  }

  group('DiscoverProvider.removeActionItemAt', () {
    test('删掉中间一条后，同会话内更大的下标全部左移一位', () {
      final dp = DiscoverProvider();
      dp.actionItems = [item('c1', 0), item('c1', 1), item('c1', 2), item('c1', 3)];
      dp.debugMarkActionItemsLoaded(total: 4, completed: 0);

      dp.removeActionItemAt(conversationId: 'c1', itemIdx: 1);

      expect(dp.actionItems.map((i) => i.description).toList(), ['c1-0', 'c1-2', 'c1-3']);
      // 关键：留下来的那两条现在的下标是 1、2 —— 后端 pop 之后就是这样。
      expect(dp.actionItems.map((i) => i.itemIdx).toList(), [0, 1, 2]);
    });

    test('别的会话的下标不受影响（各是一份 Firestore 文档）', () {
      final dp = DiscoverProvider();
      dp.actionItems = [item('c1', 0), item('c1', 1), item('c2', 0), item('c2', 1)];
      dp.debugMarkActionItemsLoaded(total: 4, completed: 0);

      dp.removeActionItemAt(conversationId: 'c1', itemIdx: 0);

      final c2 = dp.actionItems.where((i) => i.conversationId == 'c2').toList();
      expect(c2.map((i) => i.itemIdx).toList(), [0, 1]);
    });

    test('缓存里没有这条（在分页外）时，左移和计数照样要生效', () {
      final dp = DiscoverProvider();
      // 第一页只装到了下标 2、3 两条，被删的下标 1 不在缓存里。
      dp.actionItems = [item('c1', 2), item('c1', 3)];
      dp.debugMarkActionItemsLoaded(total: 60, completed: 10);

      dp.removeActionItemAt(conversationId: 'c1', itemIdx: 1);

      expect(dp.actionItems.map((i) => i.itemIdx).toList(), [1, 2],
          reason: '提前返回的话这两条的下标就永久错位了');
      expect(dp.actionItemsTotalCount, 59);
    });

    test('删已完成的减 completed 计数，删未完成的不减', () {
      final dp = DiscoverProvider();
      dp.actionItems = [item('c1', 0, completed: true), item('c1', 1)];
      dp.debugMarkActionItemsLoaded(total: 2, completed: 1);

      dp.removeActionItemAt(conversationId: 'c1', itemIdx: 0);
      expect(dp.actionItemsTotalCount, 1);
      expect(dp.actionItemsCompletedCount, 0);
      expect(dp.pendingActionItemsCount, 1);

      dp.removeActionItemAt(conversationId: 'c1', itemIdx: 0);
      expect(dp.actionItemsTotalCount, 0);
      expect(dp.actionItemsCompletedCount, 0);
    });
  });

  group('清空已完成：删除顺序', () {
    /// 模拟后端：待办是一个按下标定位的列表，删一条就是 `pop(idx)`。
    /// 越界返回 false（后端 `delete_action_item` 同样是先判范围）。
    List<String> deleteAll(List<String> store, List<int> idxSequence) {
      final s = [...store];
      for (final idx in idxSequence) {
        if (idx < 0 || idx >= s.length) continue;
        s.removeAt(idx);
      }
      return s;
    }

    // 下标:  0 已完成  1 未完成  2 已完成  3 未完成
    final store = ['done0', 'keep1', 'done2', 'keep3'];
    final completedIdx = [0, 2];

    test('降序删：剩下的正好是未完成的那些', () {
      // 与 promises_page._clearCompleted 同一个排序（组内按下标降序）。
      final ordered = [...completedIdx]..sort((a, b) => b.compareTo(a));
      expect(deleteAll(store, ordered), ['keep1', 'keep3']);
    });

    test('升序删会删掉一条没做完的待办 —— 降序不是风格偏好', () {
      final ascending = [...completedIdx]..sort();
      // 删掉下标 0 之后剩 ['keep1','done2','keep3']，下标全部左移一位；第二刀照旧
      // 砍在 2 上，砍中的是 'keep3'。结果：一条未完成的被删了，'done2' 还留着。
      expect(deleteAll(store, ascending), ['keep1', 'done2']);
    });
  });

  group('SwipeActionRow', () {
    // 组件本身支持挂 N 个动作，这里按两个测「多动作时里面那个也点得到」——P-03 的左滑区
    // 实际就是两个（Figma node 1130:2509）：`删除` 在左、`加入提醒事项` 在右（贴屏幕边、
    // 离手指最近）。这两个动作只在左滑区出现，行里没有常驻入口。

    /// 宿主：模拟页面持有「哪一行开着」的状态（一次只开一行）。
    Widget host({
      required List<SwipeAction> actions,
      required void Function(bool) onOpenChanged,
      required ValueNotifier<bool> open,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: open,
            builder: (_, isOpen, __) => SwipeActionRow(
              actions: actions,
              open: isOpen,
              onOpenChanged: onOpenChanged,
              child: Container(
                height: 52,
                color: Colors.white,
                alignment: Alignment.centerLeft,
                child: const Text('买牛奶'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('左滑到底请求打开，按钮可点', (tester) async {
      final open = ValueNotifier(false);
      final changes = <bool>[];
      var deleted = 0;
      final actions = [
        SwipeAction(
          icon: Icons.delete_outline_rounded,
          iconColor: Colors.red,
          background: Colors.red.shade50,
          semanticLabel: '删除',
          onTap: () async => deleted++,
        ),
        SwipeAction(
          icon: Icons.notifications_none_rounded,
          iconColor: Colors.blue,
          background: Colors.blue.shade50,
          // 排在删除右边，用来证明两个键并排时靠里的删除键照样点得到。
          semanticLabel: '加入提醒事项',
          onTap: () async {},
        ),
      ];

      await tester.pumpWidget(host(
        actions: actions,
        open: open,
        onOpenChanged: (v) {
          changes.add(v);
          open.value = v;
        },
      ));

      await tester.drag(find.text('买牛奶'), const Offset(-100, 0));
      await tester.pumpAndSettle();

      expect(changes, [true]);
      // 行内容整体左移，让出按钮的位置。
      final t = tester.widget<Transform>(find.ancestor(
        of: find.text('买牛奶'),
        matching: find.byType(Transform),
      ));
      expect(t.transform.getTranslation().x, lessThan(-50));

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      expect(deleted, 1);
      // 动作执行前先收起：删除会把这一行从列表里摘掉，跑完再收就没有行可收了。
      expect(changes, [true, false]);
    });

    testWidgets('轻轻一碰不算打开（不到一半弹回去）', (tester) async {
      final open = ValueNotifier(false);
      final changes = <bool>[];
      await tester.pumpWidget(host(
        actions: [
          SwipeAction(
            icon: Icons.delete_outline_rounded,
            iconColor: Colors.red,
            background: Colors.red.shade50,
            semanticLabel: '删除',
            onTap: () async {},
          ),
        ],
        open: open,
        onOpenChanged: (v) {
          changes.add(v);
          open.value = v;
        },
      ));

      await tester.drag(find.text('买牛奶'), const Offset(-8, 0));
      await tester.pumpAndSettle();

      expect(changes, isEmpty);
    });

    testWidgets('展开时点行内容只收起，不触发行本身的点击', (tester) async {
      final open = ValueNotifier(true);
      final changes = <bool>[];
      var rowTapped = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: open,
            builder: (_, isOpen, __) => SwipeActionRow(
              actions: [
                SwipeAction(
                  icon: Icons.delete_outline_rounded,
                  iconColor: Colors.red,
                  background: Colors.red.shade50,
                  semanticLabel: '删除',
                  onTap: () async {},
                ),
              ],
              open: isOpen,
              onOpenChanged: (v) {
                changes.add(v);
                open.value = v;
              },
              child: GestureDetector(
                onTap: () => rowTapped++,
                child: Container(
                  height: 52,
                  color: Colors.white,
                  alignment: Alignment.centerLeft,
                  child: const Text('买牛奶'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 点行的中段而不是 find.text：展开态下行整体左移，文字已经被移到了行外，
      // 按文字定位会点在屏幕外（谁都没收到），测不出覆盖层有没有拦住点击。
      final row = tester.getRect(find.byType(SwipeActionRow));
      await tester.tapAt(row.center);
      await tester.pumpAndSettle();

      expect(changes, [false]);
      expect(rowTapped, 0, reason: '滑开状态下顺手一点不该误勾选待办');
    });
  });
}
