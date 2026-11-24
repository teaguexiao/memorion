import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/env/env.dart';

Future<Map<String, dynamic>?> getLatestEmotion() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/discover/latest-emotion',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  if (response.statusCode == 200) {
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }
  debugPrint('getLatestEmotion error ${response.statusCode}');
  return null;
}

Future<List<dynamic>> getEmotionTrends({int days = 7}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/discover/emotion-trends?days=$days',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return [];
  if (response.statusCode == 200) {
    return jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
  }
  debugPrint('getEmotionTrends error ${response.statusCode}');
  return [];
}

Future<List<dynamic>> getCategoryStats({int days = 30}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/discover/category-stats?days=$days',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return [];
  if (response.statusCode == 200) {
    return jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
  }
  debugPrint('getCategoryStats error ${response.statusCode}');
  return [];
}

Future<String?> getPersonaTagline({int days = 7}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/discover/persona-tagline?days=$days',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  if (response.statusCode == 200) {
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final tagline = (data['tagline'] as String?)?.trim();
    return (tagline != null && tagline.isNotEmpty) ? tagline : null;
  }
  debugPrint('getPersonaTagline error ${response.statusCode}');
  return null;
}

Future<List<dynamic>> getPeopleStats({int days = 30, int limit = 20}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/discover/people-stats?days=$days&limit=$limit',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return [];
  if (response.statusCode == 200) {
    return jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
  }
  debugPrint('getPeopleStats error ${response.statusCode}');
  return [];
}

/// 返回体里额外带一个 **`ok`**：`false` = 这次拉取失败了。
///
/// ⚠️ 没有它的话，「拉取失败」和「真的没有待办」返回的是同一个空 items —— 调用方会
/// 把一次超时渲染成空态，`DiscoverProvider` 还会把这份空响应 `cacheJson` 落盘，于是
/// 假空态活到下次启动。这是本仓库记录过的类别缺陷（人物页、词库页各撞过一次）。
Future<Map<String, dynamic>> getActionItems({String status = 'all', int limit = 50, int offset = 0}) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/discover/action-items?status=$status&limit=$limit&offset=$offset',
    headers: {},
    method: 'GET',
    body: '',
  );
  const failed = {'items': [], 'total_count': 0, 'has_more': false, 'ok': false};
  if (response == null) return failed;
  if (response.statusCode == 200) {
    final payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return {...payload, 'ok': true};
  }
  debugPrint('getActionItems error ${response.statusCode}');
  return failed;
}

Future<Map<String, dynamic>> getDiscoverStats() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/discover/stats',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return {};
  if (response.statusCode == 200) {
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }
  debugPrint('getDiscoverStats error ${response.statusCode}');
  return {};
}

Future<Map<String, dynamic>?> generateDiscoverReport({String type = 'weekly', String? date}) async {
  var body = {'type': type};
  if (date != null) {
    body['date'] = date;
  }
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/discover/report',
    headers: {},
    method: 'POST',
    body: jsonEncode(body),
  );
  if (response == null) return null;
  if (response.statusCode == 200) {
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }
  debugPrint('generateDiscoverReport error ${response.statusCode}');
  return null;
}
