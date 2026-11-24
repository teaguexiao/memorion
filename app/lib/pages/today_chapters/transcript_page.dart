import 'dart:io';

import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/http/api/conversation_shares.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/pages/today_chapters/speaker_mark_page.dart';
import 'package:memorion/pages/today_chapters/conversation_share_sheet.dart';
import 'package:memorion/pages/today_chapters/widgets/audio_scrubber.dart';
import 'package:memorion/pages/today_chapters/widgets/jxb_gradient_background.dart';
import 'package:memorion/pages/today_chapters/widgets/share_qr_footer.dart';
import 'package:memorion/pages/today_chapters/widgets/transcript_common.dart';
import 'package:memorion/providers/conversation_audio_provider.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/audio/transcript_audio_alignment.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

/// P-12 完整原文（记小宝 1.0 浅色改版，Figma v2.4 node 343:16867）。
///
/// 数据全部来自传入的 [ServerConversation] 的 `transcriptSegments`，无 mock。
/// - Header：完整原文 · N 分钟
/// - 「转写文本」+ 复制（复制全文到剪贴板）
/// - 说话人头像行（按 speaker 上色）
/// - 逐段：说话人名(彩色) + 时间戳 + 正文，段间分隔线
/// - 底部悬浮音频条（[AudioScrubber]：拖动回听，手指上移切慢速/精细档）
/// - 点一句（正文或时间）从这句开始播，正在播的句子高亮；用后端给的音频位置，
///   不用段落上显示的时间（实时录音的音频是整场会话裁掉静音后的 wav，两者不是同一条时间轴）
class TranscriptPage extends StatefulWidget {
  final ServerConversation conversation;
  final ConversationSharingApi? sharingApi;
  final double? initialOffsetSeconds;

  const TranscriptPage({super.key, required this.conversation, this.sharingApi, this.initialOffsetSeconds});

  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  ServerConversation get conversation => widget.conversation;

  // 缓存 provider 引用，dispose 时不能再通过 context.read（context 已 deactivated 会抛异常）。
  ConversationAudioProvider? _audio;

  // 拖动气泡每帧都要按 id 找句子，长对话上千段，不能每次线性扫。
  late final Map<String, TranscriptSegment> _segmentsById = {
    for (final s in conversation.transcriptSegments) s.id: s,
  };

