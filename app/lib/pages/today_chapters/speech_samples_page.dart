import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:memorion/providers/user_speech_samples_provider.dart';
import 'package:memorion/ui/atoms/memorion_skeleton.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// P-30SV 语音样本（记小宝 1.0 浅色改版，Figma v2.4 node 485:727）。
///
/// 声纹档案（主样本，不可删）+ 附加样本列表（播放 + 删除）。
/// 全真数据：`UserSpeechSamplesProvider`（getSpeechProfile / getSpeechSamples /
/// playPause / deleteSampleAtIndex，走后端 `v1/speech-profiles`）。
class SpeechSamplesPage extends StatelessWidget {
  const SpeechSamplesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => UserSpeechSamplesProvider()
        ..init()
        ..setupAudioPlayerListeners(),
      child: Theme(
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
                    child: Consumer<UserSpeechSamplesProvider>(
                      builder: (context, p, _) => _body(context, p),
                    ),
                  ),
                ],
              ),
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
              child: Text(revampText(context, en: 'Voice Samples', zh: '语音样本'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            const SizedBox(width: 36),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, UserSpeechSamplesProvider p) {
    if (p.loading) {
      return const MemorionSkeletonCards(
        count: 4,
        cardHeight: 64,
        radius: JXB.radiusCard,
        gap: 10,
        withHeader: true,
        padding: EdgeInsets.fromLTRB(18, 8, 18, 28),
      );
    }
    if (p.profileUrl == null) {
      return Center(
        child: Text(revampText(context, en: 'No voice profile yet', zh: '还没有声纹档案'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder)),
      );
    }
    final playingMain = p.currentPlayingIndex == 0 && p.isPlaying;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        _sectionLabel(revampText(context, en: 'Voice Profile', zh: '声纹档案')),
        const SizedBox(height: 10),
        // 主样本卡（蓝底高亮，不可删）
        GestureDetector(
          onTap: () => p.playPause(0),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0x0F007AFF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x33007AFF), width: 1),
            ),
            child: Row(
              children: [
                _playCircle(playingMain, filled: true),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(revampText(context, en: 'Voice Profile', zh: '声纹档案'),
                          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                      const SizedBox(height: 4),
                      Text(
                          revampText(context,
                              en: 'Duration ${_fmtDuration(p.durationForIndex(0))} · Main sample',
                              zh: '时长 ${_fmtDuration(p.durationForIndex(0))} · 主样本'),
                          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        if (p.samples.isNotEmpty) ...[
          _sectionLabel(revampText(context, en: 'Additional Samples', zh: '附加样本')),
          const SizedBox(height: 10),
          _samplesCard(context, p),
        ],
      ],
    );
  }

  Widget _samplesCard(BuildContext context, UserSpeechSamplesProvider p) {
    return Container(
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (int i = 0; i < p.samples.length; i++) ...[
            if (i != 0) const Divider(height: 1, color: JXB.border),
            _sampleRow(context, p, i + 1, i), // provider index = i+1 (0 is main profile)
          ],
        ],
      ),
    );
  }

  Widget _sampleRow(BuildContext context, UserSpeechSamplesProvider p, int providerIndex, int sampleIndex) {
    final playing = p.currentPlayingIndex == providerIndex && p.isPlaying;
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          GestureDetector(
            onTap: () => p.playPause(providerIndex),
            behavior: HitTestBehavior.opaque,
            child: _playCircle(playing, filled: false),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(revampText(context, en: 'Voice Sample ${sampleIndex + 1}', zh: '声音样本 ${sampleIndex + 1}'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                const SizedBox(height: 3),
                Text(revampText(context, en: 'Duration ${_fmtDuration(p.durationForIndex(providerIndex))}', zh: '时长 ${_fmtDuration(p.durationForIndex(providerIndex))}'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _confirmDelete(context, p, providerIndex, sampleIndex),
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.delete_outline_rounded, size: 20, color: JXB.textPlaceholder),
            ),
          ),
        ],
      ),
    );
  }

  Widget _playCircle(bool playing, {required bool filled}) {
    final icon = playing ? Icons.pause_rounded : Icons.play_arrow_rounded;
    if (filled) {
      return Container(
        width: 40, height: 40, alignment: Alignment.center,
        decoration: const BoxDecoration(color: JXB.brandPrimary, shape: BoxShape.circle),
        child: Icon(icon, size: 22, color: Colors.white),
      );
    }
    return Icon(icon, size: 24, color: JXB.brandPrimary);
  }

  Future<void> _confirmDelete(BuildContext context, UserSpeechSamplesProvider p, int providerIndex, int sampleIndex) async {
    final ok = await showDialog<bool>(
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
              Text(revampText(ctx, en: 'Delete this sample?', zh: '删除这个样本？'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 8),
              Text(revampText(ctx, en: '"Voice Sample ${sampleIndex + 1}" cannot be recovered after deletion.', zh: '删除后「声音样本 ${sampleIndex + 1}」将无法找回。'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, false),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 46, alignment: Alignment.center,
                        decoration: BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(ctx, en: 'Cancel', zh: '取消'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, true),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 46, alignment: Alignment.center,
                        decoration: BoxDecoration(color: JXB.error, borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(ctx, en: 'Delete', zh: '删除'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    HapticFeedback.mediumImpact();
    final success = await p.deleteSampleAtIndex(providerIndex);
    if (!success && context.mounted) {
      UndoDeleteHost.showMessage(context, revampText(context, en: 'Failed to delete, please try again later', zh: '删除失败，请稍后再试'));
    }
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(text, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
    );
  }

  String _fmtDuration(int? seconds) {
    if (seconds == null) return '--';
    final m = seconds ~/ 60;
    final sec = seconds % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }
}
