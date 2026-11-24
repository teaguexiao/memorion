import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/pages/me/export_all_data.dart';
import 'package:memorion/pages/settings/delete_account.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:url_launcher/url_launcher.dart';

/// P-30D 隐私与数据（记小宝 1.0 浅色改版，Figma v2.4 node 431:2443 / 449:727）。
///
/// 隐私摘要（静态说明）+ AI 数据处理（可展开说明 + 同意状态）+ 数据导出（真实
/// exportAllData）+ 法律与政策（隐私政策/服务条款/EULA 链接）+ 删除账户（→ 现有页）。
class DataPrivacyPage extends StatefulWidget {
  const DataPrivacyPage({super.key});

  @override
  State<DataPrivacyPage> createState() => _DataPrivacyPageState();
}

class _DataPrivacyPageState extends State<DataPrivacyPage> {
  bool _aiExpanded = false;

  static const _privacyUrl = 'https://memorion.me/privacy';
  static const _termsUrl = 'https://memorion.me/terms-of-service';
  static const _eulaUrl = 'https://memorion.me/eula';

  List<String> _summary(BuildContext context) => [
        revampText(context,
            en: 'Your data is used to generate transcripts, chapters, journals and memory search results.',
            zh: '你的数据用于生成转写、时光、日记和记忆检索结果。'),
        revampText(context, en: 'Calendar is read-only; Reminders are write-only.', zh: '日历只读；提醒事项只写。'),
        // 日历数据会离开设备（同步到服务端供 Ask 使用），"只读"不足以说明这一点。
        revampText(context,
            en: 'Calendar event titles, times and locations are synced to our server so Ask can reference your schedule. Notes and attendees are never read.',
            zh: '日程的标题、时间和地点会同步到服务器，供 Ask 参考你的行程。备注和参会人不会被读取。'),
        revampText(context,
            en: 'Disabling a source authorization stops using that source.', zh: '关闭来源授权后停止使用该来源。'),
      ];

  List<String> _aiPoints(BuildContext context) => [
        revampText(context, en: 'Audio is used for cloud transcription.', zh: '音频用于云端转写。'),
        revampText(context, en: 'Text is used for summaries, journals and Ask.', zh: '文本用于摘要、日记和 Ask。'),
        revampText(context,
            en: 'Currently using mainstream cloud STT and large model providers.',
            zh: '当前使用主流云端 STT 与大模型服务商。'),
      ];

  void _openUrl(String url) {
    HapticFeedback.lightImpact();
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

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
                Expanded(child: _body(context)),
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
              child: Text(revampText(context, en: 'Privacy & Data', zh: '隐私与数据'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            const SizedBox(width: 36),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final consented = SharedPreferencesUtil().aiDataConsentAccepted;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        _sectionLabel(context, revampText(context, en: 'Privacy Summary', zh: '隐私摘要')),
        const SizedBox(height: 10),
        _summaryCard(context),
        const SizedBox(height: 22),

        _sectionLabel(context, revampText(context, en: 'AI Data Processing', zh: 'AI 数据处理')),
        const SizedBox(height: 10),
        _aiCard(context, consented),
        const SizedBox(height: 22),

        _sectionLabel(context, revampText(context, en: 'Data Export', zh: '数据导出')),
        const SizedBox(height: 10),
        _card([
          _navRow(revampText(context, en: 'Export All Data', zh: '导出所有数据'), () => exportAllData(context)),
        ]),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
              revampText(context,
                  en: 'Export chapters, transcripts, summaries and related metadata as a JSON file.',
                  zh: '导出时光、原文、摘要和相关元数据为 JSON 文件。'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder)),
        ),
        const SizedBox(height: 22),

        _sectionLabel(context, revampText(context, en: 'Legal & Policies', zh: '法律与政策')),
        const SizedBox(height: 10),
        _card([
          _navRow(revampText(context, en: 'Privacy Policy', zh: '隐私政策'), () => _openUrl(_privacyUrl)),
          _divider(),
          _navRow(revampText(context, en: 'Terms of Service', zh: '服务条款'), () => _openUrl(_termsUrl)),
          _divider(),
          _navRow('EULA', () => _openUrl(_eulaUrl)),
        ]),
        const SizedBox(height: 24),

        _deleteButton(context),
        const SizedBox(height: 10),
        Text(
            revampText(context,
                en: 'Permanently delete your account and cloud data, unpair devices. This action cannot be undone.',
                zh: '永久删除账户和云端数据，解除设备配对，操作不可恢复。'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder)),
      ],
    );
  }

  Widget _summaryCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      child: Column(
        children: [
          for (final line in _summary(context))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.check_circle_rounded, size: 18, color: JXB.brandPrimary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(line,
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textPrimary)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _aiCard(BuildContext context, bool consented) {
    return Container(
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // 可展开：AI 数据处理说明
          GestureDetector(
            onTap: () => setState(() => _aiExpanded = !_aiExpanded),
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              height: 52,
              child: Row(
                children: [
                  Expanded(
                    child: Text(revampText(context, en: 'AI Data Processing Details', zh: 'AI 数据处理说明'),
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
                  ),
                  AnimatedRotation(
                    turns: _aiExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.keyboard_arrow_down_rounded, size: 22, color: JXB.textPlaceholder),
                  ),
                ],
              ),
            ),
          ),
          if (_aiExpanded)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final p in _aiPoints(context))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 7),
                            child: SizedBox(width: 5, height: 5, child: DecoratedBox(decoration: BoxDecoration(color: JXB.textPlaceholder, shape: BoxShape.circle))),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(p, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
                          ),
                        ],
                      ),
                    ),
                  GestureDetector(
                    onTap: () => _openUrl(_privacyUrl),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(revampText(context, en: 'View Privacy Policy ›', zh: '查看隐私政策 ›'),
                          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w600, color: JXB.brandPrimary)),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1, color: JXB.border),
          // AI 数据同意：只读状态展示（非开关）。产品核心功能全是 AI，
          // 撤回同意 = 停用产品，故撤回路径就是删除账户，在下方说明。
          SizedBox(
            height: 52,
            child: Row(
              children: [
                Expanded(
                  child: Text(revampText(context, en: 'AI Data Consent', zh: 'AI 数据同意'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
                ),
                Container(width: 7, height: 7, decoration: BoxDecoration(color: consented ? JXB.success : JXB.textPlaceholder, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(
                    consented
                        ? revampText(context, en: 'Consented', zh: '已同意')
                        : revampText(context, en: 'Not consented', zh: '未同意'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
              ],
            ),
          ),
          if (consented)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    revampText(context,
                        en: 'AI processing is core to Memorion. To withdraw consent, delete your account below.',
                        zh: 'AI 处理是记小宝的核心能力。如需撤回同意，请在下方删除账户。'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, height: 1.5, color: JXB.textPlaceholder)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _deleteButton(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DeleteAccount())),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0x0FE55247),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0x80E55247), width: 1),
        ),
        child: Text(revampText(context, en: 'Delete Account', zh: '删除账户'),
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.error)),
      ),
    );
  }

  Widget _card(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: children),
    );
  }

  Widget _divider() => const Divider(height: 1, color: JXB.border);

  Widget _sectionLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(text, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
    );
  }

  Widget _navRow(String title, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: JXB.textPlaceholder),
          ],
        ),
      ),
    );
  }
}
