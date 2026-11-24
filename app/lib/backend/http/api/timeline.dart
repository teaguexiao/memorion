import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/env/env.dart';

/// 保存当前 Summary 的修正；不会改写构成它的源录音摘要。
Future<TimelineChapter?> updateTimelineChapter({
  required TimelineChapter chapter,
  String? title,
  String? overview,
}) async {
  final date = chapter.date ?? timelineDayKey(chapter.start);
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/timeline/$date/chapters?speaker_attribution=true',
    headers: {},
    method: 'PATCH',
    body: jsonEncode({
      'start': chapter.start.toUtc().toIso8601String(),
      'end': chapter.end.toUtc().toIso8601String(),
      'source_conversation_ids': chapter.sourceConversationIds,
      if (title != null) 'title': title,
      if (overview != null) 'overview': overview,
    }),
  );
  if (response == null || response.statusCode != 200) return null;
  try {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return TimelineChapter.fromJson(Map<String, dynamic>.from(decoded['chapter']),
        date: decoded['date'] as String? ?? date);
  } catch (_) {
    return null;
  }
}

/// 拉一天的章节（`GET /v1/timeline/{date}/chapters`）。
///
/// [date] 必须是 `YYYY-MM-DD`，且是**用户本地日**——后端按用户时区切天。
///
/// [refresh] 对应服务端的 pull-to-refresh 语义：**跳过 debounce 窗口，但不跳过
/// 指纹校验**。所以下拉刷新一个没变过的日子不会花 LLM 钱，也不必在端上另做节流。
///
/// 失败返回 null（而不是空的 TimelineDay）：调用方要能区分「这天真没有章节」和
/// 「没拉到」——后者必须保留缓存，见 `TimelineProvider`。
Future<TimelineDay?> getTimelineDayChapters({
  required String date,
  bool refresh = false,
}) async {
  var url = '${Env.apiBaseUrl}v1/timeline/$date/chapters?speaker_attribution=true';
  if (refresh) url += '&refresh=true';

  var response = await makeApiCall(
    url: url,
    headers: {},
    method: 'GET',
    body: '',
  );

  if (response == null) return null;
  if (response.statusCode != 200) {
    debugPrint('getTimelineDayChapters($date) failed with status: ${response.statusCode}');
    return null;
  }

  try {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) {
      debugPrint('getTimelineDayChapters($date): unexpected body shape ${decoded.runtimeType}');
      return null;
    }
    final day = TimelineDay.fromJson(Map<String, dynamic>.from(decoded), fallbackDate: date);
    debugPrint('getTimelineDayChapters($date): ${day.chapters.length} chapters (cache=${day.cache})');
    return day;
  } catch (e) {
    debugPrint('getTimelineDayChapters($date) parse failed: $e');
    return null;
  }
}
