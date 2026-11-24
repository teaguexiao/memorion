import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// 回听时间统一显示成 `分:秒`（分钟不封顶，与段落时间戳 `fmtSpeakerTimestamp` 一致）。
String fmtPlaybackClock(Duration d) {
  final s = d.inSeconds;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 轨道两端留给手势的余量：胶囊里播放键、时间文字与轨道之间的空隙也能按。
const double kScrubberInset = 12;

const double _trackHeight = 4;
const double _thumbRest = 12;
const double _thumbActive = 20;

/// 按下点离把手这么近就算抓住把手：不跳到手指处，只跟着手指移动。
const double _grabRadius = 22;

/// 小于这个位移算点按时的手抖。
const double _tapSlop = 8;

/// 手指高出进度条多少 pt 进入下一档；往回落时要再低 [_levelHysteresis] 才退档，免得在边界上来回跳。
const List<double> _levelThresholds = [44, 120];
const double _levelHysteresis = 10;

/// 最细一档每 1pt 走 1 秒，和录音多长无关。
const double _finestSecondsPerPoint = 1.0;

/// 震动刻度的候选间隔（秒），取相邻刻度间距不小于 [_tickMinSpacing] pt 的最小一个。
const List<int> _tickCandidates = [60, 300, 600, 1800, 3600];
const double _tickMinSpacing = 16;

/// 完整原文页底部胶囊里的回听进度条。
///
/// 为什么不用 Slider、也不在拖动中 seek：
/// - 录音很长（上传/手表录音中位数 55 分钟，最长近 5 小时），这条轨道却只有约 200pt，
///   贴着条拖每 1pt 就是十几秒。手指往上抬离进度条就切到慢速、精细档，精细档每 1pt
///   一秒，这是精确停在某一分钟的办法。
/// - 拖动中只改本地状态，松手才 seek 一次。以前每帧都 seek，进度条画的是播放器回报的
///   位置，跟不上手指，播放中还会出碎音。
/// - 整个胶囊的高度都能按（以前只有中间 20pt）。用 [Listener] 而不是手势识别器：
///   胶囊盖在列表上面，没有谁跟它抢手势，按下就该立刻有反应。
class AudioScrubber extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final bool enabled;
  final ValueChanged<Duration> onSeek;

  /// 拖动中的目标位置；松手或取消时回调 null。宿主用它让右侧时间跟着手指走。
  final ValueChanged<Duration?>? onScrub;

  /// 气泡里「这一刻在说什么」，返回 null 就不显示。
  final String? Function(Duration at)? previewAt;

  const AudioScrubber({
    super.key,
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onSeek,
    this.onScrub,
    this.previewAt,
  });

  @override
  State<AudioScrubber> createState() => _AudioScrubberState();
}

class _AudioScrubberState extends State<AudioScrubber> {
  final OverlayPortalController _bubble = OverlayPortalController();

  int? _pointer;
  Offset _downLocal = Offset.zero;
  Offset _fingerGlobal = Offset.zero;
  bool _moved = false;
  bool _grabbedThumb = false;
  double _target = 0; // 秒
  int _level = 0;
  double _trackWidth = 0;

  bool get _active => _pointer != null;
  double get _durationSeconds => widget.duration.inMilliseconds / 1000.0;
  double get _positionSeconds => widget.position.inMilliseconds / 1000.0;
  double get _shownSeconds => _active ? _target : _positionSeconds;

  /// 贴着条拖时每 1pt 对应的秒数。
  double get _coarseRate => _trackWidth > 0 ? _durationSeconds / _trackWidth : 0;

  /// 录音短到贴着拖就够细时不分档。
  bool get _hasLevels => _coarseRate > _finestSecondsPerPoint * 1.5;

  double _rateFor(int level) {
    final coarse = _coarseRate;
    final finest = math.min(coarse, _finestSecondsPerPoint);
    if (level <= 0) return coarse;
    if (level == 1) return math.sqrt(coarse * finest); // 两档之间按比例取中，长录音也不会一步跨太大
    return finest;
  }

