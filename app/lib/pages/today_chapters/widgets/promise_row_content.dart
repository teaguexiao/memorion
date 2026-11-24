import 'package:flutter/material.dart';
import 'package:memorion/pages/today_chapters/widgets/due_chip.dart';
import 'package:memorion/pages/today_chapters/widgets/due_hint.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// P-03「你答应过的事」里一条待办的行内容（设计稿 node 1130:2509）。
///
/// 有截止时间时是两行（20 + 18）：
///
/// ```
/// ○  给小王 BOM 清单     ← 第一行：勾选圈 + 描述
///    周五 10:00          ← 第二行：截止时间（灰字）
/// ```
///
/// 时间从「描述右侧的行内小蓝标签」挪到了第二行左侧的灰字：挤在一行里时它跟描述抢
/// 宽度，长描述一来时间就先被挤没；独占一行之后反而写得下星期和时点。
///
/// ⚠️ **没有截止时间的条目只有一行。** 后端 `ActionItem.due_date` 只在能确定到具体某天时
/// 才填，所以「没有时间」是常态而不是边角情况；照样留一行空的第二行会白占高度，让每条
/// 待办看着都比实际内容高一截。已完成的条目同理只有第一行——时间对做完的事没有意义。
///
/// 「加入提醒事项」不在这儿：按设计稿它和删除一起待在**左滑露出的区域**里
/// （见 `promises_page._promiseRow`）。中途试过把它做成第二行右侧一颗常驻文字胶囊
/// （node 1069:2477），已按设计稿撤回——那版还踩过一个坑：胶囊直接跟在第一行的 `Text`
/// 后面时，描述是 `Expanded` + `ellipsis`，胶囊会被挤到下一行去。
///
/// 单独成文件是为了能直接 pump：页面本体 `initState` 就发网络请求，测不了布局。
/// 规则由 `test/promise_row_layout_test.dart` 钉住。
class PromiseRowContent extends StatelessWidget {
  final String description;

  /// 只在后端能确定到具体某天时才有值。
  final DateTime? dueDate;

  /// 人说的原话（「本周内」「尽快」），模糊说法只有它。
  final String dueHint;

  /// 这条待办所在对话发生的时刻。`dueHint` 里的相对说法（「明天」）要以它为基准，
  /// 不是以今天为基准——见 [DueChip.spokenAt]。
  final DateTime? spokenAt;

  final bool completed;

  /// 点勾选圈。
  final VoidCallback? onToggle;

  /// 行底色。默认白；左滑打开的那一行按设计稿换成 #F2F2F7，好让「哪一行开着」看得出来
  /// ——短描述会被左移出裁剪区，只剩两颗按钮的话行看着是空的。
  final Color? background;

  const PromiseRowContent({
    super.key,
    required this.description,
    required this.dueDate,
    required this.dueHint,
    this.spokenAt,
    required this.completed,
    required this.onToggle,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    // ⚠️ 判据是「有没有时间可显示」，不是「dueHint 非空」：不像时间的 hint（实测有
    // `before I lose signal` 这种）DueChip 会整个不渲染，第二行就会白占 18px。这里
    // 与 DueChip 各解一次 hint，为的是让 DueChip 自己拿着 hint 也能独立工作。
    final hasDue =
        !completed && (dueDate != null || readDueHint(dueHint, spokenAt: spokenAt).isTime);
    return Container(
      // 行底色不能透明：左滑时下层的删除键会从文字后面透出来。
      color: background ?? JXB.surface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 勾选圈：命中区 34×32，别让 20px 的小圈成为唯一可点区域。多出来的高度落在
          // 第一行下方（有第二行时那儿是时间那行的左边，没有第二行时是行的内边距）。
          //
          // ⚠️ 这个 32 不能跟着内容缩。已完成的条目只有一行 20 高，命中区一旦缩到 20，
          // 整行高度也就只有 20——已完成卡里行与行贴到一起，那条 0.5px 分隔线会压在
          // 文字上。行高实际是靠这个命中区撑住的。
          GestureDetector(
            onTap: onToggle,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 34,
              height: 32,
              child: Align(
                alignment: Alignment.topLeft,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // 设计稿：未完成 = 白底 + 浅灰描边；已完成 = 品牌次级蓝实心 + 白勾。
                    color: completed ? JXB.brandSecondary : Colors.transparent,
                    border: completed ? null : Border.all(color: JXB.border, width: 1),
                  ),
                  alignment: Alignment.center,
                  child: completed ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 20,
                  child: Text(
                    description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: JXB.fontSans,
                      fontSize: 14,
                      height: 1.3,
                      letterSpacing: 0.28,
                      // 已完成：划线 + 60% 透明（设计稿 line-through / opacity 60%）
                      decoration: completed ? TextDecoration.lineThrough : null,
                      color: completed ? JXB.textPrimary.withValues(alpha: 0.6) : JXB.textPrimary,
                    ),
                  ),
                ),
                if (hasDue)
                  SizedBox(
                    height: 18,
                    child: DueChip(
                      dueDate: dueDate,
                      dueHint: dueHint,
                      spokenAt: spokenAt,
                      variant: DueChipVariant.caption,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
