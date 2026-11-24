import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 日记配图（`moment.summaryImageUrl`）专用磁盘缓存管理器。
///
/// 日记配图是后端每晚 AI 生成的重资源（Gemini 出的 PNG，通常 1024 px 量级），
/// URL 按 `{uid}/{date}_summary.png` 固定。用独立 cache key 与主 cache 隔离，
/// 并限制条数/过期时间，避免长期堆积占满用户存储：
/// - maxNrOfCacheObjects: 100（约 3 个月的每日配图余量）
/// - stalePeriod: 60 天（过期项由 cache manager 自动清理）
///
/// ⚠️ **配图一律走 [providerFor]，不许直接 `NetworkImage(url)`。**
/// `NetworkImage` 只有 Flutter 进程内的 `ImageCache`（内存 LRU，**随进程消失**），
/// 冷启动后每张卡都要重新走一次 HTTPS 下载。日记列表卡曾经就是裸 `NetworkImage`，
/// 而详情页用的是本管理器 —— 于是「点进详情秒开，退回列表反而每次都在转圈」。
/// 这是「每次打开日记 tab 都要加载很久」最直接的那一份耗时。
///
/// ⚠️ **别用 `CachedNetworkImageProvider` 的 `maxWidth`/`maxHeight` 做瘦身。**
/// 那两个参数会把磁盘缓存键改成 `resized_w..._h..._<url>`（见
/// `flutter_cache_manager` 的 `ImageCacheManager.getImageFile`），于是同一张图在
/// 列表卡、详情 Hero、全屏查看器之间**不再互相命中**，还要额外落一份重编码后的
/// PNG——100 条的容量被摊薄成 50 条。要控内存请用 [providerFor] 的 `decodeWidth`，
/// 它走 `ResizeImage`，只影响解码尺寸，不动缓存键。
class DiaryImageCache {
  DiaryImageCache._();

  static const String key = 'diaryImageCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      maxNrOfCacheObjects: 100,
      stalePeriod: const Duration(days: 60),
    ),
  );

  /// 日记配图的唯一 ImageProvider 入口（列表卡 / 详情 Hero / 全屏查看器共用）。
  ///
  /// [decodeWidth] 是目标解码宽度（**物理像素**）。传了就用 `ResizeImage` 在解码期
  /// 缩到这个宽度：磁盘上仍是同一份原图，省下的是位图内存。列表卡传屏宽即可；
  /// 全屏查看器要支持捏合放大，别传。
  static ImageProvider providerFor(String url, {int? decodeWidth}) {
    final ImageProvider provider = CachedNetworkImageProvider(url, cacheManager: instance);
    if (decodeWidth == null) return provider;
    return ResizeImage(provider, width: decodeWidth, policy: ResizeImagePolicy.fit);
  }

  /// 退出登录 / 删除账户时清空磁盘上的配图。
  ///
  /// 配图是用户当天生活的可视化，属于个人内容，不该留在换账号后的设备上。
  /// 文本侧对应的是 `clearUserPreferences()` 里的 `clearCache('moments_list')`——
  /// 那一处只动 shared_preferences，够不到 cache manager 自己的目录。
  static Future<void> clear() => instance.emptyCache();
}
