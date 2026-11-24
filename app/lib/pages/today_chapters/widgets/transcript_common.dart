import 'package:flutter/material.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// 完整原文（P-12）与实时采集（P-06）共用的说话人渲染组件与工具。
///
/// 两个页面的 segment 数据结构一致（同一个 [TranscriptSegment]），说话人推导、
/// 配色、头像与逐段渲染逻辑此前在两处逐行复制，这里统一抽出。
/// 差异点做成可选参数：
/// - [SpeakersRow.onTapSpeaker] / [TranscriptSegmentRow.onTapName]：为空则不可点（无手势、无下拉箭头）。
/// - [SpeakersRow.activeSpeakerId] / [SpeakerAvatar.breathing]：正在说话者呼吸光晕（实时页用）。
/// - [TranscriptSegmentRow.isLast]：录音中最后一条，空文本显示「…」占位。

/// 说话人配色（按出现顺序循环）。(fg, bg)
const List<(Color, Color)> kSpeakerColors = [
  (Color(0xFF21B280), Color(0x2421B280)), // 绿
  (Color(0xFFE5524D), Color(0x24E5524D)), // 红
  (Color(0xFF54A4FD), Color(0x2454A4FD)), // 蓝
  (Color(0xFFFFB13E), Color(0x24FFB13E)), // 橙
  (Color(0xFF9B7BFF), Color(0x249B7BFF)), // 紫
];

class _Agg {
  int count = 0;
  int userVotes = 0;
  final Map<String, int> personVotes = {};
}

/// speaker → 显示名（多数投票 → 人名 / 你 / 说话人 N）。
Map<int, String> speakerLabels(BuildContext context, List<TranscriptSegment> segments) {
  final Map<int, _Agg> byId = {};
  for (final seg in segments) {
    final agg = byId.putIfAbsent(seg.speakerId, () => _Agg());
    agg.count++;
    if (seg.isUser) agg.userVotes++;
    if (seg.personId != null) agg.personVotes[seg.personId!] = (agg.personVotes[seg.personId!] ?? 0) + 1;
  }
  final labels = <int, String>{};
  byId.forEach((sid, agg) {
    if (agg.userVotes * 2 >= agg.count) {
      final given = SharedPreferencesUtil().givenName;
      labels[sid] = given.isNotEmpty ? given : revampText(context, en: 'You', zh: '你');
    } else if (agg.personVotes.isNotEmpty) {
      final personId = agg.personVotes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
      labels[sid] = SharedPreferencesUtil().getPersonById(personId)?.name ?? revampText(context, en: 'Speaker $sid', zh: '说话人 $sid');
    } else {
      labels[sid] = revampText(context, en: 'Speaker $sid', zh: '说话人 $sid');
    }
  });
  return labels;
}

/// speaker → 配色索引（按首次出现顺序）。
Map<int, int> speakerColorIndex(List<TranscriptSegment> segments) {
  final map = <int, int>{};
  var next = 0;
  for (final seg in segments) {
    if (!map.containsKey(seg.speakerId)) map[seg.speakerId] = next++;
  }
  return map;
}

/// 秒 → mm:ss。
String fmtSpeakerTimestamp(double seconds) {
  final s = seconds.floor();
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 头像首字：中文名取最后一字（小王→王）；拉丁名取首字母大写；「说话人 N」取数字。
String speakerInitial(String label) {
  if (label.isEmpty) return '?';
  final speakerMatch = RegExp(r'(?:说话人|Speaker)\s*(\d+)').firstMatch(label);
  if (speakerMatch != null) return speakerMatch.group(1)!;
  if (RegExp(r'[一-鿿]').hasMatch(label)) return label.characters.last; // 小王→王，你→你
  return label.characters.first.toUpperCase(); // Teague→T
}

/// 说话人头像行。[onTapSpeaker] 非空时头像可点；[activeSpeakerId] 命中者呼吸光晕。
class SpeakersRow extends StatelessWidget {
  final Map<int, String> labels;
  final Map<int, int> colorIndex;
  final ValueChanged<int>? onTapSpeaker;
  final int? activeSpeakerId;
  const SpeakersRow({
    super.key,
    required this.labels,
    required this.colorIndex,
    this.onTapSpeaker,
    this.activeSpeakerId,
  });

  @override
  Widget build(BuildContext context) {
    final ids = colorIndex.keys.toList()..sort((a, b) => colorIndex[a]!.compareTo(colorIndex[b]!));
    if (ids.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        for (final id in ids) ...[
          Builder(builder: (_) {
            final avatar = SpeakerAvatar(
              initial: speakerInitial(labels[id] ?? '$id'),
              fg: kSpeakerColors[colorIndex[id]! % kSpeakerColors.length].$1,
              bg: kSpeakerColors[colorIndex[id]! % kSpeakerColors.length].$2,
              breathing: id == activeSpeakerId,
            );
            if (onTapSpeaker == null) return avatar;
            return GestureDetector(
              onTap: () => onTapSpeaker!(id),
              behavior: HitTestBehavior.opaque,
              child: avatar,
            );
          }),
          const SizedBox(width: 18),
        ],
      ],
    );
  }
}

