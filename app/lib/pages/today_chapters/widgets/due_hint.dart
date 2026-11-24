/// 解读后端 `ActionItem.due_hint`（人说的原话）。
///
/// 后端把「什么时候」拆成两个字段：`due_date` 只在能定到具体某天时才填，模糊说法只进
/// `due_hint`，**刻意不推算** —— 生产 prompt `conversation.structure` v8 的原话是
/// "A wrong date fires a reminder at the wrong moment, which is worse than no date"。
/// 这个文件不推翻那条原则，只补它漏掉的两种情况（2026-08-13 实测生产数据）：
///
/// 1. **hint 明明能定日，`due_date` 却是空的。** prompt 里写着「短语点到具体某天时你
///    必须同时填 due_date」，实测 13 条真实 hint 里有 4 条违反（`tomorrow` / `by Friday`
///    / `next month` / `tonight`）。后果不只是显示生硬：加进苹果提醒事项时只传
///    `due_date`，这几条等于没有到期日、根本不会响。
/// 2. **hint 里会混进根本不是时间的短语**（实测 `before I lose signal`、
///    `during apology call`），而界面把它当时间标签原样显示。
///
/// 判据与白名单沿用后端的 `scripts/migrate_action_item_due.py`（那个脚本干的是同一件
/// 事的存量版本，2026-08-13 已对全部历史数据跑过）。**两边必须一致**，否则同一句话在
/// 存量和新数据里表现不同。分界线是：`asap` / `尽快` 回答的是「什么时候」（能多快就多
/// 快）算时间，`urgent` / `高优先级` 回答的是「多要紧」不算。
///
/// ⚠️ **相对说法一律以「这句话是什么时候说的」为基准**，不是以今天为基准。三天前说的
/// 「明天」指的是两天前，按今天算会把一件已经过期的事显示成还没到期。所以 [readDueHint]
/// 的 `spokenAt` 为 null 时**不推算任何相对日期**（宁可不显示，也不给错的那天）。
library;

/// 对一句 `due_hint` 的解读。
class DueHintReading {
  /// 这段话到底是不是在说「什么时候」。false ⇒ 别把它当时间标签显示。
  final bool isTime;

  /// 从 hint 推出来的那一天（本地时区 00:00，「知道哪天、不知道几点」）。
  /// null = 推不出来，别编。
  final DateTime? date;

  /// [date] 是否已经完整表达了这句 hint。
  ///
  /// 「明天」「周五」这种整句话就是一个日子，用日期措辞替代原话只会更好（还能顺带
  /// 本地化、算逾期）。「Sunday around two」「今晚」这种除了日子还带别的信息，替换掉
  /// 就把「around two」「晚上」丢了 —— 那时要显示原话。
  final bool exact;

  /// 「…前 / by …」这类截止语气，[exact] 时用来在日期外面包一层。
  final bool deadline;

  /// 认得出来的短语的中英说法；null = 不认识这个说法，只能原样显示。
  final String? en;
  final String? zh;

  const DueHintReading({
    this.isTime = false,
    this.date,
    this.exact = false,
    this.deadline = false,
    this.en,
    this.zh,
  });

  /// 不是时间表达。
  static const none = DueHintReading();
}

