/// 真章节化投影的客户端模型（后端 `timeline_days/{YYYY-MM-DD}` 的一份子集）。
///
/// 自动摘要是可重算投影；用户对标题/正文的修正由后端独立保存，再叠加到投影上。
///
/// ⚠️ **刻意丢掉后端文档里的 `segment_refs` 与 `voice_runs`**。它们是段级溯源数据
/// （一条 segment 一个 entry，一天能有几千条），App 侧没有任何界面用得到，而
/// TimelineProvider 会把整个文档写进 shared_preferences 缓存——原样收下会让缓存
/// 膨胀一到两个数量级。需要下钻时走 [sourceConversationIds] 拿完整会话即可。
library;

import 'package:flutter/foundation.dart';
import 'chapter_speaker.dart';

/// 一个章节：一段时间 + 一份合并摘要 + 它由哪些 conversation 组成。
class TimelineChapter {
  /// 服务端按账户时区归属的日期，不能用手机时区重新计算。
  final String? date;

  /// 章节起止（本地时间；后端给的是带时区的 ISO，解析时已 toLocal）。
  final DateTime start;
  final DateTime end;

  /// 章节跨度秒数（end - start，含章节内部 <8min 的静音）。
  final double durationSeconds;

  /// 实际有人说话的秒数（后端按段级区间并集算的，重叠录音不重复计）。
  final double speechSeconds;

  /// 组成本章的源 conversation id，按时间顺序。**可能多于一条**。
  final List<String> sourceConversationIds;

  final String title;
  final String rawOverview;
  final ChapterSpeakerDisplay? speakerDisplay;
  final String? speakerRevision;
  // Rendering requires the reader's language; persistence uses rawOverview.
  String plainOverview({required bool chinese}) =>
      speakerDisplay?.render(rawOverview, chinese: chinese) ??
      rawOverview.replaceAll(ChapterSpeakerDisplay.token, chinese ? '有人' : 'Someone');
  String attributedOverview({required bool chinese}) =>
      speakerDisplay?.render(rawOverview, chinese: chinese, links: true) ?? plainOverview(chinese: chinese);
  final String emoji;
  final String firstPersonObservation;
  final bool observationStale;

  String observationWithFallback(String? sourceObservation) => observationStale
      ? ''
      : firstPersonObservation.isNotEmpty
          ? firstPersonObservation
          : (sourceObservation?.trim() ?? '');

  /// 摘要是否经过二次归纳（多条合并时为 true；单条复用原摘要为 false）。
  /// 仅用于诊断与测试断言，不影响渲染。
  final bool rolledUp;

  const TimelineChapter({
    this.date,
    required this.start,
    required this.end,
    required this.durationSeconds,
    required this.speechSeconds,
    required this.sourceConversationIds,
    required this.title,
    required String overview,
    this.speakerDisplay,
    this.speakerRevision,
    required this.emoji,
    required this.firstPersonObservation,
    this.observationStale = false,
    required this.rolledUp,
  }) : rawOverview = overview;

  /// 本章是否由多条 conversation 合并而来（决定详情页走合并视图还是单条视图）。
  bool get isMerged => sourceConversationIds.length > 1;

