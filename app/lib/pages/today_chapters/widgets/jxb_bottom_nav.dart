import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// P-01 底部导航：**居中悬浮胶囊**（今日 / 回想）。
///
/// Figma 实测：宽 198.64、高 55.64、圆角 27.56，半透明白底 (95%)，
/// 大阴影 0px 5.72px 19.76px rgba(43,41,38,0.09)，内边距 5.72。
/// 选中项为 rgba(0,122,255,0.09) 圆角 21.84 高亮块 + 品牌蓝图标/文字 Bold 9.88；
/// 未选中为透明 + 占位灰 Medium。悬浮在内容之上、贴近底部安全区。
class JxbBottomNav extends StatelessWidget {
  final int selectedIndex;
  final String todayLabel;
  final String recallLabel;
  final ValueChanged<int>? onChanged;

  const JxbBottomNav({
    super.key,
    required this.selectedIndex,
    required this.todayLabel,
    required this.recallLabel,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 55.64,
      padding: const EdgeInsets.all(5.72),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(27.56),
        border: Border.all(color: JXB.border, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x172B2926), // rgba(43,41,38,0.09)
            offset: Offset(0, 5.72),
            blurRadius: 19.76,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _NavItem(
            icon: Icons.access_time_rounded,
            label: todayLabel,
            selected: selectedIndex == 0,
            onTap: () => onChanged?.call(0),
          ),
          const SizedBox(width: 5.72),
          _NavItem(
            icon: Icons.cloud_outlined,
            label: recallLabel,
            selected: selectedIndex == 1,
            onTap: () => onChanged?.call(1),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? JXB.brandPrimary : JXB.textPlaceholder;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 89.44,
        height: 43.68,
        decoration: BoxDecoration(
          color: selected ? const Color(0x17007AFF) : Colors.transparent, // brand 9%
          borderRadius: BorderRadius.circular(21.84),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 10,
                height: 1.0,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
