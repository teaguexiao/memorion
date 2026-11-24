import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// P-13 待确认事实气泡卡（Figma node 343:16004「关于我」页，挂在「你答应过的事」下面）。
///
/// 它从对话里猜出一条关于你的事实，但**还没确认**——用虚线框（区别于实心的正式
/// 事实卡）+ 左上黄色「它猜的」标签表达「这是猜测、待你拍板」。
///
/// 真数据：`Memory` 里 `reviewed==false && manually_added==false && user_review==null`
/// 的待确认事实（LLM 提取，后端 `status=pending`）。
/// 「没错」→ `user_review=true` 写进正式事实库、出现在「它记住的事实」；
/// 「不对」→ `user_review=false` 记住否决、以后不再问（tombstone，不物理删）。
///
/// 无状态：只负责画，拍板逻辑在 `MemoriesProvider.confirmFact/rejectFact`。
class FactBubbleCard extends StatelessWidget {
  final String tagLabel;
  final String body;
  final String confirmLabel;
  final String dismissLabel;
  final VoidCallback? onConfirm;
  final VoidCallback? onDismiss;

  const FactBubbleCard({
    super.key,
    required this.tagLabel,
    required this.body,
    required this.confirmLabel,
    required this.dismissLabel,
    this.onConfirm,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return _DashedBorder(
      color: JXB.warning,
      radius: 16,
      strokeWidth: 1.5,
      dashWidth: 5,
      dashGap: 4,
      child: Container(
        width: double.infinity,
        // 虚线画在外，内容自己留白；背景用极浅黄透出「它猜的」暖调。
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: JXB.warningTint,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _GuessTag(label: tagLabel),
            const SizedBox(height: 10),
            Text(
              body,
              style: const TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 14,
                height: 1.5,
                fontWeight: FontWeight.w400,
                color: JXB.textPrimary,
                letterSpacing: 0.28,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _PillButton(label: confirmLabel, filled: true, onTap: onConfirm),
                const SizedBox(width: 8),
                _PillButton(label: dismissLabel, filled: false, onTap: onDismiss),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 左上「它猜的」小黄标：黄底白字圆角 pill。
class _GuessTag extends StatelessWidget {
  final String label;
  const _GuessTag({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: JXB.warning,
        borderRadius: BorderRadius.circular(JXB.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.help_outline_rounded, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontFamily: JXB.fontSans,
              fontSize: 11,
              height: 1.0,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback? onTap;

  const _PillButton({required this.label, required this.filled, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? JXB.brandPrimary : const Color(0xFFF2F2F7),
      borderRadius: BorderRadius.circular(JXB.radiusFull),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(JXB.radiusFull),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: JXB.fontSans,
              fontSize: 13,
              height: 1.0,
              fontWeight: filled ? FontWeight.w600 : FontWeight.w500,
              color: filled ? Colors.white : JXB.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 轻量虚线边框：用 [CustomPaint] 画圆角虚线矩形，把 child 包在里面。
/// 故意不用 pubspec 里的 `dotted_border` 包——它的圆角虚线在这个版本有对不齐的
/// 老问题，且私有实现避免和那个包的同名 widget 撞名。
class _DashedBorder extends StatelessWidget {
  final Widget child;
  final Color color;
  final double radius;
  final double strokeWidth;
  final double dashWidth;
  final double dashGap;

  const _DashedBorder({
    required this.child,
    required this.color,
    this.radius = 16,
    this.strokeWidth = 1.5,
    this.dashWidth = 5,
    this.dashGap = 4,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRRectPainter(
        color: color,
        radius: radius,
        strokeWidth: strokeWidth,
        dashWidth: dashWidth,
        dashGap: dashGap,
      ),
      child: child,
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double strokeWidth;
  final double dashWidth;
  final double dashGap;

  _DashedRRectPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
    required this.dashWidth,
    required this.dashGap,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    // 描边画在边界内侧半个线宽处，虚线才不会被裁掉半截。
    final inset = strokeWidth / 2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(inset, inset, size.width - strokeWidth, size.height - strokeWidth),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);

    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final next = distance + dashWidth;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth ||
      old.dashWidth != dashWidth ||
      old.dashGap != dashGap;
}
