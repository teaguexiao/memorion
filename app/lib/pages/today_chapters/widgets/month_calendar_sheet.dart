import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// P-01 首页日期筛选 · 月历选择弹窗（Figma node 1000:4664 / 1006:5194）。
///
/// 底部弹出「选择日期」卡片：当月网格（周一起始）+ 有内容日期的活跃度蓝点 +
/// 选中态实心圆；左上角月份可点开「年+月双列滚轮」切月；右上角 ◀▶ 翻月。
///
/// 纯展示组件：本身不碰 Provider。调用方把「按天会话数」`countByDay`（数据源见
/// [ConversationProvider.conversationCountByDay]，不受日期筛选影响）与当前
/// `selectedDate` 传进来，用户点某天即 `Navigator.pop(该天)`；未选择返回 null。
Future<DateTime?> showMonthCalendarSheet(
  BuildContext context, {
  required Map<DateTime, int> countByDay,
  DateTime? selectedDate,
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: JXB.scrim,
    builder: (_) => _MonthCalendarSheet(
      countByDay: countByDay,
      selectedDate: selectedDate,
    ),
  );
}

/// 活跃度分档（用户 2026-07-30 拍板：按当天会话数）。
/// 0 → 无点；1-2 → 浅蓝；3-4 → 中蓝；5+ → 深蓝。返回 null 表示不画点。
Color? _activityDotColor(int count) {
  if (count <= 0) return null;
  if (count <= 2) return const Color(0xFFAFD3FF); // 浅蓝
  if (count <= 4) return const Color(0xFF4A9BFF); // 中蓝
  return JXB.brandPrimary; // 深蓝 5+
}

class _MonthCalendarSheet extends StatefulWidget {
  final Map<DateTime, int> countByDay;
  final DateTime? selectedDate;
  const _MonthCalendarSheet({required this.countByDay, this.selectedDate});

  @override
  State<_MonthCalendarSheet> createState() => _MonthCalendarSheetState();
}

class _MonthCalendarSheetState extends State<_MonthCalendarSheet> {
  /// 当前展示的月份（归一到当月 1 号）。
  late DateTime _visibleMonth;

  /// 已选中的那一天（可空）。
  DateTime? _selected;

  /// 是否处于「年+月滚轮」选月模式。
  bool _pickingMonth = false;

