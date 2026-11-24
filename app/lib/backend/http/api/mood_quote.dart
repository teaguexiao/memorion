import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/models/mood_quote.dart';

/// 获取「每日一语 / 今日情绪寄语」。
/// [date] 'YYYY-MM-DD'，为空则后端用用户本地时区的当日。
/// [language] 'zh' | 'en'，为空则后端按用户偏好。
/// 鉴权（Authorization + external_user_id）由 makeApiCall 统一注入。
Future<DailyMoodQuote?> getDailyMoodQuote({String? date, String? language}) async {
  final query = <String, String>{};
  if (date != null && date.isNotEmpty) query['date'] = date;
  if (language != null && language.isNotEmpty) query['language'] = language;
  final qs =
      query.isEmpty ? '' : '?${query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';

  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/mood/daily-quote$qs',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  if (response.statusCode == 200) {
    return DailyMoodQuote.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
  }
  if (response.statusCode == 404) {
    return null;
  }
  debugPrint('getDailyMoodQuote error ${response.statusCode}');
  return null;
}

/// 历史寄语分页（按日期倒序）。
/// 返回 {items: List<DailyMoodQuote>, hasMore: bool}。
Future<MoodQuoteHistoryPage> getMoodQuoteHistory({int limit = 30, int offset = 0}) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/mood/daily-quote/history?limit=$limit&offset=$offset',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return const MoodQuoteHistoryPage(items: [], hasMore: false);
  if (response.statusCode == 200) {
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final items =
        (json['items'] as List<dynamic>? ?? []).map((e) => DailyMoodQuote.fromJson(e as Map<String, dynamic>)).toList();
    return MoodQuoteHistoryPage(items: items, hasMore: json['has_more'] as bool? ?? false);
  }
  if (response.statusCode == 404) {
    return const MoodQuoteHistoryPage(items: [], hasMore: false);
  }
  debugPrint('getMoodQuoteHistory error ${response.statusCode}');
  return const MoodQuoteHistoryPage(items: [], hasMore: false);
}

class MoodQuoteHistoryPage {
  final List<DailyMoodQuote> items;
  final bool hasMore;

  const MoodQuoteHistoryPage({required this.items, required this.hasMore});
}
