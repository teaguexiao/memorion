import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/http/api/calendar.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/pages/today_chapters/calendar_ai_consent_sheet.dart';
import 'package:memorion/services/apple_calendar_service.dart';
import 'package:memorion/services/apple_reminders_service.dart';
import 'package:memorion/services/calendar_sync_service.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:permission_handler/permission_handler.dart';

/// P-05 授权设置（记小宝 1.0 浅色改版，Figma v2.4 node 455:727）。
///
/// 两项系统授权的最小化展示与真实请求：
/// - iOS 日历（只读）：`Permission.calendarFullAccess`
/// - 提醒事项（只写，仅 iOS）：`Permission.reminders`
///
/// 开关开启 → 触发系统权限请求弹窗；开关关闭（已授权时）→ 系统权限一旦授予
/// App 内无法直接撤销，引导跳系统设置（浅色确认弹框，对齐 P-06 结束确认风格）。
class AuthorizationSettingsPage extends StatefulWidget {
  const AuthorizationSettingsPage({super.key});

  @override
  State<AuthorizationSettingsPage> createState() => _AuthorizationSettingsPageState();
}

class _AuthorizationSettingsPageState extends State<AuthorizationSettingsPage> {
  bool _calendarGranted = false;
  bool _remindersGranted = false;
  bool _loading = true;
  bool _calendarSyncing = false;
  CalendarSyncState? _calendarSyncState;
  /// 哪些卡片的说明当前是展开的（按 title 记）。默认全部收起。
  final Set<String> _expandedDesc = {};
  late final _LifecycleRefresher _lifecycleObserver;

  @override
  void initState() {
    super.initState();
    _lifecycleObserver = _LifecycleRefresher(_refreshStatus);
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    _refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    bool calendarGranted = false;
    bool remindersGranted = false;
    if (Platform.isIOS) {
      // 两项都优先走原生 EventKit 通道（与实际读写路径一致）。
      // permission_handler 只用于判 permanentlyDenied。
      calendarGranted = await AppleCalendarService().hasPermission();
      remindersGranted = await AppleRemindersService().hasPermission();
    } else {
      final calendarStatus = await Permission.calendarFullAccess.status;
      calendarGranted = calendarStatus.isGranted || calendarStatus.isLimited;
    }

    if (!mounted) return;
    setState(() {
      // 开关"开"必须同时满足系统权限与同意：用户可能在设置里给了权限却没同意
      // 数据上传，那时同步器一条都不会传，开关显示开就是在骗人。
      //
      // 这里先用本地同意缓存，服务端那份在下面异步回读。
      _calendarGranted = calendarGranted && CalendarAiConsent.granted;
      _remindersGranted = remindersGranted;
      _loading = false;
    });

    if (_calendarGranted) {
      _loadCalendarSyncState();
    } else if (_calendarSyncState != null) {
      setState(() => _calendarSyncState = null);
    }

    await _syncConsentFromServer(calendarGranted);
  }

  /// 回读服务端那份同意（真相源），与本地缓存不一致时再更新一次开关。
  ///
  /// 不这么做的后果正是本页最初的 bug：系统权限记在 iOS 侧、跨重装保留，而同意
  /// 只存在本地沙盒里、重装即丢 —— 日历开关于是回到"关"，同页的提醒事项（只看
  /// 系统权限）却还是"开"，看起来像 iOS 单独忘了日历权限。
  ///
  /// ⚠️ **必须排在首屏渲染之后**。`_loading` 期间整页 body 是 `SizedBox.shrink()`，
  /// 把这个网络往返放进首屏路径，弱网下用户就是几秒白屏（模拟器上实测：一次 401
  /// 自愈重发就够看见）—— 而这一页的两个开关本地查一下就能画出来。
  Future<void> _syncConsentFromServer(bool systemPermission) async {
    final consentGranted = await CalendarAiConsent.refreshFromServer();
    if (!mounted) return;

    final granted = systemPermission && consentGranted;
    if (granted == _calendarGranted) return;

    setState(() {
      _calendarGranted = granted;
      if (!granted) _calendarSyncState = null;
    });
    if (granted) _loadCalendarSyncState();
  }

  Future<void> _loadCalendarSyncState() async {
    final state = await fetchCalendarSyncState();
    if (!mounted) return;
    setState(() => _calendarSyncState = state);
  }

