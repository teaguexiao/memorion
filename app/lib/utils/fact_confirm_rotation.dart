import 'dart:convert';

import 'package:memorion/backend/preferences.dart';

/// 「关于我」页待确认事实气泡卡的「问过哪条、什么时候问的」本地记录。
///
/// 后端只存 `Memory.user_review`（拍板了没有：没错/不对/没表态），不存「问过几次」——
/// 因为这是纯展示节奏，不是用户数据。所以轮换状态只放 SharedPreferences：换设备
/// 重新问一遍无所谓，但同一台机器上不该反复拿同一条事实烦人。
///
/// key 用事实 id（memories 的文档 id 稳定，一条事实对应一个 id），不像待办要用
/// 「会话 id + 描述」——待办存在对话内嵌数组里、下标会移位，事实是独立集合各有 id。
///
/// 与 `TaskConfirmRotation` 是两套独立记录（不同 pref key），互不影响。
class FactConfirmRotation {
  FactConfirmRotation._();

  static const String _kAskedKey = 'factConfirmAskedAt';

  /// 本地记录保留天数。事实不设时效窗口，这个只是给陈旧记录做裁剪，防止无限增长。
  static const int _retentionDays = 30;

  /// 记一次「这条事实已经在气泡卡里露过面了」。
  static void markAsked(String memoryId, [DateTime? at]) {
    final now = at ?? DateTime.now();
    final prefs = SharedPreferencesUtil();
    final map = _read(prefs);
    map[memoryId] = now.millisecondsSinceEpoch;
    _write(prefs, map);
  }

  /// 上次问这条的时间；从没问过返回 null。
  static DateTime? lastAskedAt(String memoryId) {
    final ms = _read(SharedPreferencesUtil())[memoryId];
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
