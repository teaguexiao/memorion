import 'dart:io';

import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// P-30A 关于（记小宝 1.0 浅色改版，Figma v2.4 node 475:727）。
///
/// 静态链接页：App 图标/名称/版本 + 支持与反馈（好评/反馈/官网）+ 硬件（购买设备）。
/// 版本来自 `PackageInfo`；链接复用现有 about.dart 的真实地址。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';
  String _buildNumber = '';

  static const _reviewUrl =
      'https://apps.apple.com/us/app/memorion-ai-memory-recorder/id6758304534?action=write-review';
  static const _websiteUrl = 'https://www.memorion.me/';
  static const _shopUrl = 'https://memorion.me/shop';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _version = info.version;
        _buildNumber = info.buildNumber;
      });
    }
  }

  void _openUrl(String url) {
    HapticFeedback.lightImpact();
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  static const _supportEmail = 'support@memorion.me'; // i18n-ignore: 邮箱地址

  Future<void> _openFeedbackMail() async {
    HapticFeedback.lightImpact();
    final ver = _version.isNotEmpty ? _version : '?';
    final build = _buildNumber.isNotEmpty ? _buildNumber : '?';
    final device = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    final body = '\n\n---\nApp: Memorion v$ver (Build $build)\nDevice: $device';
    final subject = Uri.encodeComponent(revampText(context,
        en: 'Feedback Memorion v$ver (Build $build)',
        zh: '意见反馈 Memorion v$ver (Build $build)')); // i18n-ignore: 邮件主题含品牌名
    final uri = Uri.parse('mailto:$_supportEmail?subject=$subject&body=${Uri.encodeComponent(body)}');
    // 无邮箱 App（如模拟器）时兜底：复制支持邮箱 + 提示。
    final ok = await canLaunchUrl(uri);
    if (ok) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (!mounted) return;
    await Clipboard.setData(const ClipboardData(text: _supportEmail));
    if (!mounted) return;
    // i18n-ignore: revampText 双语文案含邮箱地址被误判
    UndoDeleteHost.showMessage(context, revampText(context,
            en: 'No email app found. Copied support@memorion.me',
            zh: '未找到邮箱 App，已复制 support@memorion.me'));
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
              child: Text(revampText(context, en: 'About', zh: '关于'),
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        _headerCard(context),
        const SizedBox(height: 22),
        _sectionLabel(revampText(context, en: 'Support & Feedback', zh: '支持与反馈')),
        const SizedBox(height: 10),
        _card([
          _navRow(revampText(context, en: 'Rate Us', zh: '给个好评'), () => _openUrl(_reviewUrl)),
          _divider(),
          _navRow(revampText(context, en: 'Feedback', zh: '意见反馈'), _openFeedbackMail),
          _divider(),
          _navRow(revampText(context, en: 'Website', zh: '官网'), () => _openUrl(_websiteUrl)),
        ]),
        const SizedBox(height: 22),
        _sectionLabel(revampText(context, en: 'Hardware', zh: '硬件')),
        const SizedBox(height: 10),
        _card([
          _navRow(revampText(context, en: 'Buy Memorion Device', zh: '购买 Memorion 设备'), () => _openUrl(_shopUrl)), // i18n-ignore: 中文文案含品牌名误判
        ]),
      ],
    );
  }

  Widget _headerCard(BuildContext context) {
    final version = _version.isEmpty ? '--' : _version;
    // 无卡片：logo + 名称 + 版本直接置于页面背景上。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          // 官方 logo 是横向无限环标（114×65），用 contain 完整显示不裁断。
          // 走打包资源而非联网拉取：logo 是固定资源，联网加载会先闪一帧占位图
          // （旧 logo 形态）再替换，且首屏要干等一次 HTTPS 往返。见
          // test/about_page_logo_is_bundled_test.dart。
          // identifier（→ iOS accessibilityIdentifier → Maestro 的 `id:`）让 UI 测试
          // 能把比对范围裁到 logo 本身。用 label 不行：iOS 会把整个 header 合并成一个
          // a11y 节点，label 被拼进长文本，也没法当 cropOn 的锚点。
          Semantics(
            identifier: 'about-logo-asset',
            label: 'about-logo-asset',
            child: SizedBox(
              height: 64,
              child: Image.asset(
                'assets/images/memorion_infinity_logo.png',
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => _logoFallback(),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text('Memorion',
              style: TextStyle(fontFamily: JXB.fontSans, fontSize: 20, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
          const SizedBox(height: 6),
          Text(revampText(context, en: 'Version $version', zh: '版本 $version'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder)),
        ],
      ),
    );
  }

  /// 只该在 asset 解码失败时出现（正常永远不触发）。曾被误当作 `loadingBuilder`
  /// 的占位图，于是每次进页面都必现——用户看到的「旧 logo」就是它。
  Widget _logoFallback() {
    return Semantics(
      identifier: 'about-logo-fallback',
      label: 'about-logo-fallback',
      child: Container(
        width: 64, height: 64, alignment: Alignment.center,
        decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(16)),
        child: const Text('M',
            style: TextStyle(fontFamily: JXB.fontSans, fontSize: 36, fontWeight: FontWeight.w700, color: Colors.white)),
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

  Widget _sectionLabel(String text) {
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
