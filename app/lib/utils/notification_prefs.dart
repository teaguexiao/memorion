import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/notifications.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/services/notifications/notification_service.dart';
import 'package:memorion/utils/localization_helper.dart';

/// 通知偏好网关（P-30N）。
///
/// 集中处理"客户端能自己落地"的通知逻辑：
/// - **静默时段**：`isQuietHoursNow()` 判断当前是否处于用户设置的免打扰时段
///   （支持跨午夜，默认 23:00→08:00）；`gate()` 在发送前统一拦截。
/// - **任务提醒**：`applyTaskReminderSchedule()` 为「已确认、未完成、有确切到期时间且到期
///   在未来」的待办排本地推送；到点落在静默时段内的不排，交给 app 内提醒卡兜底。
/// - **暂停提醒**：`shouldSendPauseReminder()` 供各断连/服务不可用检测点在发通知前判断
///   （开关关 or 处于静默时段则不发）。
///
/// 每日一刻由服务端在用户本地 22:00 推送。
///
/// **服务端推送**：`syncToServer()` 把这些开关上报到 `POST /v1/users/notification-preferences`，
/// 后端在发「每日一刻」(day_summary) 和「新发现」(insight_card) 推送前会 honor 对应开关
/// 与静默时段（见 backend/utils/notification_gate.py）。开关一改动就同步一次。
///
/// **双向同步**：`hydrateFromServer()` 在启动时回读一次（`GET` 同一个端点），修的是
/// 「重装 App / 换机后本地回到默认值、而云端仍是上次设的值」—— 设置页显示开着、服务端
/// 其实不推，用户无从自查。
///
/// ⚠️ **回读只覆盖服务端 `stored_keys` 里的字段。** 响应里的 `preferences` 总是全字段
/// （缺的按服务端默认补齐），无脑覆盖等于把服务端此刻的默认值固化成用户设置 —— 之后改
/// 默认值对这批用户永久无效。判定逻辑在 `resolveServerOverrides()`。
class NotificationPrefs {
  NotificationPrefs._();

  /// 当前是否处于静默时段（开关开 + 落在起止区间内，支持跨午夜）。
  static bool isQuietHoursNow([DateTime? now]) => isQuietHoursAt(now ?? DateTime.now());

  /// 指定时刻是否落在静默时段内（供排定未来通知时预判，支持跨午夜）。
  static bool isQuietHoursAt(DateTime t) {
    final prefs = SharedPreferencesUtil();
    if (!prefs.quietHoursEnabled) return false;
    final cur = t.hour * 60 + t.minute;
    final start = prefs.quietHoursStartMinutes;
    final end = prefs.quietHoursEndMinutes;
    if (start == end) return false;
    if (start < end) {
      // 同日区间，如 08:00→22:00
      return cur >= start && cur < end;
    }
    // 跨午夜区间，如 22:00→08:00
    return cur >= start || cur < end;
  }

  /// 「暂停提醒」是否应发送：开关开 + 不在静默时段。
  static bool shouldSendPauseReminder() {
    return SharedPreferencesUtil().notifPauseReminder && !isQuietHoursNow();
  }

  /// 服务端偏好 key 全集（= 后端 `NOTIFICATION_PREFERENCES_DEFAULTS` 的 key）。
  static const Set<String> allServerKeys = {..._serverBoolKeys, ..._serverMinuteKeys};

  /// 静默时段的三个字段。用户开启静默开关时就接受了当前显示的起止时间，所以三者作为
  /// 一个语义单元一起上报 —— 只报 `enabled` 会让服务端拿它自己的默认区间去判定。
  static const Set<String> quietHoursKeys = {
    'quiet_hours_enabled',
    'quiet_hours_start_minutes',
    'quiet_hours_end_minutes',
  };

