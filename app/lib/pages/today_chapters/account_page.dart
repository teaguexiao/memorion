import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/auth.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/core/app_shell.dart';
import 'package:memorion/pages/today_chapters/ui_language_page.dart';
import 'package:memorion/providers/home_provider.dart';
import 'package:memorion/providers/insights_provider.dart';
import 'package:memorion/providers/locale_provider.dart';
import 'package:memorion/providers/moments_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:memorion/utils/diary_image_cache.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// P-30 账户（记小宝 1.0 浅色改版，Figma v2.4 node 481:727）。
///
/// 入口：P-30「我·设置」顶部账户头卡点击进入（原是直接弹改名面板）。
///
/// 数据源：
/// - ✅ 姓名/邮箱/用户 ID：`SharedPreferencesUtil`
/// - ✅ 语言：`LocaleProvider`（→ 浅色 `UiLanguagePage`）
/// - ✅ 时区：`HomeProvider.userTimezone`（选择走本文件里的浅色时区 sheet。当初不复用
///   旧深色 `TimezoneSelectionDialog` 是因为 profile.dart/me_page.dart 还在共用它；
///   那两个页面和那个组件都已随旧壳删除，这里不必再改）
/// - ✅ 退出登录 / 删除用户：复刻现有真实流程（signOut / deleteAccount），
///   浅色二次确认弹框（对齐 P-06 结束确认弹框风格）。
class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: JXB.bgApp,
          body: SafeArea(
            child: Column(
              children: [
                _detailBar(context),
                Expanded(child: _body(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailBar(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            GestureDetector(
              onTap: _busy ? null : () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(width: 36, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary)),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Account', zh: '账户'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            const SizedBox(width: 36),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final name = SharedPreferencesUtil().givenName.trim();
    final uid = SharedPreferencesUtil().uid;
    final localeProvider = context.watch<LocaleProvider>();
    final homeProvider = context.watch<HomeProvider>();

    String langDisplay;
    switch (localeProvider.currentLocaleCode) {
      case 'zh':
        langDisplay = '中文（简体）'; // i18n-ignore: 语言名用自身语言显示
        break;
      case 'en':
        langDisplay = 'English';
        break;
      default:
        langDisplay = revampText(context, en: 'Follow System', zh: '跟随系统');
    }

    String tzDisplay = revampText(context, en: 'Not Set', zh: '未设置');
    final currentTz = homeProvider.userTimezone;
    if (currentTz.isNotEmpty) {
      final entry = HomeProvider.availableTimezones.entries.where((e) => e.value == currentTz).firstOrNull;
      tzDisplay = entry?.key ?? currentTz;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        _sectionLabel(revampText(context, en: 'Account Info', zh: '账户信息')),
        const SizedBox(height: 10),
        _card([
          _navRow(revampText(context, en: 'Name', zh: '姓名'), name.isEmpty ? 'Memorion' : name, () => _showNameSheet(context, name)),
          _divider(),
          _navRow(revampText(context, en: 'Language', zh: '语言'), langDisplay, () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UiLanguagePage()))),
          _divider(),
          _navRow(revampText(context, en: 'Timezone', zh: '时区'), tzDisplay, () => _showTimezoneSheet(context, homeProvider)),
          _divider(),
          _idRow(uid),
        ]),
        const SizedBox(height: 22),

        _button(
          label: revampText(context, en: 'Sign Out', zh: '退出登录'),
          onTap: () => _confirmSignOut(context),
          bg: JXB.surface,
          fg: JXB.textPrimary,
          border: JXB.border,
        ),
        const SizedBox(height: 12),
        _button(
          label: revampText(context, en: 'Delete Account', zh: '删除用户'),
          onTap: () => _confirmDeleteAccount(context),
          bg: const Color(0x0FE55247),
          fg: JXB.error,
          border: const Color(0x80E55247),
        ),
        const SizedBox(height: 10),
        Text(revampText(context, en: 'Deletion permanently erases your account and cloud data. This cannot be undone.', zh: '删除后永久清除账户和云端数据，操作不可恢复。'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder)),
      ],
    );
  }

  Widget _idRow(String uid) {
    return GestureDetector(
      onTap: uid.isEmpty
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: uid));
              UndoDeleteHost.showMessage(context, revampText(context, en: 'User ID copied', zh: '已复制用户 ID'));
            },
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(revampText(context, en: 'User ID', zh: '用户 ID'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(uid.isEmpty ? '--' : uid,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontFamily: JXB.fontNumber, fontSize: 13, height: 1.4, color: JXB.textSecondary)),
            ),
            const SizedBox(width: 6),
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.copy_rounded, size: 15, color: JXB.textPlaceholder),
            ),
          ],
        ),
      ),
    );
  }

  // ── 改名（浅色底部输入 sheet）─────────────────────────────
  Future<void> _showNameSheet(BuildContext context, String currentName) async {
    final controller = TextEditingController(text: currentName);
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: const BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 18),
              Text(revampText(context, en: 'Edit Name', zh: '修改姓名'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 40,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPrimary),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: revampText(context, en: 'Enter your name', zh: '输入姓名'),
                  hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPlaceholder),
                  filled: true,
                  fillColor: JXB.bgApp,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: JXB.brandPrimary, width: 1.5)),
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => Navigator.pop(ctx, true),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 48, alignment: Alignment.center,
                  decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
                  child: Text(revampText(context, en: 'Save', zh: '保存'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final name = controller.text.trim();
    if (confirmed != true || name.isEmpty) return;
    HapticFeedback.lightImpact();
    await updateGivenName(name);
    if (mounted) setState(() {});
  }

  // ── 时区（浅色底部选择 sheet，搜索 + 列表）───────────────────
  Future<void> _showTimezoneSheet(BuildContext context, HomeProvider homeProvider) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => _TimezoneLightSheet(homeProvider: homeProvider),
    );
    if (mounted) setState(() {});
  }

  // ── 退出登录 ────────────────────────────────────────────────
  Future<void> _confirmSignOut(BuildContext context) async {
    // 弹框前取 provider：清空跨账号会残留的状态——否则下个账号会看到上一个账号的
    // 洞察，且 isInitialized 残留会让它不再拉取。
    final insights = context.read<InsightsProvider>();
    // 日记同理：Provider 的内存态 + 磁盘配图都要清。只清 shared_preferences
    // （clearUserPreferences 做的那份）清不到已构造的 Provider，也清不到
    // cache manager 的独立目录，下个账号会先看到上一个账号的日记和配图。
    final moments = context.read<MomentsProvider>();
    final ok = await _confirmDialog(
      context,
      icon: Icons.logout_rounded,
      iconColor: JXB.brandPrimary,
      iconBg: const Color(0x14007AFF),
      title: revampText(context, en: 'Sign Out?', zh: '退出登录？'),
      body: revampText(context, en: 'You\'ll need to sign in again to use Memorion.', zh: '退出后需要重新登录才能使用记小宝。'),
      confirmLabel: revampText(context, en: 'Sign Out', zh: '退出'),
      confirmColor: JXB.brandPrimary,
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    insights.clear();
    await moments.clearCache();
    await DiaryImageCache.clear();
    await SharedPreferencesUtil().clearUserPreferences();
    await signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppShell()),
      (route) => false,
    );
  }

  // ── 删除账户 ────────────────────────────────────────────────
  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final insights = context.read<InsightsProvider>(); // 弹框前取，同 _confirmSignOut
    final moments = context.read<MomentsProvider>(); // 同上
    final ok = await _confirmDialog(
      context,
      icon: Icons.delete_forever_rounded,
      iconColor: JXB.error,
      iconBg: const Color(0x14E55247),
      title: revampText(context, en: 'Delete Account?', zh: '删除用户？'),
      body: revampText(context, en: 'This permanently deletes your account and all cloud data, and unpairs your device. It cannot be undone.', zh: '将永久删除账户和云端全部数据，解除设备配对，此操作不可恢复。'),
      confirmLabel: revampText(context, en: 'Delete', zh: '删除'),
      confirmColor: JXB.error,
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    MixpanelManager().deleteAccountConfirmed();
    MixpanelManager().deleteUser();
    insights.clear();
    await moments.clearCache();
    await DiaryImageCache.clear();
    await deleteAccount();
    await FirebaseAuth.instance.signOut();
    await SharedPreferencesUtil().clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppShell()),
      (route) => false,
    );
  }

  // ── 通用浅色二次确认弹框（对齐 P-06 结束确认风格）───────────
  Future<bool?> _confirmDialog(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String body,
    required String confirmLabel,
    required Color confirmColor,
  }) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          decoration: BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [BoxShadow(color: Color(0x1F264D78), blurRadius: 30, offset: Offset(0, 12))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56, height: 56, alignment: Alignment.center,
                decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
                child: Icon(icon, size: 28, color: iconColor),
              ),
              const SizedBox(height: 16),
              Text(title, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 8),
              Text(body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, false),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 48, alignment: Alignment.center,
                        decoration: BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(context, en: 'Cancel', zh: '取消'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, true),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 48, alignment: Alignment.center,
                        decoration: BoxDecoration(color: confirmColor, borderRadius: BorderRadius.circular(999)),
                        child: Text(confirmLabel,
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 通用 ────────────────────────────────────────────────────
  Widget _card(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: children),
    );
  }

  Widget _divider() => const Divider(height: 1, color: JXB.border);

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(text, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
    );
  }

  Widget _navRow(String title, String value, VoidCallback onTap) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(title, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.4, color: JXB.textSecondary)),
            ),
            const SizedBox(width: 4),
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.chevron_right_rounded, size: 18, color: JXB.textPlaceholder),
            ),
          ],
        ),
      ),
    );
  }

  Widget _button({required String label, required VoidCallback onTap, required Color bg, required Color fg, required Color border}) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999), border: Border.all(color: border, width: 1)),
        child: _busy
            ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
            : Text(label, style: TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: fg)),
      ),
    );
  }
}

