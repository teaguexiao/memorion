import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// P-01 今日三视图分段控件：章节 / 日记 / 关于我。
///
/// Figma v2.4：选中态为**品牌次蓝实心胶囊** (#54A4FD) + 白字；
/// 未选中为无背景无边框 + 次要灰字 (#808594)。全圆角 100，PingFang Medium 15。
class TodaySegmented extends StatelessWidget {
  final int selectedIndex;
  final List<String> labels;
  final ValueChanged<int>? onChanged;

  const TodaySegmented({
    super.key,
    required this.selectedIndex,
    required this.labels,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          _Segment(
            label: labels[i],
            selected: i == selectedIndex,
            onTap: () => onChanged?.call(i),
          ),
          if (i != labels.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _Segment extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Segment({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? JXB.brandSecondary : Colors.transparent,
          borderRadius: BorderRadius.circular(100),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: JXB.fontSans,
            fontSize: 15,
            height: 1.0,
            fontWeight: FontWeight.w500,
            color: selected ? Colors.white : JXB.textSecondary,
          ),
        ),
      ),
    );
  }
}
