import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:memorion/pages/today_chapters/widgets/chapter_ask_floating_button.dart';

/// 章节详情 → Ask 的「收缩进入口」转场，做成一个真正的页面路由。
///
/// Ask 因此和首页入口一样是独立页面：App 切后台不会被收起，iOS 可以右滑返回。
/// 收缩不再靠「把 Ask 叠在详情页里」实现（那一层曾在 App 进后台时被整个收起），
/// 而是由本路由通过 [delegatedTransition] 交给下面的章节详情播放；详情页始终挂载，
/// 滚动位置与选区都在。
///
/// 时间轴（motion-reference.json）：0–180ms 抬起到 0.95；180–760ms 收缩到 0.055 并飞向
/// 入口；760–890ms 被入口吸收；890ms 起 Ask 淡入；1110–1810ms 上下文卡升起；返回 220ms。
/// 减少动态效果：0–150ms 详情淡出，150ms 起 Ask 淡入，370–550ms 上下文卡。
class ContinueChatRoute<T> extends PageRoute<T> with MaterialRouteTransitionMixin<T> {
  ContinueChatRoute({required this.builder, required this.anchor, required this.showEntry, required this.reduceMotion});

  /// Ask 页；[cardProgress] 驱动它的上下文卡升起（0→1）。
  final Widget Function(BuildContext context, Animation<double> cardProgress) builder;

  /// 详情收缩的落点（全局坐标）：悬浮入口或底部邀请卡的中心。
  final Offset anchor;

  /// 入口是悬浮按钮：转场期间在最上层播放它的云朵动画（详情页里的真按钮此时隐藏）。
  final bool showEntry;
  final bool reduceMotion;

  /// 上下文卡的升起进度。
  late final Animation<double> cardProgress = _HandoffValue(this, (frame) => frame.card);

  // 平台转场只在用户拖动返回时跟手、其余时间静止：它在这里只贡献 iOS 的右滑返回。
  late final Animation<double> _platformAnimation = _WhileSwiping(this);

  // 返回从按下返回那一刻的状态复原，而不是把整段推入时间轴倒放一遍。
  double _popFrom = 1;

  @override
  Duration get transitionDuration => Duration(milliseconds: reduceMotion ? 550 : 1810);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 220);

  @override
  bool get maintainState => true;

  @override
  Widget buildContent(BuildContext context) => builder(context, cardProgress);

  @override
  bool didPop(T? result) {
    _popFrom = controller?.value ?? 1;
    return super.didPop(result);
  }

  bool get _swiping => navigator?.userGestureInProgress ?? false;

  _HandoffFrame get _frame {
    final total = transitionDuration.inMilliseconds.toDouble();
    final animation = this.animation;
    // 右滑返回时两层都交给平台转场，时间轴停在终点。
    if (animation == null || _swiping) return _HandoffFrame(total, 0, reduceMotion: reduceMotion);
    if (animation.isForwardOrCompleted) return _HandoffFrame(animation.value * total, 0, reduceMotion: reduceMotion);
    final from = _popFrom > 0 ? _popFrom : 1.0;
    return _HandoffFrame(from * total, Curves.easeOut.transform((1 - animation.value / from).clamp(0.0, 1.0)),
        reduceMotion: reduceMotion, popping: true);
  }

  @override
  Widget buildTransitions(
      BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final frame = _frame;
    final page = Theme.of(context)
        .pageTransitionsTheme
        .buildTransitions<T>(this, context, _platformAnimation, secondaryAnimation, child);
    return Stack(children: [
      Positioned.fill(
        // 淡入之前与返回途中都不接收点击：既不落到半透明的 Ask，也不落到下面正在变形的详情。
        child: AbsorbPointer(
          absorbing: !frame.askReady,
          child: ExcludeSemantics(
            excluding: !frame.askReady,
            child: Opacity(opacity: frame.askOpacity, child: page),
          ),
        ),
      ),
      if (showEntry && frame.entryVisible)
        Positioned(
          right: 18,
          bottom: ChapterAskFloatingButton.bottomInset(context),
          child: IgnorePointer(
            child: ChapterAskFloatingButton(
              buttonKey: const Key('continue-chat-handoff'), // i18n-ignore: widget identifier
              onTap: null,
              scale: frame.entryScale,
              rotation: frame.entryRotation,
              capture: frame.entryCapture,
            ),
          ),
        ),
    ]);
  }

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _chapterTransition;

  Widget? _chapterTransition(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation,
      bool allowSnapshotting, Widget? child) {
    if (navigator == null || child == null) return null;
    if (_swiping) {
      // 原生右滑返回：详情页和其它页面一样从左侧视差滑回。
      final theme = Theme.of(context);
      return theme.pageTransitionsTheme
              .delegatedTransition(theme.platform)
              ?.call(context, animation, secondaryAnimation, allowSnapshotting, child) ??
          child;
    }
    final frame = _frame;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(builder: (context, box) {
          // 路由铺满屏幕，全局落点即本地坐标。
          final center = box.biggest.center(Offset.zero);
          return Stack(children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFFF9FAFA))),
            Positioned.fill(
              key: const Key('continue-source-layer'), // i18n-ignore: widget identifier
              child: Transform.translate(
                offset: frame.pageOffset(anchor - center),
                child: Transform.scale(
                  key: const Key('continue-detail-transform'), // i18n-ignore: widget identifier
                  scale: frame.pageScale,
                  child: Opacity(
                    opacity: frame.pageOpacity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(frame.shadowRadius),
                        boxShadow: frame.shadowAlpha > 0
                            ? [
                                BoxShadow(
                                    color: Colors.black.withValues(alpha: frame.shadowAlpha),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8)),
                              ]
                            : null,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(frame.pageRadius),
                        // 键盘属于 Ask；详情在下面保持原来的阅读布局。
                        child: MediaQuery(
                            data: MediaQuery.of(context).copyWith(viewInsets: EdgeInsets.zero), child: child),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]);
        }),
      ),
    );
  }
}

