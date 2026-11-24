import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// P-01 空档条：这段我不在 / 你按了暂停 / 设备已关机。
///
/// Figma v2.4：矮条（高 ~22），极浅灰文案 12px + 右侧 › chevron。
/// 左侧灰点由时间线 rail 提供。文案由 `WearTracking` 推导的未覆盖时长生成。
class CoverageGapBar extends StatelessWidget {
  final String text;

  const CoverageGapBar({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 12,
                color: JXB.textPlaceholder,
              ),
            ),
          ),
          const Text('›', style: TextStyle(color: JXB.textPlaceholder, fontSize: 16)),
        ],
      ),
    );
  }
}
