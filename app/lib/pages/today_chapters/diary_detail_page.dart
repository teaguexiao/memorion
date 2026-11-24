import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/rendering.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/pages/today_chapters/widgets/diary_card.dart';
import 'package:memorion/pages/today_chapters/widgets/share_qr_footer.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/diary_document.dart';
import 'package:memorion/utils/diary_image_cache.dart';
import 'package:memorion/utils/moment_parser.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// P-41 日记详情·每日一刻（记小宝 1.0 浅色改版，Figma v2.4 node 0:3857）。
///
/// 数据来自传入的 [ServerMessage]（type=day_summary），无额外网络请求。
/// 正文由 [DiaryDocument] 解析成块、[_DiaryBody] 排版；页面、分享卡、分享纯文本
/// 三处读的是同一份解析结果，所以段落 / 引语 / 加粗不会在分享时丢掉。
class DiaryDetailPage extends StatefulWidget {
  final ServerMessage moment;
  final int gradientIndex;

  const DiaryDetailPage({super.key, required this.moment, required this.gradientIndex});

  @override
  State<DiaryDetailPage> createState() => _DiaryDetailPageState();
}

class _DiaryDetailPageState extends State<DiaryDetailPage> {
  static const List<List<Color>> _gradients = DiaryCard.gradients;

  /// 分享卡的截图锚点。卡片只在分享期间挂载（[_mountShareCard]），平时不挂——
  /// 常驻会让同一张配图多一份解码。
  final GlobalKey _shareCardKey = GlobalKey();
  bool _mountShareCard = false;

  /// 配图的真实宽高比，截图前解出来（见 [_captureShareCard]）。分享卡的 hero
  /// 靠它定高——null 时退回固定高度。
  double? _shareImageAspect;

  ServerMessage get moment => widget.moment;

  int get gradientIndex => widget.gradientIndex;

  /// 情绪化标题优先（后端 day_summary 生成），缺失时回退 MomentParser 解析标题。
  String _resolveTitle() {
    final emotionTitle = moment.emotionTitle?.trim();
    if (emotionTitle != null && emotionTitle.isNotEmpty) return emotionTitle;
    return MomentParser.parse(moment.text, date: moment.createdAt).title;
  }

