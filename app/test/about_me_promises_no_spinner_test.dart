import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/providers/discover_provider.dart';
import 'package:memorion/ui/atoms/memorion_skeleton.dart';
import 'package:provider/provider.dart';

/// 「关于我」→「你答应过的事」不该在已有数据时转圈。
///
/// 这块原来无条件 `if (loading)` 出骨架屏，且自己在 initState 里 fetch，于是每次进
/// tab 都要干等一整个网络往返（含 TLS 握手 ≈1.2s）才显示第一个字——旁边「事实」
/// 「洞察」都有缓存兜底能秒出，只有它一直转圈。
///
/// 修复后数据来自 `DiscoverProvider`，只在 `actionItemsLoadedOnce == false` 时出骨架。
/// 这里直接验证那个判据（`_PromisesCard` 是私有类，用同样的条件复刻一遍它的分支）。
void main() {
  /// 复刻 `_PromisesCard.build` 的分支判据。真实 widget 是私有的，测不到，
  /// 但决定「转不转圈」的就是这一个条件。
  Widget promisesCardBranch(DiscoverProvider dp) {
    final promises = dp.pendingActionItems;
    if (promises.isEmpty && !dp.actionItemsLoadedOnce) {
      return const MemorionSkeletonTextCard(lines: 3);
    }
    if (promises.isEmpty) {
      return const Text('还没有答应过的事');
    }
    return Column(children: [for (final p in promises.take(3)) Text(p.description)]);
  }

  Widget wrap(DiscoverProvider dp) => MaterialApp(
        home: ChangeNotifierProvider<DiscoverProvider>.value(
          value: dp,
          child: Scaffold(
            body: Consumer<DiscoverProvider>(builder: (_, p, __) => promisesCardBranch(p)),
          ),
        ),
      );

  DiscoverActionItem item(String desc, {bool completed = false}) => DiscoverActionItem(
        description: desc,
        completed: completed,
        conversationId: 'c1',
        conversationTitle: '技术方案讨论',
        itemIdx: 0,
      );

  testWidgets('还没拿到过数据 → 出骨架屏（首次冷启动才该转圈）', (tester) async {
    final dp = DiscoverProvider();
    expect(dp.actionItemsLoadedOnce, isFalse);

    await tester.pumpWidget(wrap(dp));
    expect(find.byType(MemorionSkeletonTextCard), findsOneWidget);
  });

  testWidgets('已有数据 → 直接出内容，不出骨架（本次修复的核心）', (tester) async {
    final dp = DiscoverProvider();
    dp.actionItems = [item('在群里补充服务器参数'), item('查看AWS三版报价')];
    dp.debugMarkActionItemsLoaded(total: 2, completed: 0);

    await tester.pumpWidget(wrap(dp));
    expect(find.byType(MemorionSkeletonTextCard), findsNothing);
    expect(find.text('在群里补充服务器参数'), findsOneWidget);
    expect(find.text('查看AWS三版报价'), findsOneWidget);
  });

  testWidgets('拿到了但确实是空的 → 出空态，不无限转圈', (tester) async {
    final dp = DiscoverProvider();
    dp.debugMarkActionItemsLoaded(total: 0, completed: 0);

    await tester.pumpWidget(wrap(dp));
    expect(find.byType(MemorionSkeletonTextCard), findsNothing);
    expect(find.text('还没有答应过的事'), findsOneWidget);
  });

  testWidgets('后台静默刷新时不回退到骨架屏', (tester) async {
    final dp = DiscoverProvider();
    dp.actionItems = [item('在群里补充服务器参数')];
    dp.debugMarkActionItemsLoaded(total: 1, completed: 0);

    await tester.pumpWidget(wrap(dp));
    expect(find.text('在群里补充服务器参数'), findsOneWidget);

    // 模拟切回 tab 触发的静默刷新：isLoadingActions 置真但数据还在。
    dp.isLoadingActions = true;
    dp.notifyListeners();
    await tester.pump();

    expect(find.byType(MemorionSkeletonTextCard), findsNothing,
        reason: '刷新期间应继续显示旧内容，不该闪回骨架屏');
    expect(find.text('在群里补充服务器参数'), findsOneWidget);
  });

  group('pendingActionItems / pendingActionItemsCount', () {
    test('滤掉已完成的条目', () {
      final dp = DiscoverProvider();
      dp.actionItems = [
        item('未完成 A'),
        item('已完成 B', completed: true),
        item('未完成 C'),
      ];
      expect(dp.pendingActionItems.map((i) => i.description), ['未完成 A', '未完成 C']);
    });

    test('「还有 N 条」用服务端 total-completed，算得上翻页外的条目', () {
      final dp = DiscoverProvider();
      // 第一页只有 50 条，但服务端说总共 139 条、其中 9 条已完成。
      dp.actionItems = List.generate(50, (i) => item('待办 $i'));
      dp.debugMarkActionItemsLoaded(total: 139, completed: 9);
      expect(dp.pendingActionItemsCount, 130);
    });

    test('服务端计数缺失/异常时回退到本地条数，不出负数', () {
      final dp = DiscoverProvider();
      dp.actionItems = [item('未完成 A'), item('未完成 B')];
      dp.debugMarkActionItemsLoaded(total: 0, completed: 5); // total-completed = -5
      expect(dp.pendingActionItemsCount, 2);
    });
  });

  group('DiscoverActionItem.fromJson 解析截止信息', () {
    test('due_date 解析成本地时间，due_hint 原样带上', () {
      final it = DiscoverActionItem.fromJson({
        'description': '删除转录界面顶部的转写摘要任务',
        'completed': false,
        'conversation_id': 'c1',
        'conversation_title': '转录界面功能优化建议',
        'item_idx': 0,
        'created_at': '2026-07-30T02:34:52.128712+00:00',
        'due_date': '2026-08-01T10:00:00+00:00',
        'due_hint': '当下',
      });
      expect(it.dueDate, isNotNull);
      expect(it.dueDate!.isUtc, isFalse, reason: 'toLocal() 应已转成本地时区');
      expect(it.dueHint, '当下');
    });

    test('due_date 为 null / due_hint 缺失时不炸，给出安全默认值', () {
      final it = DiscoverActionItem.fromJson({
        'description': '等待并查看AWS提供的三版服务器方案',
        'completed': false,
        'conversation_id': 'c1',
        'conversation_title': '技术方案',
        'item_idx': 1,
        'due_date': null,
      });
      expect(it.dueDate, isNull);
      expect(it.dueHint, '');
    });

    test('due_date 是无法解析的脏数据时退化成 null，而不是抛异常', () {
      final it = DiscoverActionItem.fromJson({
        'description': 'x',
        'conversation_id': 'c1',
        'conversation_title': 't',
        'item_idx': 0,
        'due_date': 'not-a-date',
      });
      expect(it.dueDate, isNull);
    });
  });
}
