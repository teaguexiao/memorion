import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// P-01 章节卡（v2.4 扁平版）：白底、圆角 12、内边距 12，无边框无重阴影。
/// 卡内仅标题 + 正文；时段与分类/高亮标签由 [ChapterMetaRow] 放在卡片上方。
class ChapterCard extends StatelessWidget {
  final String title;
  final String observation;
  final bool discarded;
  final VoidCallback? onTap;

  const ChapterCard({
    super.key,
    required this.title,
    required this.observation,
    this.discarded = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: JXB.surface,
          borderRadius: BorderRadius.circular(JXB.radiusControl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: JXB.chapterTitle),
            if (discarded) ...[
              const SizedBox(height: 4),
              Text(revampText(context, en: 'Processed · filtered', zh: '处理完成 · 已过滤'),
                  style: JXB.chapterBody.copyWith(color: JXB.textSecondary)),
            ],
            // 第一人称观察为空时整行隐藏（不显示占位/骨架），保持干净留白。
            if (observation.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(observation, style: JXB.chapterBody),
            ],
          ],
        ),
      ),
    );
  }
}

/// 章节卡上方的元信息行：时段（左）+ 分类/高亮标签（右）。
class ChapterMetaRow extends StatelessWidget {
  final String timeRange;
  final String category;

  /// 是否显示⭐高亮标签。数据源为 `structured.is_highlighted`（未来由硬件按钮触发），
  /// 与章节详情「值得回顾的时刻」(structured.highlights) 已解耦。
  final bool hasHighlight;

  const ChapterMetaRow({
    super.key,
    required this.timeRange,
    this.category = 'Other', // i18n-ignore: 兜底值，调用方均传 localizeCategory 的本地化结果
    this.hasHighlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(timeRange, style: JXB.chapterTime),
        const Spacer(),
        if (hasHighlight) ...[
          const _HighlightChip(),
          const SizedBox(width: 8),
        ],
        _CategoryChip(label: category),
      ],
    );
  }
}

/// 分类标签（如「工作」）：淡蓝底 #f6faff / 文字 #68acff。
class _CategoryChip extends StatelessWidget {
  final String label;
  const _CategoryChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF6FAFF),
        borderRadius: BorderRadius.circular(31.2),
      ),
      child: Text(label, style: JXB.tagLabel.copyWith(color: const Color(0xFF68ACFF))),
    );
  }
}

/// 高亮标签「⭐ 高亮」：暖黄底 #fff5de / 文字 #ffb13e。
///
/// 语义 = 这段被用户**按硬件按钮**标为高亮（is_highlighted），是个布尔态，
/// 故不带条数（旧版「含 N 条高亮」的 N 来自 AI 生成的 highlights，已解耦移除）。
class _HighlightChip extends StatelessWidget {
  const _HighlightChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5DE),
        borderRadius: BorderRadius.circular(31.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 14, color: JXB.warning),
          const SizedBox(width: 4),
          Text(revampText(context, en: 'Highlight', zh: '高亮'), style: JXB.tagLabel.copyWith(color: JXB.warning)),
        ],
      ),
    );
  }
}