  int _levelFor(double heightAboveBar) {
    if (!_hasLevels) return 0;
    var level = 0;
    for (final threshold in _levelThresholds) {
      if (heightAboveBar >= threshold) level++;
    }
    if (level < _level && heightAboveBar >= _levelThresholds[_level - 1] - _levelHysteresis) return _level;
    return level;
  }

  double _fraction(double seconds) =>
      _durationSeconds > 0 ? (seconds / _durationSeconds).clamp(0.0, 1.0) : 0.0;

  double _secondsAtX(double x) =>
      ((x - kScrubberInset) / _trackWidth).clamp(0.0, 1.0) * _durationSeconds;

  Duration _asDuration(double seconds) => Duration(milliseconds: (seconds * 1000).round());

  void _onDown(PointerDownEvent e) {
    if (!widget.enabled || _active || _trackWidth <= 0 || _durationSeconds <= 0) return;
    final thumbX = kScrubberInset + _trackWidth * _fraction(_positionSeconds);
    _pointer = e.pointer;
    _downLocal = e.localPosition;
    _fingerGlobal = e.position;
    _moved = false;
    _level = 0;
    _grabbedThumb = (e.localPosition.dx - thumbX).abs() <= _grabRadius;
    _target = _grabbedThumb ? _positionSeconds : _secondsAtX(e.localPosition.dx);
    _bubble.show();
    setState(() {});
    widget.onScrub?.call(_asDuration(_target));
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _fingerGlobal = e.position;
    if (!_moved) {
      if ((e.localPosition - _downLocal).distance < _tapSlop) return;
      _moved = true;
      // 越过手抖阈值的这一下，把按下以来的横向位移一次补上，不丢距离。
      _advance(e.localPosition.dx - _downLocal.dx, e.localPosition.dy);
    } else {
      _advance(e.delta.dx, e.localPosition.dy);
    }
  }

  void _advance(double dx, double localY) {
    final level = _levelFor(math.max(0.0, -localY));
    if (level != _level) {
      _level = level;
      HapticFeedback.lightImpact();
    }
    final rate = _rateFor(_level);
    final before = _target;
    _target = (_target + dx * rate).clamp(0.0, _durationSeconds);
    final interval = _tickCandidates.firstWhere((s) => s / rate >= _tickMinSpacing, orElse: () => _tickCandidates.last);
    if ((before / interval).floor() != (_target / interval).floor()) HapticFeedback.selectionClick();
    setState(() {});
    widget.onScrub?.call(_asDuration(_target));
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    final target = _asDuration(_target);
    final seek = _moved || !_grabbedThumb; // 只是点了一下把手：原地不动
    _finish();
    if (seek) widget.onSeek(target);
  }

  // 被系统打断（来电、通知中心）：不 seek。
  void _onCancel(PointerCancelEvent e) {
    if (e.pointer == _pointer) _finish();
  }

  void _finish() {
    _pointer = null;
    _bubble.hide();
    setState(() {});
    widget.onScrub?.call(null);
  }

  String? _levelLabel(BuildContext context) {
    if (!_hasLevels) return null;
    switch (_level) {
      case 0:
        return revampText(context, en: 'Slide up to scrub slower', zh: '手指上移，拖得更细');
      case 1:
        return revampText(context, en: 'Slow scrubbing', zh: '慢速拖动');
      default:
        return revampText(context, en: 'Fine scrubbing', zh: '精细拖动');
    }
  }

  Widget _buildBubble(BuildContext context) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    final bar = this.context.findRenderObject() as RenderBox?;
    if (overlay == null || bar == null || !bar.attached) return const SizedBox.shrink();
    // 气泡底边：在指尖上方，且至少在进度条上方。
    final barTop = bar.localToGlobal(Offset.zero).dy - 14;
    final fingerTop = _fingerGlobal.dy - 52;
    final anchor = overlay.globalToLocal(Offset(_fingerGlobal.dx, math.min(barTop, fingerTop)));
    final at = _asDuration(_target);
    final preview = widget.previewAt?.call(at);
    final levelLabel = _levelLabel(context);
    const numbers = [FontFeature.tabularFigures()];