/// 浅色时区选择 sheet（搜索 + 列表）。语言选择 sheet
/// （`settings/language_selection_dialog.dart`）与它同形态、同一套配色。
class _TimezoneLightSheet extends StatefulWidget {
  final HomeProvider homeProvider;
  const _TimezoneLightSheet({required this.homeProvider});

  @override
  State<_TimezoneLightSheet> createState() => _TimezoneLightSheetState();
}

class _TimezoneLightSheetState extends State<_TimezoneLightSheet> {
  late List<MapEntry<String, String>> _all;
  late List<MapEntry<String, String>> _filtered;
  String? _selected;
  bool _saving = false;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _all = HomeProvider.availableTimezones.entries.toList();
    _filtered = List.from(_all);
    _selected = widget.homeProvider.userTimezone.isNotEmpty ? widget.homeProvider.userTimezone : null;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filter(String query) {
    final q = query.toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? List.from(_all)
          : _all.where((tz) => tz.key.toLowerCase().contains(q) || tz.value.toLowerCase().contains(q)).toList();
    });
  }

  String _globeForTz(String tz) {
    if (tz.startsWith('America')) return '🌎';
    if (tz.startsWith('Europe') || tz.startsWith('Africa')) return '🌍';
    return '🌏';
  }

  Future<void> _select(MapEntry<String, String> tz) async {
    setState(() {
      _selected = tz.value;
      _saving = true;
    });
    final ok = await widget.homeProvider.updateUserTimezone(tz.value);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      UndoDeleteHost.showMessage(context, revampText(context, en: 'Timezone updated', zh: '已更新时区'));
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) Navigator.of(context).pop();
    } else {
      UndoDeleteHost.showMessage(context, revampText(context, en: 'Failed to set timezone, please try again later', zh: '设置时区失败，请稍后再试'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.85;
    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: const BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36, height: 4,
            margin: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(revampText(context, en: 'Timezone', zh: '时区'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 30, height: 30, alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Color(0x14808594), shape: BoxShape.circle),
                    child: const Icon(Icons.close_rounded, size: 16, color: JXB.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _filter,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPrimary),
              decoration: InputDecoration(
                filled: true,
                fillColor: JXB.bgApp,
                hintText: revampText(context, en: 'Search timezone', zh: '搜索时区'),
                hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPlaceholder),
                prefixIcon: const Icon(Icons.search_rounded, size: 20, color: JXB.textPlaceholder),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: _filtered.isEmpty
                ? Center(child: Text(revampText(context, en: 'No matching timezone found', zh: '没有找到匹配的时区'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: _filtered.length,
                    itemBuilder: (context, index) {
                      final tz = _filtered[index];
                      final isSelected = _selected == tz.value;
                      return GestureDetector(
                        onTap: _saving ? null : () => _select(tz),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          margin: const EdgeInsets.symmetric(vertical: 1),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0x14007AFF) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              SizedBox(width: 28, child: Text(_globeForTz(tz.value), style: const TextStyle(fontSize: 20), textAlign: TextAlign.center)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(tz.key, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
                                    const SizedBox(height: 1),
                                    Text(tz.value, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
                                  ],
                                ),
                              ),
                              if (isSelected) const Icon(Icons.check_rounded, size: 18, color: JXB.brandPrimary),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