  /// 可选年份范围：最早两年前，最晚当年（不选未来）。
  late final int _minYear;
  late final int _maxYear;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final base = widget.selectedDate ?? now;
    _visibleMonth = DateTime(base.year, base.month);
    _selected = widget.selectedDate;
    _minYear = now.year - 2;
    _maxYear = now.year;
  }

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// 当月是否已到「本月」上限（不允许再往后翻到未来月）。
  bool get _atMaxMonth {
    final now = DateTime.now();
    return _visibleMonth.year == now.year && _visibleMonth.month == now.month;
  }

  bool get _atMinMonth =>
      _visibleMonth.year == _minYear && _visibleMonth.month == 1;

  void _shiftMonth(int delta) {
    final next = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
    // 夹在允许范围内。
    final now = DateTime.now();
    if (next.isAfter(DateTime(now.year, now.month))) return;
    if (next.isBefore(DateTime(_minYear, 1))) return;
    setState(() => _visibleMonth = next);
  }

  @override
  Widget build(BuildContext context) {
    final zh = isRevampChinese(context);
    return Container(
      decoration: const BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: JXB.space6,
        right: JXB.space6,
        top: JXB.space3,
        bottom: MediaQuery.of(context).padding.bottom + JXB.space6,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部拖动条
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: JXB.border,
              borderRadius: BorderRadius.circular(JXB.radiusFull),
            ),
          ),
          const SizedBox(height: JXB.space4),
          Text(
            revampText(context, en: 'Select date', zh: '选择日期'),
            style: JXB.sectionTitle.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: JXB.space4),
          _MonthHeader(
            month: _visibleMonth,
            picking: _pickingMonth,
            canPrev: !_atMinMonth,
            canNext: !_atMaxMonth,
            onTogglePick: () => setState(() => _pickingMonth = !_pickingMonth),
            onPrev: () => _shiftMonth(-1),
            onNext: () => _shiftMonth(1),
          ),
          const SizedBox(height: JXB.space4),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _pickingMonth ? _buildMonthWheel(zh) : _buildGrid(context, zh),
          ),
        ],
      ),
    );
  }

  // ── 年+月双列滚轮（Figma 1006:5194）───────────────────────────────
  Widget _buildMonthWheel(bool zh) {
    final years = [for (var y = _minYear; y <= _maxYear; y++) y];
    final yearIndex = years.indexOf(_visibleMonth.year).clamp(0, years.length - 1);
    final monthIndex = (_visibleMonth.month - 1).clamp(0, 11);
    return SizedBox(
      height: 216,
      child: Row(
        children: [
          Expanded(
            child: _WheelColumn(
              itemCount: years.length,
              initialItem: yearIndex,
              labelBuilder: (i) => zh ? '${years[i]}年' : '${years[i]}',
              onSelected: (i) => _onWheelChanged(year: years[i]),
            ),
          ),
          Expanded(
            child: _WheelColumn(
              itemCount: 12,
              initialItem: monthIndex,
              labelBuilder: (i) => zh ? '${i + 1}月' : _monthNameEn(i + 1),
              onSelected: (i) => _onWheelChanged(month: i + 1),
            ),
          ),
        ],
      ),
    );
  }

  void _onWheelChanged({int? year, int? month}) {
    var y = year ?? _visibleMonth.year;
    var m = month ?? _visibleMonth.month;
    // 不允许选到未来月：夹到当月。
    final now = DateTime.now();
    var next = DateTime(y, m);
    if (next.isAfter(DateTime(now.year, now.month))) {
      next = DateTime(now.year, now.month);
    }
    if (next.isBefore(DateTime(_minYear, 1))) {
      next = DateTime(_minYear, 1);
    }
    setState(() => _visibleMonth = next);
  }

  // ── 当月日期网格（Figma 1000:4664）──────────────────────────────
  Widget _buildGrid(BuildContext context, bool zh) {
    final weekdays = zh
        ? const ['一', '二', '三', '四', '五', '六', '日']
        : const ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final firstOfMonth = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    // 周一起始：Dart weekday 周一=1…周日=7，前置空格数 = weekday-1。
    final leadingBlanks = firstOfMonth.weekday - 1;
    final daysInMonth =
        DateTime(_visibleMonth.year, _visibleMonth.month + 1, 0).day;
    final totalCells = leadingBlanks + daysInMonth;
    final rows = (totalCells / 7.0).ceil();

    return Column(
      children: [
        // 星期表头
        Row(
          children: [
            for (final w in weekdays)
              Expanded(
                child: Center(
                  child: Text(w,
                      style: JXB.caption.copyWith(color: JXB.textSecondary)),
                ),
              ),
          ],
        ),
        const SizedBox(height: JXB.space2),
        for (var r = 0; r < rows; r++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                for (var c = 0; c < 7; c++)
                  Expanded(child: _cellAt(r * 7 + c - leadingBlanks + 1)),
              ],
            ),
          ),
        const SizedBox(height: JXB.space4),
        _Legend(zh: zh),
      ],
    );
  }

  /// 渲染第 `day` 天的格子；`day` 越界（本月之外）时画斜纹灰占位。
  Widget _cellAt(int day) {
    final daysInMonth =
        DateTime(_visibleMonth.year, _visibleMonth.month + 1, 0).day;
    if (day < 1 || day > daysInMonth) {
      return const _DayCell.blank();
    }
    final date = DateTime(_visibleMonth.year, _visibleMonth.month, day);
    final isFuture = date.isAfter(_today);
    final count = widget.countByDay[date] ?? 0;
    final isSelected = _selected != null &&
        _selected!.year == date.year &&
        _selected!.month == date.month &&
        _selected!.day == date.day;
    final isToday = date == _today;
    return _DayCell(
      day: day,
      dotColor: isFuture ? null : _activityDotColor(count),
      selected: isSelected,
      isToday: isToday,
      disabled: isFuture,
      onTap: isFuture ? null : () => Navigator.of(context).pop(date),
    );
  }

  String _monthNameEn(int m) {
    const names = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' //
    ];
    return names[(m - 1).clamp(0, 11)];
  }
}

/// 月份标题行：左「YYYY年M月 ▶」（点开滚轮），右「◀ ▶」翻月。
class _MonthHeader extends StatelessWidget {
  final DateTime month;
  final bool picking;
  final bool canPrev;
  final bool canNext;
  final VoidCallback onTogglePick;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  const _MonthHeader({
    required this.month,
    required this.picking,
    required this.canPrev,
    required this.canNext,
    required this.onTogglePick,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final zh = isRevampChinese(context);
    final label = zh ? '${month.year}年${month.month}月' : _enLabel(month);
    return Row(
      children: [
        GestureDetector(
          onTap: onTogglePick,
          behavior: HitTestBehavior.opaque,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: JXB.sectionTitle.copyWith(
                      color: JXB.brandPrimary, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              Icon(
                picking
                    ? Icons.arrow_drop_down_rounded
                    : Icons.play_arrow_rounded,
                size: picking ? 24 : 16,
                color: JXB.brandPrimary,
              ),
            ],
          ),
        ),
        const Spacer(),
        // 选月滚轮模式下隐藏翻月箭头（避免两套操作冲突）。
        if (!picking) ...[
          _ArrowButton(icon: Icons.chevron_left_rounded, enabled: canPrev, onTap: onPrev),
          const SizedBox(width: JXB.space2),
          _ArrowButton(icon: Icons.chevron_right_rounded, enabled: canNext, onTap: onNext),
        ],
      ],
    );
  }

