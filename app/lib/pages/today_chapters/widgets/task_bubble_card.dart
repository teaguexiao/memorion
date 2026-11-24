import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// P-01 任务气泡卡：记小宝听到一件可能的待办，气泡样式询问是否记下。
///
/// Figma v2.4：白底圆角气泡（左上带小尾巴），顶部「我刚刚听到一件事：」次要色小字，
/// 正文含项目符号，右下两枚全圆角按钮「加入待办」(蓝实心) /「不是待办」(浅底)。
///
/// 真数据：`ActionItem.confirmed == false` 的待确认待办（后端 LLM 提取时写入）。
/// 「加入待办」→ confirmed=true 进 to-do list；「不是待办」→ 后端删除、直接弃掉。
class TaskBubbleCard extends StatelessWidget {
  final String speaker;
  final String body;
  final String confirmLabel;
  final String dismissLabel;
  final VoidCallback? onConfirm;
  final VoidCallback? onDismiss;

  const TaskBubbleCard({
    super.key,
    required this.speaker,
    required this.body,
    required this.confirmLabel,
    required this.dismissLabel,
    this.onConfirm,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _bubbleBody(),
        // 右上角指向云朵吉祥物的小尾巴（说话气泡效果）。
        Positioned(
          top: -6,
          right: 24,
          child: CustomPaint(size: const Size(16, 8), painter: _BubbleTailPainter()),
        ),
      ],
    );
  }

  Widget _bubbleBody() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Color(0x0F264D78), offset: Offset(0, 2), blurRadius: 12),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$speaker：',
            style: const TextStyle(
              fontFamily: JXB.fontSans,
              fontSize: 12,
              height: 1.0,
              fontWeight: FontWeight.w400,
              color: JXB.textSecondary,
              letterSpacing: 0.24,
            ),
          ),
          const SizedBox(height: 8),
          _BulletBody(text: body),
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
    );
  }
}

/// 项目符号正文：行首圆点 + 富文本（「Q3 定价评审」高亮蓝）。
class _BulletBody extends StatelessWidget {
  final String text;
  const _BulletBody({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, right: 8),
          child: Container(
            width: 4,
            height: 4,
            decoration: const BoxDecoration(color: JXB.textPrimary, shape: BoxShape.circle),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontFamily: JXB.fontSans,
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w400,
              color: JXB.textPrimary,
              letterSpacing: 0.28,
            ),
          ),
        ),
      ],
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

/// 气泡右上角的小三角尾巴，指向上方的云朵吉祥物。
class _BubbleTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = JXB.surface;
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width * 0.5, 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
