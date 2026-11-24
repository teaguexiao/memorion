import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 分享物的类型，只用来给官网链接打 `utm_content`——好在官网分析里分清
/// 哪种卡带来的流量。加新卡片时在这里补一项，别复用别人的值。
enum ShareCardKind {
  chapter('chapter'),
  insight('insight'),
  diary('diary'),
  transcript('transcript'),
  summary('summary');

  const ShareCardKind(this.utmContent);

  final String utmContent;
}

/// 分享图/分享文案里指向官网的带归因链接。
///
/// ⚠️ **UTM 参数是拼在这里而不是做成后端短链的**，所以这个 URL 一旦印进图片就
/// 无法再改向——已经发出去的图会一直指向 memorion.me 首页。若日后要换落地页或
/// 统计扫码量，得先上一个自有短链（`/s/xxx` 302），再把这里换成短链。
///
/// [medium] 区分载体：`image` 是印在图里的二维码，`text` 是文案末尾的明文链接。
String memorionShareUrl(ShareCardKind kind, {String medium = 'image'}) =>
    'https://www.memorion.me/?utm_source=share_$medium&utm_content=${kind.utmContent}';

/// 文本/文件类分享在末尾追加的一行署名 + 官网链接。
///
/// 纯文本分享挂不了二维码（#3 导出摘要、#7 导出转写），用明文链接补上传播出口。
String memorionShareSignature(BuildContext context, ShareCardKind kind) {
  final url = memorionShareUrl(kind, medium: 'text');
  return revampText(context,
      en: '\n\n— Recorded with Memorion\n$url',
      zh: '\n\n— 由记小宝 Memorion 记录\n$url');
}

/// 分享图底部的品牌带：左侧品牌名 + 一句话介绍，右侧二维码（扫码进官网）。
///
/// 视觉规格取自调研到的共识值，别随手改小：
/// - 二维码 [_qrSize] 64pt，在 `pixelRatio: 3.0` 截图下是 192px，屏对屏扫描足够；
///   再小就开始有识别失败的机型。
/// - 白色底衬 + `padding` 撑出静默区（quiet zone）。**任何元素都不能压到码上**，
///   所以刻意没有在中心嵌 logo——嵌 logo 要把纠错级别提到 Q 并逐机型实测，
///   而品牌身份已经由左边的文字承担了。
/// - 码色用 [JXB.textPrimary] 而非品牌蓝：蓝色对浅色背景的对比度不够稳。
///
/// [onDark] 给深色卡（洞察卡的渐变蓝）用：文字转白，二维码仍然是白底黑码——
/// 反相二维码有相当一部分扫码器不认。
class ShareQrFooter extends StatelessWidget {
  const ShareQrFooter({super.key, required this.kind, this.onDark = false});

  final ShareCardKind kind;
  final bool onDark;

  static const double _qrSize = 64;

  @override
  Widget build(BuildContext context) {
    final titleColor = onDark ? Colors.white : JXB.textPrimary;
    final subColor = onDark ? const Color(0xFFD9EBFF) : JXB.textSecondary;
    final dividerColor = onDark ? const Color(0x1FFFFFFF) : JXB.border;

    return Column(
      // 必须 min：父级给有界高度时（洞察卡的 Container、任何 Center）默认的 max
      // 会让这条品牌带把整块高度吃掉，截图里就是一大片空白。
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 1, color: dividerColor),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(revampText(context, en: 'Memorion', zh: '记小宝 Memorion'),
                      style: TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: titleColor)),
                  const SizedBox(height: 4),
                  Text(
                      // 逐行摊开 + 末尾逗号：i18n 守卫按括号配平判断 revampText 是否还没闭合，
                      // en/zh 和收尾的 `)` 挤在同一行会被判成裸英文字面量。
                      revampText(
                        context,
                        en: 'A wearable AI that remembers your days',
                        zh: '一枚随身的 AI，替你记住每一天',
                      ),
                      style: TextStyle(fontFamily: JXB.fontSans, fontSize: 12, height: 1.4, color: subColor)),
                  const SizedBox(height: 6),
                  Text(revampText(context, en: 'Scan to learn more', zh: '扫码了解'),
                      style: TextStyle(fontFamily: JXB.fontSans, fontSize: 11, color: subColor)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
              child: QrImageView(
                data: memorionShareUrl(kind),
                size: _qrSize,
                // QrImageView 自带的 padding 默认 10，这里由外层白底容器统一撑静默区。
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
                // 包默认是 L（7%），对「被 IM 二次压缩过的截图」偏脆；M（15%）是
                // 各家实践的共识档。要往中心嵌 logo 的话得再提到 Q 并逐机型实测。
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                semanticsLabel: revampText(context, en: 'QR code to memorion.me', zh: '扫码访问 memorion.me'),
                // gapless: false 会在模块间留缝，某些相机会因此漏采样。
                gapless: true,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: JXB.textPrimary),
                dataModuleStyle:
                    const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: JXB.textPrimary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
