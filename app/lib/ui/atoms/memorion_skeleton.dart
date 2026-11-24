import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import 'package:memorion/theme/jxb_tokens.dart';

/// 骨架屏（skeleton）占位组件族。
///
/// 加载中不再转圈，而是先把真实内容的版式用灰块占出来，加载完再换成真内容 —— 页面
/// 不跳动，等待也有形状。所有骨架块共用一层流光（shimmer），亮度扫过表示「在动」。
///
/// 用法：把若干 [SkeletonBox] / [SkeletonLine] 塞进 [MemorionSkeleton]，
/// 或直接用下面的预设（[MemorionSkeletonRows]、[MemorionSkeletonCards]）。
///
/// ⚠️ [MemorionSkeleton] 底层是 ShaderMask + srcATop，会把 child **所有**非透明
/// 像素涂成流光渐变。所以它里面只能放骨架灰块和透明间隙 —— 白底卡片、边框、
/// 分隔线必须放在它外面，否则整块会糊成一片灰（真机验证踩过）。
class MemorionSkeleton extends StatelessWidget {
  final Widget child;

  /// false 时直接返回 child，不套流光（便于按条件启停）。
  final bool enabled;

  const MemorionSkeleton({super.key, required this.child, this.enabled = true});

  /// 骨架块底色 —— 比 border 略深，浅色背景上刚好看得出是占位。
  static const Color base = Color(0xFFE9E9EF);

  /// 流光扫过时的高亮色。
  static const Color highlight = Color(0xFFF6F6FA);

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Shimmer.fromColors(
      baseColor: base,
      highlightColor: highlight,
      period: const Duration(milliseconds: 1400),
      child: child,
    );
  }
}

/// 单个矩形骨架块，用来占卡片、头像、缩略图的位置。
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.radius = JXB.radiusSmall,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: MemorionSkeleton.base,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 一行文字的骨架块。[widthFactor] 是占父级宽度的比例，用来模拟长短不一的句子。
class SkeletonLine extends StatelessWidget {
  final double widthFactor;
  final double height;

  const SkeletonLine({super.key, this.widthFactor = 1, this.height = 12});

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor.clamp(0.0, 1.0),
      child: SkeletonBox(height: height, radius: height / 2),
    );
  }
}

/// 圆形骨架块（头像位）。
class SkeletonCircle extends StatelessWidget {
  final double size;

  const SkeletonCircle({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return SkeletonBox(width: size, height: size, radius: size / 2);
  }
}

/// 列表行骨架：白底卡片 + N 行分隔线，对应「一张卡里若干行」的版式
/// （词库、人物、语音样本等页面都是这个形状）。
class MemorionSkeletonRows extends StatelessWidget {
  final int count;
  final double rowHeight;

  /// 每行右侧是否留一个小方块（对应删除/箭头等尾部控件）。
  final bool trailing;

  /// 每行左侧圆形头像的直径；null 表示不占头像位。
  final double? leadingCircle;

  /// true 时每行占两行文字（标题 + 副标题）。
  final bool twoLine;
  final EdgeInsetsGeometry padding;

  const MemorionSkeletonRows({
    super.key,
    this.count = 6,
    this.rowHeight = 56,
    this.trailing = true,
    this.leadingCircle,
    this.twoLine = false,
    this.padding = const EdgeInsets.fromLTRB(18, 0, 18, 100),
  });

  @override
  Widget build(BuildContext context) {
    // 行宽在 0.4~0.75 之间循环，避免所有行一样长显得死板。
    const widths = [0.62, 0.45, 0.72, 0.5, 0.68, 0.42];
    // 白底卡壳留在 Shimmer 外面 —— 流光只能扫灰块，否则整卡糊成一片灰。
    // 外层 ListView：卡只包住内容高度（不被 Expanded 拉满屏），且行数超一屏时可滚动。
    return ListView(
      padding: padding,
      children: [
        Container(
          decoration: BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.circular(JXB.radiusCard),
            border: Border.all(color: JXB.border, width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < count; i++) ...[
                if (i != 0) const Divider(height: 1, color: JXB.border),
                SizedBox(
                  height: rowHeight,
                  child: MemorionSkeleton(
                    child: Row(
                      children: [
                        if (leadingCircle != null) ...[
                          SkeletonCircle(size: leadingCircle!),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: twoLine
                              ? Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SkeletonLine(widthFactor: widths[i % widths.length], height: 14),
                                    const SizedBox(height: 7),
                                    SkeletonLine(widthFactor: widths[(i + 3) % widths.length] * 0.6, height: 11),
                                  ],
                                )
                              : SkeletonLine(widthFactor: widths[i % widths.length], height: 14),
                        ),
                        if (trailing) ...[
                          const SizedBox(width: 8),
                          const SkeletonBox(width: 20, height: 20, radius: 6),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 卡片列表骨架：N 个独立圆角块，对应「一屏若干张气泡卡」的版式
/// （首页时间线、答应过的事、事实列表等）。
class MemorionSkeletonCards extends StatelessWidget {
  final int count;
  final double cardHeight;
  final double radius;
  final double gap;

  /// 顶部是否先占一条小标题。
  final bool withHeader;
  final EdgeInsetsGeometry padding;

  const MemorionSkeletonCards({
    super.key,
    this.count = 4,
    this.cardHeight = 112,
    this.radius = JXB.radiusBubble,
    this.gap = 14,
    this.withHeader = false,
    this.padding = const EdgeInsets.fromLTRB(20, 10, 20, 30),
  });

  @override
  Widget build(BuildContext context) {
    // 这里整屏都是灰块（没有白底卡壳），可以整体套一层 Shimmer，流光连贯扫过。
    // 用 ListView 而非 Column：卡片超一屏时能滚，且不被父级 Expanded 拉伸。
    return MemorionSkeleton(
      child: ListView(
        padding: padding,
        children: [
          if (withHeader) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: SkeletonBox(width: 120, height: 16, radius: 8),
            ),
            SizedBox(height: gap),
          ],
          for (int i = 0; i < count; i++) ...[
            if (i != 0) SizedBox(height: gap),
            SkeletonBox(height: cardHeight, radius: radius),
          ],
        ],
      ),
    );
  }

  /// sliver 版：给 CustomScrollView 用（首页时间线）。不能直接把 ListView 塞进
  /// SliverToBoxAdapter —— 那会嵌套两层滚动且高度无界。
  Widget asSliver() {
    return SliverPadding(
      padding: padding,
      sliver: SliverToBoxAdapter(
        child: MemorionSkeleton(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (withHeader) ...[
                const SkeletonBox(width: 120, height: 16, radius: 8),
                SizedBox(height: gap),
              ],
              for (int i = 0; i < count; i++) ...[
                if (i != 0) SizedBox(height: gap),
                SkeletonBox(height: cardHeight, radius: radius),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 单张卡片内部的骨架（几行文字），用于「关于我」里那些固定高度的小卡。
class MemorionSkeletonTextCard extends StatelessWidget {
  final int lines;
  final double radius;
  final EdgeInsetsGeometry padding;

  const MemorionSkeletonTextCard({
    super.key,
    this.lines = 2,
    this.radius = 28,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
  });

  @override
  Widget build(BuildContext context) {
    const widths = [0.9, 0.65, 0.78, 0.5];
    // 同 MemorionSkeletonRows：白底卡壳在 Shimmer 外，流光只扫里面的文字灰条。
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: MemorionSkeleton(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < lines; i++) ...[
              if (i != 0) const SizedBox(height: 10),
              SkeletonLine(widthFactor: widths[i % widths.length], height: 13),
            ],
          ],
        ),
      ),
    );
  }
}
