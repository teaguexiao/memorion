import 'dart:convert';

import 'package:memorion/backend/preferences.dart';

/// P-01 任务气泡卡的「问过哪条、什么时候问的」本地记录。
///
/// 后端只存 `ActionItem.confirmed`（拍板了没有），不存「问过几次」——因为这是纯展示
/// 节奏，不是用户数据。所以轮换状态只放 SharedPreferences：换设备重新问一遍无所谓，
/// 但同一台机器上不该反复拿同一条烦人。
///
/// key 用「会话 id + 待办描述」而不是下标：下标会因删除/reprocess 整体移位，
/// 描述才是这条待办的身份。
class TaskConfirmRotation {
  TaskConfirmRotation._();

  static const String _kAskedKey = 'taskConfirmAskedAt';

  /// 本地记录保留天数（比 7 天时效窗口留一点余量，方便裁剪）。
  static const int _retentionDays = 30;

  static String keyFor(String conversationId, String description) => '$conversationId|$description';

  /// 记一次「这条已经在气泡卡里露过面了」。
  static void markAsked(String conversationId, String description, [DateTime? at]) {
    final now = at ?? DateTime.now();
    final prefs = SharedPreferencesUtil();
    final map = _read(prefs);
    map[keyFor(conversationId, description)] = now.millisecondsSinceEpoch;
    _write(prefs, map);
  }

  /// 上次问这条的时间；从没问过返回 null。
  static DateTime? lastAskedAt(String conversationId, String description) {
    final ms = _read(SharedPreferencesUtil())[keyFor(conversationId, description)];
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Map<String, int> _read(SharedPreferencesUtil prefs) {
    try {
      final raw = prefs.getString(_kAskedKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as int));
    } catch (_) {
      return {};
    }
  }

  static void _write(SharedPreferencesUtil prefs, Map<String, int> map) {
    final cutoff = DateTime.now().subtract(const Duration(days: _retentionDays)).millisecondsSinceEpoch;
    map.removeWhere((_, ms) => ms < cutoff);
    prefs.saveString(_kAskedKey, jsonEncode(map));
  }
}