    return Positioned.fill(
      child: IgnorePointer(
        child: CustomSingleChildLayout(
          delegate: _BubbleLayout(anchor: anchor, topLimit: MediaQuery.paddingOf(context).top + 8),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: JXB.surface,
              borderRadius: BorderRadius.circular(JXB.radiusCard),
              boxShadow: const [BoxShadow(color: Color(0x262B2926), blurRadius: 24, offset: Offset(0, 6))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: fmtPlaybackClock(at),
                      style: const TextStyle(
                          fontFamily: JXB.fontNumber, fontSize: 22, fontWeight: FontWeight.w600,
                          color: JXB.textPrimary, fontFeatures: numbers),
                    ),
                    TextSpan(
                      text: ' / ${fmtPlaybackClock(widget.duration)}',
                      style: const TextStyle(
                          fontFamily: JXB.fontNumber, fontSize: 13, color: JXB.textSecondary, fontFeatures: numbers),
                    ),
                  ]),
                ),
                if (preview != null) ...[
                  const SizedBox(height: 4),
                  Text(preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                ],
                if (levelLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(levelLabel,
                      style: TextStyle(
                          fontFamily: JXB.fontSans,
                          fontSize: 11,
                          color: _level > 0 ? JXB.brandSecondary : JXB.textPlaceholder)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _asDuration(_shownSeconds);
    Duration nudged(int seconds) =>
        _asDuration((_shownSeconds + seconds).clamp(0.0, math.max(0.0, _durationSeconds)));

    return Semantics(
      slider: true,
      label: revampText(context, en: 'Playback position', zh: '播放进度'),
      value: fmtPlaybackClock(shown),
      increasedValue: fmtPlaybackClock(nudged(15)),
      decreasedValue: fmtPlaybackClock(nudged(-15)),
      onIncrease: widget.enabled ? () => widget.onSeek(nudged(15)) : null,
      onDecrease: widget.enabled ? () => widget.onSeek(nudged(-15)) : null,
      child: OverlayPortal(
        controller: _bubble,
        overlayChildBuilder: _buildBubble,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onCancel,
          child: LayoutBuilder(builder: (context, constraints) {
            _trackWidth = math.max(0.0, constraints.maxWidth - 2 * kScrubberInset);
            final height = constraints.maxHeight;
            final fill = widget.enabled ? _trackWidth * _fraction(_shownSeconds) : 0.0;
            final trackTop = (height - _trackHeight) / 2;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: kScrubberInset, right: kScrubberInset, top: trackTop, height: _trackHeight,
                  child: DecoratedBox(
                      decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(2))),
                ),
                Positioned(
                  left: kScrubberInset, width: fill, top: trackTop, height: _trackHeight,
                  child: DecoratedBox(
                      decoration: BoxDecoration(color: JXB.brandSecondary, borderRadius: BorderRadius.circular(2))),
                ),
                if (widget.enabled)
                  Positioned(
                    left: kScrubberInset + fill - _thumbActive / 2,
                    top: (height - _thumbActive) / 2,
                    width: _thumbActive,
                    height: _thumbActive,
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: _active ? _thumbActive : _thumbRest,
                        height: _active ? _thumbActive : _thumbRest,
                        decoration: BoxDecoration(
                          color: JXB.brandSecondary,
                          shape: BoxShape.circle,
                          border: Border.all(color: JXB.surface, width: 2),
                          boxShadow: const [BoxShadow(color: Color(0x332B2926), blurRadius: 4, offset: Offset(0, 1))],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// 气泡水平居中在手指上、底边落在锚点上，左右和顶部都不出屏。
class _BubbleLayout extends SingleChildLayoutDelegate {
  final Offset anchor;
  final double topLimit;
  static const double _margin = 12;

  const _BubbleLayout({required this.anchor, required this.topLimit});

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: math.max(0.0, constraints.maxWidth - 2 * _margin), maxHeight: constraints.maxHeight);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxX = math.max(_margin, size.width - _margin - childSize.width);
    final x = (anchor.dx - childSize.width / 2).clamp(_margin, maxX);
    final y = math.max(topLimit, anchor.dy - childSize.height);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_BubbleLayout oldDelegate) => oldDelegate.anchor != anchor || oldDelegate.topLimit != topLimit;
}
