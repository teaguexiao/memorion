import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:memorion/pages/onboarding/onboarding_lang.dart';
import 'package:memorion/providers/auth_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:provider/provider.dart';

/// O-02 数据与隐私底部弹层（记小宝 1.0 浅色改版，Figma node 589:1909）。
///
/// 白色圆角卡 + 「数据与隐私」标题 + 说明正文 + 勾选「我已阅读并同意《数据与隐私政策》」
/// + 蓝色「同意并继续」。勾选后才可继续（保留原 EULA 同意语义）。
/// 登录首页 / 邮箱登录 / 邮箱注册 三处共用（旧壳不再使用）。
class ConsentBottomSheet extends StatefulWidget {
  final String authMethod; // 'google' | 'apple' | 'email'（保留入参，浅色版文案不再区分）
  final VoidCallback onContinue;

  const ConsentBottomSheet({super.key, required this.authMethod, required this.onContinue});

  @override
  State<ConsentBottomSheet> createState() => _ConsentBottomSheetState();

  static void show(BuildContext context, {required String authMethod, required VoidCallback onContinue}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => ConsentBottomSheet(authMethod: authMethod, onContinue: onContinue),
    );
  }
}

class _ConsentBottomSheetState extends State<ConsentBottomSheet> {
  bool _agreed = false;
  final _policyRecognizer = TapGestureRecognizer();

  @override
  void dispose() {
    _policyRecognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zh = obL(context, 'zh', 'en') == 'zh';
    return Container(
      decoration: const BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 拖动条
              Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 28),
              // 标题（居中）
              Text(zh ? '数据与隐私' : 'Data & Privacy',
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF303238))),
              const SizedBox(height: 12),
              // 说明正文
              Text(
                zh
                    ? '为了为你生成会议摘要、行动项与记忆，Memorion 会将你的语音上传至第三方语音识别与 AI 供应商进行处理。你的数据会被加密存储，你可以随时在设置中删除。'
                    : 'To generate summaries, action items and memories for you, Memorion uploads your audio to third-party speech and AI providers. Your data is encrypted and can be deleted anytime in Settings.',
                textAlign: TextAlign.justify,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.6, color: JXB.textPrimary),
              ),
              const SizedBox(height: 32),
              // 勾选
              GestureDetector(
                onTap: () => setState(() => _agreed = !_agreed),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: _agreed ? JXB.brandSecondary : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: _agreed ? JXB.brandSecondary : JXB.textPlaceholder, width: 1.04),
                      ),
                      child: _agreed ? const Icon(Icons.check_rounded, size: 13, color: Colors.white) : null,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder),
                          children: [
                            TextSpan(text: zh ? '我已阅读并同意' : "I've read and agree to the "),
                            TextSpan(
                              text: zh ? '《数据与隐私政策》' : 'Data & Privacy Policy',
                              style: const TextStyle(color: JXB.brandSecondary),
                              recognizer: _policyRecognizer
                                ..onTap = () => context.read<AuthenticationProvider>().openPrivacyPolicy(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // 同意并继续
              GestureDetector(
                onTap: _agreed
                    ? () {
                        Navigator.of(context).pop();
                        widget.onContinue();
                      }
                    : null,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: double.infinity,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _agreed ? JXB.brandSecondary : JXB.brandSecondary.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Text(zh ? '同意并继续' : 'Agree & continue',
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
