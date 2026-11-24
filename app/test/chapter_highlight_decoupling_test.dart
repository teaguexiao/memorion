import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/pages/today_chapters/widgets/chapter_card.dart';

/// 首页 P-01 章节卡⭐高亮 与 章节详情「值得回顾的时刻」解耦。
///
/// 背景：高亮曾由 `structured.highlights`（AI 随 summary 生成的「值得回顾的时刻」
/// 原话）非空推导，导致大量对话被自动高亮。现改为只看显式字段
/// `structured.is_highlighted`——未来由硬件按钮写入。
void main() {
  /// 复刻 today_chapters_page.dart `_buildDayGroups` 里的映射规则：
  /// 章节卡 hasHighlight 只取 isHighlighted，不看 highlights。
  bool hasHighlightFor(Structured s) => s.isHighlighted;

  Widget wrapMetaRow({required bool hasHighlight}) {
    return MaterialApp(
      home: Scaffold(
        body: ChapterMetaRow(timeRange: '10:00-11:00', category: '工作', hasHighlight: hasHighlight),
      ),
    );
  }

  group('数据层：is_highlighted 与 highlights 互不影响', () {
    test('标记了「值得回顾的时刻」(highlights 非空) 不再让 isHighlighted 为真', () {
      final s = Structured.fromJson({
        'title': '下午的定价会',
        'overview': '正文',
        'emoji': '',
        'category': 'work',
        // 章节详情「值得回顾的时刻」有 2 条引用原话。
        'highlights': ['你难得地没有让步', '这是本周第三次提到 DFU'],
      });

      // 详情页照常拿到 2 条引用卡内容。
      expect(s.highlights, hasLength(2));
      // 但首页高亮不再跟着亮。
      expect(s.isHighlighted, isFalse);
      expect(hasHighlightFor(s), isFalse);
    });

    test('显式 is_highlighted=true 才高亮（highlights 可为空）', () {
      final s = Structured.fromJson({
        'title': '按了按钮的一段',
        'overview': '正文',
        'emoji': '',
        'category': 'work',
        'highlights': <String>[],
        'is_highlighted': true,
      });

      expect(s.highlights, isEmpty);
      expect(s.isHighlighted, isTrue);
      expect(hasHighlightFor(s), isTrue);
    });

    test('老数据无 is_highlighted 字段 → 缺省 false（自然清零，无需迁移）', () {
      final s = Structured.fromJson({
        'title': '老会话',
        'overview': '正文',
        'emoji': '',
        'category': 'other',
        'highlights': ['一句被 AI 挑出来的原话'],
      });

      expect(s.isHighlighted, isFalse);
      expect(hasHighlightFor(s), isFalse);
    });

    test('is_highlighted 可序列化回传（供硬件按钮写入链路持久化）', () {
      final s = Structured('标题', '正文', isHighlighted: true);
      expect(s.toJson()['is_highlighted'], isTrue);

      // 序列化 → 反序列化后标记保持。
      final roundTrip = Structured.fromJson(Map<String, dynamic>.from(s.toJson()));
      expect(roundTrip.isHighlighted, isTrue);
    });
  });

  group('UI 层：⭐高亮标签能力保留', () {
    testWidgets('hasHighlight=false 时不显示⭐高亮标签', (tester) async {
      await tester.pumpWidget(wrapMetaRow(hasHighlight: false));
      await tester.pump();

      expect(find.byIcon(Icons.star_rounded), findsNothing);
      // 分类标签仍在。
      expect(find.text('工作'), findsOneWidget);
    });

    testWidgets('hasHighlight=true 时显示⭐高亮标签（纯标记，不带条数）', (tester) async {
      await tester.pumpWidget(wrapMetaRow(hasHighlight: true));
      await tester.pump();

      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      // 方案 B：布尔态标记。默认 en locale 下文案为不带条数的 'Highlight'，
      // 旧的复数计数文案（'N highlights'）已移除。
      expect(find.text('Highlight'), findsOneWidget);
      expect(find.textContaining('highlights'), findsNothing);
    });
  });
}
