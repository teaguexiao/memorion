import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// P-01 处理中卡：会话正在整理。
///
/// Figma 实测：极浅品牌底 (brandPrimary 3%) + 1px 边框、圆角 ~20、高 52，
/// 左侧品牌蓝 spinner + 文案「我还在整理刚才那段对话…」。不可点。
class ProcessingCard extends StatelessWidget {
  final String text;

  const ProcessingCard({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 52,
      decoration: BoxDecoration(
        color: JXB.brandTintFaint,
        borderRadius: BorderRadius.circular(JXB.radiusBubble),
        border: Border.all(color: JXB.border, width: 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(JXB.brandPrimary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: JXB.metaButton.copyWith(color: JXB.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
