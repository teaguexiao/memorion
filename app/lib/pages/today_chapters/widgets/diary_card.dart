import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/diary_image_cache.dart';

/// 日记卡（记小宝 1.0 浅色改版，Figma v2.4 node 506:727）。
///
/// 210px 高渐变卡：有配图用配图、无图用按索引取的渐变兜底；
/// 底部黑色渐变遮罩 + 日期 + 标题 + 右上角 ↗。
///
/// ⚠️ **配图必须走 [DiaryImageCache]，不许用裸 `NetworkImage`。** 裸的那个只有
/// Flutter 进程内的 `ImageCache`（默认 100 张 / 100MB，且**随进程消失**），冷启动
/// 或被系统回收后每张卡都要重新走一次 HTTPS 下载。日记列表首屏就有好几张全宽
/// 配图，这是「每次打开日记都在转圈」最直接的那一份耗时。
class DiaryCard extends StatelessWidget {
  final String title;
  final String dateLabel; // 「7月10日 · 周五」
  final String? imageUrl;
  final int gradientIndex;
  final VoidCallback onTap;

  const DiaryCard({
    super.key,
    required this.title,
    required this.dateLabel,
    required this.gradientIndex,
    required this.onTap,
    this.imageUrl,
  });

  /// 无配图时的渐变色板（暖橙→紫、蓝→靛…），按日期索引循环。
  static const List<List<Color>> gradients = [
    [Color(0xFFF5C89A), Color(0xFFB8A0D9)], // 暖橙 → 紫
    [Color(0xFFA0C4E8), Color(0xFF7E9BD9)], // 天蓝 → 靛蓝
    [Color(0xFFF3A5B8), Color(0xFFC98BC9)], // 粉 → 藕紫
    [Color(0xFF9FD9C0), Color(0xFF6FB0C9)], // 薄荷 → 青
    [Color(0xFFFFC98A), Color(0xFFE58BA0)], // 橘 → 玫红
  ];

  @override
  Widget build(BuildContext context) {
    final colors = gradients[gradientIndex % gradients.length];
    final url = imageUrl;
    // 列表卡最宽就是屏宽，按设备像素比换算成目标解码宽度：磁盘存的仍是同一份原图
    // （缓存键不变，与详情页互相命中），只把解码后的位图缩到卡片实际需要的尺寸。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (MediaQuery.sizeOf(context).width * dpr).round();
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 210,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
          image: (url != null && url.isNotEmpty)
              ? DecorationImage(
                  image: DiaryImageCache.providerFor(url, decodeWidth: decodeWidth),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: Stack(
          children: [
            // 底部黑渐变遮罩，保证白字可读
            Positioned(
              left: 0, right: 0, bottom: 0,
              height: 120,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xA6000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
            const Positioned(
              top: 16, right: 16,
              child: Text('↗', style: TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: Colors.white)),
            ),
            Positioned(
              left: 20, right: 20, bottom: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(dateLabel,
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xD9FFFFFF))),
                  const SizedBox(height: 6),
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