/// 中英对照的时间短语表：key 是规范化后的原文，值是两种界面语言下的说法。
///
/// hint 存的是**说话时的语言**（prompt 里是 `{{output_language}}`），所以英文对话产出的
/// `this week` 会原样出现在中文界面里。这张表就是给这种情况用的；表里没有的说法保持
/// 原样，不硬翻。
// i18n-ignore: 中英对照常量表，每个条目自带 en/zh 两种说法
const Map<String, ({String en, String zh})> _phrases = {
  'today': (en: 'Today', zh: '今天'),
  '今天': (en: 'Today', zh: '今天'),
  '今日': (en: 'Today', zh: '今天'),
  '今日内': (en: 'Today', zh: '今天内'),
  'tonight': (en: 'Tonight', zh: '今晚'),
  '今晚': (en: 'Tonight', zh: '今晚'),
  'tomorrow': (en: 'Tomorrow', zh: '明天'),
  '明天': (en: 'Tomorrow', zh: '明天'),
  '明日': (en: 'Tomorrow', zh: '明天'),
  // 「the」是可选的，两种写法都得有条目 —— 只留带 the 的那个，`day after tomorrow`
  // 会退到更短的 `tomorrow` 上，早一天。
  'the day after tomorrow': (en: 'In 2 days', zh: '后天'), // i18n-ignore: key 是待匹配的原话
  'day after tomorrow': (en: 'In 2 days', zh: '后天'), // i18n-ignore: key 是待匹配的原话
  '后天': (en: 'In 2 days', zh: '后天'),
  'this week': (en: 'This week', zh: '本周内'),
  '本周': (en: 'This week', zh: '本周内'),
  '本周内': (en: 'This week', zh: '本周内'),
  'next week': (en: 'Next week', zh: '下周'),
  '下周': (en: 'Next week', zh: '下周'),
  'this weekend': (en: 'This weekend', zh: '本周末'),
  '本周末': (en: 'This weekend', zh: '本周末'),
  'this month': (en: 'This month', zh: '本月内'),
  '本月': (en: 'This month', zh: '本月内'),
  '本月内': (en: 'This month', zh: '本月内'),
  // ⚠️ key 是**剥掉「前」/「by」之后**的样子（见 [readDueHint] 的剥离顺序）。写成
  // `月底前` / `by month end` 那个条目永远匹配不到，英文界面会退回原样显示中文。
  '月底': (en: 'Month end', zh: '月底'),
  '月末': (en: 'Month end', zh: '月底'),
  'month end': (en: 'Month end', zh: '月底'), // i18n-ignore: key 是待匹配的原话
  'end of month': (en: 'Month end', zh: '月底'), // i18n-ignore: key 是待匹配的原话
  'next month': (en: 'Next month', zh: '下月'),
  '下月': (en: 'Next month', zh: '下月'),
  'asap': (en: 'ASAP', zh: '尽快'),
  'as soon as possible': (en: 'ASAP', zh: '尽快'),
  '尽快': (en: 'ASAP', zh: '尽快'),
  'soon': (en: 'Soon', zh: '近期'),
  '近期': (en: 'Soon', zh: '近期'),
  'when convenient': (en: 'When convenient', zh: '有空时'),
  '有空时': (en: 'When convenient', zh: '有空时'),
  '方便时': (en: 'When convenient', zh: '有空时'),
  'ongoing': (en: 'Ongoing', zh: '持续'),
  '持续': (en: 'Ongoing', zh: '持续'),
  'right now': (en: 'Right now', zh: '当下'),
  '当下': (en: 'Right now', zh: '当下'),
  '现在': (en: 'Right now', zh: '当下'),
  '立刻': (en: 'Right away', zh: '立刻'),
  '马上': (en: 'Right away', zh: '立刻'),
  '立即': (en: 'Right away', zh: '立即'),
};

/// 能定到具体某天的相对说法 → 相对天数。
const Map<String, int> _relativeDays = {
  'today': 0, '今天': 0, '今日': 0, '今日内': 0,
  'tonight': 0, '今晚': 0,
  'right now': 0, '当下': 0, '现在': 0, '立刻': 0, '马上': 0,
  'tomorrow': 1, '明天': 1, '明日': 1,
  'the day after tomorrow': 2, 'day after tomorrow': 2, '后天': 2, // i18n-ignore: 待匹配的原话
};

/// 只说了这一句就等于说了一个日子的那些（其余的还带别的信息，见 [DueHintReading.exact]）。
const Set<String> _dayOnlyWords = {
  'today', '今天', '今日',
  'tomorrow', '明天', '明日',
  'the day after tomorrow', 'day after tomorrow', '后天', // i18n-ignore: 待匹配的原话
};

/// 星期名 → `DateTime.weekday`（1 = 周一）。
const Map<String, int> _weekdays = {
  'monday': 1, 'mon': 1, '周一': 1, '星期一': 1, '礼拜一': 1,
  'tuesday': 2, 'tue': 2, 'tues': 2, '周二': 2, '星期二': 2, '礼拜二': 2,
  'wednesday': 3, 'wed': 3, '周三': 3, '星期三': 3, '礼拜三': 3,
  'thursday': 4, 'thu': 4, 'thurs': 4, '周四': 4, '星期四': 4, '礼拜四': 4,
  'friday': 5, 'fri': 5, '周五': 5, '星期五': 5, '礼拜五': 5,
  'saturday': 6, 'sat': 6, '周六': 6, '星期六': 6, '礼拜六': 6,
  'sunday': 7, 'sun': 7, '周日': 7, '周天': 7, '星期日': 7, '星期天': 7, '礼拜天': 7,
};

/// 只说轻重、不说时候的词。它们不该出现在时间标签里（历史 prompt 会把它们
/// 写成 `(urgent)` 这样的括号后缀，迁移脚本把这类原样搬进了 hint）。
const Set<String> _priorityOnly = {
  'urgent', 'high priority', 'important', 'tbd',
  '紧急', '高优先级', '重要', '待定',
};

