import 'package:flutter/material.dart';

bool isRevampChinese(BuildContext context) =>
    Localizations.localeOf(context).languageCode.toLowerCase().startsWith('zh');

String revampText(
  BuildContext context, {
  required String en,
  required String zh,
}) {
  return isRevampChinese(context) ? zh : en;
}