  /// 读某个服务端 key 对应的本地当前值。与 `hydrateFromServer` 的写入分支对称。
  static Object? _localValueFor(String serverKey) {
    final prefs = SharedPreferencesUtil();
    switch (serverKey) {
      case 'daily_moment':
        return prefs.notifDailyMoment;
      case 'task_reminder':
        return prefs.notifTaskReminder;
      case 'pause_reminder':
        return prefs.notifPauseReminder;
      case 'milestone':
        return prefs.notifMilestone;
      case 'quiet_hours_enabled':
        return prefs.quietHoursEnabled;
      case 'quiet_hours_start_minutes':
        return prefs.quietHoursStartMinutes;
      case 'quiet_hours_end_minutes':
        return prefs.quietHoursEndMinutes;
    }
    return null;
  }

  /// 构建上报 body：只含 [changedKeys] 里的已知字段，取本地当前值。
  ///
  /// 抽成独立函数是为了能单测「有没有多发字段」—— 多发是静默的，服务端照样返回 200。
  static Map<String, Object> buildSyncPayload(Set<String> changedKeys) {
    final out = <String, Object>{};
    for (final key in changedKeys) {
      // 拼错的 key 不发，别让它静默变成一次空写。这层是双保险 —— `_localValueFor` 对
      // 未知 key 也返回 null，删掉这行行为不变（所以针对它的变异测试不会红）。留着是为了
      // 让「只发已知字段」在这个函数里就读得出来，不必去追 _localValueFor 的实现。
      if (!allServerKeys.contains(key)) continue;
      final value = _localValueFor(key);
      if (value != null) out[key] = value;
    }
    return out;
  }

  /// 把**本次改动的**偏好上报到服务端（fire-and-forget，失败不影响本地）。
  ///
  /// ⚠️ **只发改动的字段，别图省事全量上报。** 后端是合并写入，所以云端只会积累用户真正
  /// 设置过的 key，`GET` 返回的 `stored_keys` 才有意义。全量上报的话，用户随便动一个开关
  /// 就把 7 个字段连同**当时的默认值**一起写进云端 → `stored_keys` 退化成全集 →
  /// `hydrateFromServer()` 那层「只覆盖用户设过的字段」的防护对**除了从没同步过的人以外
  /// 的所有用户**失效，等于把当时的默认值固化成用户设置。这个链条上两个函数各自都是对的。
  ///
  /// ⚠️ **存量用户的云端已经是全集**（2026-08-12 之前是全量上报），他们的固化无法挽回。
  /// 好在那份值正是他们上次离开设置页时看到的状态，回读回去与预期一致；受影响的只是
  /// 「将来改默认值对他们不生效」。
  static Future<void> syncToServer(Set<String> changedKeys) async {
    await saveNotificationPreferencesServer(buildSyncPayload(changedKeys));
  }

  // ---- 服务端回读（双向同步的「下行」半边）----

  /// 服务端偏好 key → 本地类型。用来挡住类型不对的值，别把本地存储写坏。
  static const Set<String> _serverBoolKeys = {
    'daily_moment',
    'task_reminder',
    'pause_reminder',
    'milestone',
    'quiet_hours_enabled',
  };
  static const Set<String> _serverMinuteKeys = {
    'quiet_hours_start_minutes',
    'quiet_hours_end_minutes',
  };

  /// 把 `GET /v1/users/notification-preferences` 的响应收敛成「该覆盖到本地的字段」。
  ///
  /// 纯函数（不读不写 SharedPreferences），因为要判定的东西全在这里、而副作用没法在
  /// 单测里观察。规则：
  /// - **只取 `stored_keys` 列出的 key** —— 见类注释，这是整个回读最容易写错的一点；
  /// - 类型不符（bool key 收到数字之类）直接丢弃，而不是强转；
  /// - 分钟数越界（不在 0..1439）丢弃 —— 存进去不会崩，但静默时段判定会一直不成立；
  /// - 未知 key 忽略，这样后端加字段不会让老版本 App 写出脏数据。
  static Map<String, Object> resolveServerOverrides(Map<String, dynamic>? payload) {
    if (payload == null) return const {};
    final prefs = payload['preferences'];
    final storedKeys = payload['stored_keys'];
    if (prefs is! Map || storedKeys is! List) return const {};

    final out = <String, Object>{};
    for (final key in storedKeys) {
      if (key is! String) continue;
      final value = prefs[key];
      if (_serverBoolKeys.contains(key) && value is bool) {
        out[key] = value;
      } else if (_serverMinuteKeys.contains(key) && value is int && value >= 0 && value < 24 * 60) {
        out[key] = value;
      }
    }
    return out;
  }

