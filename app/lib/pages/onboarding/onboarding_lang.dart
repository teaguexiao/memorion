import 'package:flutter/material.dart';
import 'package:memorion/providers/locale_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:provider/provider.dart';

/// Onboarding 双语文案 helper。
///
/// onboarding 页在正式登录前展示，很多文案不走 `.arb`（S.of），这里用一个
/// 轻量 `L(zh, en)` 按当前 UI locale 返回中/英，保证登录首页右上角切换语言后
/// 整个 onboarding 立即跟随。判定依据 [LocaleProvider]（跟随系统时按设备语言）。
String obL(BuildContext context, String zh, String en) {
  final code = context.watch<LocaleProvider>().resolvedSttLanguageCode;
  return code == 'zh' ? zh : en;
}

/// 非 watch 版（在回调里用）。
String obLRead(BuildContext context, String zh, String en) {
  final code = context.read<LocaleProvider>().resolvedSttLanguageCode;
  return code == 'zh' ? zh : en;
}

/// 登录首页右上角语言切换按钮：跟随系统 / 中文 / English 三态循环 + 弹选择。
class OnboardingLangSwitch extends StatelessWidget {
  const OnboardingLangSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<LocaleProvider>();
    final code = provider.currentLocaleCode; // '' = 跟随系统
    // i18n-ignore: 语言选择器，各语言用自身名称显示，不随界面语言变化
    final label = code == 'zh'
        ? '中文'
        : code == 'en'
            ? 'EN'
            : (provider.resolvedSttLanguageCode == 'zh' ? '中文' : 'EN');

    return GestureDetector(
      onTap: () => _showSheet(context, provider),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: JXB.surface,
          borderRadius: BorderRadius.circular(999),
          boxShadow: JXB.cardShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language_rounded, size: 16, color: JXB.textSecondary),
            const SizedBox(width: 5),
            Text(label,
                style: const TextStyle(
                    fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
          ],
        ),
      ),
    );
  }

  void _showSheet(BuildContext context, LocaleProvider provider) {
    final currentCode = provider.currentLocaleCode;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        Widget row(String title, String subtitle, String value) {
          final selected = currentCode == value;
          return GestureDetector(
            onTap: () {
              provider.setLocale(value.isEmpty ? null : Locale(value));
              Navigator.pop(ctx);
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              decoration: BoxDecoration(
                color: selected ? JXB.brandTint : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(subtitle,
                              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textSecondary)),
                        ],
                      ],
                    ),
                  ),
                  if (selected) const Icon(Icons.check_rounded, color: JXB.brandPrimary, size: 20),
                ],
              ),
            ),
          );
        }

        final zh = provider.resolvedSttLanguageCode == 'zh';
        return Container(
          decoration: const BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(width: 36, height: 5, decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(3))),
              const SizedBox(height: 14),
              Text(zh ? '界面语言' : 'Language',
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 10),
              row(zh ? '跟随系统' : 'Follow system', '', ''),
              row('简体中文', 'Chinese', 'zh'),
              row('English', '英文', 'en'),
              SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
            ],
          ),
        );
      },
    );
  }
}
