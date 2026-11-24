import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';

/// P-01 今日·章节时间线的视图模型。
///
/// 分组与章节边界来自**后端章节层**（`GET /v1/timeline/{date}/chapters`，经
/// TimelineProvider）：一章可能由多条 conversation 合成，摘要是后端二次归纳的结果。
/// 处理中态仍来自 ConversationProvider（还没落地的会话不可能进章节），空档条由
/// `WearTracking` 本地佩戴追踪推导。
///
/// ⚠️ **不要在这一层重新算章节边界**。章节是后端的可重算投影，端上再算一遍就是两套
/// 边界，改一次阈值就会开始互相矛盾。拉不到章节时退回「一条 conversation 一张卡」
/// 只作为降级路径（见 today_chapters_page.dart `_buildDayGroups`）。
///
/// 第一人称观察全走真数据（structured.first_person_observation）；为空时整行隐藏，
/// 不再编造兜底语料。

/// 时间线上的一个条目（章节 / 处理中 / 空档条）。
sealed class TimelineEntry {
  const TimelineEntry();
}

/// 章节卡：时段 + 标题 + 第一人称观察 +（v2.4）分类/⭐高亮标签。
class ChapterEntry extends TimelineEntry {
  final String timeRange;
  final String title;

  /// 第一人称观察（真数据 structured.first_person_observation，老数据回退语料）。
  final String observation;

  /// 分类标签（真数据来自 structured.category，映射为中文）。
  final String category;

  /// 是否显示⭐高亮标签。真数据来自 `structured.is_highlighted`——
  /// 未来由**硬件按钮**触发写入，与「值得回顾的时刻」(structured.highlights) 无关。
  final bool hasHighlight;

  /// 锚点会话：本章第一条源 conversation。详情页的编辑/删除都从它出发，
  /// 也是降级路径（拿不到章节时）唯一的数据来源。
  final ServerConversation? conversation;

  /// 本章的全部源会话，按时间顺序，**首个即 [conversation]**。
  /// 长度 >1 表示这一章是合并出来的，详情页要走合并视图。
  final List<ServerConversation> sources;

  /// 后端章节文档；降级路径（一条 conversation 一张卡）为 null。
  final TimelineChapter? chapter;

  const ChapterEntry({
    required this.timeRange,
    required this.title,
    required this.observation,
    this.category = '工作', // i18n-ignore: 兜底值，调用方均传 localizeCategory 的本地化结果
    this.hasHighlight = false,
    this.conversation,
    this.sources = const [],
    this.chapter,
  });

  /// 由多条 conversation 合成。
  bool get isMerged => sources.length > 1;

  /// 详情页要吃的源会话列表：合并章节给全部源，单条章节退回锚点。
  List<ServerConversation> get effectiveSources =>
      sources.isNotEmpty ? sources : (conversation != null ? [conversation!] : const []);
}

/// 处理中卡：会话正在整理。真数据来自 status == processing。
class ProcessingEntry extends TimelineEntry {
  final String text;
  const ProcessingEntry({required this.text});
}

/// 空档条：确实没戴的时段，由 `WearTracking` 本地佩戴追踪推导。
class CoverageGapEntry extends TimelineEntry {
  final String text;
  const CoverageGapEntry({required this.text});
}

/// 一个日期分组：日期标题 + 元信息 + 条目列表。
///
/// NOTE: 原 kMockObservations / mockObservationFor 已删除——第一人称观察为空时
/// 章节卡整行隐藏，不再兜底假文案。
class DayGroup {
  final String dateLabel; // 例如「7月9日 · 周三」
  final String metaLabel; // 例如「3 个章节 · 5.8 小时」
  final List<TimelineEntry> entries;

  const DayGroup({
    required this.dateLabel,
    required this.metaLabel,
    required this.entries,
  });
}

