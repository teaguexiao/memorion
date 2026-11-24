import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 日记配图必须走磁盘缓存，且瘦身不能动缓存键。
///
/// 两个坑都**只在 release / 真机上显形**，单测能钉住的最短判据是源码本身：
///
/// 1. **`DiaryCard` 曾用裸 `NetworkImage`**。裸的那个只有 Flutter 进程内的
///    `ImageCache`（内存 LRU，**随进程消失**），冷启动或被系统回收后每张卡都重新
///    走一次 HTTPS。日记列表首屏就有好几张全宽配图——这是「每次打开日记都在转圈」
///    最直接的一份耗时。而详情页早就用了 `DiaryImageCache`，于是出现「点进详情秒开、
///    退回列表反而每次都在转」这种很反直觉的现象。
///
/// 2. **不能用 `CachedNetworkImageProvider` 的 `maxWidth` 做瘦身**。它会把磁盘缓存
///    键改成 `resized_w..._h..._<url>`，于是同一张图在列表卡 / 详情 Hero / 全屏
///    查看器之间**不再互相命中**，还额外落一份重编码 PNG——100 条容量被摊薄。控内存
///    要用 `ResizeImage`（只影响解码尺寸，不动缓存键）。
///
/// Run: cd app && flutter test test/diary_image_cache_test.dart
void main() {
  // ⚠️ 这里不做 `expect(DiaryImageCache.instance, isA<...>())`：碰 `instance` 会真的
  // 构造 CacheManager，而它在构造期就要 path_provider 拿缓存目录 —— 单测没有原生侧，
  // 直接抛 MissingPluginException。所以只能做源码级断言（同 about_page_logo 的取舍）。
  test('瘦身走 ResizeImage，不用会改缓存键的 maxWidth', () {
    final source = _sourceWithoutComments('lib/utils/diary_image_cache.dart');
    expect(source.contains('ResizeImage('), isTrue,
        reason: 'ResizeImage 只影响解码尺寸，磁盘上仍是同一份原图');
    expect(source.contains('maxWidth'), isFalse,
        reason: 'maxWidth 会把缓存键变成 resized_w..._h...，'
            '列表卡/详情/全屏三处从此互不命中，还多落一份重编码 PNG');
    // 独立 cache key 与主 cache 隔离，条数/过期上限仍在。
    expect(source.contains('maxNrOfCacheObjects'), isTrue);
    expect(source.contains('stalePeriod'), isTrue);
  });

  test('DiaryCard 不用裸 NetworkImage，走 DiaryImageCache', () {
    final source = _sourceWithoutComments('lib/pages/today_chapters/widgets/diary_card.dart');

    // CachedNetworkImageProvider 不含 `NetworkImage(` 这个子串（它是
    // `NetworkImageProvider(`），所以直接查裸构造即可。
    expect(source.contains('NetworkImage('), isFalse,
        reason: '裸 NetworkImage 只有进程内缓存，冷启动后每张卡都要重新下载');
    expect(source.contains('DiaryImageCache.providerFor'), isTrue);
    expect(source.contains('decodeWidth'), isTrue,
        reason: '全宽配图按原图解进内存，列表滚动几张就是几十 MB');
  });

  test('详情页 hero 与列表卡同宽解码（命中同一个 ResizeImage 键）', () {
    final source = _sourceWithoutComments('lib/pages/today_chapters/diary_detail_page.dart');
    expect(source.contains('DiaryImageCache.providerFor'), isTrue);
    expect(source.contains('decodeWidth: decodeWidth'), isTrue);
  });

  test('分享时先查磁盘缓存，不无条件重下一次', () {
    final source = _sourceWithoutComments('lib/pages/today_chapters/diary_detail_page.dart');
    expect(source.contains('getFileFromCache'), isTrue,
        reason: 'hero 刚渲染过，这张图必然已在缓存里，重下等于白花一次流量');
  });

  test('登出/删号两条路径都清日记缓存（Provider 内存态 + 磁盘配图）', () {
    final source = _sourceWithoutComments('lib/pages/today_chapters/account_page.dart');

    // 两处调用点：_confirmSignOut 和 _confirmDeleteAccount。少一处就是「换账号后
    // 还能看到上一个人的日记」——而新鲜度判定恰恰会让它不去请求，那份错内容能
    // 挂到过期为止。
    expect(_countOccurrences(source, 'moments.clearCache()'), 2,
        reason: 'clearUserPreferences 只清 shared_preferences，清不到已构造的 Provider');
    expect(_countOccurrences(source, 'DiaryImageCache.clear()'), 2,
        reason: '配图在 cache manager 的独立目录里，shared_preferences 清不到');
  });

  test('页面切到日记 tab 走 ensureLoaded，不再自己判 isInitialized', () {
    final source = _sourceWithoutComments('lib/pages/today_chapters/today_chapters_page.dart');
    expect(source.contains('ensureLoaded()'), isTrue);
    expect(source.contains('mp.loadMoments()'), isFalse,
        reason: 'isInitialized 只在服务端拉取成功后才置 true，'
            '用它做守卫等于每次冷启动都全量请求一次');
  });
}

/// 读源码并剥掉整行注释。
///
/// 注释里为了解释这些坑而写下的 `NetworkImage(` / `loadMoments()` 字面量会把断言
/// 判红（写 about_page_logo 那个测试时真踩过一次）。钉住的应该是实际代码。
int _countOccurrences(String haystack, String needle) => needle.allMatches(haystack).length;

String _sourceWithoutComments(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');