  /// 启动时回读一次服务端偏好，覆盖用户确实设置过的字段。
  ///
  /// 失败（离线、未登录、非 200）时什么都不做 —— 宁可显示旧值，也不要把设置页清成默认。
  ///
  /// ⚠️ **任务提醒受影响时必须清一次已排定的本地通知。** 那些提醒是按回读**之前**的开关
  /// 和静默时段排的，回读把 `task_reminder` 关掉或挪动静默区间后，它们照样会响。
  /// 清掉之后交给 `applyTaskReminderSchedule()` 在下次拉到会话时按新值重排（它幂等）。
  static Future<void> hydrateFromServer() async {
    final overrides = resolveServerOverrides(await fetchNotificationPreferencesServer());
    if (overrides.isEmpty) return;

    final prefs = SharedPreferencesUtil();
    var affectsTaskReminders = false;
    overrides.forEach((key, value) {
      switch (key) {
        case 'daily_moment':
          prefs.notifDailyMoment = value as bool;
        case 'task_reminder':
          if (prefs.notifTaskReminder != value) affectsTaskReminders = true;
          prefs.notifTaskReminder = value as bool;
        case 'pause_reminder':
          prefs.notifPauseReminder = value as bool;
        case 'milestone':
          prefs.notifMilestone = value as bool;
        case 'quiet_hours_enabled':
          if (prefs.quietHoursEnabled != value) affectsTaskReminders = true;
          prefs.quietHoursEnabled = value as bool;
        case 'quiet_hours_start_minutes':
          if (prefs.quietHoursStartMinutes != value) affectsTaskReminders = true;
          prefs.quietHoursStartMinutes = value as int;
        case 'quiet_hours_end_minutes':
          if (prefs.quietHoursEndMinutes != value) affectsTaskReminders = true;
          prefs.quietHoursEndMinutes = value as int;
      }
    });

    if (affectsTaskReminders) _clearScheduledTaskReminders();
    if (kDebugMode) {
      debugPrint('[NotifPrefs] hydrated from server: ${overrides.keys.join(",")}'
          '${affectsTaskReminders ? " (task reminders cleared, will re-schedule)" : ""}');
    }
  }

  /// 通用发送网关：静默时段内一律不发（对齐设计文案：设备断连/录音暂停/同步失败也不例外）。
  /// [enabled] 传入对应类别开关；返回 true 表示允许发送。
  static bool gate({required bool enabled}) {
    return enabled && !isQuietHoursNow();
  }

  /// 撤销旧版本留在系统里的废弃通知及重复排期，覆盖安装也需要执行。
  static Future<void> clearRetiredLocalNotifications() async {
    // 跌倒、SD 卡处理完成、本地日记提醒、数据保护迁移。
    for (final id in [6, 8, 1001, 1337]) {
      NotificationService.instance.clearNotification(id);
    }
  }

  // ---- 任务提醒（到期待办本地推送）----

  /// 任务提醒本地通知的 id 区间基址。1000 以下被断连/连接类占用，1001 是每日一刻，
  /// 这里从 2_000_000 起，用「会话 id + 描述」哈希落到区间内，避免撞号。
  static const int _taskReminderIdBase = 2000000;
  static const int _taskReminderIdSpan = 1000000;

  /// 由「会话 id + 待办描述」派生稳定的通知 id（同一条待办每次重排落同一个 id）。
  static int taskReminderIdFor(String conversationId, String description) {
    final hash = '$conversationId|$description'.hashCode & 0x7fffffff;
    return _taskReminderIdBase + (hash % _taskReminderIdSpan);
  }

