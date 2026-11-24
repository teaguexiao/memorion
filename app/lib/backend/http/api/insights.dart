import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/schema/insight.dart';
import 'package:memorion/env/env.dart';

/// 涌现式洞察卡 API（后端 routers/developer_insights.py）。
/// makeApiCall 对 Env.apiBaseUrl 的请求自动注入 Authorization + external_user_id。

/// 拉取洞察卡列表。默认只取 released（账本里的候选/否决是内部状态，客户端不该看）。
Future<List<InsightCard>?> getInsights({bool releasedOnly = true, int limit = 50, int offset = 0}) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/insights?released_only=$releasedOnly&limit=$limit&offset=$offset',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null || response.statusCode != 200) {
    debugPrint('[insights] GET failed: status=${response?.statusCode} body=${response?.body}');
    return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final list = (decoded['insights'] as List<dynamic>? ?? []);
    debugPrint('[insights] loaded ${list.length}/${decoded['total']}');
    return list.whereType<Map<String, dynamic>>().map(InsightCard.fromJson).toList();
  } catch (e) {
    debugPrint('[insights] parse error: $e');
    return null;
  }
}

/// 按 ID 读取单张卡，通知中的旧卡也不受列表分页限制。
Future<InsightCard?> getInsight(String insightId) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/insights/${Uri.encodeComponent(insightId)}',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null || response.statusCode != 200) return null;
  try {
    return InsightCard.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  } catch (e) {
    debugPrint('getInsight parse error: $e');
    return null;
  }
}

/// 提交「说得准 / 不太准」反馈。返回更新后的卡片（失败返回 null）。
Future<InsightCard?> submitInsightFeedback(String insightId, InsightFeedback feedback) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/insights/$insightId/feedback',
    headers: {},
    method: 'POST',
    body: jsonEncode({'feedback': feedbackToString(feedback)}),
  );
  if (response == null || response.statusCode != 200) {
    debugPrint('submitInsightFeedback failed: ${response?.statusCode}');
    return null;
  }
  try {
    return InsightCard.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  } catch (e) {
    debugPrint('submitInsightFeedback parse error: $e');
    return null;
  }
}

/// 手动跑一轮洞察引擎（一轮 40s+ 且消耗 LLM，仅 debug 入口用）。
/// 返回 skipped_reason（释放阀未放行时的原因），成功释放则为 null。
Future<Map<String, dynamic>?> runInsightEngine({int windowDays = 30}) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/insights/run',
    headers: {},
    method: 'POST',
    body: jsonEncode({'window_days': windowDays, 'dry_run': false, 'send_push': false}),
  );
  if (response == null || response.statusCode != 200) {
    debugPrint('runInsightEngine failed: ${response?.statusCode} ${response?.body}');
    return null;
  }
  try {
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  } catch (e) {
    debugPrint('runInsightEngine parse error: $e');
    return null;
  }
}
