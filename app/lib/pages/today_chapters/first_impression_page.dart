import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/rendering.dart';
import 'package:gal/gal.dart';
import 'package:memorion/backend/schema/insight.dart';
import 'package:memorion/pages/today_chapters/widgets/jxb_gradient_background.dart';
import 'package:memorion/pages/today_chapters/widgets/open_conversation.dart';
import 'package:memorion/pages/today_chapters/widgets/share_qr_footer.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 洞察卡分享页（沿用 Figma v2.4 node 343:16097「初见卡片」的渐变蓝卡视觉）。
///
/// 全真数据：接收一条 [InsightCard]（来自 `GET /v1/insights` 涌现式洞察引擎），
/// headline 当大标题、evidence 当列表项、companion_days 当「陪伴你 N 天」。
/// 原设计的 MBTI/archetype/命中率是 mock，后端无对应字段，已去掉。
/// 保存到相册 / 分享为真实动作（截卡片 → gal / share_plus）。
class FirstImpressionPage extends StatefulWidget {
  final InsightCard card;

  const FirstImpressionPage({super.key, required this.card});

  @override
  State<FirstImpressionPage> createState() => _FirstImpressionPageState();
}

class _FirstImpressionPageState extends State<FirstImpressionPage> {
  final GlobalKey _cardKey = GlobalKey();

  /// 截图中：此时卡片去掉圆角满幅出图，见 [_card] 与 [_capturePng]。
  bool _capturing = false;

  InsightCard get _insight => widget.card;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: JxbGradientBackground(
            child: SafeArea(
              child: Column(
                children: [
                  _detailBar(context),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 30),
                      children: [
                        RepaintBoundary(key: _cardKey, child: _card(context)),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(child: _btn(revampText(context, en: 'Save to Photos', zh: '保存到相册'), primary: false, onTap: _saveToGallery)),
                            const SizedBox(width: 12),
                            Expanded(child: _btn(revampText(context, en: 'Share', zh: '分享'), primary: true, onTap: _share)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailBar(BuildContext context) {
    return SizedBox(
      height: 68,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _circleBtn(Icons.chevron_left_rounded, () => Navigator.of(context).maybePop()),
            Expanded(
              child: Text(revampText(context, en: 'Insight', zh: '洞察卡'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: JXB.textSecondary)),
            ),
            const SizedBox(width: 42),
          ],
        ),
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 42, height: 42, alignment: Alignment.center,
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.5), shape: BoxShape.circle),
        child: Icon(icon, size: 24, color: JXB.textPrimary),
      ),
    );
  }