  @override
  void initState() {
    super.initState();
    // 加载该会话音频（本地→云端）。用独立实例避免与详情页共享 provider 状态冲突。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final audio = context.read<ConversationAudioProvider>();
      audio.addListener(_seekToMarkedMoment);
      audio.loadConversation(conversation.id);
    });
  }

  bool _initialSeekApplied = false;
  void _seekToMarkedMoment() {
    final offset = widget.initialOffsetSeconds;
    if (_initialSeekApplied || offset == null || _audio?.hasAudio != true) return;
    _initialSeekApplied = true;
    _audio?.seekTo(Duration(milliseconds: (offset * 1000).round()));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _audio = context.read<ConversationAudioProvider>();
  }

  @override
  void dispose() {
    // 离开页面停止并清理播放器（用缓存引用，避免 dispose 时 context.read 抛异常）。
    _audio?.removeListener(_seekToMarkedMoment);
    _audio?.clear(notify: false);
    super.dispose();
  }

  // ── More(···) 菜单：导出转写文本 / 重新识别说话人 ──────────────
  // 同章节详情页 P-11 弹出风格（Figma v2.4 node 948:6940）：白色圆角 sheet + 顶部拖动条
  // + 左上角圆形「×」关闭，各项为独立圆角卡片（导出转写文本蓝色高亮主按钮）。
  void _showMoreMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x66000000), // 遮罩 40%（Figma rgba(0,0,0,0.4)）
      builder: (sheetCtx) => Container(
        decoration: const BoxDecoration(
          color: JXB.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部拖动条
                Container(
                  width: 32,
                  height: 5,
                  decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(99)),
                ),
                const SizedBox(height: 8),
                // 左上角圆形「×」关闭按钮
                Align(
                  alignment: Alignment.centerLeft,
                  child: GestureDetector(
                    onTap: () => Navigator.of(sheetCtx).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: Color(0xFFF8F8F8), shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded, size: 18, color: JXB.textSecondary),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _MenuItem(
                  label: revampText(context, en: 'Share link', zh: '分享链接'),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    showConversationShareSheet(context, conversation, api: widget.sharingApi);
                  },
                ),
                const SizedBox(height: 12),
                _MenuItem(
                  label: revampText(context, en: 'Export transcript', zh: '导出转写文本'),
                  primary: true,
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _exportTranscript();
                  },
                ),
                const SizedBox(height: 12),
                _MenuItem(
                  label: revampText(context, en: 'Re-identify speakers', zh: '重新识别说话人'),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _reprocess();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 重新识别说话人：走后端 `reProcessConversationServer`（/reprocess）。
  Future<void> _reprocess() async {
    _toast(revampText(context, en: 'Re-identifying speakers…', zh: '正在重新识别说话人…'));
    final updated = await reProcessConversationServer(conversation.id);
    if (!mounted) return;
    if (updated != null) {
      // 同步到列表 Provider，返回后时间线也是最新。
      context.read<ConversationProvider>().updateConversation(updated);
      _toast(revampText(context, en: 'Re-identified. Go back to see the updates', zh: '已重新识别，返回可查看更新'));
    } else {
      _toast(revampText(context, en: 'Re-identification failed, please try again later', zh: '重新识别失败，请稍后重试'));
    }
  }

  /// 导出转写文本：写 .txt → 系统分享（同旧详情页 _exportTranscriptTxt）。
  Future<void> _exportTranscript() async {
    // .txt 挂不了二维码，末尾附一行官网链接（同「导出摘要」）。
    // 取在第一个 await 之前——异步之后的 context 可能已经失效。
    final signature = memorionShareSignature(context, ShareCardKind.transcript);
    try {
      final dir = await getTemporaryDirectory();
      final title = conversation.structured.title;
      final header = title.isNotEmpty ? '$title\n\n' : '';
      final file = File('${dir.path}/transcript_${conversation.id}.txt');
      await file.writeAsString('$header${conversation.getTranscript(generate: true)}$signature');
      await Share.shareXFiles([XFile(file.path)], text: title);
    } catch (e) {
      if (mounted) _toast(revampText(context, en: 'Export failed, please try again', zh: '导出失败，请重试'));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    UndoDeleteHost.showMessage(context, msg);
  }

  /// 点一句 → 从这句开始播（音频只在云端时先下载，下好后从这句开始）。
  Future<void> _playSegment(TranscriptSegment segment) async {
    final result = await context.read<ConversationAudioProvider>().playSegment(segment.id);
    if (!mounted) return;
    switch (result) {
      case SegmentPlayback.started:
        break;
      case SegmentPlayback.downloading:
        _toast(revampText(context, en: 'Downloading the recording, it will play from this line', zh: '正在下载录音，下好后从这句开始播'));
      case SegmentPlayback.noAudio:
        _toast(revampText(context, en: 'No audio was kept for this line', zh: '这句没有保留录音'));
      case SegmentPlayback.unavailable:
        _toast(revampText(context, en: "This line can't be played", zh: '这句暂时无法播放'));
    }
  }

  /// 拖动气泡里「这一刻在说什么」。
  String? _previewAt(Duration at, Map<int, String> labels) {
    final id = context.read<ConversationAudioProvider>().alignment?.segmentAt(at.inMilliseconds / 1000.0);
    if (id == null) return null;
    final segment = _segmentsById[id];
    final text = segment?.text.trim() ?? '';
    if (segment == null || text.isEmpty) return null;
    final name = labels[segment.speakerId] ??
        revampText(context, en: 'Speaker ${segment.speakerId}', zh: '说话人 ${segment.speakerId}');
    return revampText(context, en: '$name: $text', zh: '$name：$text');
  }

  /// 点说话人（头像/名字）→ 弹出「标记说话人」大卡片（P-12A，Figma 638:2542）。
  /// 返回 true 表示有变更，刷新本页说话人名/头像。
  Future<void> _openSpeakerSheet(int speakerId, List<TranscriptSegment> segments, {String? segmentId}) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SpeakerMarkSheet(conversation: conversation, speakerId: speakerId),
    );
    if (changed == true && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final segments = conversation.transcriptSegments;
    final labels = speakerLabels(context, segments);
    final colorIndex = speakerColorIndex(segments);
    final minutes = (conversation.getDurationInSeconds() / 60).ceil().clamp(1, 999);

    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary, surface: JXB.surface),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: JxbGradientBackground(
            child: SafeArea(
              child: Stack(
                children: [
                  Column(
                    children: [
                      _DetailBar(
                          title: revampText(context, en: 'Full transcript · $minutes min', zh: '完整原文 · $minutes 分钟'),
                          onMore: () => _showMoreMenu(context)),
                      Expanded(
                        child: segments.isEmpty
                            ? _empty(context)
                            : _buildBody(context, segments, labels, colorIndex),
                      ),
                    ],
                  ),
                  // 底部悬浮音频条（接 ConversationAudioProvider 实际播放）
                  Positioned(
                    left: 16, right: 16,
                    bottom: MediaQuery.of(context).padding.bottom + 12,
                    child: Consumer<ConversationAudioProvider>(
                      builder: (context, audio, _) => _AudioBar(
                        audio: audio,
                        fallbackTotal: conversation.getDurationInSeconds(),
                        previewAt: (at) => _previewAt(at, labels),
                      ),
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

  Widget _buildBody(
    BuildContext context,
    List<TranscriptSegment> segments,
    Map<int, String> labels,
    Map<int, int> colorIndex,
  ) {
    // 只在「能不能按句播」变化时重建整页；播放中换句只重建对应那一段（见 _segmentRow）。
    final alignment = context.select<ConversationAudioProvider, TranscriptAudioAlignment?>(
        (audio) => audio.canPlaySegments ? audio.alignment : null);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 96),
      children: [
        if (widget.initialOffsetSeconds != null) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: JXB.brandPrimary.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(revampText(context, en: 'Marked at ${fmtSpeakerTimestamp(widget.initialOffsetSeconds!)}', zh: '标记于 ${fmtSpeakerTimestamp(widget.initialOffsetSeconds!)}'),
                style: const TextStyle(color: JXB.brandPrimary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(segments.where((s) => (s.originalEnd ?? s.end) >= widget.initialOffsetSeconds! - 15 &&
                (s.originalStart ?? s.start) <= widget.initialOffsetSeconds! + 15).map((s) => s.text.trim()).join(' ')),
            ]),
          ),
          const SizedBox(height: 14),
        ],
        // 「转写文本」标题 + 复制
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(width: 3, height: 16, decoration: BoxDecoration(color: JXB.brandSecondary, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 8),
                Text(revampText(context, en: 'Transcript', zh: '转写文本'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
              ],
            ),
            _CopyButton(onTap: () => _copyAll(context, segments, labels)),
          ],
        ),
        const SizedBox(height: 14),
        // 说话人头像行（点击进入指派）
        SpeakersRow(
          labels: labels,
          colorIndex: colorIndex,
          onTapSpeaker: (sid) => _openSpeakerSheet(sid, segments),
        ),
        const SizedBox(height: 14),
        // 逐段
        for (int i = 0; i < segments.length; i++) ...[
          _segmentRow(context, segments, i, labels, colorIndex, alignment),
          if (i != segments.length - 1)
            Container(height: 1, color: JXB.border, margin: const EdgeInsets.symmetric(vertical: 14)),
        ],
      ],
    );
  }

  Widget _segmentRow(
    BuildContext context,
    List<TranscriptSegment> segments,
    int i,
    Map<int, String> labels,
    Map<int, int> colorIndex,
    TranscriptAudioAlignment? alignment,
  ) {
    final segment = segments[i];
    Widget row({bool highlighted = false}) => TranscriptSegmentRow(
          name: labels[segment.speakerId] ?? revampText(context, en: 'Speaker ${segment.speakerId}', zh: '说话人 ${segment.speakerId}'),
          color: kSpeakerColors[(colorIndex[segment.speakerId] ?? 0) % kSpeakerColors.length].$1,
          time: fmtSpeakerTimestamp(segment.start),
          text: segment.text.trim(),
          onTapName: () => _openSpeakerSheet(segment.speakerId, segments, segmentId: segment.id),
          // 对不齐的老录音不提供按句播放（不拿显示时间去猜音频位置）。
          onPlay: alignment == null ? null : () => _playSegment(segment),
          playable: alignment?.spanOf(segment.id)?.hasAudio ?? false,
          highlighted: highlighted,
        );
    if (alignment == null) return row();
    return ValueListenableBuilder<String?>(
      valueListenable: context.read<ConversationAudioProvider>().currentSegmentId,
      builder: (context, current, _) => row(highlighted: current == segment.id),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Text(revampText(context, en: 'No transcript to show for this recording', zh: '这段没有可显示的转写'),
          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder)),
    );
  }

  void _copyAll(BuildContext context, List<TranscriptSegment> segments, Map<int, String> labels) {
    final buf = StringBuffer();
    for (final seg in segments) {
      final name = labels[seg.speakerId] ?? revampText(context, en: 'Speaker ${seg.speakerId}', zh: '说话人 ${seg.speakerId}');
      buf.writeln('$name ${fmtSpeakerTimestamp(seg.start)}');
      buf.writeln(seg.text.trim());
      buf.writeln();
    }
    Clipboard.setData(ClipboardData(text: buf.toString().trim()));
    UndoDeleteHost.showMessage(context, revampText(context, en: 'Full transcript copied', zh: '已复制全文'));
  }
}