  /// 按「任务提醒」开关，为到期待办排定/取消本地推送。
  ///
  /// 规则（与 app 内提醒卡对齐）：
  /// - 只排 **已确认、未完成、未删除、有确切 dueDate 且 dueDate 在未来** 的待办
  ///   （已到点/逾期的排不了过去的推送，靠 app 内卡片兜底）；
  /// - 落在静默时段内的到期时刻不排系统推送（同样靠 app 内卡片兜底，避免免打扰被打破）；
  /// - 开关关 / 无权限：全部取消，不排新的。
  ///
  /// 每次调用先取消上轮排定的所有 id，再按当前会话重排——幂等，可在每次拉到会话后调用。
  /// 撤下上一轮排定的全部任务提醒。排期存在系统侧，不主动 cancel 就会按旧的开关/静默
  /// 时段继续响 —— 所以「关掉开关」和「回读改了开关」两条路径都要走这里。
  static void _clearScheduledTaskReminders() {
    final prefs = SharedPreferencesUtil();
    final svc = NotificationService.instance;
    for (final idStr in prefs.scheduledTaskReminderIds) {
      final id = int.tryParse(idStr);
      if (id != null) svc.clearNotification(id);
    }
    prefs.scheduledTaskReminderIds = [];
  }

  static Future<void> applyTaskReminderSchedule(List<ServerConversation> conversations) async {
    final prefs = SharedPreferencesUtil();
    final svc = NotificationService.instance;

    // 先清掉上一轮排定的，避免已完成/已删除的待办残留提醒。
    _clearScheduledTaskReminders();

    if (!prefs.notifTaskReminder) return;
    if (!await svc.hasNotificationPermissions()) return;

    final now = DateTime.now();
    final scheduled = <String>[];
    for (final convo in conversations) {
      if (convo.discarded) continue;
      for (final item in convo.structured.actionItems) {
        if (item.deleted || item.completed || !item.confirmed) continue;
        final due = item.dueDate;
        if (due == null || !due.isAfter(now)) continue; // 只排未来到点的
        if (isQuietHoursAt(due)) continue; // 到点时正处静默，交给 app 内卡片

        final id = taskReminderIdFor(convo.id, item.description);
        if (scheduled.contains(id.toString())) continue; // 同 id 去重（哈希碰撞或重复待办）

        svc.showNotification(
          id: id,
          title: appT((s) => s.notifTaskReminderTitle, '记小宝提醒'),
          body: item.description,
          payload: {'navigate_to': '/promises'},
          wakeUpScreen: false,
          schedule: NotificationCalendar.fromDate(date: due, allowWhileIdle: true, preciseAlarm: true),
        );
        scheduled.add(id.toString());
      }
    }
    prefs.scheduledTaskReminderIds = scheduled;
    if (kDebugMode) debugPrint('[NotifPrefs] task reminders scheduled: ${scheduled.length}');
  }

  /// 用户点「稍后提醒我」：排一条 [delay] 后的一次性本地推送（默认半小时）。
  /// 同样尊重开关/权限/静默时段——落在静默段内则不发系统推送（app 内卡片届时仍会兜底）。
  static Future<void> scheduleSnoozedReminder(
    String conversationId,
    String description, {
    Duration delay = const Duration(minutes: 30),
  }) async {
    final prefs = SharedPreferencesUtil();
    if (!prefs.notifTaskReminder) return;
    final svc = NotificationService.instance;
    if (!await svc.hasNotificationPermissions()) return;

    final fireAt = DateTime.now().add(delay);
    if (isQuietHoursAt(fireAt)) return;

    svc.showNotification(
      id: taskReminderIdFor(conversationId, description),
      title: appT((s) => s.notifTaskReminderTitle, '记小宝提醒'),
      body: description,
      payload: {'navigate_to': '/promises'},
      wakeUpScreen: false,
      schedule: NotificationCalendar.fromDate(date: fireAt, allowWhileIdle: true, preciseAlarm: true),
    );
  }
}