/// 转场的一帧：推入时间轴上的时刻 [time]（ms）与返回进度 [restore]（0→1）。
class _HandoffFrame {
  const _HandoffFrame(this.time, this.restore, {required this.reduceMotion, this.popping = false});
  final double time;
  final double restore;
  final bool reduceMotion;
  final bool popping;

  static double _segment(double time, double start, double end, [Curve curve = Curves.easeOut]) =>
      curve.transform(((time - start) / (end - start)).clamp(0.0, 1.0));

  double get _lift => _segment(time, 0, 180);
  double get _shrink => _segment(time, 180, 760, const Cubic(0.52, 0.02, 0.78, 0.50));
  double get _capture => _segment(time, 760, 890);
  double get _chatStart => reduceMotion ? 150 : 890;

  // Ask：淡入开始后才可交互；返回途中随复原淡出。
  bool get askReady => !popping && time >= _chatStart;
  double get askOpacity => _segment(time, _chatStart, _chatStart + 200) * (1 - restore);
  double get card => _segment(time, reduceMotion ? 370 : 1110, reduceMotion ? 550 : 1810, Curves.linear);

  // 悬浮入口：Ask 淡入前一直在；云朵先抬起，再随详情收缩回正、被吸收。
  bool get entryVisible => !popping && time < _chatStart;
  double get entryScale => reduceMotion
      ? 1
      : time < 180
          ? lerpDouble(1, .88, _lift)!
          : time < 760
              ? lerpDouble(.88, 1.04, _shrink)!
              : lerpDouble(1.04, 1.16, _capture)!;
  double get entryRotation => reduceMotion
      ? 0
      : time < 180
          ? -12 * _lift
          : time < 760
              ? lerpDouble(-12, 8, _shrink)!
              : 8 * (1 - _capture);
  double? get entryCapture => reduceMotion ? null : _capture;

  // 章节详情：抬起、收缩飞向入口、被吸收；返回时从当前状态复原到原样。
  double get pageScale =>
      lerpDouble(reduceMotion ? 1.0 : lerpDouble(lerpDouble(1, .95, _lift)!, .055, _shrink)!, 1, restore)!;
  Offset pageOffset(Offset centerToAnchor) => (reduceMotion ? Offset.zero : centerToAnchor * _shrink) * (1 - restore);
  double get pageOpacity => lerpDouble(reduceMotion ? 1 - _segment(time, 0, 150) : 1 - _capture, 1, restore)!;
  double get pageRadius => reduceMotion ? 0 : (26 * _lift + 16 * _shrink) * (1 - restore);
  double get shadowRadius => 26 * _lift;
  double get shadowAlpha => reduceMotion ? 0 : .12 * _lift * (1 - restore);
}

/// 只在用户拖动返回时跟随路由动画，其余时间停在 1（平台转场静止）。
class _WhileSwiping extends Animation<double> with AnimationWithParentMixin<double> {
  _WhileSwiping(this.route);
  final ContinueChatRoute<dynamic> route;

  @override
  Animation<double> get parent => route.animation!;

  @override
  double get value => route._swiping ? parent.value : 1;

  @override
  AnimationStatus get status => route._swiping ? parent.status : AnimationStatus.completed;
}

/// 推入时间轴上的某个量（例如上下文卡的升起进度），随路由动画刷新。
class _HandoffValue extends Animation<double> with AnimationWithParentMixin<double> {
  _HandoffValue(this.route, this.read);
  final ContinueChatRoute<dynamic> route;
  final double Function(_HandoffFrame frame) read;

  @override
  Animation<double> get parent => route.animation!;

  @override
  double get value => read(route._frame);

  @override
  AnimationStatus get status => value >= 1 ? AnimationStatus.completed : AnimationStatus.forward;
}