class _DetailBar extends StatelessWidget {
  final String title;
  final VoidCallback onMore;
  const _DetailBar({required this.title, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 68,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _CircleIconButton(icon: Icons.chevron_left_rounded, onTap: () => Navigator.of(context).maybePop()),
            Expanded(
              child: Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: JXB.textSecondary)),
            ),
            _CircleIconButton(icon: Icons.more_horiz_rounded, onTap: onMore),
          ],
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42, height: 42, alignment: Alignment.center,
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.5), shape: BoxShape.circle),
        child: Icon(icon, size: 24, color: JXB.textPrimary),
      ),
    );
  }
}

/// More 菜单项（底部 ActionSheet 独立圆角卡片，同章节详情页 P-11 风格）。
/// [primary] 为主操作：蓝色高亮底 + 白字；否则浅灰底深字。
class _MenuItem extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool primary;
  const _MenuItem({required this.label, required this.onTap, this.primary = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary ? JXB.brandSecondary : const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: primary ? Colors.white : JXB.textPrimary)),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CopyButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(60)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.copy_rounded, size: 16, color: JXB.textSecondary),
            const SizedBox(width: 8),
            Text(revampText(context, en: 'Copy', zh: '复制'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
          ],
        ),
      ),
    );
  }
}

/// 底部悬浮音频条（接 ConversationAudioProvider：本地/云端音频、播放/暂停、拖动进度）。
class _AudioBar extends StatefulWidget {
  final ConversationAudioProvider audio;
  final int fallbackTotal; // 秒，音频未就绪时显示会话时长
  final String? Function(Duration at)? previewAt;
  const _AudioBar({required this.audio, required this.fallbackTotal, this.previewAt});

