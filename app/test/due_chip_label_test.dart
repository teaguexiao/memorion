import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/pages/today_chapters/widgets/due_chip.dart';

/// 待办截止时间的文案（P-03「你答应过的事」第二行那串灰字）。
///
/// 这里钉的是**不许编时间**：后端 `ActionItem.due_date` 的语义是「只在能确定到具体日期
/// 时才填」，LLM 提不到时点时给的是当天 00:00。照原样渲染成「周五 0:00」会把「没说几点」
/// 显示成「凌晨要做」，而这条假信息还会被一路带进苹果提醒事项里在错的时间弹提醒。
void main() {
  /// 把 DueChip 放进一棵最小的中文 / 英文 widget 树里，读回它实际渲染的文字。
  Future<String> render(
    WidgetTester tester, {
    DateTime? dueDate,
    String dueHint = '',
    DateTime? spokenAt,
    DueChipVariant variant = DueChipVariant.caption,
    Locale locale = const Locale('zh'),
  }) async {
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh'), Locale('en')],
      home: Scaffold(
          body: DueChip(dueDate: dueDate, dueHint: dueHint, spokenAt: spokenAt, variant: variant)),
    ));
    final texts = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').toList();
    return texts.join('|');
  }

  group('caption 形态', () {
    testWidgets('00:00 不显示时点 —— 那是「只知道哪天」，不是「凌晨要做」', (tester) async {
      final d = DateTime.now().add(const Duration(days: 3));
      final midnight = DateTime(d.year, d.month, d.day);
      final label = await render(tester, dueDate: midnight);

      expect(label, isNot(contains(':')), reason: '零点的 due_date 代表没提到时点');
      expect(label, isNot(contains('0:00')));
    });

    testWidgets('有具体时点就写出来', (tester) async {
      final d = DateTime.now().add(const Duration(days: 3));
      final label = await render(tester, dueDate: DateTime(d.year, d.month, d.day, 10, 0));

      expect(label, contains('10:00'));
    });

    testWidgets('本周内用星期，今天/明天优先用「今天/明天」', (tester) async {
      final now = DateTime.now();

      DateTime at(int days) {
        final d = now.add(Duration(days: days));
        return DateTime(d.year, d.month, d.day, 9, 30);
      }

      expect(await render(tester, dueDate: at(0)), contains('今天'));
      expect(await render(tester, dueDate: at(1)), contains('明天'));

      const zh = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      final d3 = at(3);
      expect(await render(tester, dueDate: d3), contains(zh[d3.weekday - 1]));
    });

    testWidgets('超出一周落回日期，不再说星期', (tester) async {
      final d = DateTime.now().add(const Duration(days: 20));
      final label = await render(tester, dueDate: DateTime(d.year, d.month, d.day, 9, 0));

      expect(label, contains('${d.month}月${d.day}日'));
      const zh = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      expect(zh.any(label.contains), isFalse, reason: '一周以外说「周五」分不清是哪个周五');
    });

    testWidgets('逾期保留红字 + 图标（设计稿没画这个态，但信号不能丢）', (tester) async {
      final d = DateTime.now().subtract(const Duration(days: 2));
      final label = await render(tester, dueDate: DateTime(d.year, d.month, d.day, 9, 0));

      expect(label, contains('已过期'));
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });

    testWidgets('只有模糊说法时原话照搬，不推算日期', (tester) async {
      expect(await render(tester, dueHint: '本周内'), '本周内');
    });

    testWidgets('两个字段都空 → 整个标签不渲染，不占位', (tester) async {
      expect(await render(tester), '');
    });

    testWidgets('英文环境用英文星期与月/日', (tester) async {
      final now = DateTime.now();
      final d = now.add(const Duration(days: 3));
      final label = await render(
        tester,
        dueDate: DateTime(d.year, d.month, d.day, 14, 5),
        locale: const Locale('en'),
      );

      const en = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      expect(label, contains(en[d.weekday - 1]));
      expect(label, contains('14:05'));
    });
  });

  /// `due_hint` 存的是**人说的原话**，照搬有两个毛病（2026-08-13 扫生产数据实见）：
  /// 里面会混进根本不是时间的短语，而它又是按说话时的语言存的。
  group('due_hint 不照搬', () {
    testWidgets('不是时间的短语整个不渲染', (tester) async {
      expect(await render(tester, dueHint: 'before I lose signal'), '');
      expect(await render(tester, dueHint: 'during apology call'), '');
      expect(await render(tester, dueHint: '高优先级'), '');
    });

    testWidgets('英文对话产出的 hint 在中文界面里说中文', (tester) async {
      expect(await render(tester, dueHint: 'this week'), '本周内');
      expect(await render(tester, dueHint: '下周', locale: const Locale('en')), 'Next week');
    });

    testWidgets('剥掉「前」查表，但语气要补回来（月底 ≠ 月底前）', (tester) async {
      expect(await render(tester, dueHint: '月底前'), '月底前');
      expect(await render(tester, dueHint: '月底前', locale: const Locale('en')), 'By month end');
    });

    testWidgets('认不出的说法原样显示，不硬翻', (tester) async {
      expect(await render(tester, dueHint: 'in two weeks'), 'in two weeks');
    });

    testWidgets('hint 点到具体某天时按日期措辞写（后端该填 due_date 却漏了的那些）', (tester) async {
      final now = DateTime.now();
      expect(await render(tester, dueHint: 'tomorrow', spokenAt: now), contains('明天'));
      // 「…前」的语气要留住：「周五」和「周五前」不是一件事。
      expect(await render(tester, dueHint: 'by Friday', spokenAt: now), endsWith('前'));
    });

    testWidgets('三天前说的「明天」是逾期，不能显示成「明天」', (tester) async {
      final label = await render(
        tester,
        dueHint: '明天',
        spokenAt: DateTime.now().subtract(const Duration(days: 3)),
      );
      expect(label, contains('已过期'));
      expect(label, isNot(contains('明天')));
    });

    testWidgets('「今晚」这种除了日子还带别的信息 → 别用「今天」替掉原话', (tester) async {
      expect(await render(tester, dueHint: 'tonight', spokenAt: DateTime.now()), '今晚');
    });

    testWidgets('不知道这话是什么时候说的 → 只显示原话，不按今天推日期', (tester) async {
      // 按今天算就是给错的那一天；「周五」不在中英对照表里，只能原样搬。
      expect(await render(tester, dueHint: '周五'), '周五');
    });
  });

  group('inline 形态（「关于我」摘要卡，跟描述挤在同一行）', () {
    testWidgets('不带时点也不带星期 —— 一行里它得让出宽度给描述', (tester) async {
      final now = DateTime.now();
      final d = now.add(const Duration(days: 3));
      final label = await render(
        tester,
        dueDate: DateTime(d.year, d.month, d.day, 10, 0),
        variant: DueChipVariant.inline,
      );

      expect(label, '${d.month}月${d.day}日');
      expect(label, isNot(contains('10:00')));
    });
  });
}
