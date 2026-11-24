import 'package:flutter/material.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/pages/onboarding/onboarding_lang.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:url_launcher/url_launcher.dart';

/// O-08 关于你的数据 · AI 数据同意（记小宝 1.0 浅色改版，Figma node 769:1651/1818）。
///
/// 单页「卡片堆叠」：三张浅蓝渐变卡叠放旋转，当前卡在最上（01/03 标签 + 标题 + 正文），
/// 后两张露出边缘；左下 3D 渐变云朵 + 闪光；下方一句话文案；底部勾选 +「下一步」。
/// 「下一步」按序切换 01→02→03，末页勾选后写 `aiDataConsentAccepted` 并 goNext。
class AiDataConsentPage extends StatefulWidget {
  final VoidCallback goNext;

  const AiDataConsentPage({super.key, required this.goNext});

  @override
  State<AiDataConsentPage> createState() => _AiDataConsentPageState();
}

class _AiDataConsentPageState extends State<AiDataConsentPage> {
  int _step = 0; // 0..2 对应 01/03..03/03
  bool _agreed = false;

  List<_ConsentCard> _cards(BuildContext context) => [
        _ConsentCard(
          title: obL(context, '语音识别', 'Speech recognition'),
          body: obL(context, '你的录音会上传至 Deepgram、Soniox 等第三方语音识别服务转写为文字。',
              'Your audio is uploaded to speech services like Deepgram and Soniox to be transcribed into text.'),
          footer: obL(context, '我会认真听懂你的每一句话', 'I listen carefully to every word you say'),
        ),
        _ConsentCard(
          title: obL(context, 'AI 处理', 'AI processing'),
          body: obL(context, '转写文本会交由大语言模型生成摘要、行动项与记忆。所有数据均加密传输与存储。',
              'Transcripts are processed by LLMs to generate summaries, action items and memories. All data is encrypted in transit and at rest.'),
          footer: obL(context, '我会帮你整理那些容易忘记的重要事情', 'I help you keep the things you might forget'),
        ),
        _ConsentCard(
          title: obL(context, '日历行程', 'Calendar'),
          // 与授权页的 CalendarAiConsent 说明保持同口径：日历是可选功能，开启后
          // 才会同步；这里只做事前告知，真正的同意仍在设置页的开关处取得。
          body: obL(context, '若你在设置中开启日历，日程的标题、时间与地点会同步到服务器并交由 AI 处理；备注与参会人永不读取，随时可关闭并删除。',
              'If you enable Calendar in Settings, event titles, times and locations are synced to our servers and processed by AI; notes and attendees are never read, and you can turn it off and delete them anytime.'),
          footer: obL(context, '需要时我才会看你的行程', 'I only look at your schedule when you ask'),
        ),
        _ConsentCard(
          title: obL(context, '你的权利', 'Your rights'),
          body: obL(context, '你可以随时在设置中导出或永久删除你的全部数据。',
              'You can export or permanently delete all your data anytime in Settings.'),
          footer: obL(context, '你的记忆永远由你掌控', 'Your memories are always yours to control'),
        ),
      ];

