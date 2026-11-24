import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// 带可选勾选框的确认弹框（固件更新提示在用）。
///
/// ⚠️ 配色一律走 [JXB] 令牌。这里原是深色（`#1F1F25` 底 + 白字 + deepPurple 强调），
/// 依赖旧深色壳的全局主题；1.0 全线浅色之后那套在白底上不可读。
class ConfirmationDialog extends StatefulWidget {
  final String title;
  final String description;
  final String? checkboxText;
  final bool? checkboxValue;
  final void Function(bool value)? onCheckboxChanged;
  final String? cancelText;
  final String? confirmText;
  final void Function() onConfirm;
  final void Function() onCancel;

  const ConfirmationDialog({
    super.key,
    required this.title,
    required this.description,
    this.checkboxText,
    this.checkboxValue,
    this.onCheckboxChanged,
    this.cancelText,
    this.confirmText,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<ConfirmationDialog> createState() => _ConfirmationDialogState();
}

class _ConfirmationDialogState extends State<ConfirmationDialog> {
  bool _checkboxValue = false;

  static const _titleStyle = TextStyle(
    fontFamily: JXB.fontSans,
    color: JXB.textPrimary,
    fontSize: 18,
    fontWeight: FontWeight.w600,
  );
  static const _descStyle = TextStyle(
    fontFamily: JXB.fontSans,
    color: JXB.textSecondary,
    fontSize: 14,
    height: 1.4,
  );
  static const _checkboxLabelStyle = TextStyle(
    fontFamily: JXB.fontSans,
    color: JXB.textSecondary,
    fontSize: 14,
  );

  @override
  void initState() {
    super.initState();
    _checkboxValue = widget.checkboxValue ?? false;
  }

  void _updateCheckboxValue(bool? value) {
    if (value != null) {
      setState(() {
        _checkboxValue = value;
      });
      if (widget.onCheckboxChanged != null) {
        widget.onCheckboxChanged!(value);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    if (Platform.isAndroid) {
      return AlertDialog(
        backgroundColor: JXB.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(JXB.radiusCard)),
        contentPadding: const EdgeInsets.only(top: 20, left: 24, right: 24, bottom: 10),
        title: Text(widget.title, style: _titleStyle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Text(widget.description, textAlign: TextAlign.start, style: _descStyle),
            if (widget.checkboxText != null && widget.checkboxText!.isNotEmpty) ...[
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Theme(
                    data: Theme.of(context).copyWith(
                      checkboxTheme: CheckboxThemeData(
                        fillColor: WidgetStateProperty.resolveWith<Color>(
                          (states) => states.contains(WidgetState.selected) ? JXB.brandPrimary : JXB.surface,
                        ),
                        side: const BorderSide(color: JXB.border, width: 1.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                    child: Checkbox(
                      value: _checkboxValue,
                      onChanged: _updateCheckboxValue,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(widget.checkboxText!, style: _checkboxLabelStyle),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: widget.onCancel,
            style: TextButton.styleFrom(
              foregroundColor: JXB.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: Text(widget.cancelText ?? s.cancel),
          ),
          TextButton(
            onPressed: widget.onConfirm,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: JXB.brandPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(JXB.radiusSmall)),
            ),
            child: Text(widget.confirmText ?? s.confirm),
          ),
        ],
      );
    } else {
      return CupertinoAlertDialog(
        title: Text(widget.title, style: _titleStyle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Text(widget.description, textAlign: TextAlign.start, style: _descStyle),
            if (widget.checkboxText != null && widget.checkboxText!.isNotEmpty) ...[
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CupertinoCheckbox(
                    value: _checkboxValue,
                    onChanged: _updateCheckboxValue,
                    activeColor: JXB.brandPrimary,
                  ),
                  const SizedBox(width: 8),
                  Text(widget.checkboxText!, style: _checkboxLabelStyle),
                ],
              ),
            ],
          ],
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: widget.onCancel,
            isDestructiveAction: false,
            child: Text(
              widget.cancelText ?? s.cancel,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textSecondary),
            ),
          ),
          CupertinoDialogAction(
            onPressed: widget.onConfirm,
            isDefaultAction: true,
            child: Text(
              widget.confirmText ?? s.confirm,
              style: const TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 16,
                color: JXB.brandPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    }
  }
}