  static DateTime? _parseTime(dynamic value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value)?.toLocal();
    }
    return null;
  }

  static double _parseSeconds(dynamic value) => value is num ? value.toDouble() : 0.0;

  /// 后端文档 → 模型。缺少 `start`/`end` 的条目返回 null（宁可少一章，不要一个
  /// 时间为 null 的章节在渲染层到处炸）。
  static TimelineChapter? fromJson(Map<String, dynamic> json, {String? date}) {
    final start = _parseTime(json['start']);
    final end = _parseTime(json['end']);
    if (start == null || end == null) return null;
    final ids = (json['source_conversation_ids'] as List?)?.whereType<String>().toList() ?? const <String>[];
    return TimelineChapter(
      date: date ?? json['date'] as String?,
      start: start,
      end: end.isBefore(start) ? start : end,
      durationSeconds: _parseSeconds(json['duration_seconds']),
      speechSeconds: _parseSeconds(json['speech_seconds']),
      sourceConversationIds: ids,
      title: (json['title'] as String?)?.trim() ?? '',
      overview: (json['overview'] as String?)?.trim() ?? '',
      emoji: (json['emoji'] as String?) ?? '',
      firstPersonObservation: (json['first_person_observation'] as String?)?.trim() ?? '',
      observationStale: json['observation_stale'] == true,
      speakerDisplay: json['speaker_display'] is Map && json['speaker_display']['version'] == 1
          ? ChapterSpeakerDisplay.fromJson(Map<String, dynamic>.from(json['speaker_display']))
          : null,
      speakerRevision: json['speaker_revision'] as String?,
      // 后端的 `rollup` 是三态：false（复用单条）/ true（真归纳）/ 'failed'（降级）。
      rolledUp: json['rollup'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        if (date != null) 'date': date,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'duration_seconds': durationSeconds,
        'speech_seconds': speechSeconds,
        'source_conversation_ids': sourceConversationIds,
        'title': title,
        'overview': rawOverview,
        if (speakerDisplay != null) 'speaker_display': speakerDisplay!.toJson(),
        if (speakerRevision != null) 'speaker_revision': speakerRevision,
        'emoji': emoji,
        'first_person_observation': firstPersonObservation,
        if (observationStale) 'observation_stale': true,
        'rollup': rolledUp,
      };

  /// 去掉若干源 conversation 后的本章；一条不剩时返回 null（整章消失）。
  ///
  /// 用于删除的乐观更新：源会话删了，章节必须立刻跟着消失，否则界面上留着一张
  /// 指向已删数据的卡。真正的重算由后端在下次请求时做（删除端点已标记该天 dirty）。
  TimelineChapter? withoutConversations(Set<String> removedIds) {
    if (removedIds.isEmpty) return this;
    final kept = sourceConversationIds.where((id) => !removedIds.contains(id)).toList();
    if (kept.isEmpty) return null;
    if (kept.length == sourceConversationIds.length) return this;
    return TimelineChapter(
      date: date,
      start: start,
      end: end,
      durationSeconds: durationSeconds,
      speechSeconds: speechSeconds,
      sourceConversationIds: kept,
      title: title,
      // Retain evidence targets while the server recomputes this provisional
      // chapter. Its source/revision checks reject stale evidence or edits.
      overview: rawOverview,
      speakerDisplay: speakerDisplay,
      speakerRevision: speakerRevision,
      emoji: emoji,
      firstPersonObservation: firstPersonObservation,
      observationStale: observationStale,
      rolledUp: rolledUp,
    );
  }
}

/// 一天的章节文档。
class TimelineDay {
  /// 归一化后的日期字符串 `YYYY-MM-DD`（后端 doc id，也是本地缓存 key）。
  final String date;

  /// 计算时用的 IANA 时区名（后端按用户时区切天，与端上时区可能不同）。
  final String timezone;

  final List<TimelineChapter> chapters;

  /// 本天所有源 conversation id。用来判断「本地已有的会话是否已经进过章节」——
  /// 没进说明服务端那份是旧的，需要带 refresh 重算。
  final List<String> sourceConversationIds;

  /// 服务端本次响应是缓存命中还是重算：`hit` / `unchanged` / `computed` / `locked`。
  /// 只用于日志与测试，不驱动 UI。
  final String cache;

  final DateTime? computedAt;

  const TimelineDay({
    required this.date,
    required this.timezone,
    required this.chapters,
    required this.sourceConversationIds,
    required this.cache,
    required this.computedAt,
  });

  static TimelineDay fromJson(Map<String, dynamic> json, {required String fallbackDate}) {
    final rawChapters = (json['chapters'] as List?) ?? const [];
    final chapters = <TimelineChapter>[];
    for (final item in rawChapters) {
      if (item is Map) {
        final parsed =
            TimelineChapter.fromJson(Map<String, dynamic>.from(item), date: (json['date'] as String?) ?? fallbackDate);
        if (parsed != null) chapters.add(parsed);
      }
    }
    // 按开始时间升序钉住顺序：后端本来就是有序的，但缓存往返与手工构造的测试数据
    // 不该依赖这一点。
    chapters.sort((a, b) => a.start.compareTo(b.start));
    return TimelineDay(
      date: (json['date'] as String?) ?? fallbackDate,
      timezone: (json['timezone'] as String?) ?? '',
      chapters: chapters,
      sourceConversationIds:
          (json['source_conversation_ids'] as List?)?.whereType<String>().toList() ?? const <String>[],
      cache: (json['cache'] as String?) ?? '',
      computedAt: TimelineChapter._parseTime(json['computed_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'date': date,
        'timezone': timezone,
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'source_conversation_ids': sourceConversationIds,
        'cache': cache,
        'computed_at': computedAt?.toIso8601String(),
      };

  /// 删掉若干源 conversation 后的这一天（乐观更新，见
  /// [TimelineChapter.withoutConversations]）。
  TimelineDay withoutConversations(Set<String> removedIds) {
    if (removedIds.isEmpty) return this;
    final kept = <TimelineChapter>[];
    for (final chapter in chapters) {
      final next = chapter.withoutConversations(removedIds);
      if (next != null) kept.add(next);
    }
    return TimelineDay(
      date: date,
      timezone: timezone,
      chapters: kept,
      sourceConversationIds: sourceConversationIds.where((id) => !removedIds.contains(id)).toList(),
      cache: cache,
      computedAt: computedAt,
    );
  }

  @override
  String toString() => 'TimelineDay($date, ${chapters.length} chapters, cache=$cache)';
}

/// `YYYY-MM-DD`（本地日）。端上到处要用它当 key，只在这里拼一次。
String timelineDayKey(DateTime date) {
  final mm = date.month.toString().padLeft(2, '0');
  final dd = date.day.toString().padLeft(2, '0');
  return '${date.year}-$mm-$dd';
}

/// 调试用：把一天的章节打成一行。
@visibleForTesting
String describeTimelineDay(TimelineDay day) =>
    day.chapters.map((c) => '${timelineDayKey(c.start)} ${c.title}(${c.sourceConversationIds.length})').join(' | ');
