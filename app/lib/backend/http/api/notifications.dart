import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/env/env.dart';

Future<void> saveFcmTokenServer({required String token, required String timeZone}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/users/fcm-token',
    headers: {'Content-Type': 'application/json'},
    method: 'POST',
    body: jsonEncode({'fcm_token': token, 'time_zone': timeZone}),
  );

  debugPrint('[FCM] token upload HTTP ${response?.statusCode ?? "unavailable"}');
  if (response?.statusCode != 200) {
    throw StateError('FCM token upload failed');
  }
}

/// 同步通知偏好到服务端，让服务端 FCM 推送（每日一刻 / 新发现 / 静默时段）honor 这些开关。
///
/// [preferences] 的 key 是后端 `SaveNotificationPreferencesRequest` 的 snake_case 字段名，
/// 由 `NotificationPrefs.buildSyncPayload()` 构建。
///
/// ⚠️ **只传本次改动的字段，不要全量上报。** 后端是合并写入，云端因此只积累用户真正设置过
/// 的 key —— 回读时 `stored_keys` 才分得清「用户设成 true」和「从没设过、默认是 true」。
/// 详见 `NotificationPrefs.syncToServer()`。
Future<void> saveNotificationPreferencesServer(Map<String, Object> preferences) async {
  if (preferences.isEmpty) return;
  try {
    final response = await makeApiCall(
      url: '${Env.apiBaseUrl}v1/users/notification-preferences',
      headers: {'Content-Type': 'application/json'},
      method: 'POST',
      body: jsonEncode(preferences),
    );
    debugPrint('saveNotificationPreferences(${preferences.keys.join(",")}): ${response?.statusCode}');
  } catch (e) {
    // 同步失败不影响本地已生效的开关，下次改动或启动时会再次上报。
    debugPrint('saveNotificationPreferences error: $e');
  }
}

/// 从服务端回读通知偏好（启动时调一次，见 `NotificationPrefs.hydrateFromServer`）。
///
/// 返回 `{'preferences': {...}, 'stored_keys': [...]}`；任何失败都返回 null，
/// 调用方保持本地值不动。
///
/// ⚠️ **`stored_keys` 必须一起用，不能只看 `preferences`。** 服务端返回的偏好总是
/// 全字段（缺的按它自己的默认补齐），所以「用户设过 true」和「从没设过、默认 true」
/// 长得一样。只按 `preferences` 覆盖本地，等于把服务端默认值固化成用户设置。
Future<Map<String, dynamic>?> fetchNotificationPreferencesServer() async {
  try {
    final response = await makeApiCall(
      url: '${Env.apiBaseUrl}v1/users/notification-preferences',
      headers: {},
      method: 'GET',
      body: '',
    );
    if (response == null || response.statusCode != 200) {
      debugPrint('fetchNotificationPreferences: ${response?.statusCode}');
      return null;
    }
    final decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (e) {
    // 回读失败就沿用本地值 —— 宁可显示旧的，也不要把设置页清成默认。
    debugPrint('fetchNotificationPreferences error: $e');
    return null;
  }
}
