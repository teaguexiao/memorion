import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:memorion/widgets/jxb_toast.dart';
import 'package:provider/provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// Lives above the Navigator so back navigation never destroys an Undo window.
class UndoDeleteHost extends StatefulWidget {
  final Widget child;
  const UndoDeleteHost({super.key, required this.child});

  /// Feedback shares the same floating slot; deletion Undo has priority.
  static void showMessage(BuildContext context, String message,
      {String? actionLabel,
      VoidCallback? onAction,
      Duration duration = const Duration(seconds: 3),
      bool showProgress = false}) {
    assert((actionLabel == null) == (onAction == null));
    if (!context.mounted) return;
    final route = ModalRoute.of(context);
    context.findAncestorStateOfType<_UndoDeleteHostState>()?._showMessage(_Feedback(message, duration, actionLabel,
        onAction, showProgress, onAction == null ? null : () => context.mounted && (route?.isActive ?? true)));
  }

  /// Capture before an async operation that can outlive its originating page.
  static ValueChanged<String> messageSink(BuildContext context) {
    final host = context.findAncestorStateOfType<_UndoDeleteHostState>();
    return (message) => host?._showMessage(_Feedback(message, const Duration(seconds: 3)));
  }

  @override
  State<UndoDeleteHost> createState() => _UndoDeleteHostState();
}

class _Feedback {
  final String message;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool showProgress;
  final bool Function()? isRelevant;
  const _Feedback(this.message, this.duration,
      [this.actionLabel, this.onAction, this.showProgress = false, this.isRelevant]);
  bool get relevant => isRelevant?.call() ?? true;
}

class _UndoDeleteHostState extends State<UndoDeleteHost> with WidgetsBindingObserver {
  UndoDeleteController? _controller;
  final _focus = Object(), _screenReader = Object();
  final _feedbackClock = ValueNotifier<double>(0);
  Timer? _feedbackTimer;
  Duration _feedbackRemaining = Duration.zero;
  _Feedback? _feedback;
  final List<_Feedback> _queuedFeedback = [];
  bool _clockSyncScheduled = false;
  bool _feedbackFocused = false;
  bool _foreground = true;

  void _showMessage(_Feedback feedback) {
    if (!mounted || !feedback.relevant) return;
    // Never replace an actionable message with incidental copy/save feedback.
    if (_feedback?.onAction != null) {
      if (feedback.onAction == null) _queuedFeedback.removeWhere((entry) => entry.onAction == null);
      _queuedFeedback.add(feedback);
      return;
    }
    _activate(feedback);
  }

  void _activate(_Feedback? feedback) {
    _feedbackTimer?.cancel();
    _feedbackTimer = null;
    _feedbackRemaining = feedback?.duration ?? Duration.zero;
    _feedbackClock.value = 0;
    setState(() {
      _feedback = feedback;
      _feedbackFocused = false;
    });
    _updateClock();
  }

  void _finishFeedback() {
    _queuedFeedback.removeWhere((entry) => !entry.relevant);
    _activate(_queuedFeedback.isEmpty ? null : _queuedFeedback.removeAt(0));
  }

