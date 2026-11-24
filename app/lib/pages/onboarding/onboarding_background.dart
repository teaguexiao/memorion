import 'package:flutter/material.dart';
import 'package:memorion/pages/today_chapters/widgets/jxb_gradient_background.dart';

/// Onboarding 浅色背景 = 蓝白渐变（复用 [JxbGradientBackground]）+ 点阵装饰。
///
/// 还原 Figma v2.4 onboarding 各页背景的「多圆点画板」(Dot Matrix Board)：
/// 右上一簇 + 左侧中部一簇，小圆点 `#E7E4DD`（72% 透明）平铺，营造柔和肌理。
class OnboardingBackground extends StatelessWidget {
  final Widget child;
  const OnboardingBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return JxbGradientBackground(
      child: Stack(
        children: [
          // 点阵装饰（不拦截手势）
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _DotMatrixPainter()),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _DotMatrixPainter extends CustomPainter {
  static const Color _dot = Color(0xB8E7E4DD); // #E7E4DD @ 72%
  static const double _gap = 13; // 点间距
  static const double _r = 1.3; // 点半径

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = _dot;

    // 右上簇（对齐设计稿 x≈232..405, y≈-45..200）
    _cluster(canvas, paint, Rect.fromLTWH(size.width - 158, -30, 173, 244));
    // 左侧中部簇（x≈-55..70, y≈117..294）
    _cluster(canvas, paint, const Rect.fromLTWH(-55, 117, 125, 177));
  }

  void _cluster(Canvas canvas, Paint paint, Rect area) {
    for (double y = area.top; y < area.bottom; y += _gap) {
      for (double x = area.left; x < area.right; x += _gap) {
        if (x < -_r || y < -_r) continue;
        canvas.drawCircle(Offset(x, y), _r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