  void _onNext(int total) {
    if (_step < total - 1) {
      setState(() => _step++);
    } else {
      SharedPreferencesUtil().aiDataConsentAccepted = true;
      widget.goNext();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cards = _cards(context);
    final total = cards.length;
    final isLast = _step == total - 1;
    final canNext = !isLast || _agreed;

    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 40),
          // 标题
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _GradientTitle(
                zh: obL(context, 'zh', 'en') == 'zh',
                zhSpans: const ['关于你的', '数据'],
                enSpans: const ['About your ', 'data'],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  obL(context, '了解 Memorion 如何处理你的记录，你始终拥有掌控权。',
                      'See how Memorion handles your recordings — you stay in control.'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary, height: 1.5)),
            ),
          ),
          // 卡片堆叠区
          Expanded(
            child: Center(
              child: SizedBox(
                width: 320,
                height: 360,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 后两张卡（露边，半透明），营造堆叠
                    Transform.translate(
                      offset: const Offset(-14, 6),
                      child: Transform.rotate(angle: -1.39 * 3.1415926 / 180, child: _cardShell(opacity: 0.5)),
                    ),
                    Transform.translate(
                      offset: const Offset(14, 2),
                      child: Transform.rotate(angle: 1.02 * 3.1415926 / 180, child: _cardShell(opacity: 0.7)),
                    ),
                    // 当前卡
                    Transform.rotate(
                      angle: 1.02 * 3.1415926 / 180,
                      child: _frontCard(cards[_step], _step, total),
                    ),
                    // 3D 云朵（左下，压在卡片上）
                    Positioned(
                      left: 2,
                      bottom: 46,
                      child: Image.asset('assets/images/onboarding/cloud_3d.png', width: 92),
                    ),
                    // 闪光装饰
                    const Positioned(left: 26, bottom: 132, child: Text('✦', style: TextStyle(fontSize: 16, color: Color(0xFF9DC3FF)))),
                    const Positioned(left: 8, bottom: 108, child: Text('✦', style: TextStyle(fontSize: 10, color: Color(0xFFBFD8FF)))),
                  ],
                ),
              ),
            ),
          ),
          // 一句话文案
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(cards[_step].footer,
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
          ),
          const SizedBox(height: 18),
          // 隐私政策链接
          GestureDetector(
            onTap: () => launchUrl(Uri.parse('https://memorion.me/en/privacy'), mode: LaunchMode.externalApplication),
            child: Text(obL(context, '查看隐私政策', 'View privacy policy'),
                style: const TextStyle(
                    fontFamily: JXB.fontSans,
                    fontSize: 13,
                    color: JXB.brandPrimary,
                    decoration: TextDecoration.underline,
                    decorationColor: JXB.brandPrimary)),
          ),
          const SizedBox(height: 14),
          // 同意勾选（仅末页需要勾选才可继续，但全程展示）
          GestureDetector(
            onTap: () => setState(() => _agreed = !_agreed),
            behavior: HitTestBehavior.opaque,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: _agreed ? JXB.brandPrimary : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: _agreed ? JXB.brandPrimary : JXB.textPlaceholder, width: 1.4),
                  ),
                  child: _agreed ? const Icon(Icons.check_rounded, size: 13, color: Colors.white) : null,
                ),
                const SizedBox(width: 8),
                Text(obL(context, '我理解并同意', 'I understand and agree'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder)),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 14, 24, MediaQuery.of(context).padding.bottom + 16),
            child: GestureDetector(
              onTap: canNext ? () => _onNext(total) : null,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: canNext ? JXB.brandPrimary : JXB.brandPrimary.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(obL(context, '下一步', 'Next'),
                    style: const TextStyle(
                        fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 空卡壳（后层堆叠用）。
  Widget _cardShell({required double opacity}) {
    return Opacity(
      opacity: opacity,
      child: Container(
        width: 243,
        height: 288,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.bottomRight,
            end: Alignment.topLeft,
            colors: [Color(0xFFDCECFF), Color(0xFFF6FAFF)],
          ),
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: const Color(0xFFDCECFF)),
        ),
      ),
    );
  }

  /// 当前卡（含标签 + 标题 + 正文）。
  Widget _frontCard(_ConsentCard card, int step, int total) {
    return Container(
      width: 243,
      height: 288,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.bottomRight,
          end: Alignment.topLeft,
          colors: [Color(0xFFDCECFF), Color(0xFFF6FAFF)],
        ),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: const Color(0xFFDCECFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 0X/03 标签（白渐变胶囊）
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.centerRight,
                end: Alignment.centerLeft,
                colors: [Colors.white, Color(0x00FFFFFF)],
              ),
              borderRadius: BorderRadius.circular(24),
            ),
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14),
                children: [
                  TextSpan(
                      text: '0${step + 1}',
                      style: const TextStyle(color: JXB.brandSecondary, fontWeight: FontWeight.w600)),
                  TextSpan(text: '/0$total', style: const TextStyle(color: Color(0xFFACB6D4))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(card.title,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 20, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
          const SizedBox(height: 12),
          Text(card.body,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.57, color: JXB.textSecondary)),
        ],
      ),
    );
  }
}

class _ConsentCard {
  final String title;
  final String body;
  final String footer;
  _ConsentCard({required this.title, required this.body, required this.footer});
}

/// 渐变标题（深灰→蓝），还原设计稿 Title Gradient。
class _GradientTitle extends StatelessWidget {
  final bool zh;
  final List<String> zhSpans;
  final List<String> enSpans;
  const _GradientTitle({required this.zh, required this.zhSpans, required this.enSpans});

  @override
  Widget build(BuildContext context) {
    final spans = zh ? zhSpans : enSpans;
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [Color(0xFF24262C), Color(0xFF68ACFF)],
        stops: [0.62, 1.0],
      ).createShader(bounds),
      child: Text(
        spans.join(),
        style: const TextStyle(
            fontFamily: JXB.fontDisplay, fontSize: 30, fontWeight: FontWeight.w700, height: 1.1, color: Colors.white),
      ),
    );
  }
}