/// 「像时间」的词根。中文直接包含匹配，英文按词边界匹配（否则 `sat` 会命中
/// `saturate`、`mon` 会命中 `money`）。
///
/// 这条线是这么划的：**能落到日历或一天之内某个时点上的算时间**（`after dinner`
/// = 饭后，放得下）；**要靠另一件没排期的事才定位的不算**（`during apology call`
/// 得先知道那通电话什么时候打，`before I lose signal` 更是无从落点）。后两种是
/// 2026-08-13 在生产数据里实见的，界面把它们摆在日期的位置上纯属噪音。
final RegExp _zhTimeMarker = RegExp(
    '周|星期|礼拜|今|明|后天|昨|天|日|号|月|年|季|早|上午|中午|下午|晚|夜|点|时|分|秒|小时|'
    '分钟|内|前|后|末|初|旬|尽快|随时|近期|有空|方便|持续|立刻|马上|现在|当下|假|节|'
    '饭|睡|起床|通勤');
final RegExp _enTimeMarker = RegExp(
    r'\b(week|weeks|weekend|day|days|today|tonight|tomorrow|yesterday|month|months|year|'
    r'years|morning|afternoon|evening|night|noon|midnight|hour|hours|minute|minutes|'
    r'oclock|am|pm|asap|soon|later|now|immediately|monday|mon|tuesday|tue|tues|wednesday|'
    r'wed|thursday|thu|thurs|friday|fri|saturday|sat|sunday|sun|convenient|ongoing|'
    r'deadline|due|eod|eow|breakfast|lunch|dinner|bedtime)\b',
    caseSensitive: false);

/// `08/20` `8-20` `2026-08-20` `8月20日`
final RegExp _md = RegExp(r'^(\d{1,2})[/-](\d{1,2})$');
final RegExp _iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$');
final RegExp _mdZh = RegExp(r'^(\d{1,2})月(\d{1,2})[日号]$');

