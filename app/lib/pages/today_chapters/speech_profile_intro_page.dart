import 'package:flutter/material.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/pages/onboarding/speech_profile_onboarding_page.dart';
import 'package:memorion/pages/today_chapters/people_page.dart';
import 'package:memorion/pages/today_chapters/speech_samples_page.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// P-30S 声纹识别（记小宝 1.0 浅色改版，Figma v2.4 node 431:2217）。
///
/// 声纹训练入口页：状态徽标（是否已创建）+ 说明 + 录制/重新录制按钮 +
/// 「听我的声纹档案」（→ 语音样本页）+「识别其他人」（→ 人物管理）。
///
/// 数据源：`SharedPreferencesUtil().hasSpeakerProfile`（真实，后端同步）；
/// 录制流程复用现有 `SpeechProfilePage`（深色）。
class SpeechProfileIntroPage extends StatefulWidget {
  const SpeechProfileIntroPage({super.key});

  @override
  State<SpeechProfileIntroPage> createState() => _SpeechProfileIntroPageState();
}

class _SpeechProfileIntroPageState extends State<SpeechProfileIntroPage> {
  bool get _hasProfile => SharedPreferencesUtil().hasSpeakerProfile;

  Future<void> _record() async {
    // 复用浅色声纹录制页（standalone），录完 pop 返回后刷新状态徽标。
    // 不再用旧深色 SpeechProfilePage（避免深浅不一 + 与本页功能重复）。
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SpeechProfileOnboardingPage(
          standalone: true,
          onDone: () => Navigator.of(context).maybePop(),
          onSkip: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _openSamples() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SpeechSamplesPage()));
  }

  void _openPeople() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PeoplePage()));
  }

  void _showHelp() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
          decoration: BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [BoxShadow(color: Color(0x1F264D78), blurRadius: 30, offset: Offset(0, 12))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(revampText(ctx, en: 'What is voice recognition?', zh: '什么是声纹识别？'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 10),
              Text(
                revampText(ctx,
                    en: 'After you record your voice, Memorion can tell "you" apart from others in conversations, making transcripts more accurate and memories more personal. Your voiceprint is only used for recognition and is never shared.',
                    zh: '录制一段你的声音后，记小宝能在对话中区分出「你」和其他人，让转写更准确、记忆更懂你。声纹只用于识别，不会分享。'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.6, color: JXB.textSecondary),
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => Navigator.pop(ctx),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 46, width: double.infinity, alignment: Alignment.center,
                  decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
                  child: Text(revampText(ctx, en: 'Got it', zh: '知道了'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasProfile = _hasProfile;
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
                Expanded(child: _body(context, hasProfile)),
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
              child: Text(revampText(context, en: 'Voice Recognition', zh: '声纹识别'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            GestureDetector(
              onTap: _showHelp,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 36, height: 36, alignment: Alignment.center,
                decoration: const BoxDecoration(color: Color(0x14808594), shape: BoxShape.circle),
                child: const Text('?', style: TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, bool hasProfile) {
    return Column(
      children: [
        const SizedBox(height: 16),
        // 状态徽标
        _statusPill(context, hasProfile),
        const SizedBox(height: 40),
        // 大图标
        Container(
          width: 128, height: 128, alignment: Alignment.center,
          decoration: const BoxDecoration(color: Color(0x1F007AFF), shape: BoxShape.circle),
          child: const Text('🗣️', style: TextStyle(fontSize: 60)),
        ),
        const SizedBox(height: 28),
        Text(
            revampText(context, en: 'Teach Memorion\nto recognize your voice', zh: '教 Memorion\n识别你的声音'), // i18n-ignore: 中文文案含品牌名误判
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 24, height: 1.3, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Text(
              revampText(context,
                  en: 'Memorion needs to learn your voice to recognize you in conversations. Please speak naturally for about 30 seconds.',
                  zh: 'Memorion 需要学习你的声音以在对话中识别你。请自然说话约 30 秒。'), // i18n-ignore: 中文文案含品牌名误判
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.6, color: JXB.textSecondary)),
        ),
        const Spacer(),
        // 录制按钮
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: GestureDetector(
            onTap: _record,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 51, alignment: Alignment.center,
              decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
              child: Text(
                  hasProfile
                      ? revampText(context, en: 'Re-record', zh: '重新录制')
                      : revampText(context, en: 'Start Recording', zh: '开始录制'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ),
        const SizedBox(height: 18),
        // 次级入口
        if (hasProfile) ...[
          _linkRow('🎧', revampText(context, en: 'Listen to my voice profile', zh: '听我的声纹档案'), _openSamples),
          const SizedBox(height: 10),
        ],
        _linkRow('👥', revampText(context, en: 'Recognize Others', zh: '识别其他人'), _openPeople),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _statusPill(BuildContext context, bool hasProfile) {
    if (hasProfile) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(color: const Color(0x14007AFF), borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_rounded, size: 15, color: JXB.brandPrimary),
            const SizedBox(width: 6),
            Text(revampText(context, en: 'Voice profile created', zh: '声纹已创建'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w600, color: JXB.brandPrimary)),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(color: const Color(0x14808594), borderRadius: BorderRadius.circular(999)),
      child: Text(revampText(context, en: 'Not created yet', zh: '尚未创建'),
          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w600, color: JXB.textSecondary)),
    );
  }

  Widget _linkRow(String emoji, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w600, color: JXB.brandPrimary)),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded, size: 16, color: JXB.brandPrimary),
        ],
      ),
    );
  }
}
