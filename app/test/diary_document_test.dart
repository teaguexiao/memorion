import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/pages/today_chapters/diary_detail_page.dart';
import 'package:memorion/utils/diary_document.dart';
import 'package:memorion/utils/moment_parser.dart';

/// 日记正文解析的不变式（格式约定见 `backend/utils/llm/daily_summary.py` 模块说明）。
///
/// 旧解析（`_DiaryContent`）的两个缺陷是这里要钉住的反面：**所有标题被丢掉**、**所有列表
/// 项被抽到文末「这天你还提到」**——于是 legacy 日记的「关键跟进事项」读起来是一串没有
/// 归属的条目，journal 的段落 / 加粗 / 引语也都被压成一坨纯文本。
///
/// Run: cd app && flutter test test/diary_document_test.dart
void main() {
  // MomentParser 的默认标题走 appT，它要读 navigatorKey ⇒ 需要 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  List<DiaryBlockKind> kinds(DiaryDocument d) => d.blocks.map((b) => b.kind).toList();

  group('journal', () {
    const journal = '和小林把发布时间定在了**周五**，拖了两周的事总算落地。\n'
        '第二行仍属同一段。\n\n'
        '晚上妈妈打电话来，说的第一句是：\n\n'
        '> "别太晚睡"\n\n'
        '### 明天记得\n\n'
        '- 把发布说明发给小林\n'
        '- 交房租';

    test('段落、引语、明日便签各自成块，顺序不变', () {
      final doc = DiaryDocument.parse(journal);
      expect(kinds(doc), [
        DiaryBlockKind.paragraph,
        DiaryBlockKind.paragraph,
        DiaryBlockKind.quote,
        DiaryBlockKind.heading,
        DiaryBlockKind.list,
      ]);
      expect(doc.blocks[0].text, contains('\n第二行仍属同一段。'), reason: '段内软换行保留');
      expect(doc.blocks[2].text, '"别太晚睡"');
      expect(doc.blocks[3].text, '明天记得');
      expect(doc.blocks[4].items, ['把发布说明发给小林', '交房租']);
    });

    test('加粗拆成片段，其余文字原样', () {
      final runs = DiaryDocument.inlineRuns(DiaryDocument.parse(journal).blocks[0].text);
      expect(runs.where((r) => r.bold).map((r) => r.text), ['周五']);
      expect(runs.map((r) => r.text).join(), startsWith('和小林把发布时间定在了周五，'));
    });

    test('纯文本分享不带任何 markdown 记号，引语补上引号', () {
      final plain = DiaryDocument.parse('今天**很短**。\n\n> 下次再说\n\n### 明天记得\n- 交房租').toPlainText();
      expect(plain, '今天很短。\n\n“下次再说”\n\n明天记得\n\n· 交房租');
      expect(plain, isNot(contains('**')));
      expect(plain, isNot(contains('#')));
      expect(plain, isNot(contains('>')));
    });
  });

  group('legacy 五段式', () {
    const legacy = '### 今日亮点\n\n今天把方向收拢了。\n\n'
        '### 关键跟进事项\n\n1. 明天把纪要发出去。\n2. 跟进演示反馈。\n\n'
        '### 今日决定\n\n- 先做 iOS\n- 安卓延后\n\n'
        '### 可以改进的地方\n\n开会可以更早给结论。';

    test('标题保留、列表留在自己的标题下面', () {
      final doc = DiaryDocument.parse(legacy);
      expect(kinds(doc), [
        DiaryBlockKind.heading,
        DiaryBlockKind.paragraph,
        DiaryBlockKind.heading,
        DiaryBlockKind.list,
        DiaryBlockKind.heading,
        DiaryBlockKind.list,
        DiaryBlockKind.heading,
        DiaryBlockKind.paragraph,
      ]);
      expect(doc.blocks[3].ordered, isTrue);
      expect(doc.blocks[3].items, ['明天把纪要发出去。', '跟进演示反馈。']);
      expect(doc.blocks[5].ordered, isFalse);
    });

    test('信息一个字都不丢：每条原文都出现在纯文本里', () {
      final plain = DiaryDocument.parse(legacy).toPlainText();
      for (final s in ['今日亮点', '今天把方向收拢了。', '关键跟进事项', '明天把纪要发出去。', '跟进演示反馈。', '今日决定', '先做 iOS', '安卓延后',
        '可以改进的地方', '开会可以更早给结论。']) {
        expect(plain, contains(s));
      }
    });

    test('更老的整行加粗小标题也认成标题，但整句加粗不算', () {
      final doc = DiaryDocument.parse('**Key Highlights**\n- one\n\n**I finally said it out loud.**');
      expect(kinds(doc), [DiaryBlockKind.heading, DiaryBlockKind.list, DiaryBlockKind.paragraph]);
      expect(doc.blocks[0].text, 'Key Highlights');
    });
  });

  group('行内与列表边界', () {
    test('「10.5 万」「2026年」不是编号列表，「1、」是', () {
      final doc = DiaryDocument.parse('10.5 万的预算批了。\n\n2026年的计划还没定。\n\n1、买票\n2、订酒店');
      expect(kinds(doc), [DiaryBlockKind.paragraph, DiaryBlockKind.paragraph, DiaryBlockKind.list]);
      expect(doc.blocks[2].items, ['买票', '订酒店']);
    });

    test('斜体 / 代码 / 链接 / __加粗__ 归一，不成对的 ** 去掉', () {
      final doc = DiaryDocument.parse('一点*斜体*、`code`、[链接](https://x.y) 和 __重点__\n\n孤零零的 ** 记号');
      expect(doc.blocks[0].text, '一点斜体、code、链接 和 **重点**');
      expect(doc.blocks[1].text, '孤零零的  记号');
    });

    test('勾选框标记从条目里去掉', () {
      expect(DiaryDocument.parse('- [ ] 交房租\n- [x] 回电话').blocks.single.items, ['交房租', '回电话']);
    });

    test('空文本得到空文档', () {
      expect(DiaryDocument.parse('').isEmpty, isTrue);
      expect(DiaryDocument.parse('\n \n').isEmpty, isTrue);
    });
  });

  group('分享卡截断', () {
    test('短日记整篇放下，不标「日记节选」', () {
      final doc = DiaryDocument.parse('今天很短。\n\n> 下次再说');
      final excerpt = diaryShareExcerpt(doc);
      expect(excerpt.blocks.length, 2);
      expect(excerpt.truncated, isFalse);
      expect(excerpt.lastMaxLines, isNull);
    });

    test('长日记按预算截断，跨预算的段落按剩余行数截', () {
      final long = List.filled(5, '这' * 120).join('\n\n');
      final excerpt = diaryShareExcerpt(DiaryDocument.parse(long));
      expect(excerpt.truncated, isTrue);
      expect(excerpt.blocks.length, lessThan(5));
      expect(excerpt.lastMaxLines, isNotNull);
      expect(excerpt.lastMaxLines, greaterThanOrEqualTo(2));
    });

    test('不留一个后面什么都没有的孤立小标题', () {
      final text = '${'这' * 330}\n\n### 明天记得\n\n- ${'那' * 200}';
      final excerpt = diaryShareExcerpt(DiaryDocument.parse(text));
      expect(excerpt.truncated, isTrue);
      expect(excerpt.blocks.last.kind, isNot(DiaryBlockKind.heading));
    });
  });

  group('MomentParser 回退标题', () {
    test('正文开头的加粗短语不会被当成标题', () {
      final date = DateTime(2026, 10, 20); // 周二
      final parsed = MomentParser.parse('**周五**终于定下来了。', date: date);
      expect(parsed.title, isNot('周五'));
    });

    test('整行加粗的旧标题照旧识别', () {
      expect(MomentParser.parse('**A Quiet Tuesday**\n\nbody').title, 'A Quiet Tuesday');
    });
  });
}
