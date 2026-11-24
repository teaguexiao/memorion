import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/models/calendar_event.dart';

/// 上传一个时间窗内的行程，服务端会用它**整体替换**该窗口已存的数据。
///
/// 窗口显式传参而不是从 events 推断：`events` 为空是有意义的信号
/// （"这段时间我没有日程"），必须能清掉此前存的内容。
///
/// 返回服务端写入/删除条数，失败返回 null。
Future<CalendarSyncResult?> syncCalendarEvents({
  required DateTime windowStart,
  required DateTime windowEnd,
  required List<DeviceCalendarEvent> events,
  String? timezone,
}) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/calendar/sync',
    headers: {},
    method: 'POST',
    body: jsonEncode({
      'window_start': windowStart.toUtc().toIso8601String(),
      'window_end': windowEnd.toUtc().toIso8601String(),
      'events': events.map((e) => e.toJson()).toList(),
      if (timezone != null) 'timezone': timezone,
    }),
  );
  if (response == null) return null;
  if (response.statusCode == 200) {
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return CalendarSyncResult(
      written: (json['written'] as num?)?.toInt() ?? 0,
      deleted: (json['deleted'] as num?)?.toInt() ?? 0,
    );
  }
  debugPrint('syncCalendarEvents error ${response.statusCode} ${response.body}');
  return null;
}

/// 读回服务端已存的行程 —— 用来验证同步真的落库了。
Future<List<DeviceCalendarEvent>> fetchStoredCalendarEvents({
  DateTime? start,
  DateTime? end,
  int limit = 100,
}) async {
  final query = <String>[
    if (start != null) 'start=${Uri.encodeComponent(start.toUtc().toIso8601String())}', // i18n-ignore: URL 查询参数
    if (end != null) 'end=${Uri.encodeComponent(end.toUtc().toIso8601String())}',
    'limit=$limit',
  ].join('&');

  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/calendar/events?$query',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return [];
  if (response.statusCode == 200) {
    final list = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    return list.map((e) => DeviceCalendarEvent.fromServerJson(e as Map<String, dynamic>)).whereType<DeviceCalendarEvent>().toList();
  }
  debugPrint('fetchStoredCalendarEvents error ${response.statusCode}');
  return [];
}

/// 上报同意决定。`granted: false` 时服务端**同时删除**已同步的行程。
///
/// 撤回与删数据合成一次请求，客户端就不可能留下半截状态：只撤同意不删数据，
/// 在用户眼里就是"我关了你还留着"；只删数据不撤同意，则下次同步又静默传回去。
///
/// 返回是否成功。失败时调用方**不得**改动本地同意状态 —— 否则界面显示已撤回，
/// 而服务端还在允许同步。
Future<bool> setCalendarConsent(bool granted) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/calendar/consent',
    headers: {},
    method: 'POST',
    body: jsonEncode({'granted': granted}),
  );
  if (response == null) return false;
  if (response.statusCode == 200) return true;
  debugPrint('setCalendarConsent error ${response.statusCode} ${response.body}');
  return false;
}

/// 同意状态 + 最近一次同步状态。授权页开关要的两半都在这一个请求里。
Future<CalendarSyncState?> fetchCalendarSyncState() async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/calendar/sync-state',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  if (response.statusCode == 200) {
    return CalendarSyncState.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  }
  debugPrint('fetchCalendarSyncState error ${response.statusCode}');
  return null;
}

class CalendarSyncResult {
  final int written;
  final int deleted;

  const CalendarSyncResult({required this.written, required this.deleted});

  @override
  String toString() => 'CalendarSyncResult(written: $written, deleted: $deleted)';
}

class CalendarSyncState {
  final DateTime? syncedAt;
  final int eventCount;

  /// 服务端记录的同意状态 —— 开关的真相源。
  ///
  /// 系统日历权限记在 iOS 侧、跨 App 更新保留；同意标记原先只存在本地
  /// NSUserDefaults 里，重装会连同沙盒一起丢，于是开关显示"关"而系统权限还在
  /// （看起来像权限 bug，其实是本地状态丢了）。放到服务端后跟着账号走。
  ///
  /// ⚠️ **null 表示服务端还没有这个字段**，不是「未同意」。App 走 TestFlight、后端走
  /// ECS，两边的上线顺序保证不了：把缺字段当成 false，会在新 App 碰上旧后端时把
  /// **所有**用户的日历开关打成关 —— 比它要修的 bug 还严重。调用方遇到 null 一律
  /// 保持本地缓存不动（见 `CalendarAiConsent.refreshFromServer`）。
  final bool? consentGranted;

  const CalendarSyncState({this.syncedAt, this.eventCount = 0, this.consentGranted});

  factory CalendarSyncState.fromJson(Map<String, dynamic> json) {
    final syncedAtRaw = json['synced_at'] as String?;
    return CalendarSyncState(
      syncedAt: syncedAtRaw == null ? null : DateTime.tryParse(syncedAtRaw)?.toLocal(),
      eventCount: (json['event_count'] as num?)?.toInt() ?? 0,
      consentGranted: json['consent_granted'] as bool?,
    );
  }
}