/// 说话人头像。[breathing]=true 时外圈呼吸光晕（表示正在说话）。
class SpeakerAvatar extends StatefulWidget {
  final String initial;
  final Color fg;
  final Color bg;
  final bool breathing;
  const SpeakerAvatar({
    super.key,
    required this.initial,
    required this.fg,
    required this.bg,
    this.breathing = false,
  });

  @override
  State<SpeakerAvatar> createState() => _SpeakerAvatarState();
}

class _SpeakerAvatarState extends State<SpeakerAvatar> with SingleTickerProviderStateMixin {
  /// ⚠️ **必须在 initState 里建，不能写成 `late final _c = AnimationController(...)`。**
  /// 那种写法是**惰性**的：`breathing=false` 时 build 走 early return，从没读过 `_c`，
  /// 于是 `dispose()` 里的 `_c.dispose()` 成了它的首次读取——在 element 已经 deactivate
  /// 之后才去 `createTicker`，抛 "Looking up a deactivated widget's ancestor is unsafe"。
  /// 而它抛在 dispose 里，被框架捕获后只是刷一堆红字，界面看着照常，所以极难发现。
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
    if (widget.breathing) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant SpeakerAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.breathing && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.breathing && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final core = Container(
      width: 48, height: 48, alignment: Alignment.center,
      decoration: BoxDecoration(color: widget.bg, shape: BoxShape.circle, border: Border.all(color: widget.fg, width: 1.56)),
      child: Text(widget.initial, style: TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w600, color: widget.fg)),
    );
    if (!widget.breathing) return core;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value; // 0..1
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: widget.fg.withValues(alpha: 0.15 + 0.35 * t), blurRadius: 6 + 10 * t, spreadRadius: 1 + 3 * t),
            ],
          ),
          child: core,
        );
      },
    );
  }
}

/// 逐段：说话人名(彩色) + 时间戳 + 正文。
/// [onTapName] 非空时名字可点（进入说话人分配）并显示下拉箭头；
/// [isLast]=true 且正文为空时显示「…」占位（录音中最后一条）。
/// [onPlay] 非空时点正文或时间从这句开始播（完整原文页）；[playable] 时时间显示成「▶ 12:34」，
/// [highlighted] 是正在播的这一句。实时采集页三者都不传，样子不变。
class TranscriptSegmentRow extends StatelessWidget {
  final String name;
  final Color color;
  final String time;
  final String text;
  final VoidCallback? onTapName;
  final bool isLast;
  final VoidCallback? onPlay;
  final bool playable;
  final bool highlighted;
  const TranscriptSegmentRow({
    super.key,
    required this.name,
    required this.color,
    required this.time,
    required this.text,
    this.onTapName,
    this.isLast = false,
    this.onPlay,
    this.playable = false,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool showPlay = onPlay != null && playable;
    final Widget timeLabel = showPlay
        ? GestureDetector(
            onTap: onPlay,
            behavior: HitTestBehavior.opaque,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_arrow_rounded, size: 15, color: JXB.brandSecondary),
                Text(time, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.brandSecondary)),
              ],
            ),
          )
        : Text(time, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder));
    final header = Row(
      children: [
        Text(name, style: TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: color)),
        if (onTapName != null) ...[
          const SizedBox(width: 6),
          Icon(Icons.expand_more_rounded, size: 15, color: color.withValues(alpha: 0.6)),
          const SizedBox(width: 4),
        ] else
          const SizedBox(width: 8),
        timeLabel,
      ],
    );
    Widget body = Text(text.isEmpty && isLast ? '…' : text,
        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, height: 1.75, color: JXB.textPrimary));
    if (onPlay != null) {
      // 整行宽度都能点，不只是字所在的那一截。
      body = GestureDetector(
        onTap: onPlay,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(width: double.infinity, child: body),
      );
    }
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        onTapName == null
            ? header
            : GestureDetector(onTap: onTapName, behavior: HitTestBehavior.opaque, child: header),
        const SizedBox(height: 8),
        body,
      ],
    );
    if (onPlay == null) return content;
    // 高亮画在内容外圈（伸进列表边距和段间距里），不占布局：播放换句时正文不会跳。
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: -10, right: -10, top: -6, bottom: -6,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: highlighted ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: DecoratedBox(
                decoration: BoxDecoration(color: JXB.brandTint, borderRadius: BorderRadius.circular(JXB.radiusControl)),
              ),
            ),
          ),
        ),
        content,
      ],
    );
  }
}
