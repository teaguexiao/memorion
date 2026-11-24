import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// 章节详情右下角 60×60「问这段」悬浮入口；底部邀请卡进入阅读视口时由详情页隐藏。
///
/// 进入 Ask 的转场期间，[ContinueChatRoute] 在最上层画一份同样的按钮，用 [scale]、
/// [rotation]（度）与 [capture] 播放云朵的抬起与吸收；静止时它们都取默认值。
class ChapterAskFloatingButton extends StatelessWidget {
  const ChapterAskFloatingButton(
      {super.key, required this.onTap, this.buttonKey, this.scale = 1, this.rotation = 0, this.capture});

  final VoidCallback? onTap;

  /// 挂在可点区域（InkWell）上的 key：外层 [Transform] 不参与命中测试，测试点它会被判成「点空」。
  final Key? buttonKey;
  final double scale;
  final double rotation;

  /// 吸收阶段外圈扩散的进度（0→1）；null 不画外圈。
  final double? capture;

  /// 按钮底边距屏幕底边：沿用安全区规则再上移 32（390×844、底部安全区 34 时落在 (312,732,60,60)）。
  static double bottomInset(BuildContext context) => math.max(8.0, MediaQuery.paddingOf(context).bottom - 14) + 32;

  @override
  Widget build(BuildContext context) => Transform.scale(
        scale: scale,
        child: Semantics(
          button: true,
          label: revampText(context, en: 'Ask about this conversation', zh: '基于这段对话提问'),
          child: Material(
            color: JXB.surface,
            shape: const CircleBorder(),
            child: InkWell(
              key: buttonKey,
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: JXB.surface,
                    boxShadow: [BoxShadow(color: Color(0x1A2B2926), blurRadius: 30)]),
                child: Stack(alignment: Alignment.center, children: [
                  if (capture != null)
                    Transform.scale(
                        scale: 1 + .65 * capture!,
                        child: Container(
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: JXB.brandSecondary.withValues(alpha: .4 * (1 - capture!)), width: 2)))),
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    Transform.rotate(
                        angle: rotation * math.pi / 180,
                        child: SvgPicture.asset('assets/images/continue_chat/imgGroup1940699823.svg',
                            width: 23.3996, height: 15.3467)),
                    const SizedBox(height: 3),
                    Text(revampText(context, en: 'Ask', zh: '问这段'),
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: JXB.brandSecondary)),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      );
}
