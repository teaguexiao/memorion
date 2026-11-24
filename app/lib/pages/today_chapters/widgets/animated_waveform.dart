import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// 顶栏「正在听」动态声音波形。
///
/// 7 根竖条以不同相位做正弦起伏，模拟实时录音波动。
/// Reduce Motion 时可由上层改为静态（本组件默认动画）。
class AnimatedWaveform extends StatefulWidget {
  final Color color;
  final int barCount;
  final double width;

  const AnimatedWaveform({
    super.key,
    this.color = JXB.brandPrimary,
    this.barCount = 7,
    this.width = 34,
  });

  @override
  State<AnimatedWaveform> createState() => _AnimatedWaveformState();
}

class _AnimatedWaveformState extends State<AnimatedWaveform> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // 每根竖条的相位偏移与基础高度系数，制造错落感。
  late final List<double> _phases;
  static const double _minH = 5;
  static const double _maxH = 17;

  @override
  void initState() {
    super.initState();
    _phases = List.generate(widget.barCount, (i) => i * 0.9);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200), // 比初版 900ms 慢 1/3
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: _maxH,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value * 2 * math.pi;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(widget.barCount, (i) {
              final s = (math.sin(t + _phases[i]) + 1) / 2; // 0..1
              final h = _minH + (_maxH - _minH) * s;
              return Container(
                width: 2.6,
                height: h,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
