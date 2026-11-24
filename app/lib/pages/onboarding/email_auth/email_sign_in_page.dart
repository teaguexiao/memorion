import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/onboarding/email_auth/email_sign_up_page.dart';
import 'package:memorion/pages/onboarding/email_auth/forgot_password_page.dart';
import 'package:memorion/pages/onboarding/onboarding_lang.dart';
import 'package:memorion/providers/auth_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/pages/onboarding/onboarding_background.dart';
import 'package:memorion/widgets/consent_bottom_sheet.dart';
import 'package:memorion/pages/onboarding/email_auth/onboarding_light_field.dart';
import 'package:provider/provider.dart';

/// O-02 邮箱登录（记小宝 1.0 浅色改版，Figma node 655:6660）。
class EmailSignInPage extends StatefulWidget {
  final VoidCallback onSignIn;

  const EmailSignInPage({super.key, required this.onSignIn});

  @override
  State<EmailSignInPage> createState() => _EmailSignInPageState();
}

class _EmailSignInPageState extends State<EmailSignInPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool _validateInputs() {
    final s = S.of(context);
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty) {
      setState(() => _errorMessage = s.authErrorEnterEmail);
      return false;
    }
    if (!RegExp(r'^[\w\-.]+@([\w-]+\.)+[\w-]{2,}$').hasMatch(email)) {
      setState(() => _errorMessage = s.authErrorInvalidEmail);
      return false;
    }
    if (password.isEmpty) {
      setState(() => _errorMessage = s.authErrorEnterPassword);
      return false;
    }
    return true;
  }

  Future<void> _signIn() async {
    if (!_validateInputs()) return;
    setState(() => _errorMessage = null);

    final s = S.of(context);
    final provider = context.read<AuthenticationProvider>();
    final error = await provider.onEmailSignIn(
      s,
      _emailController.text.trim(),
      _passwordController.text,
      () {
        if (!mounted) return;
        Navigator.of(context).pop();
        widget.onSignIn();
      },
    );
    if (error != null && mounted) setState(() => _errorMessage = error);
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
            child: Consumer<AuthenticationProvider>(
              builder: (context, provider, child) {
                return Column(
                  children: [
                    _backBar(context),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            _title(obL(context, '登录你的账号', 'Sign in to your account')),
                            const SizedBox(height: 6),
                            Text(obL(context, '开始你的智能生活记录之旅 ✦', 'Start your smart life journal ✦'),
                                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
                            const SizedBox(height: 30),
                            OnboardingLightField(
                              controller: _emailController,
                              hint: obL(context, '邮箱', 'Email'),
                              icon: Icons.person_outline_rounded,
                              keyboardType: TextInputType.emailAddress,
                            ),
                            const SizedBox(height: 14),
                            OnboardingLightField(
                              controller: _passwordController,
                              hint: obL(context, '密码', 'Password'),
                              icon: Icons.lock_outline_rounded,
                              obscure: _obscurePassword,
                              onToggleObscure: () => setState(() => _obscurePassword = !_obscurePassword),
                              onSubmitted: (_) => _signIn(),
                            ),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerRight,
                              child: GestureDetector(
                                onTap: () => Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => const ForgotPasswordPage())),
                                child: Text(obL(context, '忘记密码?', 'Forgot password?'),
                                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.brandPrimary)),
                              ),
                            ),
                            const SizedBox(height: 22),
                            if (_errorMessage != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 14),
                                child: Text(_errorMessage!,
                                    style: const TextStyle(fontFamily: JXB.fontSans, color: JXB.error, fontSize: 14)),
                              ),
                            _primaryButton(obL(context, '登录', 'Sign in'), provider.loading ? null : _signIn, loading: provider.loading),
                            const SizedBox(height: 18),
                            Center(
                              child: GestureDetector(
                                onTap: () => Navigator.of(context).pushReplacement(
                                    MaterialPageRoute(builder: (_) => EmailSignUpPage(onSignIn: widget.onSignIn))),
                                child: RichText(
                                  text: TextSpan(
                                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14),
                                    children: [
                                      TextSpan(text: obL(context, '还没有账号? ', "Don't have an account? "), style: const TextStyle(color: JXB.textSecondary)),
                                      TextSpan(text: obL(context, '注册', 'Sign up'), style: const TextStyle(color: JXB.brandPrimary, fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 34),
                            _dividerWithText(obL(context, '其他登录方式', 'Or continue with')),
                            const SizedBox(height: 20),
                            _socialRow(provider),
                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
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

  Widget _title(String t) => Text(t,
      style: const TextStyle(fontFamily: JXB.fontDisplay, fontSize: 28, fontWeight: FontWeight.w700, color: JXB.textPrimary));

  Widget _dividerWithText(String text) {
    return Row(
      children: [
        const Expanded(child: Divider(color: JXB.border)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(text, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder)),
        ),
        const Expanded(child: Divider(color: JXB.border)),
      ],
    );
  }

  Widget _socialRow(AuthenticationProvider provider) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (Platform.isIOS) ...[
          _socialButton(
            Image.asset('assets/images/apple_icon_black.png', width: 26, height: 26),
            () {
              HapticFeedback.mediumImpact();
              ConsentBottomSheet.show(context,
                  authMethod: 'apple', onContinue: () async => provider.onAppleSignIn(widget.onSignIn));
            },
          ),
          const SizedBox(width: 20),
        ],
        _socialButton(
          Image.asset('assets/images/google_logo.png', width: 26, height: 26),
          () {
            HapticFeedback.mediumImpact();
            ConsentBottomSheet.show(context,
                authMethod: 'google', onContinue: () async => provider.onGoogleSignIn(widget.onSignIn));
          },
        ),
      ],
    );
  }

  Widget _socialButton(Widget icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 56, height: 56, alignment: Alignment.center,
        decoration: BoxDecoration(color: JXB.surface, shape: BoxShape.circle, boxShadow: JXB.cardShadow),
        child: icon,
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback? onTap, {bool loading = false}) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
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
