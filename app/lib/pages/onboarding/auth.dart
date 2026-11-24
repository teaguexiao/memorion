import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/pages/onboarding/email_auth/email_sign_in_page.dart';
import 'package:memorion/pages/onboarding/onboarding_lang.dart';
import 'package:memorion/providers/auth_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/widgets/consent_bottom_sheet.dart';
import 'package:provider/provider.dart';

/// O-01 登录首页（记小宝 1.0 浅色改版，Figma node 655:6488）。
///
/// 浅色渐变背景 + 无限环 logo +「记小宝」+ 三种登录方式（Google / Apple / 邮箱）。
/// 业务逻辑全部复用旧壳：`AuthenticationProvider` + `ConsentBottomSheet`。
class AuthComponent extends StatefulWidget {
  final VoidCallback onSignIn;

  const AuthComponent({super.key, required this.onSignIn});

  @override
  State<AuthComponent> createState() => _AuthComponentState();
}

class _AuthComponentState extends State<AuthComponent> {
  @override
  Widget build(BuildContext context) {
    return Consumer<AuthenticationProvider>(
      builder: (context, provider, child) {
        return SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  const Spacer(flex: 3),
                  // 品牌区：无限环 logo +「记小宝」+ 副标题
                  Image.asset(
                    'assets/images/memorion_infinity_logo.png',
                    height: 58,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 14),
                  const Text('Memorion', // i18n-ignore: 品牌名（中英一致）
                      style: TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 30, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                  const SizedBox(height: 16),
                  Text(obL(context, 'Memorion 记住你说过的一切', 'Memorion remembers everything you say'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textSecondary)),
                  const Spacer(flex: 4),
                  // 登录按钮组
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 20,
                          child: provider.loading
                              ? const Center(
                                  child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: JXB.brandPrimary)))
                              : null,
                        ),
                        const SizedBox(height: 8),
                        _authButton(
                          icon: Image.asset('assets/images/google_logo.png', width: 22, height: 22),
                          label: obL(context, '通过 Google 继续', 'Continue with Google'),
                          onTap: () {
                            HapticFeedback.mediumImpact();
                            ConsentBottomSheet.show(
                              context,
                              authMethod: 'google',
                              onContinue: () async => provider.onGoogleSignIn(widget.onSignIn),
                            );
                          },
                        ),
                        if (Platform.isIOS) ...[
                          const SizedBox(height: 14),
                          _authButton(
                            icon: Image.asset('assets/images/apple_icon_black.png', width: 22, height: 22),
                            label: obL(context, '通过 Apple 继续', 'Continue with Apple'),
                            onTap: () {
                              HapticFeedback.mediumImpact();
                              ConsentBottomSheet.show(
                                context,
                                authMethod: 'apple',
                                onContinue: () async => provider.onAppleSignIn(widget.onSignIn),
                              );
                            },
                          ),
                        ],
                        const SizedBox(height: 14),
                        _authButton(
                          icon: const Icon(Icons.mail_outline_rounded, size: 21, color: JXB.textPrimary),
                          label: obL(context, '用邮箱登录', 'Sign in with email'),
                          onTap: () {
                            HapticFeedback.mediumImpact();
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => EmailSignInPage(onSignIn: widget.onSignIn)),
                            );
                          },
                        ),
                        const SizedBox(height: 22),
                        _legalText(context, provider),
                        SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
                      ],
                    ),
                  ),
                ],
              ),
              // 右上角语言切换
              Positioned(
                top: 8,
                right: 16,
                child: const OnboardingLangSwitch(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _authButton({required Widget icon, required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 54,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: JXB.surface,
          borderRadius: BorderRadius.circular(999),
          boxShadow: JXB.cardShadow,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(width: 10),
            Text(label,
                style: const TextStyle(
                    fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
          ],
        ),
      ),
    );
  }

  Widget _legalText(BuildContext context, AuthenticationProvider provider) {
    final zh = obL(context, 'zh', 'en') == 'zh';
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder),
        children: [
          TextSpan(text: zh ? '继续即代表同意 ' : 'By continuing you agree to the '),
          TextSpan(
            text: zh ? '用户协议' : 'Terms',
            style: const TextStyle(color: JXB.brandPrimary),
            recognizer: TapGestureRecognizer()..onTap = provider.openTermsOfService,
          ),
          TextSpan(text: zh ? ' 与 ' : ' & '),
          TextSpan(
            text: zh ? '隐私政策' : 'Privacy Policy',
            style: const TextStyle(color: JXB.brandPrimary),
            recognizer: TapGestureRecognizer()..onTap = provider.openPrivacyPolicy,
          ),
        ],
      ),
    );
  }
}
