import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/providers/locale_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// P-30·界面语言（记小宝 1.0 浅色改版，Figma v2.4 node 455:768）。
///
/// 独立页，三选一：跟随系统 / 简体中文 / English。切换即时生效并同步后端主语言。
/// 数据源：`LocaleProvider`（currentLocaleCode / setLocale）+ `setUserPrimaryLanguage`。
class UiLanguagePage extends StatelessWidget {
  const UiLanguagePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: JXB.bgApp,
          body: SafeArea(
            child: Column(
              children: [
                _detailBar(context),
                Expanded(
                  child: Consumer<LocaleProvider>(
                    builder: (context, provider, _) => _body(context, provider),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailBar(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(width: 36, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary)),
            ),
            Expanded(
              child: Text(revampText(context, en: 'App language', zh: '界面语言'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            const SizedBox(width: 36),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, LocaleProvider provider) {
    final current = provider.currentLocaleCode; // '' = 跟随系统
    final options = [
      ('', revampText(context, en: 'Follow system', zh: '跟随系统')),
      ('zh', '简体中文'),
      ('en', 'English'),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        Container(
          decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              for (int i = 0; i < options.length; i++) ...[
                if (i != 0) const Divider(height: 1, color: JXB.border),
                _row(context, options[i].$1, options[i].$2, options[i].$1 == current),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
            revampText(context,
                en: 'The app language takes effect immediately after switching. The transcription language is set separately in "Transcription settings".',
                zh: '切换后 App 界面语言立即生效。转写语言在「转写设置」中单独设置。'),
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, height: 1.55, color: JXB.textPlaceholder)),
      ],
    );
  }

  Widget _row(BuildContext context, String code, String label, bool selected) {
    return GestureDetector(
      onTap: () => _select(context, code),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 54,
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: JXB.textPrimary)),
            ),
            if (selected) const Icon(Icons.check_rounded, size: 20, color: JXB.brandPrimary),
          ],
        ),
      ),
    );
  }

  void _select(BuildContext context, String code) {
    HapticFeedback.lightImpact();
    final provider = context.read<LocaleProvider>();
    if (code == provider.currentLocaleCode) return;
    provider.setLocale(code.isEmpty ? null : Locale(code));
    // 同步后端主语言（服务端生成内容与 UI 语言一致）；跟随系统时发送解析后的设备语言。
    unawaited(setUserPrimaryLanguage(provider.resolvedSttLanguageCode));
  }
}
