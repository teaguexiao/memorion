import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/onboarding_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/notification_prefs.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

/// P-30N 通知设置（记小宝 1.0 浅色改版，Figma v2.4 node 431:2036 / 478:744 / 478:805）。
///
/// 三态（读 `Permission.notification.status`）：
/// - granted：正常，提醒开关可用
/// - denied（尚未请求/可再请求）：顶部蓝色「开启通知」引导卡，点击请求权限
/// - permanentlyDenied/restricted：顶部橙色「已在系统设置中关闭」卡 + 前往系统设置；提醒开关置灰
///
/// 数据源：
/// - ✅ 权限状态：`Permission.notification`；请求走 `OnboardingProvider.askForNotificationPermissions`
/// - ✅ 4 个提醒开关 + 静默时段：本地持久化（`SharedPreferencesUtil`）+ 与服务端双向同步。
///   改动后经 `NotificationPrefs.syncToServer()` 上报到 `POST /v1/users/notification-preferences`，
///   启动时 `hydrateFromServer()` 回读一次；服务端「每日一刻」「新发现」推送已 honor
///   对应开关与静默时段。
///
/// 四个开关落在两种通知上，改动时别混：
/// - **服务端 FCM**：每日一刻（本地 22:00）、新发现（本地 10:00）。由后端
///   `notification_gate.py` 读同步上来的偏好决定发不发。
/// - **App 本地通知**：任务提醒（`applyTaskReminderSchedule`，按待办到期时间排）、
///   暂停提醒（断连/服务不可用时即时发）。这两个走 `SharedPreferencesUtil` 本地判定，
///   偏好字段虽然也上传了，但目前没有任何服务端推送用它们。
///
/// ⚠️ **改开关时只上报改动的那几个字段**（`_syncPrefs(changedKeys)`）。全量上报会把当时的
/// 全部默认值一起写进云端，启动回读就分不清「用户设过」和「默认恰好如此」，等于把默认值
/// 固化成用户设置 —— 详见 `NotificationPrefs.syncToServer()`。静默时段的三个字段是一个
/// 语义单元（用户开启开关就接受了当前显示的时间段），用 `quietHoursKeys` 一起报。
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

enum _PermState { granted, denied, blocked }

