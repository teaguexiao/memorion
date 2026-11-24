import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:memorion/backend/preferences.dart';

/// 佩戴时段本地记录（P-01 首页「未佩戴」空档条数据源）。
///
/// ## 为什么要它
/// 首页时光轴会在两段会话之间的空档插一条「这段可能没戴」。旧逻辑只看**会话间隔**：
/// 只要相邻两段会话隔了 >1h 就判未佩戴——但戴着没说话、说了被 discard（媒体内容等）、
/// 或未来离线录音还没同步回来，都会被误判成未佩戴。
///
/// ## 判定模型（取并集，不误报）
/// 一段空档 `[会话结束, 下段会话开始]` 里，真正的未佩戴时长 =
///   空档总长 − （**BLE 连接时段** ∪ **静默时段**）落在这段内的覆盖。
/// 剩余部分才是"确实没设备在覆盖、又不是睡觉"的时间。
///
/// 这个模型同时兼容两种设备形态，无需分支：
/// - **无本地存储（当前硬件）**：只有会话 + BLE 连接记录，空档里减掉「连着的」和
///   「睡觉的」，剩下才显示未佩戴。
/// - **未来有同步机制**：离线音频同步回来会变成新的 conversation，空档本身被会话
///   切碎/填满，未佩戴条自动消失——公式一个字都不用改。
///
/// ## 只存本地（与用户确认过的决策）
/// 这是一份**残缺的近似信号**（iOS 后台杀进程时 disconnect 事件可能发不出去），
/// 存后端也给不出可信的历史真相；长期的历史准确性由后端 conversation（+未来 SD 卡
/// 离线同步）负责。故只用 SharedPreferences 存最近 [_retentionDays] 天的连接时段，
/// 重装/重登录后历史日期没有记录时**不显示**未佩戴条（宁可漏报，不误报）。
///
/// ## BLE 连接 ≈ 佩戴（近似，与用户确认过）
/// 设备连着蓝牙放桌上没戴，BLE 仍是 connected——真正的佩戴检测需硬件传感器
/// （IMU 静止/皮肤触点），当前固件无此能力。这里接受用「BLE 连接与否」作为近似，
/// 故文案措辞留有余地（「可能没戴」而非断言「未佩戴」）。
class WearTracking {
  WearTracking._();

  static const String _kSessionsKey = 'wearBleSessions';
  static const String _kOpenStartKey = 'wearBleOpenSessionStart';

  /// 本地保留天数：超过此天数的时段在写入时裁剪掉。
  static const int _retentionDays = 30;

  /// 兜底闭合上限：一个未闭合的连接时段（app 被系统杀掉、没走到 disconnect 打点）
  /// 最多被算作这么长。偏"漏报不误报"——超过则视为无效，不贡献覆盖。
  static const Duration _maxOpenSession = Duration(hours: 12);

  /// 记一次 BLE 连接开始。
  static void onConnected([DateTime? at]) {
    final now = at ?? DateTime.now();
    final prefs = SharedPreferencesUtil();
    // 若已有未闭合时段（重复 connect 事件），保留较早的开始时间，避免丢覆盖。
    final existing = prefs.getInt(_kOpenStartKey);
    if (existing != null && existing <= now.millisecondsSinceEpoch) return;
    prefs.saveInt(_kOpenStartKey, now.millisecondsSinceEpoch);
  }

  /// 记一次 BLE 断开：闭合当前未闭合时段并落库。
  static void onDisconnected([DateTime? at]) {
    final now = at ?? DateTime.now();
    final prefs = SharedPreferencesUtil();
    final startMs = prefs.getInt(_kOpenStartKey);
    if (startMs == null) return; // 没有开区间，忽略。
    prefs.remove(_kOpenStartKey);
    final start = DateTime.fromMillisecondsSinceEpoch(startMs);
    if (!now.isAfter(start)) return; // 时钟异常，丢弃。
    _appendSession(start, now);
  }

  /// 返回最近记录的 BLE 连接时段（含对未闭合时段的兜底闭合），已按保留期裁剪。
  /// [now] 用于兜底闭合仍开着的时段（测试可注入）。
  static List<DateTimeRange> connectedSessions([DateTime? now]) {
    final ref = now ?? DateTime.now();
    final prefs = SharedPreferencesUtil();
    final sessions = _readSessions(prefs);

    // 兜底闭合：仍开着的时段按 min(now, start + _maxOpenSession) 闭合，只用于计算、不落库。
    final openMs = prefs.getInt(_kOpenStartKey);
    if (openMs != null) {
      final start = DateTime.fromMillisecondsSinceEpoch(openMs);
      final cap = start.add(_maxOpenSession);
      final end = ref.isBefore(cap) ? ref : cap;
      if (end.isAfter(start)) sessions.add(DateTimeRange(start: start, end: end));
    }
    return sessions;
  }

