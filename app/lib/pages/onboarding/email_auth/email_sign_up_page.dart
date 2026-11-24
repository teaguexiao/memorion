import 'package:flutter/material.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/onboarding/email_auth/email_sign_in_page.dart';
import 'package:memorion/pages/onboarding/email_auth/email_verification_page.dart';
import 'package:memorion/pages/onboarding/email_auth/onboarding_light_field.dart';
import 'package:memorion/pages/onboarding/onboarding_lang.dart';
import 'package:memorion/providers/auth_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/pages/onboarding/onboarding_background.dart';
import 'package:memorion/widgets/consent_bottom_sheet.dart';
import 'package:provider/provider.dart';

/// O-02b 创建账号（记小宝 1.0 浅色改版，Figma node 655:6837）。
class EmailSignUpPage extends StatefulWidget {
  final VoidCallback onSignIn;

  const EmailSignUpPage({super.key, required this.onSignIn});

  @override
  State<EmailSignUpPage> createState() => _EmailSignUpPageState();
}

class _EmailSignUpPageState extends State<EmailSignUpPage> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _errorMessage;
  bool _isCreating = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  bool _validateInputs() {
    final s = S.of(context);
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmPasswordController.text;
    if (name.isEmpty) {
      setState(() => _errorMessage = s.authErrorEnterName);
      return false;
    }
    if (email.isEmpty) {
      setState(() => _errorMessage = s.authErrorEnterEmail);
      return false;
    }
    if (!RegExp(r'^[\w\-.]+@([\w-]+\.)+[\w-]{2,}$').hasMatch(email)) {
      setState(() => _errorMessage = s.authErrorInvalidEmail);
      return false;
    }
    if (password.length < 6) {
      setState(() => _errorMessage = s.authErrorPasswordMinLength);
      return false;
    }
    if (password != confirm) {
      setState(() => _errorMessage = s.authErrorPasswordsDoNotMatch);
      return false;
    }
    return true;
  }

  void _onCreateAccount() {
    if (!_validateInputs()) return;
    setState(() => _errorMessage = null);
    ConsentBottomSheet.show(context, authMethod: 'email', onContinue: () => _performSignUp());
  }

  Future<void> _performSignUp() async {
    setState(() => _isCreating = true);
    final provider = context.read<AuthenticationProvider>();
    final s = S.of(context);
    final email = _emailController.text.trim();
    try {
      final error = await provider.onEmailSignUp(
        s,
        email,
        _passwordController.text,
        _nameController.text.trim(),
        () {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => EmailVerificationPage(email: email, onContinue: widget.onSignIn)),
          );
        },
      );
      if (error != null && mounted) setState(() => _errorMessage = error);
    } finally {
      if (mounted) setState(() => _isCreating = false);
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
            child: Stack(
              children: [
                Consumer<AuthenticationProvider>(
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
                                Text(obL(context, '创建账号', 'Create account'),
                                    style: const TextStyle(
                                        fontFamily: JXB.fontDisplay, fontSize: 28, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                                const SizedBox(height: 6),
                                Text(obL(context, '这个旅程或许会让你感到惊喜 ✦', 'This journey might surprise you ✦'),
                                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
                                const SizedBox(height: 30),
                                OnboardingLightField(
                                  controller: _nameController,
                                  hint: obL(context, '姓名', 'Name'),
                                  icon: Icons.person_outline_rounded,
                                  textCapitalization: TextCapitalization.words,
                                ),
                                const SizedBox(height: 14),
                                OnboardingLightField(
                                  controller: _emailController,
                                  hint: obL(context, '邮箱地址', 'Email address'),
                                  icon: Icons.mail_outline_rounded,
                                  keyboardType: TextInputType.emailAddress,
                                ),
                                const SizedBox(height: 14),
                                OnboardingLightField(
                                  controller: _passwordController,
                                  hint: obL(context, '密码', 'Password'),
                                  icon: Icons.lock_outline_rounded,
                                  obscure: _obscurePassword,
                                  onToggleObscure: () => setState(() => _obscurePassword = !_obscurePassword),
                                ),
                                const SizedBox(height: 14),
                                OnboardingLightField(
                                  controller: _confirmPasswordController,
                                  hint: obL(context, '确认密码', 'Confirm password'),
                                  icon: Icons.lock_outline_rounded,
                                  obscure: _obscureConfirm,
                                  onToggleObscure: () => setState(() => _obscureConfirm = !_obscureConfirm),
                                ),
                                const SizedBox(height: 10),
                                Text(obL(context, '密码至少 8 位，需包含字母与数字', 'At least 8 characters, with letters and numbers'),
                                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder)),
                                const SizedBox(height: 22),
                                if (_errorMessage != null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 14),
                                    child: Text(_errorMessage!,
                                        style: const TextStyle(fontFamily: JXB.fontSans, color: JXB.error, fontSize: 14)),
                                  ),
                                _primaryButton(obL(context, '创建账号', 'Create account'),
                                    (provider.loading || _isCreating) ? null : _onCreateAccount),
                                const SizedBox(height: 18),
                                Center(
                                  child: GestureDetector(
                                    onTap: () => Navigator.of(context).pushReplacement(
                                        MaterialPageRoute(builder: (_) => EmailSignInPage(onSignIn: widget.onSignIn))),
                                    child: RichText(
                                      text: TextSpan(
                                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14),
                                        children: [
                                          TextSpan(text: obL(context, '已有账号? ', 'Already have an account? '), style: const TextStyle(color: JXB.textSecondary)),
                                          TextSpan(text: obL(context, '登录', 'Sign in'), style: const TextStyle(color: JXB.brandPrimary, fontWeight: FontWeight.w600)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 24),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                if (_isCreating)
                  Container(
                    color: Colors.white.withValues(alpha: 0.7),
                    child: const Center(child: CircularProgressIndicator(color: JXB.brandPrimary)),
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

  Widget _primaryButton(String label, VoidCallback? onTap) {
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
        child: Text(label,
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }
}