  /// 用户刚授权后立刻同步一次，让开关打开这个动作有可见结果
  /// （否则用户不知道生效没有）。
  Future<void> _syncCalendarNow() async {
    if (_calendarSyncing) return;
    setState(() => _calendarSyncing = true);
    try {
      await CalendarSyncService().syncNow(force: true);
      if (!mounted) return;
      await _loadCalendarSyncState();
    } finally {
      if (mounted) setState(() => _calendarSyncing = false);
    }
  }

  String _calendarStatusLine() {
    if (_calendarSyncing) return revampText(context, en: 'Syncing…', zh: '正在同步…');
    final state = _calendarSyncState;
    if (state?.syncedAt == null) {
      return revampText(context, en: 'Not synced yet', zh: '尚未同步');
    }
    final count = state!.eventCount;
    final ago = _relativeTime(state.syncedAt!);
    return revampText(context, en: 'Synced $count events · $ago', zh: '已同步 $count 个日程 · $ago');
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 2) return revampText(context, en: 'just now', zh: '刚刚');
    if (diff.inHours < 1) return revampText(context, en: '${diff.inMinutes}m ago', zh: '${diff.inMinutes} 分钟前');
    if (diff.inDays < 1) return revampText(context, en: '${diff.inHours}h ago', zh: '${diff.inHours} 小时前');
    return revampText(context, en: '${diff.inDays}d ago', zh: '${diff.inDays} 天前');
  }

  Future<void> _toggleCalendar(bool value) async {
    if (value) {
      HapticFeedback.lightImpact();

      // 先要同意再要权限。顺序是刻意的：数据流向要在用户做任何授权决定**之前**
      // 讲清楚，而不是先骗到系统权限再补告知。不同意就到此为止，连系统弹窗都不弹。
      final outcome = await CalendarAiConsent.ensure(context);
      if (!mounted) return;
      if (outcome == CalendarConsentOutcome.failed) {
        // 用户明明点了"同意并同步"，不能就这么没反应。
        _showConsentFailedDialog();
        return;
      }
      if (outcome != CalendarConsentOutcome.granted) return;

      // 走原生 EventKit 通道：iOS 17+ 读日历要的是 full access，原生侧已兼容。
      if (Platform.isIOS) {
        await AppleCalendarService().requestPermission();
      } else {
        await Permission.calendarFullAccess.request();
      }
      if (!mounted) return;
      // 授权弹窗关闭到状态更新有窗口期，留一小段延迟再重拉真实状态。
      await Future.delayed(const Duration(milliseconds: 250));
      await _refreshStatus();
      if (!mounted) return;
      if (_calendarGranted) {
        await _syncCalendarNow();
      } else {
        final phStatus = await Permission.calendarFullAccess.status;
        if (!mounted) return;
        if (phStatus.isPermanentlyDenied) {
          _showGoToSettingsDialog(revampText(context, en: 'Calendar', zh: '日历'));
        }
      }
    } else {
      await _turnCalendarOff();
    }
  }

  /// 关闭日历：撤回同意 + 删除服务端已同步的数据。
  ///
  /// 系统权限本身 App 内撤销不了（只能引导去设置），但**我们自己存的那份必须
  /// 当场删掉** —— 否则"关掉开关"只是停止新增，已上传的内容还躺在服务器上，
  /// 那不构成撤回同意（5.1.1(ii)、GDPR Art. 7(3)）。
  ///
  /// 撤同意与删数据是服务端的**同一次请求**，所以不会出现"同意撤了数据还在"或
  /// 反过来的半截状态。
  Future<void> _turnCalendarOff() async {
    HapticFeedback.lightImpact();
    setState(() => _calendarSyncing = true);
    bool deleted = false;
    try {
      deleted = await CalendarAiConsent.revoke();
      if (deleted) {
        // 节流状态也要清：留着的话下次重新开启会被判成"刚同步过"而不上传。
        SharedPreferencesUtil().calendarLastSyncedAt = null;
        SharedPreferencesUtil().calendarLastSyncFingerprint = '';
      }
    } finally {
      if (mounted) {
        setState(() {
          _calendarSyncing = false;
          if (deleted) {
            // ⚠️ 开关必须跟着变关，别照抄提醒事项那条路。提醒事项的开关就是纯系统
            // 权限，App 关不掉，所以它"只弹去设置、开关不动"是对的；日历的开关是
            // `系统权限 ∧ 同意` 的合取，而同意这一半刚刚已经撤掉了。漏掉这一行，
            // 开关会停在"开"而 CalendarSyncService 的闸门已经关闭 —— 显示在同步、
            // 实际一条都不传，跟这次要修的 bug 是同一种骗人，只是方向相反。
            _calendarGranted = false;
            _calendarSyncState = null;
          }
        });
      }
    }
    if (!mounted) return;

    if (!deleted) {
      // 删除失败就不撤回同意 —— 宁可让开关还开着，也不能让用户以为数据已经删了。
      _showDeleteFailedDialog();
      return;
    }
    // 数据已清，剩下的是系统权限本身，只能去设置里关。
    _showCalendarStoppedDialog();
  }

  /// 同意没能记到服务端。同意必须是服务端可查的记录，本地写一下不算数
  /// （见 `CalendarAiConsent.ensure`），所以这里只能请用户重试。
  void _showConsentFailedDialog() {
    _confirmDialog(
      icon: Icons.cloud_off_rounded,
      iconColor: JXB.brandPrimary,
      iconBg: const Color(0x14007AFF),
      title: revampText(context, en: 'Couldn\'t save your choice', zh: '未能保存你的选择'),
      body: revampText(context,
          en: 'We couldn\'t record your consent because the request failed. Please check your connection and try again.',
          zh: '请求失败，未能记录你的同意。请检查网络后重试。'),
      confirmLabel: revampText(context, en: 'Retry', zh: '重试'),
      confirmColor: JXB.brandPrimary,
      onConfirm: () => _toggleCalendar(true),
    );
  }

  void _showDeleteFailedDialog() {
    _confirmDialog(
      icon: Icons.cloud_off_rounded,
      iconColor: JXB.brandPrimary,
      iconBg: const Color(0x14007AFF),
      title: revampText(context, en: 'Couldn\'t delete synced events', zh: '未能删除已同步的日程'),
      body: revampText(context,
          en: 'Your synced calendar events are still on our servers because the request failed. Please check your connection and try again.',
          zh: '请求失败，已同步的日程仍在我们的服务器上。请检查网络后重试。'),
      confirmLabel: revampText(context, en: 'Retry', zh: '重试'),
      confirmColor: JXB.brandPrimary,
      onConfirm: _turnCalendarOff,
    );
  }

  Future<void> _toggleReminders(bool value) async {
    if (value) {
      HapticFeedback.lightImpact();
      // 走项目原生 EventKit 通道，权威且与实际使用路径一致
      await AppleRemindersService().requestPermission();
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 250));
      await _refreshStatus();
      if (!mounted) return;
      if (!_remindersGranted) {
        // 原生通道返回 false 且刷新后依旧未授予，说明被拒或被永久拒绝
        // permission_handler 用来判断 permanentlyDenied 依然可靠
        final phStatus = await Permission.reminders.status;
        if (phStatus.isPermanentlyDenied) {
          if (!mounted) return;
          _showGoToSettingsDialog(revampText(context, en: 'Reminders', zh: '提醒事项'));
        }
      }
    } else {
      _showRevokeDialog(revampText(context, en: 'Reminders', zh: '提醒事项'));
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
                Expanded(child: _loading ? const SizedBox.shrink() : _body(context)),
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
              child: const SizedBox(width: 36, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary)),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Permissions', zh: '授权设置'),
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        _sectionLabel(revampText(context, en: 'System permissions', zh: '系统授权')),
        const SizedBox(height: 10),
        _permCard(
          title: revampText(context, en: 'iOS Calendar', zh: 'iOS 日历'),
          // 文案必须在**做授权决定的这一刻**说明数据会离开设备。放在隐私页里
          // 不够——用户不一定看到，而且那不是决策点（5.1.2(ii) 目的外使用）。
          desc: revampText(context,
              en: 'Reads events only — titles, times, locations — and syncs them to our server so Ask can reference your schedule. Notes and attendees are never read. Never adds, edits, or deletes.',
              zh: '只读取日程的标题、时间和地点，并同步到我们的服务器，供 Ask 参考你的行程。备注和参会人不会被读取。不会新增、修改或删除。'),
          value: _calendarGranted,
          onChanged: _toggleCalendar,
          // 已授权时展示同步结果 —— 开关打开必须有可见反馈。
          // 只读不可点：同步是自动的（开启时立刻同步 + 之后按 _minInterval 节流），
          // 给个「立即同步」按钮会让用户以为不点就不同步。
          statusLine: _calendarGranted ? _calendarStatusLine() : null,
          toggleId: 'calendar_toggle',
        ),
        const SizedBox(height: 14),
        _permCard(
          title: revampText(context, en: 'Reminders', zh: '提醒事项'),
          desc: Platform.isIOS
              ? revampText(context,
                  en: 'Only writes completed to-dos to Reminders; never reads your reminders.',
                  zh: '仅把已完成的待办写入提醒事项，不读取你的提醒内容。')
              : revampText(context,
                  en: 'Only writes completed to-dos to Reminders; never reads your reminders. (iOS only for now)',
                  zh: '仅把已完成的待办写入提醒事项，不读取你的提醒内容。（当前仅 iOS 支持）'),
          value: _remindersGranted,
          onChanged: Platform.isIOS ? _toggleReminders : null,
          toggleId: 'reminders_toggle',
        ),
        const SizedBox(height: 22),
        _sectionLabel(revampText(context, en: 'Notes', zh: '说明')),
        const SizedBox(height: 10),
        _noteCard(),
      ],
    );
  }

  /// 权限卡。
  ///
  /// 说明文字默认收起：这些文案为了满足披露要求必须写全（数据去哪、读什么、
  /// 不读什么），铺开就有四五行，把整页压成一堵字墙。折到标题旁的问号后面，
  /// 想看的人点一下就有，不看的人只面对「标题 + 开关」这一个决定。
  ///
  /// 注意 desc 仍**始终存在于 widget 树**（只是折叠），不是懒加载 —— 屏幕阅读器
  /// 与「查找页面内容」仍能拿到它，披露不因折叠而消失。
  Widget _permCard({
    required String title,
    required String desc,
    required bool value,
    required ValueChanged<bool>? onChanged,
    String? statusLine,
    required String toggleId,
  }) {
    final expanded = _expandedDesc.contains(title);
    return Opacity(
      opacity: onChanged == null ? 0.5 : 1,
      child: Container(
        // 垂直 padding 收到 12：说明折叠后卡片只剩一行，16 的上下留白会把
        // 标题挤成"矮胖卡片里的一条小字"。行高由 Switch（约 48）决定，这里
        // 只需要让标题不贴边。
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 17/w600 而不是 16/w700：这一行是页面的主操作项（配一个开关），
                // 不是区块标头。同页 _sectionLabel 才是标头。原来的 16/w700 在
                // 说明文字展开时看着像标头，说明一折叠就显小 —— 加大字号、
                // 减轻字重，让它读起来是"条目"。
                Text(title, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                const SizedBox(width: 6),
                Semantics(
                  button: true,
                  expanded: expanded,
                  label: revampText(context, en: 'About $title', zh: '关于$title'),
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() {
                        if (expanded) {
                          _expandedDesc.remove(title);
                        } else {
                          _expandedDesc.add(title);
                        }
                      });
                    },
                    behavior: HitTestBehavior.opaque,
                    // 图标只有 18px，靠 padding 把点击区撑到 ~34px 满足最小触控尺寸。
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        expanded ? Icons.help_rounded : Icons.help_outline_rounded,
                        size: 18,
                        color: expanded ? JXB.brandPrimary : JXB.textPlaceholder,
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                // identifier 映射成 iOS 的 accessibilityIdentifier，让 UI 测试能直接
                // 断言开关本身（`id: calendar_toggle` + value 1/0）。原来只能靠状态行
                // 在不在来反推开关状态 —— 而那正好漏掉过一个真 bug：撤回同意后状态行
                // 消失了、开关却还开着，断言「已同步」不可见照样通过。
                Semantics(
                  identifier: toggleId,
                  child: Switch.adaptive(
                    value: value,
                    activeTrackColor: JXB.success,
                    onChanged: onChanged,
                  ),
                ),
              ],
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 160),
              firstCurve: Curves.easeOut,
              secondCurve: Curves.easeOut,
              sizeCurve: Curves.easeOut,
              crossFadeState: expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
              firstChild: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(desc,
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, height: 1.5, color: JXB.textSecondary)),
              ),
              secondChild: const SizedBox(width: double.infinity),
            ),
            if (statusLine != null) ...[
              // 6 而不是 10：状态行是标题的附属信息，要读成一组；说明折叠后
              // 10px 会让它浮在卡片中间像独立一行。
              const SizedBox(height: 6),
              Text(statusLine,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12.5, color: JXB.textPlaceholder)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _noteCard() {
    final notes = isRevampChinese(context)
        ? const [
            '关闭授权后立即停止使用对应来源。',
            '可随时在 iOS 系统设置中撤销权限。',
          ]
        : const [
            'Turning a permission off stops using that source immediately.',
            'You can revoke permissions anytime in iOS Settings.', // i18n-ignore: revampText 英文侧文案
          ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      child: Column(
        children: [
          for (int i = 0; i < notes.length; i++) ...[
            if (i != 0) const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 7),
                  child: SizedBox(width: 5, height: 5, child: DecoratedBox(decoration: BoxDecoration(color: JXB.textPlaceholder, shape: BoxShape.circle))),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(notes[i], style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── 浅色弹框（对齐 P-06 结束确认风格）─────────────────────────
  void _showGoToSettingsDialog(String permName) {
    _confirmDialog(
      icon: Icons.settings_rounded,
      iconColor: JXB.brandPrimary,
      iconBg: const Color(0x14007AFF),
      title: revampText(context, en: 'Enable in Settings', zh: '需要在系统设置中开启'),
      body: revampText(context,
          en: '$permName permission was denied. Please enable it manually in Settings and try again.',
          zh: '$permName权限已被拒绝。请前往系统设置手动开启后再试。'),
      confirmLabel: revampText(context, en: 'Open Settings', zh: '前往设置'),
      confirmColor: JXB.brandPrimary,
      onConfirm: openAppSettings,
    );
  }

  void _showRevokeDialog(String permName) {
    _confirmDialog(
      icon: Icons.info_outline_rounded,
      iconColor: JXB.brandPrimary,
      iconBg: const Color(0x14007AFF),
      title: revampText(context, en: 'Turn off in Settings?', zh: '前往系统设置关闭？'),
      body: revampText(context,
          en: '$permName permission is granted and can\'t be revoked from within the app. You can turn it off in iOS Settings.',
          zh: '$permName权限已授予，App 内无法直接撤销。可前往 iOS 系统设置中关闭。'),
      confirmLabel: revampText(context, en: 'Open Settings', zh: '前往设置'),
      confirmColor: JXB.brandPrimary,
      onConfirm: openAppSettings,
    );
  }

  /// 日历关掉后的收尾。**不能用 `_showRevokeDialog`**：那句「权限已授予，App 内无法
  /// 直接撤销」对提醒事项是准确的（那个开关就是纯系统权限），对日历是错的——此刻同意
  /// 已撤回、服务端日程已删、开关已经变关。照搬会让用户以为什么都没关掉，而恰恰漏掉
  /// 撤回同意里最该讲清的那一句：**你的数据已经删了**（5.1.1(ii)、GDPR Art. 7(3)）。
  ///
  /// 剩下的确实只有系统读取权限，那部分照旧只能引导去设置。
  void _showCalendarStoppedDialog() {
    _confirmDialog(
      icon: Icons.info_outline_rounded,
      iconColor: JXB.brandPrimary,
      iconBg: const Color(0x14007AFF),
      title: revampText(context, en: 'Sync stopped', zh: '已停止同步'),
      body: revampText(context,
          en: 'The calendar events previously synced to our servers have been deleted, and nothing more will be synced. iOS still grants calendar read access, which can\'t be revoked from within the app — you can turn that off in iOS Settings.',
          zh: '已删除此前同步到我们服务器上的日程，之后也不会再同步。iOS 的日历读取权限仍然授予着，App 内无法撤销；如需一并收回，可前往 iOS 系统设置中关闭。'),
      confirmLabel: revampText(context, en: 'Open Settings', zh: '前往设置'),
      confirmColor: JXB.brandPrimary,
      onConfirm: openAppSettings,
    );
  }

  Future<void> _confirmDialog({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String body,
    required String confirmLabel,
    required Color confirmColor,
    required Future<void> Function() onConfirm,
  }) async {
    final ok = await showDialog<bool>(
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
              Text(title, textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
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
    if (ok == true) {
      await onConfirm();
      await _refreshStatus();
    }
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(text, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
    );
  }
}

/// 从系统设置返回时刷新权限状态。
class _LifecycleRefresher extends WidgetsBindingObserver {
  final Future<void> Function() onResume;
  _LifecycleRefresher(this.onResume);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}