class _NotificationSettingsPageState extends State<NotificationSettingsPage> with WidgetsBindingObserver {
  final _prefs = SharedPreferencesUtil();
  _PermState _perm = _PermState.granted;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPerm();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置返回时刷新权限态。
    if (state == AppLifecycleState.resumed) _refreshPerm();
  }

  Future<void> _refreshPerm() async {
    final status = await Permission.notification.status;
    if (!mounted) return;
    setState(() {
      if (status.isGranted) {
        _perm = _PermState.granted;
      } else if (status.isPermanentlyDenied || status.isRestricted) {
        _perm = _PermState.blocked;
      } else {
        _perm = _PermState.denied;
      }
      _loading = false;
    });
  }

  Future<void> _requestPermission() async {
    await context.read<OnboardingProvider>().askForNotificationPermissions();
    await _refreshPerm();
    // 授权后按当前开关重排任务提醒（每日一刻是服务端推送，无需本地排期）。
    if (mounted) _applyTaskReminder();
  }

  /// 切换「任务提醒」→ 按当前待办的到期时间排定/取消本地推送。
  void _applyTaskReminder() {
    NotificationPrefs.applyTaskReminderSchedule(context.read<ConversationProvider>().conversations);
  }

  /// 某个开关/静默时段改动后，把**改动的那几个字段**同步到服务端（让服务端推送 honor
  /// 这些开关），并按新的静默时段重排任务提醒（到点落在静默段内的会被撤下，交给 app 内卡片）。
  ///
  /// ⚠️ [changedKeys] 必须只含用户这次真正动了的字段。传全集会让云端记下当时的全部默认值，
  /// 启动回读时就分不清「用户设过」和「默认恰好如此」了 —— 见 `NotificationPrefs.syncToServer`。
  void _syncPrefs(Set<String> changedKeys) {
    NotificationPrefs.syncToServer(changedKeys);
    _applyTaskReminder();
  }

  @override
  Widget build(BuildContext context) {
    final togglesEnabled = _perm == _PermState.granted;
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
                Expanded(
                  child: _loading
                      ? const SizedBox.shrink()
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
                          children: [
                            if (_perm == _PermState.denied) ...[
                              _enableBanner(),
                              const SizedBox(height: 22),
                            ],
                            if (_perm == _PermState.blocked) ...[
                              _blockedBanner(),
                              const SizedBox(height: 22),
                            ],
                            _sectionLabel(revampText(context, en: 'Reminder types', zh: '提醒类型')),
                            const SizedBox(height: 10),
                            _categoryCard(togglesEnabled),
                            const SizedBox(height: 22),
                            _sectionLabel(revampText(context, en: 'Quiet hours', zh: '静默时段')),
                            const SizedBox(height: 10),
                            _quietCard(togglesEnabled),
                            const SizedBox(height: 14),
                            Text(
                              revampText(context,
                                  en: 'No notifications are sent during quiet hours, including device disconnects, paused recording, and sync failures. Please check these states when you open the app.',
                                  zh: '静默时段内不发送任何通知，设备断连、录音暂停与同步失败也不例外。请在打开 App 时查看这些状态。'),
                              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, height: 1.55, color: JXB.textPlaceholder),
                            ),
                          ],
                        ),
                ),
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
              child: Text(revampText(context, en: 'Notifications', zh: '通知设置'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            const SizedBox(width: 36),
          ],
        ),
      ),
    );
  }

  // ── 蓝色「开启通知」引导卡（denied 态）─────────────────────────
  Widget _enableBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x0F007AFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: JXB.brandPrimary, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🔔', style: TextStyle(fontSize: 17)),
              const SizedBox(width: 8),
              Text(revampText(context, en: 'Turn on notifications', zh: '开启通知'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
              revampText(context,
                  en: 'Turn this on so we can remind you to check your Daily Moment, task due dates, and new discoveries.',
                  zh: '开启后才能提醒你查看每日一刻、任务到期和新发现。'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _requestPermission,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 42, alignment: Alignment.center,
              decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
              child: Text(revampText(context, en: 'Turn on notifications', zh: '开启通知'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  // ── 橙色「系统已关闭」卡（blocked 态）─────────────────────────
  Widget _blockedBanner() {
    const orange = Color(0xFFF2841A);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x14F2841A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: orange, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('⚠️', style: TextStyle(fontSize: 15)),
              const SizedBox(width: 8),
              Text(revampText(context, en: 'Notifications are turned off in Settings', zh: '通知已在系统设置中关闭'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
              revampText(context,
                  en: 'Memorion can\'t send notifications. Please turn them back on in Settings.',
                  zh: 'Memorion 无法发送通知。请在系统设置中重新开启。'), // i18n-ignore: 中文文案，含品牌名误判
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () => openAppSettings(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 42, alignment: Alignment.center,
              decoration: BoxDecoration(
                color: JXB.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: orange, width: 1),
              ),
              child: Text(revampText(context, en: 'Open Settings', zh: '前往系统设置'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: orange)),
            ),
          ),
        ],
      ),
    );
  }

  // ── 提醒类型卡 ──────────────────────────────────────────────
  // 四个都是真实开关。任务提醒排 App 本地通知（applyTaskReminderSchedule），
  // 其余三个见类注释里的「两种通知」分类。
  //
  // 「每日一刻」= 服务端日记推送，用户本地 22:00（Modal `memorion-daily-summary`）。
  // 「新发现」= 后端涌现式洞察引擎的洞察卡推送（`_send_insight_push`，Modal cron 本地 10:00 判定）。
  // 两个开关改动后都经 NotificationPrefs.syncToServer() 上报，后端发推前会读偏好
  //（notifDailyMoment / notifMilestone / 静默时段）决定是否推送（见 backend/utils/notification_gate.py）。
  Widget _categoryCard(bool enabled) {
    return _card([
      _toggleRow(
          revampText(context, en: 'Daily Moment', zh: '每日一刻'),
          revampText(context, en: 'Your diary for the day, at 22:00', zh: '每天 22:00 送上当天的日记'),
          _prefs.notifDailyMoment,
          (v) => setState(() {
                _prefs.notifDailyMoment = v;
                _syncPrefs({'daily_moment'});
              }), enabled),
      _divider(),
      _toggleRow(
          revampText(context, en: 'Task reminders', zh: '任务提醒'),
          revampText(context, en: 'Reminds you when a to-do is due', zh: '待办到期时提醒你'),
          _prefs.notifTaskReminder,
          (v) => setState(() {
                _prefs.notifTaskReminder = v;
                _applyTaskReminder();
                _syncPrefs({'task_reminder'});
              }), enabled),
      _divider(),
      _toggleRow(
          revampText(context, en: 'Pause alerts', zh: '暂停提醒'),
          revampText(context, en: 'Alerts you when recording pauses unexpectedly or the connection drops', zh: '录音意外暂停或连接中断时提醒'),
          _prefs.notifPauseReminder,
          (v) => setState(() {
                _prefs.notifPauseReminder = v;
                _syncPrefs({'pause_reminder'});
              }), enabled),
      _divider(),
      _toggleRow(
          revampText(context, en: 'New discoveries', zh: '新发现'),
          revampText(context, en: 'Reminds you when there\'s a new discovery about you', zh: '有新的、关于你的发现时提醒'),
          _prefs.notifMilestone,
          (v) => setState(() {
                _prefs.notifMilestone = v;
                _syncPrefs({'milestone'});
              }), enabled),
    ]);
  }

  Widget _toggleRow(String title, String subtitle, bool value, ValueChanged<bool> onChanged, bool enabled) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                  const SizedBox(height: 3),
                  Text(subtitle, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch.adaptive(
              value: value,
              activeTrackColor: JXB.success,
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }

  // ── 静默时段卡 ─────────────────────────────────────────────
  Widget _quietCard(bool enabled) {
    final on = _prefs.quietHoursEnabled;
    final start = _fmtMinutes(_prefs.quietHoursStartMinutes);
    final end = _fmtMinutes(_prefs.quietHoursEndMinutes);
    return _card([
      Opacity(
        opacity: enabled ? 1 : 0.4,
        child: SizedBox(
          height: 61,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(revampText(context, en: 'Quiet hours', zh: '静默时段'),
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                    const SizedBox(height: 3),
                    Text(
                        revampText(context,
                            en: 'No notifications from $start to $end next day',
                            zh: '$start 至次日 $end 不发送通知'),
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch.adaptive(
                value: on,
                activeTrackColor: JXB.success,
                onChanged: enabled
                    ? (v) => setState(() {
                          _prefs.quietHoursEnabled = v;
                          _syncPrefs(NotificationPrefs.quietHoursKeys);
                        })
                    : null,
              ),
            ],
          ),
        ),
      ),
      if (on) ...[
        _divider(),
        _timeRow(revampText(context, en: 'Start time', zh: '开始时间'), _prefs.quietHoursStartMinutes, (m) => setState(() {
              _prefs.quietHoursStartMinutes = m;
              _syncPrefs(NotificationPrefs.quietHoursKeys);
            }), enabled),
        _divider(),
        _timeRow(revampText(context, en: 'End time', zh: '结束时间'), _prefs.quietHoursEndMinutes, (m) => setState(() {
              _prefs.quietHoursEndMinutes = m;
              _syncPrefs(NotificationPrefs.quietHoursKeys);
            }), enabled),
      ],
    ]);
  }

  Widget _timeRow(String label, int minutes, ValueChanged<int> onPicked, bool enabled) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        onTap: enabled ? () => _pickTime(label, minutes, onPicked) : null,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              Expanded(
                child: Text(label, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
              ),
              Text(_fmtMinutes(minutes),
                  style: const TextStyle(fontFamily: JXB.fontNumber, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }

  /// 点击时间行 → 弹浅色数字输入框（时 / 分，只能填数字），无时钟。
  Future<void> _pickTime(String label, int minutes, ValueChanged<int> onPicked) async {
    final hourCtrl = TextEditingController(text: (minutes ~/ 60).toString().padLeft(2, '0'));
    final minCtrl = TextEditingController(text: (minutes % 60).toString().padLeft(2, '0'));
    final result = await showDialog<int>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 44),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
          decoration: BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [BoxShadow(color: Color(0x1F264D78), blurRadius: 30, offset: Offset(0, 12))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _timeField(hourCtrl, revampText(context, en: 'HH', zh: '时'), 23),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text(':', style: TextStyle(fontFamily: JXB.fontNumber, fontSize: 28, fontWeight: FontWeight.w700, color: JXB.textPlaceholder)),
                  ),
                  _timeField(minCtrl, revampText(context, en: 'MM', zh: '分'), 59),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 46, alignment: Alignment.center,
                        decoration: BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(context, en: 'Cancel', zh: '取消'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        final h = (int.tryParse(hourCtrl.text) ?? 0).clamp(0, 23);
                        final m = (int.tryParse(minCtrl.text) ?? 0).clamp(0, 59);
                        Navigator.pop(ctx, h * 60 + m);
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 46, alignment: Alignment.center,
                        decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(context, en: 'Confirm', zh: '确定'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
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
    if (result != null) onPicked(result);
  }

  Widget _timeField(TextEditingController ctrl, String hint, int max) {
    return SizedBox(
      width: 72,
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 2,
        autofocus: false,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontFamily: JXB.fontNumber, fontSize: 26, fontWeight: FontWeight.w700, color: JXB.textPrimary),
        decoration: InputDecoration(
          counterText: '',
          hintText: hint,
          hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPlaceholder),
          filled: true,
          fillColor: JXB.bgApp,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: JXB.brandPrimary, width: 1.5)),
        ),
      ),
    );
  }

  String _fmtMinutes(int m) {
    final h = (m ~/ 60) % 24;
    final min = m % 60;
    return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
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
}