  Widget _card(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        // 截图时去掉圆角，让渐变铺满整张图。RepaintBoundary 截的是矩形，圆角外那
        // 一块没人绘制 → alpha=0，而透明的观感由**对方的客户端**决定：浅色底合成
        // 白角、深色底合成黑角，微信转发一次被转成 JPEG 后 alpha 直接丢、多数编码器
        // 按黑底合成。满幅出图就没这回事，IM 展示缩略图时还会自己裁圆角。
        borderRadius: _capturing ? BorderRadius.zero : BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF0D2666), Color(0xFF017AFF)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_insight.companionDays != null)
            Text(
                revampText(context,
                    en: 'With you ${_insight.companionDays} days',
                    zh: '陪伴你 ${_insight.companionDays} 天'),
                style: const TextStyle(
                    fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFFB2D9FF))),
          const SizedBox(height: 32),
          Text('「${_insight.headline}」',
              style: const TextStyle(
                  fontFamily: JXB.fontSans, fontSize: 28, height: 1.3, fontWeight: FontWeight.w600, color: Colors.white)),
          if (_insight.body.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(_insight.body,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.6, color: Color(0xFFD9EBFF))),
          ],
          // 深读段：headline/body 是「我注意到什么」（必须挂得住证据），这一段是
          // 「我从中看到一个什么样的人」（后端刻意放松了证据要求）。所以视觉上要能
          // 分辨——一条细分割线加一行小字标记，让用户知道下面这段是解读而不是记录，
          // 这也是规格 1.4「结论必须带证据」的另一半：解读要坦承是解读。
          if (_insight.depth != null) ...[
            const SizedBox(height: 24),
            Container(height: 1, color: Colors.white.withValues(alpha: 0.18)),
            const SizedBox(height: 16),
            Text(revampText(context, en: 'And what I make of it', zh: '而我是这么看的'),
                style: const TextStyle(
                    fontFamily: JXB.fontSans,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.4,
                    color: Color(0xFF8FC4FF))),
            const SizedBox(height: 10),
            Text(_insight.depth!,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.8, color: Color(0xFFEAF4FF))),
          ],
          // 原话压到解读之后：它是脚注性质的取证材料，夹在正文与解读之间会把这张
          // 卡读断。排版也与正文分开（引用竖线 + 更弱的字色 + 日期单独一行），免得
          // 「他自己说的话」和「我们写的解读」看起来是同一种东西。
          if (_insight.evidence.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(revampText(context, en: 'What I heard', zh: '我听到的'),
                style: const TextStyle(
                    fontFamily: JXB.fontSans,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.4,
                    color: Color(0xFF8FC4FF))),
            const SizedBox(height: 12),
            // 点原话 → P-11 章节详情取证。不加箭头等可点暗示——本卡要截图分享，
            // 视觉保持干净；P-31 证据区有带箭头的同款入口。
            for (final ev in _insight.evidence) ...[
              GestureDetector(
                onTap: ev.canOpen ? () => openConversationById(context, ev.conversationId!) : null,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: Colors.white.withValues(alpha: 0.25), width: 2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ev.displayText,
                          style: const TextStyle(
                              fontFamily: JXB.fontSans, fontSize: 13, height: 1.55, color: Color(0xFFCFE4FF))),
                      if (ev.date != null) ...[
                        const SizedBox(height: 4),
                        Text(ev.date!,
                            style: const TextStyle(
                                fontFamily: JXB.fontSans, fontSize: 11, color: Color(0xFF8FC4FF))),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
          const SizedBox(height: 20),
          if (_insight.windowStart != null && _insight.windowEnd != null)
            Text('${_insight.windowStart} ~ ${_insight.windowEnd}',
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 11, color: Color(0xFFB2D9FF))),
          const SizedBox(height: 14),
          // 品牌带常显（不像章节卡那样只在截图态出现）：这张卡本身就是给人看的
          // 分享物，二维码在页面上也不算噪音，且用户能先自己扫一下确认指向哪儿。
          // 原来那行右下角的 'Memorion' 小字被它取代了。
          const ShareQrFooter(kind: ShareCardKind.insight, onDark: true),
        ],
      ),
    );
  }

  Widget _btn(String label, {required bool primary, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 52, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary ? JXB.brandSecondary : const Color(0xFFF2F3F3),
          borderRadius: BorderRadius.circular(99),
          border: primary ? null : Border.all(color: JXB.border, width: 1),
        ),
        child: Text(label,
            style: TextStyle(fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w500, color: primary ? Colors.white : JXB.textPrimary)),
      ),
    );
  }

  Future<Uint8List?> _capturePng() async {
    setState(() => _capturing = true);
    try {
      // 等两帧：第一帧完成 layout/paint（直角生效），第二帧确保 RepaintBoundary
      // 已有图层。别用 Future.delayed 拍一个毫秒数——那是在赌重绘已经发生。
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _saveToGallery() async {
    final bytes = await _capturePng();
    if (bytes == null || !mounted) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/insight_card_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);
      await Gal.putImage(file.path);
      if (mounted) _toast(revampText(context, en: 'Saved to Photos', zh: '已保存到相册'));
    } catch (_) {
      if (mounted) _toast(revampText(context, en: 'Save failed, please try again', zh: '保存失败，请重试'));
    }
  }

  Future<void> _share() async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : Rect.zero;
    final bytes = await _capturePng();
    if (bytes == null || !mounted) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/insight_card_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(file.path)], text: '「${_insight.headline}」— Memorion', sharePositionOrigin: origin);
    } catch (_) {
      if (mounted) _toast(revampText(context, en: 'Share failed, please try again', zh: '分享失败，请重试'));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    UndoDeleteHost.showMessage(context, msg);
  }
}
