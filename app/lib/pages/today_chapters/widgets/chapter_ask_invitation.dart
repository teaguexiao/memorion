import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// Figma 1480:3469: invitation after the chapter summary and before its actions.
class ChapterAskInvitation extends StatelessWidget {
  const ChapterAskInvitation({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFFEAF3FF),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFFDAE8FA))),
        child: InkWell(
          key: const Key('chapter-ask-invitation'), // i18n-ignore: widget identifier
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: JXB.space4, vertical: JXB.space3),
              child: Row(children: [
                Expanded(
                  child:
                      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(revampText(context, en: 'Chat about this conversation', zh: '聊聊这次对话'),
                        style: JXB.metaButton.copyWith(color: const Color(0xFF4172B1), height: 22 / 14)),
                    const SizedBox(height: 3),
                    Text(
                        revampText(context,
                            en: 'What else would you like to explore?', // i18n-ignore: paired revampText
                            zh: '这段回忆里，还有什么想聊的？'),
                        style: JXB.caption.copyWith(fontSize: 12, height: 18 / 12, color: const Color(0xFF8FA0B5))),
                  ]),
                ),
                const SizedBox(width: 10),
                SvgPicture.asset('assets/images/continue_chat/imgAsk.svg', width: 20, height: 20),
                const SizedBox(width: 12),
                SizedBox(
                  width: 42,
                  height: 32,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(boxShadow: [
                      BoxShadow(color: Color(0x14264D78), offset: Offset(0, 2), blurRadius: 6.6),
                    ]),
                    child: ClipRect(
                      child: Stack(children: [
                        Positioned(
                          left: -5.4432,
                          top: -9.6288,
                          width: 52.8906,
                          height: 51.808,
                          child: Image.asset('assets/images/continue_chat/chapter_ask_cloud.png',
                              fit: BoxFit.fill, excludeFromSemantics: true),
                        ),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}
