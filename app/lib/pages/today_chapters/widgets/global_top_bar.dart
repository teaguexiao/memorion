import 'package:flutter/material.dart';
import 'package:memorion/pages/today_chapters/widgets/animated_waveform.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// P-01 全局顶栏：左设备电量芯片 / 中录音波形 / 右设置。
///
/// Figma v2.4：左右都带一层浅色椭圆/圆形背景（半透明白 + 极浅描边）。
/// 图标用 Figma 导出的真实 SVG，保证 100% 还原（设置为定位/齿轮环样式）。
class GlobalTopBar extends StatelessWidget {
  final int batteryPercent;
  final bool connected;
  final bool charging;
  final bool recording; // 正在录音 → 中间指示灯变红闪烁
  final VoidCallback? onDeviceTap;
  final VoidCallback? onDeviceLongPress; // DEBUG：长按切换模拟设备状态
  final VoidCallback? onRecordTap;
  final VoidCallback? onSettingsTap;

  const GlobalTopBar({
    super.key,
    this.batteryPercent = 82,
    this.connected = true,
    this.charging = false,
    this.recording = false,
    this.onDeviceTap,
    this.onDeviceLongPress,
    this.onRecordTap,
    this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _DeviceChip(percent: batteryPercent, connected: connected, charging: charging, onTap: onDeviceTap, onLongPress: onDeviceLongPress),
            const Spacer(),
            _RecordingCenter(onTap: onRecordTap, recording: recording),
            const Spacer(),
            _SettingsButton(onTap: onSettingsTap),
          ],
        ),
      ),
    );
  }
}

/// 左：浅色椭圆芯片。已连接→电量环+百分比（充电显闪电）；未连接→灰底+断开蓝牙图标+「未连接」。
class _DeviceChip extends StatelessWidget {
  final int percent;
  final bool connected;
  final bool charging;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const _DeviceChip({required this.percent, this.connected = true, this.charging = false, this.onTap, this.onLongPress});

  Color _batteryColor(int p) {
    if (p > 50) return JXB.success;
    if (p >= 20) return const Color(0xFFF2B21A);
    return JXB.error;
  }

  @override
  Widget build(BuildContext context) {
    // 未连接态：灰芯片 + 断开蓝牙图标 + 「未连接」。
    if (!connected) {
      return GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: const Color(0x14808594),
            borderRadius: BorderRadius.circular(21.6),
            border: Border.all(color: Colors.white, width: 0.45),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bluetooth_disabled_rounded, size: 15, color: JXB.textSecondary),
              const SizedBox(width: 5),
              Text(revampText(context, en: 'Offline', zh: '未连接'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12.6, fontWeight: FontWeight.w500, color: JXB.textSecondary)),
            ],
          ),
        ),
      );
    }

    final ringColor = _batteryColor(percent);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(21.6),
          border: Border.all(color: Colors.white, width: 0.45),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 21.6,
              height: 21.6,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 21.6,
                    height: 21.6,
                    child: CircularProgressIndicator(
                      value: percent / 100.0,
                      strokeWidth: 2,
                      backgroundColor: const Color(0xFFDEE6F0),
                      valueColor: AlwaysStoppedAnimation<Color>(ringColor),
                    ),
                  ),
                  // 充电显闪电，否则蓝牙图标
                  Icon(charging ? Icons.bolt_rounded : Icons.bluetooth, size: 10,
                      color: charging ? const Color(0xFFF2B21A) : JXB.brandSecondary),
                ],
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '$percent%',
              style: const TextStyle(
                fontFamily: JXB.fontNumber,
                fontSize: 12.6,
                fontWeight: FontWeight.w500,
                color: JXB.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 中：录音状态（绿点 + 动态波形）。点击进 P-06（未录音开始录音 / 录音中看详情）。
/// 去掉了原来独立的暂停圆钮——录音详情页内已有暂停/结束，避免重复入口；声波保持常驻动态。
class _RecordingCenter extends StatelessWidget {
  final VoidCallback? onTap;
  final bool recording;
  const _RecordingCenter({this.onTap, this.recording = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusDot(recording: recording),
            const SizedBox(width: 8),
            const AnimatedWaveform(color: JXB.brandSecondary),
          ],
        ),
      ),
    );
  }
}

/// 状态指示灯：未录音 → 静态绿点；录音中 → 红点，透明度 1s 周期呼吸闪烁。
class _StatusDot extends StatefulWidget {
  final bool recording;
  const _StatusDot({required this.recording});

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
    if (widget.recording) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.recording && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.recording && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.recording) {
      return Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(color: JXB.success, shape: BoxShape.circle),
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final opacity = 0.3 + 0.7 * (1 - _controller.value); // 1.0 ↔ 0.3 呼吸
        return Opacity(
          opacity: opacity,
          child: Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(color: JXB.error, shape: BoxShape.circle),
          ),
        );
      },
    );
  }
}

/// 右：浅色圆形背景 + 设置图标（Figma 真实 SVG）。
class _SettingsButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _SettingsButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.4),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 0.45),
        ),
        child: const Icon(Icons.settings, size: 21.6, color: JXB.textPrimary),
      ),
    );
  }
}
