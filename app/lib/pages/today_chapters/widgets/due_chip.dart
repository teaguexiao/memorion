import 'package:flutter/material.dart';
import 'package:memorion/pages/today_chapters/widgets/due_hint.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// [DueChip] 的三种显示形态。同一份「什么时候」的信息，摆在不同宽度里要长得不一样。
enum DueChipVariant {
  /// 独占一行的胶囊：浅色底 + 图标 + 文字。
  pill,

  /// 行内紧凑：去掉底色和内边距，只留图标 + 文字，靠颜色区分。
  /// 用在「一行放下描述 + 时间」的地方（「关于我」摘要卡），省掉胶囊那 16px 横向占位。
  inline,

  /// 描述下方独立一行的灰色小字（Figma v2.4 node 1069:2477 的 P-03 待办行）。
  /// 无底色、无图标（逾期例外），因为**有一整行的宽度**，可以把星期和时点都写出来。
  caption,
}

/// 待办的截止标签（P-03「你答应过的事」与「关于我」摘要卡共用）。
///
/// 后端把截止时间拆成两个字段：
/// - `dueDate`：只在能确定到具体某天时才有值；
/// - `dueHint`：人说的原话（「本周内」「尽快」），模糊说法只有它。
///
/// 有日期就显示日期（今天/明天/逾期特殊措辞），只有模糊说法就显示那句原话，
/// 两者都没有则整个标签不渲染——不占位、不编造时间。
///
/// ⚠️ **原话不是照搬**，`dueHint` 要先过 [readDueHint]（2026-08-13 起）：
/// - 不像时间的短语整个不渲染。实测生产上有 `before I lose signal`、
///   `during apology call` 这种进了 hint，照搬就是在时间位置上写一句废话。
/// - 认得出的说法按界面语言显示：hint 存的是**说话时**的语言，英文对话产出的
///   `this week` 会原样出现在中文界面里。
/// - hint 本身点到了具体某天（`明天`、`周五`、`by Friday`）时，用日期措辞替代原话——
///   顺带把逾期算出来。`dueDate` 本该由后端填上，实测 13 条真实 hint 里 4 条没填。
class DueChip extends StatelessWidget {
  final DateTime? dueDate;
  final String dueHint;

  /// 这条待办所在对话发生的时刻（列表接口的 `created_at`）。
  ///
  /// `dueHint` 里的相对说法以它为基准：三天前说的「明天」指的是两天前。为 null 时
  /// 不推算相对日期（宁可只显示原话，也不按今天算出错的那天）。
  final DateTime? spokenAt;

  /// 顶部间距（[DueChipVariant.pill] 才用得上）。
  final double topPadding;

  final DueChipVariant variant;

  const DueChip({
    super.key,
    required this.dueDate,
    required this.dueHint,
    this.spokenAt,
    this.topPadding = 6,
    this.variant = DueChipVariant.pill,
  });

  @override
  Widget build(BuildContext context) {
    final label = _label(context);
    if (label == null) return const SizedBox.shrink();
    final overdue = label.overdue;

    if (variant == DueChipVariant.caption) {
      // 逾期仍然给红字 + 图标：设计稿没画这个态，但「已经错过了」是必须留的信号。
      final color = overdue ? JXB.error : JXB.textSecondary;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (overdue) ...[
            Icon(Icons.error_outline_rounded, size: 12, color: color),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              label.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: JXB.fontSans, fontSize: 12, height: 1.3, color: color),
            ),
          ),
        ],
      );
    }

    final color = overdue ? JXB.error : JXB.brandPrimary;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(overdue ? Icons.error_outline_rounded : Icons.schedule_rounded, size: 12, color: color),
        const SizedBox(width: 3),
        Text(
          label.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: JXB.fontSans,
            fontSize: 11,
            height: 1.0,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
    if (variant == DueChipVariant.inline) return content;
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: overdue ? JXB.errorTint : JXB.brandPrimary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(JXB.radiusFull),
        ),
        child: content,
      ),
    );
  }

  ({String text, bool overdue})? _label(BuildContext context) {
    // hint 只在后端没给日期时才解读——有 due_date 就以它为准，那是后端算过的。
    final reading = dueDate != null || dueHint.isEmpty
        ? DueHintReading.none
        : readDueHint(dueHint, spokenAt: spokenAt);
    final d = dueDate ?? reading.date;

    if (d == null) {
      // 推不出日子：认得出的说法按界面语言写，不认识的原样搬，不是时间的不渲染。
      if (!reading.isTime) return null;
      final known = isRevampChinese(context) ? reading.zh : reading.en;
      if (known == null) return (text: dueHint, overdue: false);
      // 「…前 / by …」的语气在解读时被剥掉了（表里存的是剥完的样子），这里补回来——
      // 不补的话「月底前」会显示成「月底」，那是两件事。
      if (reading.deadline) {
        return (text: revampText(context, en: 'By ${known.toLowerCase()}', zh: '$known前'), overdue: false);
      }
      return (text: known, overdue: false);
    }

    // caption 独占一行，写得下星期 + 时点；pill / inline 挤在描述旁边，只给最短的那种。
    final verbose = variant == DueChipVariant.caption;
    final now = DateTime.now();
    final days = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    final date = revampText(context, en: '${d.month}/${d.day}', zh: '${d.month}月${d.day}日');
    if (days < 0) {
      // 已经过去的日子一律走这条，包括从 hint 推出来的：一句三天前说的「明天」
      // 标成红色的「明天」只会让人困惑，写「已过期 · 8月10日」才说得清。
      return (text: revampText(context, en: 'Overdue · $date', zh: '已过期 · $date'), overdue: true);
    }
    // 日子是从 hint 推出来的，而这句话除了日子还带别的信息（「今晚」「Sunday around
    // two」）——那就显示原话，别用日期把「晚上」「around two」抹掉。
    if (dueDate == null && !reading.exact) {
      final known = isRevampChinese(context) ? reading.zh : reading.en;
      return (text: known ?? dueHint, overdue: false);
    }
    // 「今天/明天」比「周三」好认，所以近两天优先用它，本周内的才落到星期。
    final day = days == 0
        ? revampText(context, en: 'Today', zh: '今天')
        : days == 1
            ? revampText(context, en: 'Tomorrow', zh: '明天')
            : (verbose && days < 7)
                ? _weekday(context, d)
                : date;
    final time = verbose ? _timeOfDay(d) : null;
    final text = time == null ? day : '$day $time';
    // hint 是「…前 / by …」那种截止语气时把语气留住：「周五」和「周五前」不是一件事。
    if (dueDate == null && reading.deadline) {
      return (text: revampText(context, en: 'By $text', zh: '$text前'), overdue: false);
    }
    return (text: text, overdue: false);
  }

  String _weekday(BuildContext context, DateTime d) {
    // DateTime.weekday 是 1(周一)~7(周日)。
    const zh = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const en = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final i = d.weekday - 1;
    return revampText(context, en: en[i], zh: zh[i]); // i18n-ignore: 上面两张表是中英对照的星期名
  }

  /// 具体时点，`null` 表示不显示。
  ///
  /// ⚠️ 00:00 一律当成「只知道哪天、不知道几点」：LLM 提不到时点时给的就是当天零点
  /// （`ActionItem.due_date` 的语义是「只在能确定到具体日期时才填」）。照原样渲染成
  /// 「周五 0:00」会把「没说时间」显示成「凌晨要做」。代价是真约在零点的那种会少显示
  /// 一个时点，比编一个假时间划算。
  String? _timeOfDay(DateTime d) {
    if (d.hour == 0 && d.minute == 0) return null;
    return '${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  }
}
