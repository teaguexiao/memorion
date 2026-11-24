import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/insight.dart';
import 'package:memorion/pages/today_chapters/first_impression_page.dart';
import 'package:memorion/pages/today_chapters/widgets/share_qr_footer.dart';

/// 洞察卡分享图必须**满幅不透明**。
///
/// 圆角卡片被 RepaintBoundary 截出来时，圆角外那一块没人绘制 → alpha=0，而透明的
/// 观感由对方客户端决定：浅色底合成白角（用户报的就是这个）、深色底合成黑角、被 IM
/// 转成 JPEG 后 alpha 直接丢。所以截图态要去掉圆角。
///
/// ⚠️ 判据只能落在**像素**上。读 `BoxDecoration.borderRadius` 是白盒断言，挡不住
/// 「圆角去了但别处又引入一层透明」——2026-08-13 定位这个问题时就是靠读四角 RGBA 才
/// 发现「已经是透明的」，读代码看不出来。
void main() {
  const card = InsightCard(
    id: 'i1',
    topicKey: 'k',
    headline: '你在周五格外话多',
    body: '最近两周，你的对话有一半集中在周五傍晚。',
    evidence: [InsightEvidence(stat: '周五 80 段 / 周日 6 段', date: '2026-08-01')],
    windowStart: '2026-07-30',
    windowEnd: '2026-08-12',
    companionDays: 42,
  );

  /// 读四角 + 中心的 alpha。
  Future<List<int>> cornerAlphas(WidgetTester tester, RenderRepaintBoundary boundary) async {
    late List<int> alphas;
    // toImage 必须走 runAsync：测试默认的 fake async 时钟不推进真实异步任务。
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3.0);
      final px = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      final w = image.width, h = image.height;
      int alphaAt(int x, int y) => px[(y * w + x) * 4 + 3];
      alphas = [
        alphaAt(0, 0),
        alphaAt(w - 1, 0),
        alphaAt(0, h - 1),
        alphaAt(w - 1, h - 1),
        alphaAt(w ~/ 2, h ~/ 2), // 中心：证明确实截到了卡片，而不是一张空图
      ];
    });
    return alphas;
  }

  testWidgets('截图态四角不透明，页面态仍是圆角', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: FirstImpressionPage(card: card)));
    await tester.pumpAndSettle();

    // 卡片的 RepaintBoundary = 品牌带最近的 RepaintBoundary 祖先。
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.ancestor(of: find.byType(ShareQrFooter), matching: find.byType(RepaintBoundary)).first);

    // ── 页面态：圆角还在，所以四角是透明的（这一半是防「把页面圆角也砍了」的回归）
    final idle = await cornerAlphas(tester, boundary);
    expect(idle.sublist(0, 4), everyElement(0),
        reason: '页面上的卡片应保持圆角 28（圆角外不绘制 → alpha 0）');
    expect(idle[4], 255, reason: '中心必须是实心的，否则说明根本没截到卡片');

    // ── 截图态：点「保存到相册」让 _capturing 置位。
    // 不 await 这个 future：_capturePng 内部的 toImage 在 fake async 下不会自行完成，
    // 我们只需要它把 _capturing 置成 true 并重绘出这一帧。
    final saveLabel = find.text('Save to Photos');
    expect(saveLabel, findsOneWidget);
    await tester.tap(saveLabel);
    await tester.pump(); // setState 生效 + 直角 layout/paint

    final capturing = await cornerAlphas(tester, boundary);
    expect(capturing, everyElement(255),
        reason: '截图态四角必须完全不透明（满幅出图），否则分享出去的图四角会随对方客户端变白或变黑');

    // 顺手出一张真图供人工核对满幅构图（落 build/，不入库）。测试环境没有 PingFang SC，
    // 文字会是 Ahem 方块——只看构图和四角。
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3.0);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      final out = File('build/insight_share_card_capturing.png');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(png);
    });
  });
}