  String _enLabel(DateTime m) {
    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December' //
    ];
    return '${names[m.month - 1]} ${m.year}';
  }
}

class _ArrowButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  const _ArrowButton({required this.icon, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Icon(icon,
          size: 26,
          color: enabled ? JXB.textSecondary : JXB.textPlaceholder.withValues(alpha: 0.4)),
    );
  }
}

/// 单个日期格子（40×40 圆）。空格子画斜纹灰。
class _DayCell extends StatelessWidget {
  final int? day;
  final Color? dotColor;
  final bool selected;
  final bool isToday;
  final bool disabled;
  final VoidCallback? onTap;

  const _DayCell({
    required this.day,
    this.dotColor,
    this.selected = false,
    this.isToday = false,
    this.disabled = false,
    this.onTap,
  });

  const _DayCell.blank()
      : day = null,
        dotColor = null,
        selected = false,
        isToday = false,
        disabled = true,
        onTap = null;

  @override
  Widget build(BuildContext context) {
    // 本月之外 / 未来：斜纹灰占位。
    if (day == null || disabled) {
      return AspectRatio(
        aspectRatio: 1,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFF0F0F3),
              borderRadius: BorderRadius.circular(JXB.radiusFull),
            ),
            child: day == null
                ? CustomPaint(painter: _HatchPainter())
                : Center(
                    child: Text('$day',
                        style: JXB.metaButton.copyWith(
                            fontFamily: JXB.fontNumber,
                            color: JXB.textPlaceholder.withValues(alpha: 0.5))),
                  ),
          ),
        ),
      );
    }

    final Color bg = selected ? JXB.brandPrimary : const Color(0xFFF0F0F3);
    final Color fg = selected ? Colors.white : JXB.textPrimary;

    return AspectRatio(
      aspectRatio: 1,
      child: Center(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: isToday && !selected
                  ? Border.all(color: JXB.brandPrimary, width: 1.5)
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text('$day',
                    style: JXB.metaButton.copyWith(
                        fontFamily: JXB.fontNumber,
                        color: fg,
                        fontWeight: FontWeight.w500)),
                if (dotColor != null && !selected)
                  Positioned(
                    bottom: 5,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 斜纹填充（本月之外的空格子）。
class _HatchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE2E2E8)
      ..strokeWidth = 1.2;
    const gap = 6.0;
    for (double x = -size.height; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 底部图例：「活跃值 低 ● ● ● 高」。
class _Legend extends StatelessWidget {
  final bool zh;
  const _Legend({required this.zh});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(zh ? '高光记录活跃值' : 'Activity',
            style: JXB.caption.copyWith(color: JXB.textSecondary)),
        const Spacer(),
        Text(zh ? '低' : 'Low', style: JXB.caption.copyWith(color: JXB.textSecondary)),
        const SizedBox(width: 6),
        for (final c in const [
          Color(0xFFAFD3FF),
          Color(0xFF4A9BFF),
          JXB.brandPrimary,
        ]) ...[
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
        ],
        const SizedBox(width: 2),
        Text(zh ? '高' : 'High', style: JXB.caption.copyWith(color: JXB.textSecondary)),
      ],
    );
  }
}

/// 单列滚轮（Cupertino 风）。
class _WheelColumn extends StatelessWidget {
  final int itemCount;
  final int initialItem;
  final String Function(int) labelBuilder;
  final ValueChanged<int> onSelected;
  const _WheelColumn({
    required this.itemCount,
    required this.initialItem,
    required this.labelBuilder,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoPicker(
      scrollController: FixedExtentScrollController(initialItem: initialItem),
      itemExtent: 40,
      diameterRatio: 1.2,
      selectionOverlay: const CupertinoPickerDefaultSelectionOverlay(
        background: Color(0x14000000),
      ),
      onSelectedItemChanged: onSelected,
      children: [
        for (var i = 0; i < itemCount; i++)
          Center(
            child: Text(labelBuilder(i),
                style: JXB.body.copyWith(fontWeight: FontWeight.w500)),
          ),
      ],
    );
  }
}