/// 读一句 `due_hint`。
///
/// [spokenAt] 是这条待办所在**对话发生的时刻**（列表接口返回的 `created_at`），相对说法
/// 以它为基准。为 null 时不推算相对日期 —— 见文件头的说明。
DueHintReading readDueHint(String raw, {DateTime? spokenAt}) {
  var s = raw.trim();
  if (s.isEmpty) return DueHintReading.none;

  // 「…前」「by …」「due …」：截止语气，剥掉之后再按日子解析。
  var deadline = false;
  final byPrefix = RegExp(r'^(by|before|due)\s+', caseSensitive: false);
  if (byPrefix.hasMatch(s)) {
    deadline = true;
    s = s.replaceFirst(byPrefix, '').trim();
  }
  if (s.length > 1 && (s.endsWith('前') || s.endsWith('之前'))) { // i18n-ignore: 待剥掉的原话后缀
    deadline = true;
    s = s.substring(0, s.length - (s.endsWith('之前') ? 2 : 1)); // i18n-ignore: 同上
  }
  final key = s.toLowerCase().replaceAll(RegExp(r'[.。,，、!！?？\s]+$'), '');
  if (key.isEmpty) return DueHintReading.none;

  // 只说轻重的词整个丢掉：显示成时间会让人以为「urgent」是个日子。
  if (_priorityOnly.contains(key)) return DueHintReading.none;

  final phrase = _phrases[key];

  DateTime? date;
  var exact = false;

  final rel = _relativeDays[key];
  if (rel != null) {
    if (spokenAt != null) date = _midnight(spokenAt).add(Duration(days: rel));
    exact = _dayOnlyWords.contains(key);
  } else if (_weekdays.containsKey(key)) {
    if (spokenAt != null) date = _nextWeekday(_midnight(spokenAt), _weekdays[key]!);
    exact = true;
  } else {
    final m = _iso.firstMatch(key);
    if (m != null) {
      date = _safeDate(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
      exact = date != null;
    } else {
      final md = _md.firstMatch(key) ?? _mdZh.firstMatch(s);
      if (md != null) {
        // 没有年份：先按说话那年算，算出来比说话时刻早太多就当次年（跨年说「1月5日」）。
        final base = spokenAt ?? DateTime.now();
        var cand = _safeDate(base.year, int.parse(md.group(1)!), int.parse(md.group(2)!));
        if (cand != null && base.difference(cand).inDays > 180) {
          cand = _safeDate(base.year + 1, cand.month, cand.day);
        }
        date = cand;
        exact = date != null;
      }
    }
  }

  // 整句话不是一个日子，但里面嵌着一个（`Sunday around two`、`明天下午`，都来自生产）。
  // 日子照推——提醒事项要靠它才会响；exact 保持 false，界面继续显示原话，不然
  // 「around two」「下午」就被替换掉了。
  if (date == null && spokenAt != null) {
    date = _embeddedDay(s, key, spokenAt);
  }

  final looksLikeTime = date != null ||
      phrase != null ||
      _zhTimeMarker.hasMatch(s) ||
      _enTimeMarker.hasMatch(s);
  if (!looksLikeTime) return DueHintReading.none;

  return DueHintReading(
    isTime: true,
    date: date,
    exact: exact,
    deadline: deadline,
    en: phrase?.en,
    zh: phrase?.zh,
  );
}

/// 一条待办写进苹果提醒事项时的到期时刻。null = 不设到期日。
///
/// 后端的 [dueDate] 优先，那是它算过的；为空时才退回 [dueHint] 里能定死的那一天——
/// prompt 要求「短语点到具体某天时必须同时填 due_date」，实测 13 条真实 hint 里有 4 条
/// 没填（`tomorrow` / `by Friday` / `tonight` / `next month`）。只认 `due_date` 的话
/// 这几条加进提醒事项后没有到期日、根本不会响，而这正是加提醒的全部意义。
///
/// ⚠️ **只知道哪天（00:00）时抬到当天 09:00 再写出去。** 原生那侧
/// （`AppleRemindersService.swift:105`）把年月日时分整套塞进 `dueDateComponents`，
/// 零点就是零点——提醒会在午夜响，落在人的感受里是「前一天深夜」。更正的做法是不传时分、
/// 让它成为全天提醒，那要改原生，先不动。显示侧不受影响：`DueChip` 拿到的还是原始的
/// 00:00，仍然不显示时点。
DateTime? reminderDueAt({DateTime? dueDate, String dueHint = '', DateTime? spokenAt}) {
  final d = dueDate ?? readDueHint(dueHint, spokenAt: spokenAt).date;
  if (d == null) return null;
  if (d.hour == 0 && d.minute == 0) return DateTime(d.year, d.month, d.day, 9);
  return d;
}

/// 从一句更长的话里认出它落在哪一天。认不出就返回 null（宁可不显示日期）。
DateTime? _embeddedDay(String s, String key, DateTime spokenAt) {
  // 「next Friday」在英语里本身就有歧义（这周五还是下周五），「上周五」是过去的事，
  // 「下个月 15 号」也不是最近那个 15 号 —— 这几类一律不猜。
  if (RegExp(r'\b(next|last|coming|following|previous)\b').hasMatch(key) ||
      RegExp('下个|上个|下周|上周|下月|上月|去年|明年').hasMatch(s)) { // i18n-ignore: 待匹配的原话
    return null;
  }
  // ⚠️ **长的说法先试。** `\btomorrow\b` 会命中「the day after tomorrow」，按声明顺序
  // 找的话「day after tomorrow morning」会被算成明天 —— 提醒早响一天。
  for (final e in _longestFirst(_relativeDays)) {
    if (_mentions(s, key, e.key)) return _midnight(spokenAt).add(Duration(days: e.value));
  }
  for (final e in _longestFirst(_weekdays)) {
    if (_mentions(s, key, e.key)) return _nextWeekday(_midnight(spokenAt), e.value);
  }
  return null;
}

/// 按 key 从长到短，好让「the day after tomorrow」在「tomorrow」之前被试到。
List<MapEntry<String, int>> _longestFirst(Map<String, int> m) =>
    m.entries.toList()..sort((a, b) => b.key.length.compareTo(a.key.length));

/// 这句话里有没有提到 [token]。
///
/// 英文按词边界匹配（`\bsun\b` 不会命中 `sunday`，更不会命中 `sunscreen`）；中文没有词
/// 边界的概念，直接看是不是子串。
bool _mentions(String s, String key, String token) {
  if (RegExp(r'^[a-z0-9 ]+$').hasMatch(token)) {
    return RegExp('\\b${RegExp.escape(token)}\\b').hasMatch(key);
  }
  return s.contains(token);
}

DateTime _midnight(DateTime d) {
  final l = d.toLocal();
  return DateTime(l.year, l.month, l.day);
}

/// 从 [from]（含当天）起最近的那个星期 [weekday]。
///
/// 含当天是有意的：周五上午说「周五交」指的就是今天，不是下周五。
DateTime _nextWeekday(DateTime from, int weekday) {
  final delta = (weekday - from.weekday + 7) % 7;
  return from.add(Duration(days: delta));
}

DateTime? _safeDate(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  final made = DateTime(y, m, d);
  // DateTime 会把 2 月 30 日滚成 3 月 2 日，滚过就说明这个日子不存在。
  if (made.month != m || made.day != d) return null;
  return made;
}