  void _syncClock() {
    if (_clockSyncScheduled) return;
    _clockSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _clockSyncScheduled = false;
      if (!mounted) return;
      if (_feedback != null && !_feedback!.relevant) {
        _finishFeedback();
        return;
      }
      _updateClock();
    });
  }

  void _updateClock() {
    final c = _controller;
    final media = MediaQuery.of(context);
    final blocked = !_foreground ||
        (c?.modalVisible ?? false) ||
        (c?.pending.isNotEmpty ?? false) ||
        (c?.failed ?? false) ||
        _feedbackFocused ||
        (media.accessibleNavigation && _feedback?.onAction != null);
    if (_feedback == null || blocked) {
      _feedbackTimer?.cancel();
      _feedbackTimer = null;
    } else if (_feedbackTimer == null) {
      // Timer ticks do not schedule frames for ordinary feedback. Only an
      // explicit progress strip needs repainting while the window runs.
      var lastTick = 0;
      _feedbackTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
        _feedbackRemaining -= Duration(milliseconds: 50 * (timer.tick - lastTick));
        lastTick = timer.tick;
        if (_feedbackRemaining <= Duration.zero) {
          _finishFeedback();
        } else if (_feedback!.showProgress) {
          _feedbackClock.value = 1 - _feedbackRemaining.inMicroseconds / _feedback!.duration.inMicroseconds;
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateClock();
    // Leaving the app cancels reversible reservations before possible termination.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) {
      _queuedFeedback.clear();
      _controller?.undo();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _feedbackTimer?.cancel();
    _feedbackClock.dispose();
    for (final reason in [_focus, _screenReader]) {
      _controller?.pause(reason, false);
    }
    super.dispose();
  }

  String _noun(BuildContext context, DeleteKind kind, int count) => switch (kind) {
        DeleteKind.chapter => revampText(context, en: count == 1 ? 'chapter' : 'chapters', zh: '个章节'),
        DeleteKind.fact => revampText(context, en: count == 1 ? 'fact' : 'facts', zh: '条事实'),
        DeleteKind.contact => revampText(context, en: count == 1 ? 'contact' : 'contacts', zh: '位联系人'),
        DeleteKind.promise => revampText(context, en: count == 1 ? 'to-do' : 'to-dos', zh: '条待办'),
        DeleteKind.recording =>
          revampText(context, en: count == 1 ? 'recording record' : 'recording records', zh: '条录音记录'),
      };

  @override
  Widget build(BuildContext context) {
    final c = context.watch<UndoDeleteController>();
    _controller = c;
    final media = MediaQuery.of(context);
    // Screen reader users get an explicit action instead of a timed target.
    c.pause(_screenReader, media.accessibleNavigation);
    final entries = c.pending;
    final count = entries.length;
    if (count == 0) c.pause(_focus, false);
    final singleKind = count > 0 && entries.every((d) => d.kind == entries.first.kind);
    final noun = singleKind ? _noun(context, entries.first.kind, count) : revampText(context, en: 'items', zh: '项内容');
    _syncClock();
    final message = count == 1
        ? entries.first.title
        : count > 1
            ? revampText(context, en: '$count $noun', zh: '$count $noun')
            : revampText(context,
                en: 'Some deletions failed. Undeleted content has been kept.', // i18n-ignore: Localized by revampText below.
                zh: '部分删除未成功，未删除的内容已保留。');
    Widget deletionToast(double progress) => JxbToast(
          surfaceKey: const ValueKey('undo_delete_toast'), // i18n-ignore: Widget key.
          prefix: count > 0 ? revampText(context, en: 'Deleted: ', zh: '已删除：') : null,
          message: message,
          footer: count > 0 && media.accessibleNavigation
              ? TextButton(
                  style: TextButton.styleFrom(foregroundColor: JXB.brandSecondary),
                  onPressed: c.finish,
                  child: Text(revampText(context, en: 'Confirm deletion', zh: '确认删除')))
              : null,
          progress: count > 0 ? (media.disableAnimations ? 1 : progress) : null,
          action: count > 0
              ? Focus(
                  onFocusChange: (focused) => c.pause(_focus, focused),
                  child: TextButton(
                    key: const ValueKey('undo_delete_action'), // i18n-ignore: Widget key.
                    onPressed: c.undo,
                    style: TextButton.styleFrom(
                      foregroundColor: JXB.brandSecondary,
                      minimumSize: const Size(44, 44),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(
                        fontFamily: JXB.fontSans,
                        fontSize: 14,
                        height: 20 / 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    child: Text(count == 1
                        ? revampText(context, en: 'Undo', zh: '撤销')
                        : revampText(context, en: 'Undo all', zh: '全部撤销')),
                  ),
                )
              : null,
        );
    return Stack(children: [
      widget.child,
      if (!c.modalVisible && (count > 0 || c.failed || (_feedback?.relevant ?? false)))
        Positioned(
          left: 16,
          right: 16,
          // Figma 390×844: both variants start at y=700 with a 34px safe
          // area. The root page also needs room for its navigation pill.
          bottom: math.max(
              media.padding.bottom +
                  (c.rootPageVisible ? 80 : (count > 0 || c.failed || _feedback?.onAction != null ? 62 : 66)),
              media.viewInsets.bottom + 12),
          child: Center(
            child: Semantics(
              liveRegion: true,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (count > 0 || c.failed)
                  ValueListenableBuilder<double>(
                    valueListenable: c.countdown,
                    builder: (_, progress, __) => deletionToast(progress),
                  )
                else
                  AnimatedBuilder(
                    animation: _feedbackClock,
                    builder: (_, __) {
                      final feedback = _feedback!;
                      return JxbToast(
                        message: feedback.message,
                        surfaceKey: const ValueKey('feedback_toast'), // i18n-ignore: Widget key.
                        progress:
                            feedback.showProgress ? (media.disableAnimations ? 1 : 1 - _feedbackClock.value) : null,
                        action: feedback.onAction == null
                            ? null
                            : Focus(
                                onFocusChange: (focused) {
                                  _feedbackFocused = focused;
                                  _syncClock();
                                },
                                child: TextButton(
                                  onPressed: () {
                                    if (_feedback != feedback || !feedback.relevant) return;
                                    _finishFeedback();
                                    feedback.onAction!();
                                  },
                                  style: TextButton.styleFrom(
                                    foregroundColor: JXB.brandSecondary,
                                    minimumSize: const Size(44, 44),
                                    padding: EdgeInsets.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    textStyle: const TextStyle(
                                        fontFamily: JXB.fontSans,
                                        fontSize: 14,
                                        height: 20 / 14,
                                        fontWeight: FontWeight.w500),
                                  ),
                                  child: Text(feedback.actionLabel!),
                                ),
                              ),
                      );
                    },
                  ),
              ]),
            ),
          ),
        ),
    ]);
  }
}

/// Keep the toast out of dialogs and preserve its remaining Undo time.
class UndoDeleteNavigatorObserver extends NavigatorObserver {
  final UndoDeleteController controller;
  final Set<Route<dynamic>> _dialogs = {};
  final List<Route<dynamic>> _pages = [];
  UndoDeleteNavigatorObserver(this.controller);

  void _update() {
    // Navigator notifications occur during route builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.syncNavigation(modal: _dialogs.isNotEmpty, rootPage: _pages.length <= 1);
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is RawDialogRoute) _dialogs.add(route);
    if (route is PageRoute) _pages.add(route);
    _update();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _dialogs.remove(route);
    _pages.remove(route);
    _update();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _dialogs.remove(route);
    _pages.remove(route);
    _update();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _dialogs.remove(oldRoute);
    if (newRoute is RawDialogRoute) _dialogs.add(newRoute);
    final index = oldRoute == null ? -1 : _pages.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute is PageRoute) {
        _pages[index] = newRoute;
      } else {
        _pages.removeAt(index);
      }
    } else if (newRoute is PageRoute) {
      _pages.add(newRoute);
    }
    _update();
  }
}
