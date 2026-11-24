import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:url_launcher/url_launcher.dart';

/// P-30DEV 开发者（记小宝 1.0 浅色改版，Figma v2.4 node 431:2592）。
///
/// 静态介绍页：开发者 CLI 卡（查看文档）+ 能力清单 + 快速开始命令（点击复制）。
/// 文档链接 memorion.me/docs。
class DeveloperPage extends StatelessWidget {
  const DeveloperPage({super.key});

  static const _docsUrl = 'https://memorion.me/docs';

  static List<(String, String)> _capabilities(BuildContext context) => [
        (
          revampText(context, en: 'Export all data', zh: '导出全量数据'),
          revampText(context,
              en: 'One-tap export of raw transcripts, moments, facts, and profile',
              zh: '原始转写、时光、facts、画像一键导出'),
        ),
        (
          revampText(context, en: 'Realtime data API', zh: '实时数据 API'),
          revampText(context,
              en: 'Access your memory data in realtime via API/CLI',
              zh: '经 API/CLI 实时访问你的记忆数据'),
        ),
        (
          revampText(context, en: 'Connect your agent', zh: '接入你的 Agent'),
          revampText(context,
              en: 'Feed raw data into your own agent workflow',
              zh: '将原始数据接入自建 Agent 工作流'),
        ),
        (
          revampText(context, en: 'Bypass in-app AI', zh: '绕过 App 内 AI'),
          revampText(context,
              en: 'Use only hardware + transcription pipeline, handle AI yourself',
              zh: '只用硬件 + 转写管线，AI 处理自己来'),
        ),
      ];

  static const List<String> _commands = [
    r'$ brew install memorion',
    r'$ memorion login',
    r'$ memorion export --all',
  ];

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
              child: Text(revampText(context, en: 'Developer', zh: '开发者'),
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
        _cliCard(context),
        const SizedBox(height: 22),
        _sectionLabel(revampText(context, en: 'What you can do with it', zh: '你可以用它做什么')),
        const SizedBox(height: 10),
        _capabilityCard(context),
        const SizedBox(height: 22),
        _sectionLabel(revampText(context, en: 'Quick start', zh: '快速开始')),
        const SizedBox(height: 10),
        _quickStartCard(context),
      ],
    );
  }

  // ── 开发者 CLI 卡（浅蓝底）─────────────────────────────────
  Widget _cliCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0x0F007AFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33007AFF), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('⌘', style: TextStyle(fontSize: 24, color: JXB.brandPrimary)),
              const SizedBox(width: 10),
              Text(revampText(context, en: 'Developer CLI', zh: '开发者 CLI'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ],
          ),
          const SizedBox(height: 14),
          Text(
              revampText(context,
                  en: 'Memorion offers a command-line tool (CLI) to export all your memory data and connect it to your own agent workflow. See the docs for installation and usage.',
                  zh: 'Memorion 提供命令行工具（CLI），你可以导出全量记忆数据、接入自己的 Agent 工作流。安装与使用详见文档。'), // i18n-ignore: revampText 双语文案含 CLI/Agent 英文词被误判
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.55, color: JXB.textSecondary)),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              launchUrl(Uri.parse(_docsUrl), mode: LaunchMode.externalApplication);
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 44, alignment: Alignment.center,
              decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
              child: Text(revampText(context, en: 'View docs ↗', zh: '查看文档 ↗'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
          const SizedBox(height: 14),
          const Center(
            child: Text('memorion.me/docs',
                style: TextStyle(fontFamily: JXB.fontNumber, fontSize: 12, color: JXB.textPlaceholder)),
          ),
        ],
      ),
    );
  }

  // ── 能力清单卡 ─────────────────────────────────────────────
  Widget _capabilityCard(BuildContext context) {
    final capabilities = _capabilities(context);
    return Container(
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (int i = 0; i < capabilities.length; i++) ...[
            if (i != 0) const Divider(height: 1, color: JXB.border),
            _capabilityRow(capabilities[i].$1, capabilities[i].$2),
          ],
        ],
      ),
    );
  }

  Widget _capabilityRow(String title, String subtitle) {
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          Container(
            width: 22, height: 22, alignment: Alignment.center,
            decoration: const BoxDecoration(color: Color(0x14007AFF), shape: BoxShape.circle),
            child: const Icon(Icons.check_rounded, size: 14, color: JXB.brandPrimary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                const SizedBox(height: 3),
                Text(subtitle, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 快速开始卡（深色终端命令，点击复制）─────────────────────
  Widget _quickStartCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < _commands.length; i++) ...[
            if (i != 0) const SizedBox(height: 12),
            _cmdRow(context, _commands[i]),
          ],
          const SizedBox(height: 14),
          Text(
              revampText(context,
                  en: 'See the developer docs for full commands, authentication, and API reference.',
                  zh: '完整命令、认证与 API 参考见开发者文档。'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder)),
        ],
      ),
    );
  }

  Widget _cmdRow(BuildContext context, String cmd) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        Clipboard.setData(ClipboardData(text: cmd.replaceFirst(r'$ ', '')));
        UndoDeleteHost.showMessage(context, revampText(context, en: 'Command copied', zh: '已复制命令'));
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: const Color(0xFF1C1E26), borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            Expanded(
              child: Text(cmd,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: JXB.fontNumber, fontSize: 13, color: Color(0xFF7FE0A8))),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.copy_rounded, size: 15, color: Colors.white38),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(text, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
    );
  }
}
