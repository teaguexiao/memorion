import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// Onboarding 浅色输入框（邮箱认证各页共用）。
///
/// 浅灰底圆角 + 左侧图标 + 可选密码显隐开关，样式对齐 Figma v2.4 登录/注册页。
class OnboardingLightField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final VoidCallback? onToggleObscure;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onSubmitted;

  const OnboardingLightField({
    super.key,
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.onToggleObscure,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFFEDEFF2), borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon, size: 20, color: JXB.textPlaceholder),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              keyboardType: keyboardType,
              textCapitalization: textCapitalization,
              autocorrect: false,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPrimary),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPlaceholder),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
              ),
              onSubmitted: onSubmitted,
            ),
          ),
          if (onToggleObscure != null)
            GestureDetector(
              onTap: onToggleObscure,
              behavior: HitTestBehavior.opaque,
              child: Icon(obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 20, color: JXB.textPlaceholder),
            ),
        ],
      ),
    );
  }
}
