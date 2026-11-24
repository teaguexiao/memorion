import 'package:flutter/material.dart';

/// 记小宝 1.0 页面背景：白底 + 三层径向渐变（蓝/紫蓝），还原 Figma v2.4 的柔和渐变。
///
/// Figma 定义（node 343:3025）：底色 #F9FAFA，叠加
///  1. 左上 紫蓝 rgba(121,133,255) 径向，透明度 30%
///  2. 右上 蓝  rgba(117,172,255) 径向，透明度 30%
///  3. 左侧 天蓝 rgba(150,197,252) 径向（竖向拉伸），透明度 100%
/// 用 Stack 叠三个 Container(RadialGradient) 近似（Flutter 无多背景图能力）。
class JxbGradientBackground extends StatelessWidget {
  final Widget child;
  final double? fadeHeight;
  const JxbGradientBackground({super.key, required this.child, this.fadeHeight});

  static const Color _base = Color(0xFFF9FAFA);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _base,
      child: Stack(
        children: [
          // 左侧天蓝（竖向拉伸，从左边缘往右淡出）
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-1.0, -0.9),
                  radius: 1.3,
                  colors: [
                    const Color(0xFF96C5FC).withValues(alpha: 0.9),
                    const Color(0x0096C5FC),
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
          ),
          // 右上蓝
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(1.0, -0.95),
                  radius: 1.1,
                  colors: [
                    const Color(0xFF75ACFF).withValues(alpha: 0.45),
                    const Color(0x00BAD6FF),
                  ],
                  stops: const [0.0, 0.75],
                ),
              ),
            ),
          ),
          // 顶部中偏左 紫蓝
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.1, -1.0),
                  radius: 0.95,
                  colors: [
                    const Color(0xFF7985FF).withValues(alpha: 0.35),
                    const Color(0x00F9FAFA),
                  ],
                  stops: const [0.0, 0.85],
                ),
              ),
            ),
          ),
          if (fadeHeight != null)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_base.withValues(alpha: .25), _base, _base],
                    stops: [0, (fadeHeight! / MediaQuery.sizeOf(context).height).clamp(0.0, 1.0), 1],
                  ),
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}
