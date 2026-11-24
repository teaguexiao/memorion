import 'package:flutter/material.dart';
import 'package:memorion/backend/auth.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/pages/today_chapters/data_privacy_page.dart';
import 'package:memorion/pages/today_chapters/device_detail_page.dart';
import 'package:memorion/pages/today_chapters/about_page.dart';
import 'package:memorion/pages/today_chapters/account_page.dart';
import 'package:memorion/pages/today_chapters/authorization_settings_page.dart';
import 'package:memorion/pages/today_chapters/developer_page.dart';
import 'package:memorion/pages/today_chapters/device_pairing_page.dart';
import 'package:memorion/pages/today_chapters/notification_settings_page.dart';
import 'package:memorion/pages/today_chapters/people_page.dart';
import 'package:memorion/pages/today_chapters/recording_device_page.dart';
import 'package:memorion/pages/today_chapters/speech_profile_intro_page.dart';
import 'package:memorion/pages/today_chapters/subscription_page.dart';
import 'package:memorion/pages/today_chapters/vocabulary_page.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

/// P-30 我·设置（记小宝 1.0 浅色改版，Figma v2.4 node 343:15622）。
///
/// 入口：顶栏右上角齿轮 → 这里。
/// 结构：账户头卡（真实姓名/邮箱/陪伴天数）+ 分组列表 + 版本页脚。
///
/// 数据源：
/// - ✅ 姓名/邮箱：`SharedPreferencesUtil().givenName / email`
/// - ✅ 陪伴天数：Firebase `User.metadata.creationTime` 起算（无则 --）
/// - ✅ 版本：`PackageInfo.fromPlatform()`
/// - 录音与同步管理统一从设备详情进入。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _version = '';
  String _buildNumber = '';
  int? _companionDays;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadCompanionDays();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _version = info.version;
        _buildNumber = info.buildNumber;
      });
    }
  }

  void _loadCompanionDays() {
    try {
      final user = getFirebaseUser();
      final created = user?.metadata.creationTime;
      if (created != null) {
        final days = DateTime.now().difference(created).inDays;
        _companionDays = days < 0 ? 0 : days;
      }
    } catch (_) {
      _companionDays = null;
    }
  }

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
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                  width: 36, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary)),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Me', zh: '我'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            const SizedBox(width: 36),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
      children: [
        _accountHeader(context),
        const SizedBox(height: 20),
        _sectionLabel(revampText(context, en: 'Membership', zh: '会员与订阅')),
        const SizedBox(height: 10),
        _card([
          _navRow(
            revampText(context, en: 'Subscription', zh: '订阅'),
            () => _push(context, const SubscriptionPage()),
          ),
        ]),
        const SizedBox(height: 20),
        _sectionLabel(revampText(context, en: 'Device', zh: '设备')),
        const SizedBox(height: 10),
        _card([
          _navRow(revampText(context, en: 'Device & Firmware', zh: '设备与固件'), () => _openDevice(context)),
        ]),
        const SizedBox(height: 20),
        _sectionLabel(revampText(context, en: 'Recording & Recognition', zh: '录音与识别')),
        const SizedBox(height: 10),
        _card([
          _navRow(revampText(context, en: 'Recording Device', zh: '录音设备'),
              () => _push(context, const RecordingDevicePage())),
          _divider(),
          _navRow(revampText(context, en: 'Voice Training', zh: '声纹训练'),
              () => _push(context, const SpeechProfileIntroPage())),
          _divider(),
          _navRow(revampText(context, en: 'Recognize Others', zh: '识别其他人'), () => _push(context, const PeoplePage())),
          _divider(),
          _navRow(revampText(context, en: 'Vocabulary', zh: '词库管理'), () => _push(context, const VocabularyPage())),
        ]),
        const SizedBox(height: 20),
        _sectionLabel(revampText(context, en: 'Reminders', zh: '提醒')),
        const SizedBox(height: 10),
        _card([
          _navRow(revampText(context, en: 'Notifications', zh: '通知'),
              () => _push(context, const NotificationSettingsPage())),
        ]),
        const SizedBox(height: 20),
        _sectionLabel(revampText(context, en: 'General', zh: '通用')),
        const SizedBox(height: 10),
        _card([
          _navRow(revampText(context, en: 'Permissions', zh: '授权设置'),
              () => _push(context, const AuthorizationSettingsPage())),
          _divider(),
          _navRow(
              revampText(context, en: 'Privacy & Data', zh: '隐私与数据'), () => _push(context, const DataPrivacyPage())),
          _divider(),
          _navRow(revampText(context, en: 'Developer', zh: '开发者'), () => _push(context, const DeveloperPage())),
          _divider(),
          _navRow(revampText(context, en: 'About', zh: '关于'), () => _push(context, const AboutPage())),
        ]),
        const SizedBox(height: 24),
        Center(
          child: Text(_versionFooter,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
        ),
      ],
    );
  }

  // ── 账户头卡 ────────────────────────────────────────────────
  Widget _accountHeader(BuildContext context) {
    final name = SharedPreferencesUtil().givenName.trim();
    final email = SharedPreferencesUtil().email.trim();
    final displayName = name.isEmpty ? 'Memorion' : name;
    final initial = displayName.characters.first.toUpperCase();
    return GestureDetector(
      onTap: () => _push(context, const AccountPage()),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: JXB.border, width: 1)),
        child: Row(
          children: [
            // 首字母渐变头像（暂无真实 photoURL）
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [JXB.brandSecondary, JXB.brandPrimary],
                ),
              ),
              child: Text(initial,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                  if (email.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 陪伴天数
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(_companionDays?.toString() ?? '--',
                    style: const TextStyle(
                        fontFamily: JXB.fontNumber,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: JXB.brandPrimary)),
                const SizedBox(height: 2),
                Text(revampText(context, en: 'Days Together', zh: '陪伴天数'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textSecondary)),
              ],
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, size: 20, color: JXB.textPlaceholder),
          ],
        ),
      ),
    );
  }

  // ── 通用行/卡/分组 ──────────────────────────────────────────
  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(text,
          style: const TextStyle(
              fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
    );
  }

  Widget _card(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: children),
    );
  }

  Widget _divider() => const Divider(height: 1, color: JXB.border);

  Widget _navRow(String title, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: JXB.textPlaceholder),
          ],
        ),
      ),
    );
  }

  String get _versionFooter {
    if (_version.isEmpty) return 'Memorion';
    return 'Memorion v$_version (Build $_buildNumber)'; // i18n-ignore: 品牌名+版本号，无需翻译
  }

  // ── 跳转 ────────────────────────────────────────────────────
  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _openDevice(BuildContext context) {
    final dp = context.read<DeviceProvider>();
    final paired = dp.pairedDevice != null;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => paired ? const DeviceDetailPage() : const DevicePairingPage(),
    ));
  }
}
