import 'package:flutter/material.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/onboarding/email_auth/onboarding_light_field.dart';
import 'package:memorion/pages/onboarding/onboarding_lang.dart';
import 'package:memorion/providers/auth_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/pages/onboarding/onboarding_background.dart';
import 'package:provider/provider.dart';

/// O-02d 重置密码（记小宝 1.0 浅色改版，Figma node 731:2981）。
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _emailController = TextEditingController();
  String? _errorMessage;
  bool _sent = false;
  bool _loading = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendResetLink() async {
    final s = S.of(context);
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _errorMessage = s.authErrorEnterEmail);
      return;
    }
    if (!RegExp(r'^[\w\-.]+@([\w-]+\.)+[\w-]{2,}$').hasMatch(email)) {
      setState(() => _errorMessage = s.authErrorInvalidEmail);
      return;
    }
    setState(() {
      _errorMessage = null;
      _loading = true;
    });
    final provider = context.read<AuthenticationProvider>();
    final error = await provider.onForgotPassword(s, email);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _errorMessage = error;
        _loading = false;
      });
    } else {
      setState(() {
        _sent = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: Scaffold(
        backgroundColor: JXB.bgApp,
        body: OnboardingBackground(
          child: SafeArea(
            child: Column(
              children: [
                _backBar(context),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        Text(obL(context, '重置密码', 'Reset password'),
                            style: const TextStyle(
                                fontFamily: JXB.fontDisplay, fontSize: 28, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                        const SizedBox(height: 8),
                        Text(
                            obL(context, '输入你的注册邮箱，我们会向你发送重置密码的链接。✦',
                                'Enter your email and we\'ll send you a reset link. ✦'),
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
                        const SizedBox(height: 28),
                        if (_sent) ...[
                          Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color: JXB.successTint,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: JXB.success.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.check_circle_rounded, color: JXB.success, size: 22),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(S.of(context).emailAuthResetEmailSent,
                                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPrimary)),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 22),
                          Center(
                            child: GestureDetector(
                              onTap: () => Navigator.of(context).pop(),
                              child: Text(S.of(context).emailAuthBackToSignIn,
                                  style: const TextStyle(
                                      fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.brandPrimary)),
                            ),
                          ),
                        ] else ...[
                          OnboardingLightField(
                            controller: _emailController,
                            hint: obL(context, '邮箱地址', 'Email address'),
                            icon: Icons.mail_outline_rounded,
                            keyboardType: TextInputType.emailAddress,
                            onSubmitted: (_) => _sendResetLink(),
                          ),
                          const SizedBox(height: 20),
                          if (_errorMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Text(_errorMessage!,
                                  style: const TextStyle(fontFamily: JXB.fontSans, color: JXB.error, fontSize: 14)),
                            ),
                          _primaryButton(obL(context, '发送重置链接', 'Send reset link'), _loading ? null : _sendResetLink, loading: _loading),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _backBar(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 36, height: 36, alignment: Alignment.center,
              decoration: const BoxDecoration(color: Color(0x14808594), shape: BoxShape.circle),
              child: const Icon(Icons.chevron_left_rounded, size: 24, color: JXB.textPrimary),
            ),
          ),
        ),
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback? onTap, {bool loading = false}) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? JXB.brandPrimary : JXB.brandPrimary.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(999),
        ),
        child: loading
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Text(label,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }
}
