import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/pages/today_chapters/diary_detail_page.dart';

import 'helpers/source_stripper.dart';

/// 日记的两条不变式：**分享出去的图不许裁掉配图**，**全屏看图能存能分享**。
///
/// ## 为什么高度必须按比例算
///
/// 配图是 1:1 方图（后端 `utils/llm/image_generation.py` 的 prompt 明写 square 1:1），
/// 而分享卡宽 360。hero 曾钉死 `height: 200` + `BoxFit.cover` ⇒ 图被缩到 360×360 再
/// 垂直居中裁剪，**上下各裁掉 80px（22%）**。用户报的「分享的时候图片显示不全，顶部
/// 被截掉一部分」就是这 22%。详情页的 hero 同样裁切，但那儿点一下能看全图；分享物
/// 到了对方手里没有这个退路，所以只有分享卡必须按真实比例给高。
///
/// ## 为什么只能做源码级接线断言
///
/// 碰 `DiaryImageCache.instance` 会真构造 CacheManager，它在构造期就要 path_provider
/// 拿目录 —— 单测没有原生侧，直接抛 MissingPluginException（`diary_image_cache_test`
/// 里记的是同一个取舍）。于是「pump 详情页 → 点 hero → 找按钮」这条路走不通，能钉住
/// 的最短判据是纯函数 + 调用点存在。所以扫源码前必须**剥掉注释**：这份文件的注释里
/// 就写着 `height: 200`、`Gal.putImage` 这些字面量，不剥的话删掉真代码照样绿。
///
/// Run: cd app && flutter test test/diary_share_hero_and_image_actions_test.dart
void main() {
  final source = stripCommentsAndStrings(
    File('lib/pages/today_chapters/diary_detail_page.dart').readAsStringSync(),
  );

  group('分享卡 hero 高度', () {
    test('方图整幅显示，不被裁', () {
      // 判据是「高度 ≥ 按比例铺满卡宽所需的高度」——只有这样 cover 才无处可裁。
      expect(diaryShareHeroHeight(360, 1.0), 360);
      expect(diaryShareHeroHeight(360, 1.0), isNot(200),
          reason: '钉死 200 就是上下各裁 22%，这正是用户报的「顶部被截掉」');
    });

    test('4:3 横图也整幅显示', () {
      expect(diaryShareHeroHeight(360, 4 / 3), closeTo(270, 0.01));
    });

    test('比例取不到时退回固定高度，而不是 0 或 NaN', () {
      expect(diaryShareHeroHeight(360, null), 200);
      expect(diaryShareHeroHeight(360, 0), 200, reason: '除零会算出 Infinity');
      expect(diaryShareHeroHeight(360, -1), 200);
    });

    test('极端比例被 clamp 住，不把分享卡拉成长条或压扁标题', () {
      // 超宽 4:1 → 90px，底部两行日期/标题会挤爆，抬到下限 180。
      expect(diaryShareHeroHeight(360, 4), 180);
      // 超高 1:2 → 720px，卡片会变成长条，压到上限 420。
      expect(diaryShareHeroHeight(360, 0.5), 420);
    });
  });

  group('接线', () {
    test('截图前真的解了一次配图比例', () {
      final body = functionBody(source, '_captureShareCard');
      expect(body, isNotNull, reason: '找不到 _captureShareCard，改名了就把断言范围一起更新');
      expect(body!.contains('_resolveImageAspectRatio('), isTrue,
          reason: '不解比例的话 imageAspectRatio 恒为 null，'
              'diaryShareHeroHeight 写得再对也只会返回那个固定高度');
      // 顺序也要对：必须先 precache（拿到已解码的那份）再问比例，否则问到的是空。
      expect(body.indexOf('precacheImage'), lessThan(body.indexOf('_resolveImageAspectRatio(')));
    });

    test('分享卡的 hero 用算出来的高度', () {
      final body = _classBody(source, '_DiaryShareCard');
      expect(body, isNotNull);
      expect(body!.contains('diaryShareHeroHeight('), isTrue);
      expect(body.contains('height: heroHeight'), isTrue);
      expect(body.contains('height: 200'), isFalse, reason: 'hero 高度不许再钉死');
    });

    test('全屏查看器能存相册、能分享', () {
      // ⚠️ 名字必须带 `()`。`functionBody` 判「声明」的依据是参数列表 `)` 后面紧跟
      // `{`/`async`/`=>`，而 `onTap: _shareImage,` 这个调用点后面正好排着
      // `Widget _action({...}) {` —— 光名字会从调用点起配平，截出 `_action` 的函数体
      // （断言于是查不到 shareXFiles，代码却是对的）。带括号就只匹配声明。
      final save = functionBody(source, '_saveToGallery()');
      expect(save, isNotNull, reason: '全屏查看器缺保存动作');
      expect(save!.contains('Gal.putImage('), isTrue);

      final share = functionBody(source, '_shareImage()');
      expect(share, isNotNull, reason: '全屏查看器缺分享动作');
      expect(share!.contains('Share.shareXFiles('), isTrue);
      expect(share.contains('sharePositionOrigin'), isTrue,
          reason: 'iOS/iPad 缺锚点会静默不弹分享面板');
    });

    test('交给系统的文件另存一份带扩展名的，不直接用缓存文件', () {
      final body = functionBody(source, '_resolveDiaryImageFile');
      expect(body, isNotNull);
      expect(body!.contains('_imageExtension('), isTrue,
          reason: 'cache manager 落盘的文件名不保证带扩展名，而 Gal 按扩展名分图片/视频通道，'
              '不对时只是静默不出图');
      expect(body.contains('getFileFromCache'), isTrue,
          reason: 'hero 刚渲染过，这张图必然已在缓存里，重下等于白花一次流量');
    });
  });
}

/// 从（已剥注释的）源码里按大括号配平截出某个类的类体。找不到返回 null。
///
/// 不能用 [functionBody]：类声明后面没有参数列表。
String? _classBody(String src, String name) {
  final idx = src.indexOf('class $name');
  if (idx < 0) return null;
  final open = src.indexOf('{', idx);
  if (open < 0) return null;
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(open, i + 1);
    }
  }
  return null;
}
