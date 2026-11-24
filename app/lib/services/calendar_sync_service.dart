import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/calendar.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/models/calendar_event.dart';
import 'package:memorion/services/apple_calendar_service.dart';

/// 把系统日历镜像到服务端，让 chat agent 知道用户的行程。
///
/// 静默运行，没有 UI：App 启动和回前台时触发一次，未授权就直接跳过。
/// 日历只读——本服务永远不写回设备。
class CalendarSyncService {
  static final CalendarSyncService _instance = CalendarSyncService._internal();
  factory CalendarSyncService() => _instance;
  CalendarSyncService._internal();

  /// 同步窗口：过去 7 天 + 未来 60 天。
  ///
  /// 往前留一周，是为了 agent 能回答"我上周三见的谁"这类回顾问题；往后 60 天
  /// 覆盖绝大多数已排定的日程。窗口越大每次整窗重写的成本越高，别随手放大。
  static const _pastWindow = Duration(days: 7);
  static const _futureWindow = Duration(days: 60);

  /// 最小同步间隔。回前台可能很频繁（切个 App 就触发），没必要每次都打后端。
  static const _minInterval = Duration(minutes: 30);

  bool _syncing = false;

  /// 执行一次同步。
  ///
  /// [force] 为 true 时忽略时间间隔与指纹检查（用于用户刚授权、或调试探针）。
  /// **[force] 不能绕过同意闸门** —— 那是合规约束，不是性能优化。
  ///
  /// 返回 null 表示本轮跳过（未同意/未授权/未到间隔/内容未变/正在同步中）。
  Future<CalendarSyncResult?> syncNow({bool force = false}) async {
    final calendar = AppleCalendarService();
    if (!calendar.isAvailable) return null;

    // 并发保护：回前台和启动可能几乎同时触发，两轮整窗重写会互相踩。
    if (_syncing) {
      debugPrint('[calendar-sync] already running, skip');
      return null;
    }

    final prefs = SharedPreferencesUtil();

    // 本机没有决定记录（刚重装、刚换号）时先回读服务端那份。
    //
    // 同意的真相源在服务端（见 `CalendarAiConsent`）：本地缓存跟着 App 沙盒走、
    // 重装即丢，而系统日历权限记在 iOS 侧、不会丢。不回读的话用户得再手动开一次
    // 开关——那正是"每装一次新版日历就要重开"的来源。
    //
    // 只在"从未决定"时问，不是每次启动都问：明确的 false 是用户按过"暂不同意"，
    // 不该反复发请求；明确的 true 直接用，真被别的设备撤回了服务端会 409 挡掉。
    if (prefs.calendarAiConsentDecision == null) {
      // 读不到（请求失败，或后端还没上 consent_granted 这个字段）就保持未决定，
      // 下次启动再试；绝不默认成已同意。
      final remote = (await fetchCalendarSyncState())?.consentGranted;
      if (remote != null) prefs.calendarAiConsentGranted = remote;
    }

    // 同意闸门：日程会离开设备并被送给第三方 AI 供应商，系统日历权限**不**代表
    // 用户同意了这件事。App Review 5.1.2(i) 要求事前取得明确许可，所以这里挡在
    // 最前面，且刻意不受 force 影响 —— 没有任何调用方能跳过它。
    if (!prefs.calendarAiConsentGranted) {
      debugPrint('[calendar-sync] no AI-sharing consent, skip');
      return null;
    }

    if (!force) {
      final last = prefs.calendarLastSyncedAt;
      if (last != null && DateTime.now().difference(last) < _minInterval) {
        return null;
      }
    }

    // 不主动请求权限：授权时机由授权设置页掌握，同步器只在已授权时工作，
    // 否则用户会在莫名其妙的时刻被弹框。
    if (!await calendar.hasPermission()) {
      debugPrint('[calendar-sync] no permission, skip');
      return null;
    }

    _syncing = true;
    try {
      final now = DateTime.now();
      final windowStart = now.subtract(_pastWindow);
      final windowEnd = now.add(_futureWindow);

      final events = await calendar.getEvents(start: windowStart, end: windowEnd);
      final active = events.where(_shouldUpload).toList();

      // 读取量单独记一行：上传失败时也要能看出"到底是没读到，还是没传上去"。
      debugPrint('[calendar-sync] read ${events.length} from device, ${active.length} to upload');

      final fingerprint = _fingerprintOf(active);
      if (!force && fingerprint == prefs.calendarLastSyncFingerprint) {
        // 内容没变，但仍推进时间戳，否则每次回前台都要重新读一遍日历。
        prefs.calendarLastSyncedAt = now;
        debugPrint('[calendar-sync] unchanged (${active.length} events), skip upload');
        return null;
      }

      final result = await syncCalendarEvents(
        windowStart: windowStart,
        windowEnd: windowEnd,
        events: active,
        timezone: prefs.userTimezone.isNotEmpty ? prefs.userTimezone : null,
      );

      if (result == null) {
        // 上传失败：不推进时间戳也不存指纹，下一次触发会重试。
        debugPrint('[calendar-sync] upload failed, will retry');
        return null;
      }

      prefs.calendarLastSyncedAt = now;
      prefs.calendarLastSyncFingerprint = fingerprint;
      debugPrint('[calendar-sync] $result (read ${events.length}, uploaded ${active.length})');
      return result;
    } catch (e, stack) {
      debugPrint('[calendar-sync] failed: $e\n$stack');
      return null;
    } finally {
      _syncing = false;
    }
  }

  /// 系统自带的节假日/节气/生日订阅日历。
  ///
  /// 实测一个空日历的模拟器就有 13 条，其中 11 条是「立秋」「处暑」这类节气——
  /// 它们不是用户的行程，对"我什么时候有空、要去哪"毫无帮助，却会挤占
  /// 原生侧 500 条上限、放大整窗重写的成本，还会让 agent 把节气当成安排。
  ///
  /// 按日历名匹配（EventKit 没有可靠的"这是订阅日历"标志位——`EKCalendar.type`
  /// 对本地节假日日历也可能返回 .local）。宁可漏放几个也不误删用户自建日历：
  /// 只匹配系统内置的这几个名字。
  static const _noiseCalendarNames = {
    '中国大陆节假日',
    '中国大陆節假日',
    '生日',
    'Birthdays',
    'Holidays',
    'US Holidays',
    'Chinese Holidays',
    'Siri Suggestions',
    'Siri 建议',
  };

  bool _shouldUpload(DeviceCalendarEvent event) {
    // 已取消的日程会让 agent 误报行程。
    if (event.status == 'canceled') return false;
    final cal = event.calendarTitle;
    if (cal != null && _noiseCalendarNames.contains(cal)) return false;
    // 无标题的日程传上去也没有信息量。
    if (event.title.trim().isEmpty) return false;
    return true;
  }

  /// 全窗内容的指纹。逐条 fingerprint 拼起来，条数变化或任一条改动都会变。
  String _fingerprintOf(List<DeviceCalendarEvent> events) {
    if (events.isEmpty) return 'empty';
    final parts = events.map((e) => '${e.instanceId}${e.fingerprint}').toList()..sort();
    // 用 hashCode 而不是存全文：这串只需要能判"变没变"，不需要能还原。
    return '${events.length}:${Object.hashAll(parts)}';
  }
}
