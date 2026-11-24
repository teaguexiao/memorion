import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// Figma JXB/Feedback/Toast: compact feedback or a 320px Undo reservation.
class JxbToast extends StatelessWidget {
  static const background = Color(0xEB25282D);
  final String message;
  final String? prefix;
  final Widget? action;
  final double? progress;
  final Key? surfaceKey;
  final Widget? footer;

  const JxbToast(
      {super.key, required this.message, this.prefix, this.action, this.progress, this.surfaceKey, this.footer});

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    final undo = action != null;
    const style = TextStyle(
        fontFamily: JXB.fontSans, fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400, color: Colors.white);
    final largeText = scale.scale(14) > 28;
    final text = Text.rich(
      TextSpan(children: [if (prefix != null) TextSpan(text: prefix), TextSpan(text: message)]),
      maxLines: undo ? 1 : null,
      overflow: undo ? TextOverflow.ellipsis : null,
      style: style,
    );
    final content = largeText && undo
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [text, Align(alignment: Alignment.centerRight, child: action!)])
        : Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(fit: undo ? FlexFit.tight : FlexFit.loose, child: text),
            if (action != null) ...[const SizedBox(width: 12), action!],
          ]);
    return Container(
      constraints: BoxConstraints(maxWidth: 320, minHeight: undo ? scale.scale(20) + 28 : 44),
      width: undo ? 320 : null,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Color(0x1F000000), offset: Offset(0, 6), blurRadius: 20)],
      ),
      child: Material(
        key: surfaceKey,
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: undo ? const BorderSide(color: Colors.black) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(alignment: Alignment.center, children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: undo ? (largeText || footer != null ? 12 : 2) : 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [content, if (footer != null) footer!]),
          ),
          if (progress != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 8,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(1),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 2,
                      color: JXB.brandSecondary,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
