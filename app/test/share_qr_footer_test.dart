import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/pages/today_chapters/widgets/share_qr_footer.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 二维码印进图片后就改不动了（见 [memorionShareUrl] 的注释），所以链接形态本身
/// 值得钉住：域名写错、utm_content 撞车都会在发出去之后才发现。
void main() {
  test('分享链接指向官网，且按卡片类型区分 utm_content', () {
    expect(memorionShareUrl(ShareCardKind.chapter),
        'https://www.memorion.me/?utm_source=share_image&utm_content=chapter');
    expect(memorionShareUrl(ShareCardKind.transcript, medium: 'text'),
        'https://www.memorion.me/?utm_source=share_text&utm_content=transcript');

    // 每种卡片的 utm_content 必须互不相同，否则官网侧分不清流量来源。
    final contents = ShareCardKind.values.map((k) => k.utmContent).toSet();
    expect(contents.length, ShareCardKind.values.length);
  });

  testWidgets('品牌带渲染出二维码，编码的正是带归因的官网链接', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 320, child: ShareQrFooter(kind: ShareCardKind.insight, onDark: true)),
        ),
      ),
    ));

    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    // 白底黑码：反相二维码有相当一部分扫码器不认。深色卡上也必须保持白底。
    expect(qr.backgroundColor, Colors.white);
    // 纠错级别不能退回包默认的 L —— 被 IM 压缩过的截图撑不住 7% 的冗余。
    expect(qr.errorCorrectionLevel, QrErrorCorrectLevel.M);
  });

  /// 出真图供人工核对：二维码是否完整、静默区是否被压、能否扫得动。
  /// 产物落在 build/share_qr_footer_preview{,_dark}.png（不入库）。
  ///
  /// 想验证码里到底编了什么，跑：
  /// ```
  /// python3 -c "import cv2; print(cv2.QRCodeDetector().detectAndDecode(
  ///   cv2.imread('build/share_qr_footer_preview.png'))[0])"
  /// ```
  /// 注意测试环境没有 PingFang SC，图里的文字会是 Ahem 方块 —— 只看二维码。
  for (final (name, onDark, bg) in [
    ('preview', false, Colors.white),
    ('preview_dark', true, const Color(0xFF0D2666)),
  ]) {
    testWidgets('导出品牌带预览图 · $name', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: bg,
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: Container(
                width: 360,
                color: bg,
                padding: const EdgeInsets.all(16),
                child: ShareQrFooter(kind: ShareCardKind.chapter, onDark: onDark),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 品牌带必须 shrink-wrap：撑满高度会在分享图里留一大片空白（踩过）。
      // 360 宽 + 16 padding 下实测约 120pt 高，留足余量到 200 只为挡住「撑满屏幕」。
      final size = tester.getSize(find.byKey(key));
      expect(size.width, 360);
      expect(size.height, lessThan(200));

      final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      // toImage / 文件 IO 必须走 runAsync：测试默认的 fake async 时钟不推进真实
      // 异步任务，直接 await 会挂到测试超时（踩过一次，10 分钟才报出来）。
      final out = File('build/share_qr_footer_$name.png');
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 3.0);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        await out.parent.create(recursive: true);
        await out.writeAsBytes(bytes);
      });
      expect(out.lengthSync(), greaterThan(0));
    });
  }
}
