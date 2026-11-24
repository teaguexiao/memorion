import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// 左滑露出的一个动作按钮（图标 + 底色）。
class SwipeAction {
  final IconData icon;
  final Color iconColor;
  final Color background;

  /// 点了之后做什么。返回后本行会自动收起。
  final Future<void> Function() onTap;

  /// 转圈代替图标（写提醒事项要等原生返回，不给反馈会像点了没反应）。
  final bool busy;

  /// 灰掉不可点（已经加过提醒事项的那条）。
  final bool disabled;

  /// 无障碍与测试用的标签。
  final String semanticLabel;

  const SwipeAction({
    required this.icon,
    required this.iconColor,
    required this.background,
    required this.onTap,
    required this.semanticLabel,
    this.busy = false,
    this.disabled = false,
  });
}

/// 左滑露出尾部动作按钮的行容器（Figma v2.4 node 1130:2509 的删除/提醒双键）。
///
/// **不是 `Dismissible`**：本页要的是「滑开停住、露出两个按钮」，而 Dismissible 是
/// 整条滑走即触发单一动作。两者的手势模型不兼容，所以自己写。
///
/// 打开状态由父级持有（[open] / [onOpenChanged]）而不是自管，为的是**一次只开一行**
/// ——同时敞着好几行时用户没有办法一次收干净，只能一行行滑回去。
class SwipeActionRow extends StatefulWidget {
  final List<SwipeAction> actions;
  final Widget child;

  /// 当前是否处于展开态。父级用行的稳定 key 判断。
  final bool open;

  /// 请求打开（true）/ 收起（false）。父级据此关掉别的行。
  final ValueChanged<bool> onOpenChanged;

  /// 按钮边长（设计稿 36）。
  static const double buttonSize = 36;

  /// 按钮之间的间距（设计稿 16）。
  static const double buttonGap = 12;

  /// 露出区右侧留白。
  static const double trailingPad = 4;

  const SwipeActionRow({
    super.key,
    required this.actions,
    required this.child,
    required this.open,
    required this.onOpenChanged,
  });

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  /// 露出宽度：n 个按钮 + (n-1) 个间距 + 右侧留白。
  double get _maxReveal {
    final n = widget.actions.length;
    if (n == 0) return 0;
    return n * SwipeActionRow.buttonSize + (n - 1) * SwipeActionRow.buttonGap + SwipeActionRow.trailingPad * 2;
  }

  @override
  void initState() {
    super.initState();
    // Even rows with no actions need initialization while the element is
    // active; lazy initialization in dispose() cannot create a ticker safely.
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    if (widget.open) _c.value = 1;
  }

  @override
  void didUpdateWidget(SwipeActionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 按钮数量变了（比如「加入提醒事项」变成已加入）不该让行自己跳位置，
    // 只有 open 变化才动画。
    if (widget.open != oldWidget.open) {
      widget.open ? _c.animateTo(1, curve: Curves.easeOut) : _c.animateTo(0, curve: Curves.easeOut);
    }
    if (widget.actions.isEmpty && _c.value != 0) _c.value = 0;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_maxReveal == 0) return;
    // 往左拖（dx<0）增大露出量。value 是 0~1 的比例。
    final next = (_c.value - d.primaryDelta! / _maxReveal).clamp(0.0, 1.0);
    _c.value = next;
  }

  void _onDragEnd(DragEndDetails d) {
    if (_maxReveal == 0) return;
    // 甩的速度够大就按方向定，否则看有没有过半——只看位置的话轻快一划会弹回去。
    final v = d.primaryVelocity ?? 0;
    final shouldOpen = v < -200 ? true : (v > 200 ? false : _c.value > 0.5);
    if (shouldOpen == widget.open) {
      // 父级状态没变化 ⇒ didUpdateWidget 不会被调，得自己收尾动画。
      shouldOpen ? _c.animateTo(1, curve: Curves.easeOut) : _c.animateTo(0, curve: Curves.easeOut);
      return;
    }
    widget.onOpenChanged(shouldOpen);
  }

  Future<void> _runAction(SwipeAction a) async {
    // 先收起再执行：删除会把本行从列表里摘掉，等动作跑完再收就没有行可收了。
    widget.onOpenChanged(false);
    await a.onTap();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) return widget.child;
    return GestureDetector(
      // 只认横向拖拽，纵向留给外面的 ListView。
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: AnimatedBuilder(
                  animation: _c,
                  // 露出比例小的时候按钮跟着淡入，避免刚碰一下就冒出半个按钮。
                  builder: (_, child) => Opacity(opacity: _c.value.clamp(0.0, 1.0), child: child),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: SwipeActionRow.trailingPad),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < widget.actions.length; i++) ...[
                          if (i != 0) const SizedBox(width: SwipeActionRow.buttonGap),
                          _actionButton(widget.actions[i]),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _c,
              builder: (_, child) => Transform.translate(
                offset: Offset(-_c.value * _maxReveal, 0),
                child: child,
              ),
              child: Stack(
                children: [
                  widget.child,
                  // 展开时整行内容不再响应点击，点一下先收起（iOS 惯例）。
                  // 少了这层，滑开后想收回去只能再横滑一次，而顺手一点会误勾选。
                  if (widget.open)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.onOpenChanged(false),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton(SwipeAction a) {
    final enabled = !a.disabled && !a.busy;
    return Semantics(
      label: a.semanticLabel,
      button: true,
      enabled: enabled,
      child: GestureDetector(
        onTap: enabled ? () => _runAction(a) : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: SwipeActionRow.buttonSize,
          height: SwipeActionRow.buttonSize,
          decoration: BoxDecoration(
            color: a.background,
            borderRadius: BorderRadius.circular(JXB.radiusControl),
          ),
          alignment: Alignment.center,
          child: a.busy
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8, color: a.iconColor),
                )
              : Icon(a.icon, size: 20, color: a.disabled ? a.iconColor.withValues(alpha: 0.4) : a.iconColor),
        ),
      ),
    );
  }
}
