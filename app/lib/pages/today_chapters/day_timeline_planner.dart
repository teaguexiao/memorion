/// 首页 P-01 一天时间线的排布规则（纯函数层，无 BuildContext、无 Provider）。
///
/// 从 `today_chapters_page.dart` 里抽出来的原因：这几条规则各自都能静默出错，而
/// 「渲染出来的卡片对不对」用 widget 测试断言的成本远高于直接断言排布结果。
/// 页面只负责把 [DayTimelineSlot] 映射成 `TimelineEntry`（那一步要 context 做本地化）。
///
/// ⚠️ **这里不算章节边界**。哪些 conversation 属于同一章完全由后端章节层决定
/// （`GET /v1/timeline/{date}/chapters`）。端上再算一遍就是两套边界，改一次阈值
/// 就会开始互相矛盾。本文件只做三件事：按天归拢、把章节和会话对上、排序。
library;

import 'package:flutter/material.dart' show DateTimeRange;
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';

/// 时间线上的一个槽位：一张卡该占的时间区间 + 它背后的数据。
class DayTimelineSlot {
  /// 后端章节文档；**降级槽位为 null**（见 [planDayTimeline] 的降级路径）。
  final TimelineChapter? chapter;

  /// 本槽位的源会话，按时间顺序，至少一条。降级槽位就是那一条。
  final List<ServerConversation> sources;

  final DateTime start;
  final DateTime end;

  /// 计入当天总时长（页头「N 个章节 · X 小时」）的秒数。
  ///
  /// ⚠️ **是「有人说话的时长」，不是章节跨度**。章节跨度含内部 <8min 的静音，
  /// 拿它累加会让页头小时数在章节化后凭空变大——同一天的录音一点没多，数字却涨了。
  /// 所以章节槽位取后端的 `speech_seconds`（段级区间**并集**，重叠录音不重复计），
  /// 降级槽位取会话自己的段级跨度，两者量纲一致。
  final double seconds;

  const DayTimelineSlot({
    required this.chapter,
    required this.sources,
    required this.start,
    required this.end,
    required this.seconds,
  });

  /// 由多条 conversation 合并而来（详情页要走合并视图）。
  bool get isMerged => sources.length > 1;

  /// 锚点会话：详情页的编辑/删除/举报从它出发。
  ServerConversation get anchor => sources.first;
}

/// 会话的时间线起点。
///
/// ⚠️ 用 `startedAt` 而不是 `createdAt`：批量转录的音频 `createdAt`（落库时刻）
/// 可能比录制时间晚一天以上，跟着它归日会把同一章劈到两天，而后端章节层是按
/// `started_at` 归日的——两边不一致会让本地会话永远被判成「服务端漏了」。
DateTime timelineStartOf(ServerConversation c) => c.startedAt ?? c.createdAt;

bool isMediaRecordingTitle(String title) =>
    title.trim().replaceAll(RegExp(r'^\[+|\]+$'), '').trim().toLowerCase() == 'media recording';

/// Kept audio remains accessible from recording history; ignored content has no
/// timeline card, including the fallback path and legacy media placeholders.
bool isVisibleTimelineConversation(ServerConversation c) =>
    !c.discarded && !isMediaRecordingTitle(c.structured.title);

/// 把会话按「章节起始日」归拢。键是 [timelineDayKey] 的结果（`YYYY-MM-DD`）。
Map<String, List<ServerConversation>> groupConversationsByDay(Iterable<ServerConversation> conversations) {
  final byDay = <String, List<ServerConversation>>{};
  for (final c in conversations) {
    (byDay[timelineDayKey(timelineStartOf(c))] ??= []).add(c);
  }
  return byDay;
}

