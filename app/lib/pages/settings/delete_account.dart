import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/core/app_shell.dart';
import 'package:memorion/pages/me/export_all_data.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:memorion/utils/other/temp.dart';
import 'package:memorion/widgets/dialog.dart';

/// 删除账户页（数据隐私页 → 删除账户）。
///
/// ⚠️ 1.0 浅色改版：原版整页靠 `Theme.of(context).colorScheme.primary` 当底色
/// （旧深色壳里那是黑），文字全靠深色主题的白字兜底，按钮是上游的四色渐变边框。
/// 现在配色一律走 [JXB]，与账号页 / 数据隐私页同一套。
///
/// 功能刻意保持不变（比账号页的一次性确认弹框更稳妥）：先摊开「会删掉什么」，
/// 给一个导出数据的出口，再要求勾选 + 二次确认。
class DeleteAccount extends StatefulWidget {
  const DeleteAccount({super.key});

  @override
  State<DeleteAccount> createState() => _DeleteAccountState();
}

class _DeleteAccountState extends State<DeleteAccount> {
  bool checkboxValue = false;
  bool isDeleteing = false;

  void updateCheckboxValue(bool value) {
    setState(() {
      checkboxValue = value;
    });
  }

  Future deleteAccountNow() async {
    setState(() {
      isDeleteing = true;
    });
    MixpanelManager().deleteAccountConfirmed();
    MixpanelManager().deleteUser();
    await deleteAccount();
    await FirebaseAuth.instance.signOut();
    SharedPreferencesUtil().clear();
    setState(() {
      isDeleteing = false;
    });
    routeToPage(context, const AppShell(), replace: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return PopScope(
      canPop: !isDeleteing,
      child: Scaffold(
        backgroundColor: JXB.bgApp,
        appBar: AppBar(
          backgroundColor: JXB.bgApp,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: JXB.textPrimary),
          title: Text(s.deleteAccount, style: JXB.sectionTitle),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: JXB.pageMargin),
            child: Column(
              children: [
                const SizedBox(height: 12),
                Text(
                  s.areYouSureDeleteAccount,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: JXB.fontSans,
                    fontSize: 22,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                    color: JXB.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(s.cannotBeUndone,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontFamily: JXB.fontSans, fontSize: 15, height: 1.4, color: JXB.textSecondary)),
                const SizedBox(height: 24),
                Container(
                  decoration: BoxDecoration(
                    color: JXB.surface,
                    borderRadius: BorderRadius.circular(JXB.radiusCard),
                    boxShadow: JXB.cardShadow,
                  ),
                  child: Column(
                    children: [
                      _row(icon: Icons.chat_bubble_outline_rounded, label: s.allDataErased),
                      const Divider(height: 1, thickness: 1, color: JXB.border, indent: 16, endIndent: 16),
                      _row(icon: Icons.person_pin_outlined, label: s.appsDisconnected),
                      const Divider(height: 1, thickness: 1, color: JXB.border, indent: 16, endIndent: 16),
                      _row(
                        icon: Icons.upload_file_outlined,
                        label: s.exportBeforeDelete,
                        onTap: () => exportAllData(context),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // 勾选确认
                GestureDetector(
                  onTap: () => updateCheckboxValue(!checkboxValue),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Checkbox(
                        value: checkboxValue,
                        onChanged: (value) {
                          if (value != null) updateCheckboxValue(value);
                        },
                        activeColor: JXB.error,
                        side: const BorderSide(color: JXB.border, width: 1.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      ),
                      Expanded(
                        child: Text(s.deleteAccountCheckbox,
                            style: const TextStyle(
                                fontFamily: JXB.fontSans, fontSize: 14, height: 1.4, color: JXB.textSecondary)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: JXB.sizeButton,
                  child: isDeleteing
                      ? const Center(child: CircularProgressIndicator(color: JXB.error))
                      : ElevatedButton(
                          onPressed: _onDeletePressed,
                          style: ElevatedButton.styleFrom(
                            // 未勾选时按钮变淡——但仍可点，点了给出「请先勾选」的提示，
                            // 这样「为什么点不动」不用用户自己猜（原版也是这个行为）。
                            backgroundColor: checkboxValue ? JXB.error : JXB.error.withValues(alpha: 0.35),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(JXB.radiusControl)),
                          ),
                          child: Text(
                            s.deleteAccount,
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w600),
                          ),
                        ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onDeletePressed() {
    final s = S.of(context);
    if (!checkboxValue) {
      UndoDeleteHost.showMessage(context, s.checkBoxToConfirm);
      return;
    }
    showDialog(
      context: context,
      builder: (c) => getDialog(
        context,
        () {
          MixpanelManager().deleteAccountCancelled();
          Navigator.of(context).pop();
        },
        () {
          deleteAccountNow();
          Navigator.of(context).pop();
        },
        s.areYouSureFinal,
        s.deleteAccountFinalMessage,
        okButtonText: s.deleteNow,
        cancelButtonText: s.goBack,
      ),
    );
  }

  Widget _row({required IconData icon, required String label, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(JXB.radiusCard),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: JXB.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 15, height: 1.4, color: JXB.textPrimary)),
            ),
            if (onTap != null) const Icon(Icons.chevron_right_rounded, size: 20, color: JXB.textPlaceholder),
          ],
        ),
      ),
    );
  }
}
