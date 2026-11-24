import 'dart:convert';

import 'package:memorion/backend/preferences.dart';

/// 到期待办「提醒卡」的本地状态：哪条已被「知晓」（不再提醒）、哪条「稍后提醒」到几点。
///
/// 提醒是纯展示节奏，不是用户数据——后端只存 `ActionItem`（是否 confirmed / completed），
/// 不记「提醒过几次 / 用户点了知晓」。所以这份状态只放 SharedPreferences：换设备重来一遍
/// 无所谓，但同一台机器上，用户点过「知晓」的就别再唠叨，点过「稍后」的半小时内先闭嘴。
///
/// key 用「会话 id + 待办描述」而不是下标：下标会因删除 / reprocess 整体移位，
/// 描述才是这条待办的身份（与 [TaskConfirmRotation] 同理）。
class TaskReminderState {
  TaskReminderState._();

  static const String _kAckKey = 'taskReminderAcknowledged';
  static const String _kSnoozeKey = 'taskReminderSnoozedUntil';

  /// 「稍后提醒」的间隔：半小时后再弹。
  static const Duration snoozeDuration = Duration(minutes: 30);

  /// 本地记录保留天数（与待办时效窗口留余量，方便裁剪陈旧项）。
  static const int _retentionDays = 30;

  static String keyFor(String conversationId, String description) => '$conversationId|$description';

  /// 用户点了「OK / 已经知晓」：这条以后都不再弹提醒（待办本身仍保留）。
  static void acknowledge(String conversationId, String description) {
    final prefs = SharedPreferencesUtil();
    final key = keyFor(conversationId, description);
    final map = _read(prefs, _kAckKey);
    map[key] = DateTime.now().millisecondsSinceEpoch;
    _write(prefs, _kAckKey, map);
    // 知晓即清掉可能存在的 snooze，两份状态不必并存。
    final snooze = _read(prefs, _kSnoozeKey);
    if (snooze.remove(key) != null) _write(prefs, _kSnoozeKey, snooze);
  }

  /// 这条是否已被「知晓」。
  static bool isAcknowledged(String conversationId, String description) {
    return _read(SharedPreferencesUtil(), _kAckKey).containsKey(keyFor(conversationId, description));
  }

  /// 用户点了「稍后提醒我」：[snoozeDuration] 之后才允许再弹这条。
  static void snooze(String conversationId, String description, [DateTime? now]) {
    final until = (now ?? DateTime.now()).add(snoozeDuration);
    final prefs = SharedPreferencesUtil();
    final map = _read(prefs, _kSnoozeKey);
    map[keyFor(conversationId, description)] = until.millisecondsSinceEpoch;
    _write(prefs, _kSnoozeKey, map);
  }

  /// 这条现在是否处于「稍后」静默期内。
  static bool isSnoozed(String conversationId, String description, [DateTime? now]) {
    final ms = _read(SharedPreferencesUtil(), _kSnoozeKey)[keyFor(conversationId, description)];
    if (ms == null) return false;
    return DateTime.fromMillisecondsSinceEpoch(ms).isAfter(now ?? DateTime.now());
  }

  static Map<String, int> _read(SharedPreferencesUtil prefs, String storeKey) {
    try {
      final raw = prefs.getString(storeKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as int));
    } catch (_) {
      return {};
    }
  }

  static void _write(SharedPreferencesUtil prefs, String storeKey, Map<String, int> map) {
    final cutoff = DateTime.now().subtract(const Duration(days: _retentionDays)).millisecondsSinceEpoch;
    map.removeWhere((_, ms) => ms < cutoff);
    prefs.saveString(storeKey, jsonEncode(map));
  }
}
