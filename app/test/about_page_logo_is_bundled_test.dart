import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 关于页的 logo 必须来自打包资源，不许 `Image.network`。
///
/// 踩过的坑：原来写的是 `Image.network('https://memorion.me/memorion.png')`，
/// 并把「M」占位方块 `_logoFallback()` 同时挂在 `loadingBuilder` 上。于是每次进
/// 关于页都必然先闪一帧占位方块（用户看到的「之前设计的旧 logo」），再等一整个
/// HTTPS 往返（实测 ≈1.7s）才换成真 logo。
///
/// 而远程那张图和仓库里的 `assets/images/memorion_infinity_logo.png` 是**同一个
/// 文件**（sha256 一致，11409 B / 114×65）——联网加载没换来任何东西，纯粹是把一个
/// 固定资源做成了网络依赖（离线还会退化成占位方块）。
///
/// 这里做源码级断言：widget 私有、`Image.network` 在测试里也无法真发请求，能钉住
/// 「不许回退成网络加载」的最短判据就是源码本身。
void main() {
  final raw = File('lib/pages/today_chapters/about_page.dart').readAsStringSync();

  // 断言前先剥掉注释：否则注释里为了解释这个坑而写下的 `Image.network` /
  // `loadingBuilder` 字面量会把测试判红（写这个测试时真踩了一次）。注释该能自由
  // 描述历史问题，钉住的应该是实际代码。
  final source = raw
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  test('关于页不出现 Image.network（logo 是固定资源，必须打包）', () {
    expect(source.contains('Image.network'), isFalse,
        reason: 'logo 走网络会先闪占位图再替换，且首屏要等一次 HTTPS 往返');
  });

  test('关于页不引用远程 logo URL', () {
    expect(source.contains('memorion.me/memorion.png'), isFalse);
  });

  test('关于页用 Image.asset 引用打包内的无限环 logo', () {
    expect(source.contains('Image.asset'), isTrue);
    expect(source.contains('assets/images/memorion_infinity_logo.png'), isTrue);
  });

  test('引用的 asset 文件真实存在（pubspec 已声明整个 assets/images/ 目录）', () {
    expect(File('assets/images/memorion_infinity_logo.png').existsSync(), isTrue);
  });

  test('占位方块不再挂在 loadingBuilder 上（asset 是同步解码的，没有 loading 态）', () {
    expect(source.contains('loadingBuilder'), isFalse,
        reason: '_logoFallback 只该作为 errorBuilder 兜底，不该当成必现的过渡形态');
  });

  test('两个 Semantics identifier 都在——maestro/about_page_logo.yaml 靠它们裁剪比对范围', () {
    // identifier → iOS accessibilityIdentifier → Maestro 的 `id:`，是 assertScreenshot
    // cropOn 的锚点。少了它，截图只能全屏比对：logo 只占屏幕 1.8%，把它整块涂掉
    // 都过不了 3% 容差（实测涂红 320×180 仍全绿），flow 就静默失去判别力。
    expect(source.contains("identifier: 'about-logo-asset'"), isTrue);
    expect(source.contains("identifier: 'about-logo-fallback'"), isTrue);
  });
}
