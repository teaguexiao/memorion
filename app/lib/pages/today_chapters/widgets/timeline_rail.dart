import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// 时间线左侧竖轴：连接线 + 圆点。作为每个条目的 leading 列。
///
/// Figma v2.4：竖线浅灰、圆点 8px（章节=品牌蓝 #007AFF，空档=灰 #B2B2B2）。
/// 圆点纵向对齐到条目顶部的 meta 行（时段文字）中心。高度自适应条目内容。
class TimelineRail extends StatelessWidget {
  final bool isFirst;
  final bool isLast;
  final Color dotColor;

  /// 圆点相对条目顶部的中心 y。章节条目顶部是 meta 行(高约 22)，取其中心 ~11。
  final double dotCenterY;

  const TimelineRail({
    super.key,
    required this.isFirst,
    required this.isLast,
    this.dotColor = JXB.brandPrimary,
    this.dotCenterY = 11,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      child: CustomPaint(
        painter: _RailPainter(
          isFirst: isFirst,
          isLast: isLast,
          dotColor: dotColor,
          dotCenterY: dotCenterY,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  final bool isFirst;
  final bool isLast;
  final Color dotColor;
  final double dotCenterY;

  _RailPainter({
    required this.isFirst,
    required this.isLast,
    required this.dotColor,
    required this.dotCenterY,
  });

  static const double _dotRadius = 4; // 8px 直径
  static const double _lineWidth = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final linePaint = Paint()
      ..color = JXB.border
      ..strokeWidth = _lineWidth
      ..strokeCap = StrokeCap.round;

    // 竖线：首条从圆点向下，末条到圆点为止，中间贯穿全高。
    final top = isFirst ? dotCenterY : 0.0;
    final bottom = isLast ? dotCenterY : size.height;
    canvas.drawLine(Offset(cx, top), Offset(cx, bottom), linePaint);

    // 圆点：实心色（不再画底色光晕，避免盖住渐变背景）。
    canvas.drawCircle(Offset(cx, dotCenterY), _dotRadius, Paint()..color = dotColor);
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.isFirst != isFirst ||
      old.isLast != isLast ||
      old.dotColor != dotColor ||
      old.dotCenterY != dotCenterY;
}
