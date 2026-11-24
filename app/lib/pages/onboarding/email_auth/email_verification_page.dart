import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/onboarding/onboarding_lang.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/pages/onboarding/onboarding_background.dart';

/// O-02c 验证你的邮箱（记小宝 1.0 浅色改版，Figma node 655:6962）。
class EmailVerificationPage extends StatefulWidget {
  final String email;
  final VoidCallback onContinue;

  const EmailVerificationPage({super.key, required this.email, required this.onContinue});

  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage> {
  bool _checking = false;
  String? _message;
  bool _isSuccessMessage = false;
  int _resendCooldown = 0;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkVerification() async {
    final s = S.of(context);
    setState(() {
      _checking = true;
      _message = null;
      _isSuccessMessage = false;
    });
    try {
      await FirebaseAuth.instance.currentUser?.reload();
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && user.emailVerified) {
        if (mounted) {
          setState(() {
            _message = s.emailAuthVerifySuccess;
            _isSuccessMessage = true;
          });
          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted) {
            Navigator.of(context).pop();
            widget.onContinue();
          }
        }
      } else {
        if (mounted) setState(() => _message = s.emailAuthVerifyPending);
      }
    } catch (_) {
      if (mounted) setState(() => _message = s.emailAuthVerifyCheckFailed);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _resendEmail() async {
    if (_resendCooldown > 0) return;
    final s = S.of(context);
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification();
      setState(() {
        _message = s.emailAuthVerifyResent;
        _resendCooldown = 60;
      });
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_resendCooldown <= 1) {
          timer.cancel();
          if (mounted) setState(() => _resendCooldown = 0);
        } else {
          if (mounted) setState(() => _resendCooldown--);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _message = s.emailAuthVerifyResendFailed);
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  // 邮箱图标（还原设计稿 664:7044）：浅蓝渐变圆角卡 + 渐变信封 SVG，微旋转 4°
                  Transform.rotate(
                    angle: 4 * 3.1415926 / 180,
                    child: Container(
                      width: 100,
                      height: 100,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.bottomRight,
                          end: Alignment.topLeft,
                          colors: [Color(0xFFDCECFF), Color(0xFFF6FAFF)],
                        ),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: const Color(0xFFDCECFF)),
                      ),
                      child: Transform.rotate(
                        angle: -4 * 3.1415926 / 180,
                        child: SvgPicture.asset('assets/images/onboarding/envelope_mail.svg', width: 48, height: 40),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(obL(context, '验证你的邮箱', 'Verify your email'),
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 24, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                  const SizedBox(height: 14),
                  Text(
                      obL(context, '我们向 ${widget.email} 发送了验证邮件，请点击邮件中的链接完成验证。',
                          'We sent a verification email to ${widget.email}. Tap the link inside to finish.'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.6, color: JXB.textSecondary)),
                  const SizedBox(height: 24),
                  GestureDetector(
                    onTap: _resendCooldown > 0 ? null : _resendEmail,
                    behavior: HitTestBehavior.opaque,
                    child: Text(
                      _resendCooldown > 0
                          ? obL(context, '重新发送 (${_resendCooldown}s)', 'Resend (${_resendCooldown}s)')
                          : obL(context, '重新发送', 'Resend'),
                      style: TextStyle(
                          fontFamily: JXB.fontSans,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: _resendCooldown > 0 ? JXB.textPlaceholder : JXB.brandPrimary),
                    ),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 16),
                    Text(_message!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontFamily: JXB.fontSans, fontSize: 13, color: _isSuccessMessage ? JXB.success : JXB.textSecondary)),
                  ],
                  const Spacer(flex: 2),
                  _primaryButton(obL(context, '我已验证', "I've verified"), _checking ? null : _checkVerification, loading: _checking),
                  SizedBox(height: MediaQuery.of(context).padding.bottom + 20),
                ],
              ),
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
