import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// 到期待办「提醒卡」：已确认的待办到点了，记小宝在首页顶部提醒一句。
///
/// Figma（node 343-16307 / 343-16463）：白底圆角气泡（右上带小尾巴指向云朵吉祥物），
/// 顶部「小宝提醒：」次要色小字，正文一句话（可高亮关键词），右下两枚全圆角按钮
/// 「OK」(蓝实心) /「稍后提醒我」(浅底)。
///
/// 两种形态：
///  - [TaskReminderCard]：提醒态，两枚按钮；
///  - [TaskReminderAckCard]：点「稍后提醒我」后的回执态（无按钮），「收到 👌，半小时后我再提醒你」。
class TaskReminderCard extends StatelessWidget {
  final String speaker;
  final String body;
  final String confirmLabel;
  final String snoozeLabel;
  final VoidCallback? onConfirm;
  final VoidCallback? onSnooze;

  const TaskReminderCard({
    super.key,
    required this.speaker,
    required this.body,
    required this.confirmLabel,
    required this.snoozeLabel,
    this.onConfirm,
    this.onSnooze,
  });

  @override
  Widget build(BuildContext context) {
    return _ReminderBubble(
      speaker: speaker,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _ReminderBody(text: body),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _PillButton(label: confirmLabel, filled: true, onTap: onConfirm),
              const SizedBox(width: 8),
              _PillButton(label: snoozeLabel, filled: false, onTap: onSnooze),
            ],
          ),
        ],
      ),
    );
  }
}

/// 点「稍后提醒我」后的回执气泡：只显示一句确认文案，无按钮。
class TaskReminderAckCard extends StatelessWidget {
  final String speaker;
  final String body;

  const TaskReminderAckCard({super.key, required this.speaker, required this.body});

  @override
  Widget build(BuildContext context) {
    return _ReminderBubble(
      speaker: speaker,
      child: _ReminderBody(text: body),
    );
  }
}

/// 白底圆角气泡 + 顶部说话人小字 + 右上小尾巴，两种形态共用。
class _ReminderBubble extends StatelessWidget {
  final String speaker;
  final Widget child;

  const _ReminderBubble({required this.speaker, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
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
              child,
            ],
          ),
        ),
        // 右上角指向云朵吉祥物的小尾巴（说话气泡效果）。
        Positioned(
          top: -6,
          right: 24,
          child: CustomPaint(size: const Size(16, 8), painter: _BubbleTailPainter()),
        ),
      ],
    );
  }
}

/// 提醒正文：整段文字，无项目符号（与待确认卡的 bullet 区分开）。
class _ReminderBody extends StatelessWidget {
  final String text;
  const _ReminderBody({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: JXB.fontSans,
        fontSize: 14,
        height: 1.5,
        fontWeight: FontWeight.w400,
        color: JXB.textPrimary,
        letterSpacing: 0.28,
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
