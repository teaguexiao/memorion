import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/platform/platform_service.dart';

/// 通用二次确认弹框。onboarding（配对失败、声纹）、无网提示、删除账户共用。
///
/// ⚠️ **按钮文字不要写 `Colors.white`。** 这里曾是白字——那只在旧深色壳下成立，
/// 靠的是全局深色主题。1.0 全线浅色之后白字落在白底弹框上等于隐形按钮，而
/// `getDialog` 的调用点恰好全在浅色页面上。现在颜色一律走 [JXB] 令牌。
//TODO: switch to required named parameters
getDialog(
  BuildContext context,
  Function onCancel,
  Function onConfirm,
  String title,
  String content, {
  bool singleButton = false,
  String? okButtonText,
  String? cancelButtonText,
}) {
  final effectiveOkText = okButtonText ?? S.of(context).ok;
  final effectiveCancelText = cancelButtonText ?? S.of(context).cancel;
  const okStyle = TextStyle(fontFamily: JXB.fontSans, fontWeight: FontWeight.w600, color: JXB.brandPrimary);
  const cancelStyle = TextStyle(fontFamily: JXB.fontSans, color: JXB.textSecondary);

  var actions = singleButton
      ? [
          TextButton(
            onPressed: () => onCancel(),
            child: Text(effectiveOkText, style: okStyle),
          )
        ]
      : [
          TextButton(
            onPressed: () => onCancel(),
            child: Text(effectiveCancelText, style: cancelStyle),
          ),
          TextButton(onPressed: () => onConfirm(), child: Text(effectiveOkText, style: okStyle)),
        ];

  const titleStyle = TextStyle(
      fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w600, color: JXB.textPrimary);
  const contentStyle = TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.4, color: JXB.textSecondary);

  if (PlatformService.isApple) {
    // CupertinoAlertDialog 自带浅色材质（跟随 CupertinoTheme 的 brightness），
    // 只需要把文字颜色钉住，别再依赖主题默认色。
    return CupertinoAlertDialog(
      title: Text(title, style: titleStyle),
      content: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(content, style: contentStyle),
      ),
      actions: actions,
    );
  }
  return AlertDialog(
    backgroundColor: JXB.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(JXB.radiusCard)),
    title: Text(title, style: titleStyle),
    content: Text(content, style: contentStyle),
    actions: actions,
  );
}