  /// 计算某个空档 `[gapStart, gapEnd]` 内**真正未被覆盖**的时长。
  /// 覆盖 = BLE 连接时段 ∪ 静默时段（睡觉）；返回 gap 总长减去覆盖后的净未佩戴时长。
  static Duration uncoveredDuration(DateTime gapStart, DateTime gapEnd, {DateTime? now}) {
    if (!gapEnd.isAfter(gapStart)) return Duration.zero;
    final covers = <DateTimeRange>[];
    // BLE 连接时段。
    for (final s in connectedSessions(now)) {
      final c = _clip(s, gapStart, gapEnd);
      if (c != null) covers.add(c);
    }
    // 静默时段（可能与空档有多天交叠，逐日切）。
    covers.addAll(_quietRangesWithin(gapStart, gapEnd));

    final merged = _mergeRanges(covers);
    var coveredMs = 0;
    for (final r in merged) {
      coveredMs += r.end.difference(r.start).inMilliseconds;
    }
    final totalMs = gapEnd.difference(gapStart).inMilliseconds;
    return Duration(milliseconds: math.max(0, totalMs - coveredMs));
  }

  // ── 内部工具 ──────────────────────────────────────────────

  static void _appendSession(DateTime start, DateTime end) {
    final prefs = SharedPreferencesUtil();
    final sessions = _readSessions(prefs)..add(DateTimeRange(start: start, end: end));
    // 裁剪保留期外的时段（以结束时间判断）。
    final cutoff = end.subtract(const Duration(days: _retentionDays));
    final kept = sessions.where((s) => s.end.isAfter(cutoff)).toList();
    _writeSessions(prefs, kept);
  }

  static List<DateTimeRange> _readSessions(SharedPreferencesUtil prefs) {
    final raw = prefs.getString(_kSessionsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<dynamic>();
      return list
          .map((e) => DateTimeRange(
                start: DateTime.fromMillisecondsSinceEpoch((e['s'] as num).toInt()),
                end: DateTime.fromMillisecondsSinceEpoch((e['e'] as num).toInt()),
              ))
          .toList();
    } catch (e) {
      debugPrint('[WearTracking] failed to decode sessions: $e');
      return [];
    }
  }

  static void _writeSessions(SharedPreferencesUtil prefs, List<DateTimeRange> sessions) {
    final encoded = jsonEncode(sessions
        .map((s) => {'s': s.start.millisecondsSinceEpoch, 'e': s.end.millisecondsSinceEpoch})
        .toList());
    prefs.saveString(_kSessionsKey, encoded);
  }

  /// 把时段裁剪到 [lo, hi] 窗口内；无交叠返回 null。
  static DateTimeRange? _clip(DateTimeRange r, DateTime lo, DateTime hi) {
    final start = r.start.isAfter(lo) ? r.start : lo;
    final end = r.end.isBefore(hi) ? r.end : hi;
    return end.isAfter(start) ? DateTimeRange(start: start, end: end) : null;
  }

  /// 返回 [lo, hi] 内所有落在用户静默时段（睡觉）里的子区间。
  /// 复用 P-30N 的 quietHours 设置（分钟数，支持跨午夜）。
  static List<DateTimeRange> _quietRangesWithin(DateTime lo, DateTime hi) {
    final prefs = SharedPreferencesUtil();
    if (!prefs.quietHoursEnabled) return [];
    final startMin = prefs.quietHoursStartMinutes;
    final endMin = prefs.quietHoursEndMinutes;
    if (startMin == endMin) return [];

    final result = <DateTimeRange>[];
    // 从 lo 当天前一天开始逐日展开静默窗口（跨午夜的窗口可能起于前一天），
    // 直到超过 hi。
    var day = DateTime(lo.year, lo.month, lo.day).subtract(const Duration(days: 1));
    final limit = DateTime(hi.year, hi.month, hi.day).add(const Duration(days: 2));
    while (day.isBefore(limit)) {
      final winStart = day.add(Duration(minutes: startMin));
      // 同日区间（start<end）：当天 start→end；跨午夜（start>end）：当天 start→次日 end。
      final winEnd = startMin < endMin
          ? day.add(Duration(minutes: endMin))
          : day.add(const Duration(days: 1)).add(Duration(minutes: endMin));
      final clipped = _clip(DateTimeRange(start: winStart, end: winEnd), lo, hi);
      if (clipped != null) result.add(clipped);
      day = day.add(const Duration(days: 1));
    }
    return result;
  }

  /// 合并重叠/相邻的时段。
  static List<DateTimeRange> _mergeRanges(List<DateTimeRange> ranges) {
    if (ranges.isEmpty) return [];
    final sorted = [...ranges]..sort((a, b) => a.start.compareTo(b.start));
    final merged = <DateTimeRange>[sorted.first];
    for (final r in sorted.skip(1)) {
      final last = merged.last;
      if (!r.start.isAfter(last.end)) {
        // 有重叠或相接：并入。
        if (r.end.isAfter(last.end)) {
          merged[merged.length - 1] = DateTimeRange(start: last.start, end: r.end);
        }
      } else {
        merged.add(r);
      }
    }
    return merged;
  }
}
