/// 涌现式洞察卡（后端 routers/developer_insights.py 的 `_to_card_out` 契约）。
///
/// 产品模型：不是「Day2/Day7 排期 + 固定模板」的里程碑，而是后台持续「提名」
/// 关于用户值得说的一件事，经怀疑者审核后进账本，由释放阀决定何时推一张卡。
/// 所以客户端拿到的就是一串**独立洞察**，没有 MBTI/archetype 这类固定字段。
library;

/// 用户在卡片上的反馈（对应后端 InsightFeedback）。
enum InsightFeedback { none, accurate, inaccurate }

InsightFeedback _feedbackFromString(String? v) {
  switch (v) {
    case 'accurate':
      return InsightFeedback.accurate;
    case 'inaccurate':
      return InsightFeedback.inaccurate;
    default:
      return InsightFeedback.none;
  }
}

String feedbackToString(InsightFeedback f) {
  switch (f) {
    case InsightFeedback.accurate:
      return 'accurate';
    case InsightFeedback.inaccurate:
      return 'inaccurate';
    case InsightFeedback.none:
      return 'none';
  }
}

/// 生成侧填 conversation_id 时爱用的占位词。
/// 与后端 utils/insights/engine.py 的 `_BOGUS_IDS` 对应。
const _bogusConversationIds = {
  '未知', '无', '不明', '未提供', '无法确定', '略',
  'unknown', 'n/a', 'na', 'none', 'null', 'nil', '-', '?', '??',
};

/// 这个 conversation_id 能不能拿去跳转取证。
///
/// 光判 `isNotEmpty` 不够：生成侧曾把字面量「未知」填进 conversation_id
/// （生产账本实测 139 条原话证据里有 5 条），非空字符串照样过判空，然后跳进
/// 一个不存在的对话。后端出口已经抹掉这些值，客户端再挡一道——真 id 是
/// Firestore doc id（36 字符 UUID），占位词全都远短于此。
bool canOpenConversationId(String? id) {
  if (id == null || id.length < 20) return false;
  return !_bogusConversationIds.contains(id.toLowerCase());
}

/// 一条证据。统计型洞察可以没有原话，只有 stat 数字描述。
class InsightEvidence {
  final String? quote; // 用户原话（逐字）
  final String? conversationId; // 原话所在对话 id，供跳转取证
  final String? date; // YYYY-MM-DD
  final String? stat; // 统计型证据的可读描述，如「周五 80 段 / 周日 6 段」

  const InsightEvidence({this.quote, this.conversationId, this.date, this.stat});

  factory InsightEvidence.fromJson(Map<String, dynamic> json) {
    return InsightEvidence(
      quote: (json['quote'] as String?)?.trim(),
      conversationId: (json['conversation_id'] as String?)?.trim(),
      date: json['date'] as String?,
      stat: (json['stat'] as String?)?.trim(),
    );
  }

  /// 展示用文本：优先原话（加引号），否则统计描述。
  String get displayText {
    final q = quote;
    if (q != null && q.isNotEmpty) return '「$q」';
    return stat ?? '';
  }

  bool get isEmpty => displayText.isEmpty;

  /// 这条证据能不能跳去取证。见 [canOpenConversationId]。
  bool get canOpen => canOpenConversationId(conversationId);
}

class InsightCard {
  final String id;
  final String topicKey;
  final String headline;
  final String body;

  /// 深读段散文（可能为 null）。
  ///
  /// headline/body 是「我注意到什么」——必须挂得住原话或统计数字；depth 是
  /// 「我从中看到一个什么样的人」，后端刻意放松了证据要求（允许推测动机与情绪），
  /// 唯一红线是不许编造可核对的硬事实。所以展示时别把它和 evidence 混在一起，
  /// 也别因为它没有证据行就以为拿错了字段。存量卡片没有这一层，故可空。
  final String? depth;

  final List<InsightEvidence> evidence;
  final int worth;
  final int confidence;
  final String status;
  final InsightFeedback feedback;
  final String? windowStart;
  final String? windowEnd;
  final int? companionDays;
  final bool isScaffold;
  final DateTime? releasedAt;
  final DateTime? createdAt;

  const InsightCard({
    required this.id,
    required this.topicKey,
    required this.headline,
    required this.body,
    this.depth,
    this.evidence = const [],
    this.worth = 0,
    this.confidence = 0,
    this.status = 'candidate',
    this.feedback = InsightFeedback.none,
    this.windowStart,
    this.windowEnd,
    this.companionDays,
    this.isScaffold = false,
    this.releasedAt,
    this.createdAt,
  });

  factory InsightCard.fromJson(Map<String, dynamic> json) {
    final ev = (json['evidence'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(InsightEvidence.fromJson)
        .where((e) => !e.isEmpty)
        .toList();
    return InsightCard(
      id: (json['id'] ?? '').toString(),
      topicKey: (json['topic_key'] ?? '').toString(),
      headline: (json['headline'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      depth: (json['depth'] as String?)?.trim().isNotEmpty == true ? (json['depth'] as String).trim() : null,
      evidence: ev,
      worth: (json['worth'] as num?)?.toInt() ?? 0,
      confidence: (json['confidence'] as num?)?.toInt() ?? 0,
      status: (json['status'] ?? 'candidate').toString(),
      feedback: _feedbackFromString(json['feedback'] as String?),
      windowStart: json['window_start'] as String?,
      windowEnd: json['window_end'] as String?,
      companionDays: (json['companion_days'] as num?)?.toInt(),
      isScaffold: json['is_scaffold'] == true,
      releasedAt: _parseDate(json['released_at']),
      createdAt: _parseDate(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'topic_key': topicKey,
        'headline': headline,
        'body': body,
        'depth': depth,
        'evidence': evidence
            .map((e) => {
                  'quote': e.quote,
                  'conversation_id': e.conversationId,
                  'date': e.date,
                  'stat': e.stat,
                })
            .toList(),
        'worth': worth,
        'confidence': confidence,
        'status': status,
        'feedback': feedbackToString(feedback),
        'window_start': windowStart,
        'window_end': windowEnd,
        'companion_days': companionDays,
        'is_scaffold': isScaffold,
        'released_at': releasedAt?.toIso8601String(),
        'created_at': createdAt?.toIso8601String(),
      };

  InsightCard copyWith({InsightFeedback? feedback}) {
    return InsightCard(
      id: id,
      topicKey: topicKey,
      headline: headline,
      body: body,
      depth: depth,
      evidence: evidence,
      worth: worth,
      confidence: confidence,
      status: status,
      feedback: feedback ?? this.feedback,
      windowStart: windowStart,
      windowEnd: windowEnd,
      companionDays: companionDays,
      isScaffold: isScaffold,
      releasedAt: releasedAt,
      createdAt: createdAt,
    );
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v)?.toLocal();
    return null;
  }
}