/// 一天的槽位排布，**按开始时间倒序**（新→旧，与 Figma 时间线一致）。
///
/// [completed] 必须只含已完成的会话（processing / in_progress 的还没进章节，
/// 由页面单独排在最前）。[chapters] 是后端给这一天的章节。
///
/// ⚠️ **降级路径是必须的，不是保险**：没被任何章节收进去的会话仍然一条一张卡。
/// 章节缓存可能还没重算（服务端 debounce 10min）、可能拉取失败、可能这条会话刚
/// 落库。少一张卡 = 用户认为录音丢了。
List<DayTimelineSlot> planDayTimeline({
  required List<ServerConversation> completed,
  required List<TimelineChapter> chapters,
}) {
  final byId = {for (final c in completed) c.id: c};
  final covered = <String>{};
  final slots = <DayTimelineSlot>[];

  for (final chapter in chapters) {
    // A stale chapter can still contain ignored content. Use the retained
    // sources' own summaries until the server recomputes it.
    if (isMediaRecordingTitle(chapter.title) ||
        chapter.sourceConversationIds.any((id) =>
            byId[id] != null && !isVisibleTimelineConversation(byId[id]!))) {
      continue;
    }
    final sources = <ServerConversation>[];
    for (final id in chapter.sourceConversationIds) {
      final convo = byId[id];
      if (convo != null) sources.add(convo);
    }
    // 一条源都取不到：这章的会话被搜索/日期筛掉了，或还没翻页拉到。
    // 渲染它只会得到一张点不开的卡。
    if (sources.isEmpty) continue;
    covered.addAll(sources.map((c) => c.id));
    // speech_seconds 缺失（老缓存文档 / 后端未算）时退回源会话时长之和——不能退回
    // durationSeconds，那是含静音的跨度，会把页头小时数撑大。
    final speech = chapter.speechSeconds > 0
        ? chapter.speechSeconds
        : sources.fold<double>(0, (sum, c) => sum + c.getDurationInSeconds());
    slots.add(DayTimelineSlot(
      chapter: chapter,
      sources: sources,
      start: chapter.start,
      end: chapter.end.isAfter(chapter.start) ? chapter.end : chapter.start,
      seconds: speech,
    ));
  }

  for (final c in completed) {
    if (!isVisibleTimelineConversation(c)) continue;
    if (covered.contains(c.id)) continue;
    final start = timelineStartOf(c);
    slots.add(DayTimelineSlot(
      chapter: null,
      sources: [c],
      start: start,
      end: c.finishedAt ?? start,
      seconds: c.getDurationInSeconds().toDouble(),
    ));
  }

  slots.sort((a, b) => b.start.compareTo(a.start));
  return slots;
}

/// 时间线上每个条目**之前**要不要留一个空档候选区间。
///
/// 入参是按开始时间**倒序**（新→旧）的条目区间，返回等长列表：第 i 项是「第 i 条
/// 与它上一条（更晚那条）之间的空隙」，没有空隙则为 null。
///
/// 只给「时间轴上的空白」，**不判要不要显示空档条**——那要扣掉 BLE 连接时段与静默
/// 时段（`WearTracking.uncoveredDuration`），依赖本地存储，不属于纯函数层。
///
/// 空档条的正确性不在于「算得出几小时」，而在于**它只出现在条目之间**。章节化前一天
/// 有 ~7.7 张碎片卡，碎片间的间隙（实测 46.2% 小于 5 分钟）都会进这个判断；章节化后
/// 这些间隙被后端合并进章节内部，这里就再也看不到它们了。所以「章节内部不出现空档条」
/// 不是这个函数额外做的判断，而是它只看条目边界的自然结果——真正要防的回归是有人改成
/// 遍历源 conversation。
///
/// ⚠️ 相邻条目**重叠**时（后端时间轴重叠实测 12.4%）返回 null，不返回负区间：
/// `WearTracking.uncoveredDuration` 对 end <= start 会返回 zero，但让越界区间流进去
/// 依赖的是它的容错，而不是这里的正确性。
List<DateTimeRange?> timelineGapCandidates(List<DateTimeRange> descending) {
  final out = List<DateTimeRange?>.filled(descending.length, null);
  for (var i = 1; i < descending.length; i++) {
    final laterStart = descending[i - 1].start; // 上一条（更晚）的开始
    final end = descending[i].end; // 本条的结束
    if (laterStart.isAfter(end)) {
      out[i] = DateTimeRange(start: end, end: laterStart);
    }
  }
  return out;
}

/// [timelineGapCandidates] 的槽位版：直接吃 [planDayTimeline] 的结果。
List<DateTimeRange?> gapCandidatesForSlots(List<DayTimelineSlot> slots) =>
    timelineGapCandidates([for (final s in slots) DateTimeRange(start: s.start, end: s.end)]);

/// Hiding irrelevant audio must not turn its recording interval into a claim
/// that the device was not worn. Subtract all captured intervals from a gap
/// before applying BLE/quiet-hour coverage.
List<DateTimeRange> unrecordedGapRanges(DateTimeRange gap, Iterable<ServerConversation> recordings) {
  final covers = <DateTimeRange>[];
  for (final c in recordings) {
    final start = timelineStartOf(c);
    final end = c.finishedAt;
    if (end == null || !end.isAfter(start)) continue;
    final lo = start.isAfter(gap.start) ? start : gap.start;
    final hi = end.isBefore(gap.end) ? end : gap.end;
    if (hi.isAfter(lo)) covers.add(DateTimeRange(start: lo, end: hi));
  }
  covers.sort((a, b) => a.start.compareTo(b.start));
  final ranges = <DateTimeRange>[];
  var cursor = gap.start;
  for (final cover in covers) {
    if (!cover.end.isAfter(cursor)) continue;
    if (cover.start.isAfter(cursor)) ranges.add(DateTimeRange(start: cursor, end: cover.start));
    cursor = cover.end;
    if (!gap.end.isAfter(cursor)) break;
  }
  if (gap.end.isAfter(cursor)) ranges.add(DateTimeRange(start: cursor, end: gap.end));
  return ranges;
}