  @override
  State<_AudioBar> createState() => _AudioBarState();
}

class _AudioBarState extends State<_AudioBar> {
  Duration? _scrubbing; // 拖动中：右侧时间跟着手指走，而不是播放器

  @override
  Widget build(BuildContext context) {
    final audio = widget.audio;
    final bool ready = audio.hasAudio;
    final bool loading = audio.isLoading;
    final bool downloadable = audio.isDownloadable;
    final bool downloading = audio.isDownloading;

    final String posLabel = ready ? fmtPlaybackClock(_scrubbing ?? audio.position) : '00:00';
    final String totalLabel =
        ready ? fmtPlaybackClock(audio.duration) : fmtPlaybackClock(Duration(seconds: widget.fallbackTotal));

    // 中心图标：加载/下载中→spinner；可下载→下载；就绪→播放/暂停。
    Widget leading;
    VoidCallback? onTap;
    if (loading || downloading) {
      leading = const SizedBox(
        width: 18, height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
      );
    } else if (downloadable) {
      leading = const Icon(Icons.download_rounded, size: 20, color: Colors.white);
      onTap = () => audio.downloadAudio();
    } else if (ready) {
      leading = Icon(audio.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 20, color: Colors.white);
      onTap = () => audio.playPause();
    } else {
      // 无音频
      leading = const Icon(Icons.music_off_rounded, size: 18, color: Colors.white);
    }

    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.circular(98),
        boxShadow: const [BoxShadow(color: Color(0x1A2B2926), blurRadius: 30)],
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onTap,
            child: Container(
              width: 32, height: 32, alignment: Alignment.center,
              decoration: BoxDecoration(
                color: (ready || downloadable) ? JXB.brandSecondary : JXB.textPlaceholder,
                shape: BoxShape.circle,
              ),
              child: leading,
            ),
          ),
          // 轨道两侧的 12pt 空隙在 AudioScrubber 里（kScrubberInset），这样空隙也能按；
          // 高度撑满胶囊，整条 60pt 都是可按区域。
          Expanded(
            child: SizedBox(
              height: 60,
              child: AudioScrubber(
                // 未就绪时不读播放器状态（与改版前一致：只有 ready 才读 position/duration）。
                position: ready ? audio.position : Duration.zero,
                duration: ready ? audio.duration : Duration.zero,
                enabled: ready,
                onSeek: (target) => audio.seekTo(target),
                onScrub: (target) => setState(() => _scrubbing = target),
                previewAt: widget.previewAt,
              ),
            ),
          ),
          // 等宽数字：拖动时数字变化不会让轨道宽度跟着抖。
          Text('$posLabel / $totalLabel',
              style: const TextStyle(
                  fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textSecondary,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}
