import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/pages/today_chapters/widgets/due_hint.dart';

/// `due_hint` 的解读（后端存的是「人说的原话」）。
///
/// 语料不是编的：下面每条带 ← 注释的都取自 2026-08-13 扫生产 Firestore 的结果
/// （排除 App Store 展示用的 mock 账号后，13 条真实 hint 的全集）。这个解析器就是
/// 为那 13 条里的两种毛病写的：4 条能定日却没填 due_date、2 条根本不是时间。
void main() {
  // 2026-08-05 是周三，下面所有相对日期都以它为基准。
  final wed = DateTime(2026, 8, 5, 14, 30);

  group('不是时间的短语 → 整个不当时间用', () {
    test('before I lose signal / during apology call（都来自生产）', () {
      expect(readDueHint('before I lose signal', spokenAt: wed).isTime, isFalse);
      expect(readDueHint('during apology call', spokenAt: wed).isTime, isFalse);
    });

    test('只说轻重不说时候的词也不算', () {
      // 老 prompt 把它们写成描述末尾的 `(urgent)`，迁移脚本原样搬进了 hint。
      for (final s in ['urgent', 'high priority', '高优先级', '紧急', '重要']) {
        expect(readDueHint(s, spokenAt: wed).isTime, isFalse, reason: s);
      }
    });

    test('空串', () {
      expect(readDueHint('', spokenAt: wed).isTime, isFalse);
      expect(readDueHint('   ', spokenAt: wed).isTime, isFalse);
    });
  });

  group('能定到具体某天的，要真的推出那一天', () {
    test('tomorrow ← 生产上这条 due_date 是空的', () {
      final r = readDueHint('tomorrow', spokenAt: wed);
      expect(r.date, DateTime(2026, 8, 6));
      expect(r.exact, isTrue, reason: '整句话就是一个日子，可以用日期措辞替代原话');
      expect(r.deadline, isFalse);
    });

    test('by Friday ← 同上；「前」这个语气要留住', () {
      final r = readDueHint('by Friday', spokenAt: wed);
      expect(r.date, DateTime(2026, 8, 7));
      expect(r.exact, isTrue);
      expect(r.deadline, isTrue);
    });

    test('周五前 / 8月20日前：中文的截止语气', () {
      expect(readDueHint('周五前', spokenAt: wed).date, DateTime(2026, 8, 7));
      expect(readDueHint('周五前', spokenAt: wed).deadline, isTrue);
      expect(readDueHint('8月20日前', spokenAt: wed).date, DateTime(2026, 8, 20));
    });

    test('星期名取「当天或之后最近的那个」', () {
      // 周三说「周三」指今天，不是下周三——周五上午说「周五交」同理。
      expect(readDueHint('Wednesday', spokenAt: wed).date, DateTime(2026, 8, 5));
      expect(readDueHint('周一', spokenAt: wed).date, DateTime(2026, 8, 10));
      expect(readDueHint('星期天', spokenAt: wed).date, DateTime(2026, 8, 9));
    });

    test('明确日期：08/20、2026-08-20、8月20日', () {
      expect(readDueHint('08/20', spokenAt: wed).date, DateTime(2026, 8, 20));
      expect(readDueHint('2026-08-20', spokenAt: wed).date, DateTime(2026, 8, 20));
      expect(readDueHint('8月20日', spokenAt: wed).date, DateTime(2026, 8, 20));
      expect(readDueHint('due 08/20', spokenAt: wed).date, DateTime(2026, 8, 20));
    });

    test('没有年份且日子已经过去很久 → 算次年（跨年说「1月5日」）', () {
      final dec = DateTime(2026, 12, 28, 10);
      expect(readDueHint('01/05', spokenAt: dec).date, DateTime(2027, 1, 5));
      // 只早几天的不算次年：那就是刚过去的那天，逾期是真的。
      expect(readDueHint('12/20', spokenAt: dec).date, DateTime(2026, 12, 20));
    });

    test('不存在的日子不许滚成下个月', () {
      // DateTime(2026, 2, 30) 会自己滚成 3 月 2 日 —— 那是编出来的一天。
      expect(readDueHint('02/30', spokenAt: wed).date, isNull);
      expect(readDueHint('13/01', spokenAt: wed).date, isNull);
    });
  });

  group('推不出日子的模糊说法：认，但不编日期', () {
    test('this week / 下周 / 尽快（都来自生产）', () {
      for (final s in ['this week', '下周', '尽快', 'next month', '本周内']) {
        final r = readDueHint(s, spokenAt: wed);
        expect(r.isTime, isTrue, reason: s);
        expect(r.date, isNull, reason: '$s 说不到具体哪天，编一个日期会在错的时间弹提醒');
      }
    });

    test('认得出的说法带中英对照，认不出的不硬翻', () {
      expect(readDueHint('this week', spokenAt: wed).zh, '本周内');
      expect(readDueHint('下周', spokenAt: wed).en, 'Next week');
      // 对照表的 key 是剥掉「前」之后的样子 —— 写成「月底前」那个条目永远匹配不到，
      // 英文界面就会退回原样显示中文。
      final monthEnd = readDueHint('月底前', spokenAt: wed);
      expect(monthEnd.en, 'Month end');
      expect(monthEnd.deadline, isTrue, reason: '「前」剥掉了，但语气要留在 deadline 上');
      expect(readDueHint('by month end', spokenAt: wed).zh, '月底');
      final unknown = readDueHint('Sunday around two', spokenAt: wed);
      expect(unknown.zh, isNull, reason: '不认识的说法只能原样显示，别猜着翻');
    });

    test('「今晚」「当下」这种除了日子还带别的信息 → 日子照推，但别用日期替代原话', () {
      final tonight = readDueHint('tonight', spokenAt: wed);
      expect(tonight.date, DateTime(2026, 8, 5), reason: '今晚就是今天，提醒事项要拿到这一天');
      expect(tonight.exact, isFalse, reason: '换成「今天」就把「晚上」丢了');
      expect(tonight.zh, '今晚');

      final now = readDueHint('当下', spokenAt: wed);
      expect(now.date, DateTime(2026, 8, 5));
      expect(now.exact, isFalse);
    });

    test('Sunday around two：日子能定，但原话里还有「around two」', () {
      final r = readDueHint('Sunday around two', spokenAt: wed);
      expect(r.date, DateTime(2026, 8, 9));
      expect(r.exact, isFalse, reason: 'exact 会让界面用「周日」替掉原话，那就丢了 around two');
    });

    test('嵌在长句里的日子也要推出来（提醒事项要靠它才会响）', () {
      expect(readDueHint('明天下午', spokenAt: wed).date, DateTime(2026, 8, 6));
      expect(readDueHint('明天下午', spokenAt: wed).exact, isFalse);
      // 长的说法要先试到：`\btomorrow\b` 也命中「day after tomorrow」，找短的会早一天。
      expect(readDueHint('day after tomorrow morning', spokenAt: wed).date, DateTime(2026, 8, 7));
      expect(readDueHint('后天上午', spokenAt: wed).date, DateTime(2026, 8, 7));
      expect(readDueHint('Wednesday at seven', spokenAt: wed).date, DateTime(2026, 8, 5));
      expect(readDueHint('tonight after dinner', spokenAt: wed).date, DateTime(2026, 8, 5));
    });

    test('说不清是哪一周的一律不猜', () {
      // 「next Friday」英语里本身就有歧义（这周五 or 下周五）；猜错就是提前/推后一周弹提醒。
      expect(readDueHint('next Friday', spokenAt: wed).date, isNull);
      expect(readDueHint('next Friday', spokenAt: wed).isTime, isTrue);
      expect(readDueHint('下周五', spokenAt: wed).date, isNull);
      // 过去的日子更不能当截止日。
      expect(readDueHint('last Monday', spokenAt: wed).date, isNull);
    });
  });

  group('写进苹果提醒事项的到期时刻', () {
    test('后端的 due_date 优先，hint 只在它为空时兜底', () {
      final backend = DateTime(2026, 8, 20, 15, 0);
      expect(reminderDueAt(dueDate: backend, dueHint: 'tomorrow', spokenAt: wed), backend);
      // 这条是修的正题：due_date 空 + hint 说了「明天」，以前传出去的是 null（不会响）。
      expect(reminderDueAt(dueHint: 'tomorrow', spokenAt: wed), DateTime(2026, 8, 6, 9));
    });

    test('只知道哪天时抬到 09:00，别让提醒在午夜响', () {
      expect(reminderDueAt(dueDate: DateTime(2026, 8, 20), dueHint: ''), DateTime(2026, 8, 20, 9));
      // 后端给了真时点就照用，别覆盖掉。
      expect(reminderDueAt(dueDate: DateTime(2026, 8, 20, 0, 30), dueHint: ''),
          DateTime(2026, 8, 20, 0, 30));
    });

    test('定不到具体某天就不设到期日，不编一个', () {
      expect(reminderDueAt(dueHint: '本周内', spokenAt: wed), isNull);
      expect(reminderDueAt(dueHint: 'before I lose signal', spokenAt: wed), isNull);
      expect(reminderDueAt(dueHint: 'tomorrow'), isNull, reason: '不知道这话什么时候说的');
      expect(reminderDueAt(), isNull);
    });
  });

  group('spokenAt 缺失', () {
    test('相对说法一律不推日期 —— 按今天算就是给错的那一天', () {
      final r = readDueHint('tomorrow');
      expect(r.isTime, isTrue);
      expect(r.date, isNull);
      expect(readDueHint('周五').date, isNull);
    });

    test('明确日期不受影响（只有年份要靠基准猜）', () {
      expect(readDueHint('2026-08-20').date, DateTime(2026, 8, 20));
    });
  });
}