  @override
  Widget build(BuildContext context) {
    final title = _resolveTitle();
    final document = DiaryDocument.parse(moment.text);
    final colors = _gradients[gradientIndex % _gradients.length];
    final dateFull = _fmtFullDate(context, moment.createdAt);
    final dateShort = _fmtShortDate(context, moment.createdAt);
    // hero 与列表卡的解码宽度一致（都是屏宽），于是从列表点进来命中的是同一个
    // ResizeImage 键，连解码都省了。磁盘那份始终是原图，跟全屏查看器也共用。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (MediaQuery.sizeOf(context).width * dpr).round();

    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: JXB.bgApp,
          body: Stack(
            children: [
              SafeArea(
                child: Column(
                  children: [
                    _detailBar(context, dateShort),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                        children: [
                          _hero(context, title, dateFull, colors, decodeWidth),
                          const SizedBox(height: 16),
                          if (!document.isEmpty) _DiaryPaper(document: document),
                          const SizedBox(height: 24),
                          // AI 免责：底部居中一行淡字（替代原醒目徽章）
                          Center(
                            child: Text(revampText(context, en: 'AI-generated content may be inaccurate', zh: '内容由 AI 生成，可能存在不准确的情况'),
                                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 分享卡挂在屏幕外而不是 Offstage 里——Offstage 不 layout 也不 paint，
              // RepaintBoundary.toImage() 会直接抛「不在渲染树上」。移出可视区则照常绘制。
              if (_mountShareCard)
                Positioned(
                  left: -_shareCardWidth * 2,
                  top: 0,
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      key: _shareCardKey,
                      child: _DiaryShareCard(
                        width: _shareCardWidth,
                        title: title,
                        dateFull: dateFull,
                        colors: colors,
                        document: document,
                        imageUrl: moment.summaryImageUrl,
                        imageAspectRatio: _shareImageAspect,
                        decodeWidth: decodeWidth,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailBar(BuildContext context, String dateShort) {
    // 最小高度而不是钉死 52：大字下日期会被上下截掉。
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                width: 36, height: 36,
                child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary),
              ),
            ),
            Expanded(
              child: Text(dateShort,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            Builder(
              builder: (btnCtx) => GestureDetector(
                onTap: () => _share(btnCtx),
                behavior: HitTestBehavior.opaque,
                child: const SizedBox(
                  width: 36, height: 36,
                  child: Icon(Icons.ios_share_rounded, size: 20, color: JXB.textPrimary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(BuildContext context, String title, String dateFull, List<Color> colors, int decodeWidth) {
    final hasImage = moment.summaryImageUrl != null && moment.summaryImageUrl!.isNotEmpty;
    return GestureDetector(
      onTap: hasImage
          ? () => Navigator.of(context).push(
                PageRouteBuilder(
                  opaque: false,
                  barrierColor: Colors.black,
                  pageBuilder: (_, __, ___) => _ImageViewer(
                    imageUrl: moment.summaryImageUrl!,
                    fileStem: 'diary_${moment.id}',
                  ),
                ),
              )
          : null,
      behavior: HitTestBehavior.opaque,
      child: _heroCard(title, dateFull, colors, decodeWidth),
    );
  }

  Widget _heroCard(String title, String dateFull, List<Color> colors, int decodeWidth) {
    return Container(
      height: 240,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
        image: (moment.summaryImageUrl != null && moment.summaryImageUrl!.isNotEmpty)
            ? DecorationImage(
                image: DiaryImageCache.providerFor(moment.summaryImageUrl!, decodeWidth: decodeWidth),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0, right: 0, bottom: 0, height: 140,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter, end: Alignment.topCenter,
                  colors: [Color(0xB3000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
          Positioned(
            left: 20, right: 20, bottom: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(dateFull,
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xD9FFFFFF))),
                const SizedBox(height: 8),
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 24, fontWeight: FontWeight.w700, color: Colors.white)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分享卡的逻辑宽度。3.0 的 pixelRatio 下出图 1080px 宽，正好是各家 IM 不再
  /// 二次压缩的常见上限。
  static const double _shareCardWidth = 360;

  Future<void> _share(BuildContext context) async {
    final buf = StringBuffer()
      ..writeln(_resolveTitle())
      ..writeln()
      ..writeln(DiaryDocument.parse(moment.text).toPlainText());
    // iOS 需要 sharePositionOrigin（iPad 必需，iPhone 缺失偶发静默失败）。
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : Rect.zero;

    // 优先分享自绘的日记卡：它底部带二维码，是唯一能把看图的人引回官网的载体。
    // 合成失败（配图没解码出来、截图抛错）才退回原来的「配图原图 + 文本」，
    // 再不行退纯文本——分享本身绝不能因为二维码而失败。
    final card = await _captureShareCard();
    if (card != null) {
      await Share.shareXFiles([XFile(card.path)], text: buf.toString(), sharePositionOrigin: origin);
      return;
    }
    final file = await _downloadImage();
    if (file != null) {
      await Share.shareXFiles(
        [XFile(file.path)],
        text: buf.toString(),
        sharePositionOrigin: origin,
      );
    } else {
      await Share.share(buf.toString(), sharePositionOrigin: origin);
    }
  }

  /// 挂载屏外分享卡 → 截图 → 临时 png 文件。任何一步失败返回 null。
  Future<File?> _captureShareCard() async {
    final url = moment.summaryImageUrl;
    double? aspect;
    // 先把配图灌进内存缓存再挂卡片：屏外那份与 hero 共用 ImageProvider
    // （同 decodeWidth → 同 cache key），已解码才能在第一帧就画出来。
    // 少了这一步，配图慢的那次会截出一张只有渐变底的卡。
    if (url != null && url.isNotEmpty) {
      try {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final decodeWidth = (MediaQuery.sizeOf(context).width * dpr).round();
        final provider = DiaryImageCache.providerFor(url, decodeWidth: decodeWidth);
        await precacheImage(provider, context);
        // 顺手取真实比例：卡片的 hero 要按它定高，否则 cover 会裁掉配图上下两截。
        // 这里能拿到是因为上一行已经解完码——命中的是同一个 provider。
        aspect = await _resolveImageAspectRatio(provider);
      } catch (_) {
        // 配图取不到不该让分享失败，继续截——卡片会退化成渐变底。
      }
    }
    if (!mounted) return null;
    setState(() {
      _shareImageAspect = aspect;
      _mountShareCard = true;
    });
    try {
      // 等两帧：第一帧完成 layout/paint，第二帧确保 RepaintBoundary 已有图层。
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _shareCardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))?.buffer.asUint8List();
      if (bytes == null) return null;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/diary_card_${moment.id}.png');
      await file.writeAsBytes(bytes);
      return file;
    } catch (_) {
      return null;
    } finally {
      if (mounted) setState(() => _mountShareCard = false);
    }
  }

  Future<File?> _downloadImage() {
    final url = moment.summaryImageUrl;
    if (url == null || url.isEmpty) return Future.value(null);
    return _resolveDiaryImageFile(url, fileStem: 'diary_${moment.id}');
  }

  static const List<String> _weekdaysZh = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static const List<String> _weekdaysEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String _fmtFullDate(BuildContext context, DateTime d) => revampText(context,
      en: '${_weekdaysEn[d.weekday - 1]}, ${d.month}/${d.day}/${d.year}',
      zh: '${d.year}年${d.month}月${d.day}日 · ${_weekdaysZh[d.weekday - 1]}');

  String _fmtShortDate(BuildContext context, DateTime d) => revampText(context,
      en: '${d.month}/${d.day} · ${_weekdaysEn[d.weekday - 1]}',
      zh: '${d.month}月${d.day}日 · ${_weekdaysZh[d.weekday - 1]}');
}

/// 没有配图（纯渐变底）或比例取不到时的 hero 高度。
const double _shareHeroFallbackHeight = 200;

/// 按比例算出的 hero 高度上下限。下限保证底部那两行日期/标题不会挤爆超宽图；
/// 上限拦住异常竖图把分享卡拉成长条。只有撞到边界时才会重新出现裁切。
const double _shareHeroMinHeight = 180;
const double _shareHeroMaxHeight = 420;

/// 分享卡 hero 的高度：跟着配图真实比例走，而不是钉死一个值。
///
/// 🚨 **钉死高度 = 裁掉配图。** 配图是 1:1 的方图（后端
/// `utils/llm/image_generation.py` 的 prompt 就要求 square），塞进 360×200 的框里
/// `BoxFit.cover` 会把上下各裁掉 22% —— 用户看到的「分享出去的图顶部被截掉一块」
/// 就是这么来的。详情页的 hero 同样是裁切构图，但那儿点一下能看全图（还能存/分享
/// 原图）；分享物没有这个退路，所以只有这里必须按比例给高。
///
/// [aspectRatio] = 配图 width / height；null 或非正数表示没有配图或比例取不到。
@visibleForTesting
double diaryShareHeroHeight(double cardWidth, double? aspectRatio) {
  if (aspectRatio == null || aspectRatio <= 0) return _shareHeroFallbackHeight;
  return (cardWidth / aspectRatio).clamp(_shareHeroMinHeight, _shareHeroMaxHeight);
}

/// 取日记配图的本地文件（分享面板缩略图 / 存相册 / 分享原图共用），失败返回 null。
///
/// 优先命中 [DiaryImageCache] 的磁盘缓存——页面刚渲染过 hero，这张图基本必然
/// 已经在缓存里，走缓存等于零网络。只有缓存未命中才真下载一次。
///
/// ⚠️ **不能直接把缓存文件交出去，必须另存一份带正确扩展名的。**
/// `flutter_cache_manager` 落盘的文件名是它自己生成的（常常连扩展名都没有），
/// 而 `Gal.putImage` 在 iOS 侧按扩展名决定走图片还是视频通道，`Share.shareXFiles`
/// 也靠它猜 mime——扩展名不对时两边都只是**静默**地不出图。
Future<File?> _resolveDiaryImageFile(String url, {required String fileStem}) async {
  Uint8List? bytes;
  try {
    final cached = await DiaryImageCache.instance.getFileFromCache(url);
    if (cached != null && await cached.file.exists()) bytes = await cached.file.readAsBytes();
  } catch (_) {
    // 缓存查询失败不该让分享失败，继续走下载兜底。
  }
  if (bytes == null || bytes.isEmpty) {
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;
      bytes = resp.bodyBytes;
    } catch (_) {
      return null;
    }
  }
  try {
    final dir = await getTemporaryDirectory();
    final ext = _imageExtension(bytes);
    final file = File('${dir.path}/$fileStem$ext');
    await file.writeAsBytes(bytes);
    return file;
  } catch (_) {
    return null;
  }
}

/// 按 magic bytes 判扩展名（后端配图是 Gemini 出的 PNG，但别赌 URL 后缀）。
String _imageExtension(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return '.jpg';
  return '.png';
}

/// 解出 [provider] 解码后的宽高比（width / height），拿不到返回 null。
///
/// 只在图已经解码时可靠（`precacheImage` 之后），所以带 2s 超时兜底：这条链路上
/// 谁都不该为了一个比例把分享卡住。
Future<double?> _resolveImageAspectRatio(ImageProvider provider) {
  final completer = Completer<double?>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  void finish(double? ratio) {
    stream.removeListener(listener);
    if (!completer.isCompleted) completer.complete(ratio);
  }

  listener = ImageStreamListener(
    (info, _) => finish(info.image.height == 0 ? null : info.image.width / info.image.height),
    onError: (_, __) => finish(null),
  );
  stream.addListener(listener);
  return completer.future.timeout(const Duration(seconds: 2), onTimeout: () => null);
}

/// 日记的分享物：hero 配图 + 正文 + 「这天你还提到」+ 底部二维码品牌带。
///
/// 页面上看不到它——只在分享时挂到屏幕外截图（见 `_captureShareCard`）。所以这里
/// 不接任何交互，也不用 [CachedNetworkImage]（它的加载/失败态是异步的，截图会
/// 撞上占位符），直接用 [DecorationImage] 走已预热的内存缓存。
class _DiaryShareCard extends StatelessWidget {
  const _DiaryShareCard({
    required this.width,
    required this.title,
    required this.dateFull,
    required this.colors,
    required this.document,
    required this.imageUrl,
    required this.imageAspectRatio,
    required this.decodeWidth,
  });

  final double width;
  final String title;
  final String dateFull;
  final List<Color> colors;
  final DiaryDocument document;
  final String? imageUrl;

  /// 配图真实宽高比（width / height）。null = 拿不到，退回 [_heroFallbackHeight]。
  final double? imageAspectRatio;
  final int decodeWidth;

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    final heroHeight = diaryShareHeroHeight(width, hasImage ? imageAspectRatio : null);
    final excerpt = diaryShareExcerpt(document);

    // 分享物是一张固定版式的图：系统大字设置只该影响屏幕上的阅读，不该把出图撑成长条。
    return MediaQuery.withNoTextScaling(
      child: SizedBox(
        width: width,
        child: Material(
          color: JXB.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // hero：配图 + 底部暗渐变 + 日期/标题（同页面上那张，尺寸按卡宽缩）
              Container(
                height: heroHeight,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
                  image: hasImage
                      ? DecorationImage(
                          image: DiaryImageCache.providerFor(imageUrl!, decodeWidth: decodeWidth),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 130,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Color(0xB3000000), Color(0x00000000)],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 20,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(dateFull,
                              style: const TextStyle(
                                  fontFamily: JXB.fontSans,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xD9FFFFFF))),
                          const SizedBox(height: 6),
                          Text(title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontFamily: JXB.fontSans, fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DiaryBody(blocks: excerpt.blocks, compact: true, lastBlockMaxLines: excerpt.lastMaxLines),
                    if (excerpt.truncated) ...[
                      const SizedBox(height: 10),
                      // 只说「这是节选」：收图的人打不开别人的私密日记，二维码也只通向官网，
                      // 不能写成「打开 App 看全文」这种暗示能读到全文的话。
                      Text(revampText(context, en: 'Diary excerpt', zh: '日记节选'),
                          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
                    ],
                    const SizedBox(height: 16),
                    const ShareQrFooter(kind: ShareCardKind.diary),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全屏图片查看器：黑底 + 双指缩放 + 点击关闭 + 保存到相册 / 分享原图。
class _ImageViewer extends StatefulWidget {
  final String imageUrl;

  /// 落到临时目录的文件名前缀（不含扩展名），用来区分不同日记的配图。
  final String fileStem;

  const _ImageViewer({required this.imageUrl, required this.fileStem});

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  /// 取文件是异步的（缓存未命中要下载）。期间禁掉两个按钮，否则连点会重复下载。
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).maybePop(),
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: CachedNetworkImage(
                  imageUrl: widget.imageUrl,
                  cacheManager: DiaryImageCache.instance,
                  fit: BoxFit.contain,
                  progressIndicatorBuilder: (context, url, progress) => const Center(
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  ),
                  errorWidget: (context, _, __) => const Center(
                    child: Icon(Icons.broken_image_rounded, size: 48, color: Colors.white54),
                  ),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 16,
              child: GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 36, height: 36, alignment: Alignment.center,
                  decoration: const BoxDecoration(color: Color(0x66000000), shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded, size: 22, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _action(
                    icon: Icons.download_rounded,
                    label: revampText(context, en: 'Save', zh: '保存'),
                    onTap: _saveToGallery,
                  ),
                  const SizedBox(width: 16),
                  _action(
                    icon: Icons.ios_share_rounded,
                    label: revampText(context, en: 'Share', zh: '分享'),
                    onTap: _shareImage,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _action({required IconData icon, required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: _busy ? 0.5 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0x66000000),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveToGallery() async {
    // 两句文案在 await 之前算好：Gal.putImage 之后 context 已跨过异步边界。
    final ok = revampText(context, en: 'Saved to Photos', zh: '已保存到相册');
    final failed = revampText(context, en: 'Save failed, please try again', zh: '保存失败，请重试');
    final file = await _prepareFile();
    if (file == null || !mounted) return;
    try {
      await Gal.putImage(file.path);
      _toast(ok);
    } catch (_) {
      // 权限被拒也落这里——文案统一说「保存失败」，系统那边已经弹过权限说明了。
      _toast(failed);
    }
  }

  Future<void> _shareImage() async {
    // 分享锚点要在 await 之前取：iOS/iPad 缺 sharePositionOrigin 会静默失败。
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : Rect.zero;
    final file = await _prepareFile();
    if (file == null || !mounted) return;
    await Share.shareXFiles([XFile(file.path)], sharePositionOrigin: origin);
  }

  /// 拿到可交给系统的本地文件；失败时自己 toast 并返回 null。
  Future<File?> _prepareFile() async {
    if (_busy) return null;
    setState(() => _busy = true);
    final file = await _resolveDiaryImageFile(widget.imageUrl, fileStem: widget.fileStem);
    if (!mounted) return null;
    setState(() => _busy = false);
    if (file == null) {
      _toast(revampText(context, en: "Couldn't load the image", zh: '图片加载失败'));
      return null;
    }
    return file;
  }

  void _toast(String msg) {
    if (!mounted) return;
    UndoDeleteHost.showMessage(context, msg);
  }
}

/// 详情页上的「日记纸」：白底圆角卡片托住正文，跟页面的淡蓝底拉开一层，读起来像一页
/// 自己的本子而不是一段系统文案。正文可选中复制。
class _DiaryPaper extends StatelessWidget {
  const _DiaryPaper({required this.document});

  final DiaryDocument document;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
      decoration: BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: JXB.cardShadow,
      ),
      child: SelectionArea(child: _DiaryBody(blocks: document.blocks)),
    );
  }
}

/// 日记正文排版：段落 / 引语 / 小标题 / 列表四种块。「小标题 + 紧跟的列表」合成一张
/// 浅蓝便签（journal 的「明天记得」、legacy 的「关键跟进事项」都是这个形状）；只有标题
/// 跟着散文时（legacy 的「今日亮点」）就只是一行小标签。
///
/// [compact] 给分享卡用：字号小一档、间距收紧。[lastBlockMaxLines] 只作用于最后一个
/// 块，配合 [diaryShareExcerpt] 的截断。所有尺寸都不钉死高度，大字与窄屏下只会换行。
class _DiaryBody extends StatelessWidget {
  const _DiaryBody({required this.blocks, this.compact = false, this.lastBlockMaxLines});

  final List<DiaryBlock> blocks;
  final bool compact;
  final int? lastBlockMaxLines;

  static const Color _ink = Color(0xFF2B2E33);

  TextStyle get _paragraphStyle => TextStyle(
      fontFamily: JXB.fontSans, fontSize: compact ? 14 : 16, height: compact ? 1.8 : 1.9, color: _ink);

  TextStyle get _itemStyle =>
      TextStyle(fontFamily: JXB.fontSans, fontSize: compact ? 13 : 15, height: 1.6, color: JXB.textPrimary);

  /// 加粗是重读时的落点：字重 + 一点蓝黑墨水色，像钢笔写重的那几个字。
  ///
  /// ⚠️ 别给它垫底色或粗下划线。`background` 会撑满 1.9 倍行高成一块色块，而且跟
  /// [JXB.textSelection] 几乎同色——正文包在 SelectionArea 里，看着就像「被选中了」；
  /// 加粗下划线则渲染成一条细蓝线，像超链接。
  static TextStyle _boldOf(TextStyle base) => base.copyWith(fontWeight: FontWeight.w600, color: _boldInk);

  static const Color _boldInk = Color(0xFF1F3B63);

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final gap = compact ? 12.0 : 16.0;
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final isLast = i == blocks.length - 1;
      final next = i + 1 < blocks.length ? blocks[i + 1] : null;
      if (children.isNotEmpty) {
        // 小标题与它下面的内容贴近、与上一块拉开，归属一眼可见。
        final afterHeading = blocks[i - 1].kind == DiaryBlockKind.heading;
        children.add(SizedBox(
            height: afterHeading ? (compact ? 6 : 8) : (block.kind == DiaryBlockKind.heading ? gap + 6 : gap)));
      }
      if (block.kind == DiaryBlockKind.heading && next?.kind == DiaryBlockKind.list) {
        children.add(_note(block.text, next!, i + 1 == blocks.length - 1 ? lastBlockMaxLines : null));
        i++;
        continue;
      }
      children.add(_block(block, isLast ? lastBlockMaxLines : null));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _block(DiaryBlock block, int? maxLines) {
    switch (block.kind) {
      case DiaryBlockKind.paragraph:
        return _rich(block.text, _paragraphStyle, maxLines: maxLines);
      case DiaryBlockKind.quote:
        return _quote(block.text, maxLines);
      case DiaryBlockKind.heading:
        return _label(block.text);
      case DiaryBlockKind.list:
        return _list(block, maxLines);
    }
  }

  Widget _rich(String text, TextStyle style, {int? maxLines}) {
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          for (final run in DiaryDocument.inlineRuns(text))
            TextSpan(text: run.text, style: run.bold ? _boldOf(style) : null),
        ],
      ),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }

  /// 原话：浅蓝底 + 左侧一道品牌色竖线，字比正文略小一号、略重，让它从叙述里浮出来。
  Widget _quote(String text, int? maxLines) {
    final style = TextStyle(
        fontFamily: JXB.fontSans,
        fontSize: compact ? 13.5 : 15.5,
        height: 1.7,
        fontWeight: FontWeight.w500,
        color: const Color(0xFF3A3F47));
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: JXB.brandTintFaint, borderRadius: BorderRadius.circular(JXB.radiusControl)),
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 14 : 18, compact ? 10 : 12, compact ? 12 : 16, compact ? 10 : 12),
            child: _rich(text, style, maxLines: maxLines),
          ),
          const Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: SizedBox(width: 3, child: ColoredBox(color: JXB.brandSecondary)),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) {
    return Text(text,
        style: TextStyle(
            fontFamily: JXB.fontSans,
            fontSize: compact ? 13 : 14,
            height: 1.4,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: JXB.brandPrimary));
  }

  Widget _note(String title, DiaryBlock list, int? maxLines) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(color: const Color(0x0A007AFF), borderRadius: BorderRadius.circular(JXB.radiusCard)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _label(title),
          SizedBox(height: compact ? 8 : 10),
          _list(list, maxLines),
        ],
      ),
    );
  }

  /// 圆点 / 编号与条目文字按基线对齐，而不是靠一个钉死高度的容器居中——后者在大字下
  /// 会让圆点漂到第一行上方。
  Widget _list(DiaryBlock list, int? maxItems) {
    final items = maxItems == null ? list.items : list.items.take(maxItems).toList();
    final markerStyle = _itemStyle.copyWith(
        fontFamily: list.ordered ? JXB.fontNumber : JXB.fontSans,
        fontWeight: FontWeight.w600,
        color: JXB.brandPrimary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(height: compact ? 4 : 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(list.ordered ? '${i + 1}.' : '•', style: markerStyle),
              const SizedBox(width: 8),
              Expanded(child: _rich(items[i], _itemStyle, maxLines: compact ? 2 : null)),
            ],
          ),
        ],
      ],
    );
  }
}

/// 分享卡正文的字数预算（权重：中日韩字符记 1、其余记 0.5，约等于卡片上一行 22 个
/// 汉字 × 16 行）。日记偶尔几千字，全量出图会得到一张又长又被 IM 压糊的图。
const double _shareTextBudget = 360;
const double _shareCharsPerLine = 22;

/// 分享卡展示到哪儿：按顺序放块直到预算用完；跨过预算的那个段落 / 引语 / 列表若还剩
/// 两行以上就截断显示（[lastMaxLines] 是行数，列表则是条目数），否则整块不放。
/// [truncated] 为 true 时卡片底部标注「日记节选」。
@visibleForTesting
({List<DiaryBlock> blocks, int? lastMaxLines, bool truncated}) diaryShareExcerpt(DiaryDocument document,
    {double budget = _shareTextBudget}) {
  double weightOf(String s) {
    var w = 0.0;
    for (final r in s.runes) {
      w += r >= 0x2E80 ? 1 : 0.5;
    }
    return w;
  }

  // 每个块的固定开销 ≈ 半行间距；列表每条再加半行（圆点 + 行距）。
  double cost(DiaryBlock b) => b.kind == DiaryBlockKind.list
      ? b.items.fold(_shareCharsPerLine / 2, (sum, item) => sum + weightOf(item) + _shareCharsPerLine / 2)
      : weightOf(b.plainText) + _shareCharsPerLine / 2;

  final shown = <DiaryBlock>[];
  var used = 0.0;
  for (var i = 0; i < document.blocks.length; i++) {
    final block = document.blocks[i];
    final c = cost(block);
    if (used + c <= budget) {
      shown.add(block);
      used += c;
      continue;
    }
    final remaining = budget - used;
    int? lastMaxLines;
    if (block.kind == DiaryBlockKind.list) {
      var room = remaining - _shareCharsPerLine / 2;
      var n = 0;
      for (final item in block.items) {
        final itemCost = weightOf(item) + _shareCharsPerLine / 2;
        if (itemCost > room) break;
        room -= itemCost;
        n++;
      }
      if (n > 0) lastMaxLines = n;
    } else if (block.kind != DiaryBlockKind.heading && remaining >= _shareCharsPerLine * 2) {
      lastMaxLines = (remaining / _shareCharsPerLine).floor();
    }
    if (lastMaxLines != null) {
      shown.add(block);
    } else if (shown.isNotEmpty && shown.last.kind == DiaryBlockKind.heading) {
      // 不留一个后面什么都没有的孤零零小标题。
      shown.removeLast();
    }
    return (blocks: shown, lastMaxLines: lastMaxLines, truncated: true);
  }
  return (blocks: shown, lastMaxLines: null, truncated: false);
}
