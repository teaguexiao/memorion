import 'dart:convert';
import 'dart:math';

class Structured {
  int id = 0;

  String title;
  String overview;
  String emoji;
  String category;
  String? emotion;

  /// P-01 今日·时光时间线章节卡第二行——记小宝的第一人称观察（后端
  /// structured.first_person_observation，轻量二次 LLM 生成）。老数据/生成失败
  /// 时为 null，由 UI 回退本地 mock 语料。
  String? firstPersonObservation;

  /// 值得回顾的高亮原话（后端 structured.highlights，随 summary 一次生成，0~3 句、
  /// 可为空）。**仅**用于 P-11「值得回顾的时刻」引用卡。
  ///
  /// ⚠️ 不要用它推导首页 P-01 章节卡的⭐高亮标签——高亮已改为硬件按钮驱动，
  /// 见 [isHighlighted]。二者已解耦，AI 自动生成的原话不再让首页跟着高亮。
  List<String> highlights = [];

  /// 显式高亮标记（后端 structured.is_highlighted）。**唯一**决定 P-01 首页章节卡
  /// 是否显示⭐高亮标签。
  ///
  /// 触发源：未来用户**按硬件按钮**时，由固件上报 → 后端把这条会话置 true。
  /// 目前尚无写入方（硬件链路未接），故线上数据一律缺省 false → 首页无高亮，
  /// 这是预期行为。老数据无此字段 → fromJson 回落 false，无需迁移。
  bool isHighlighted = false;

  List<ActionItem> actionItems = [];

  List<Event> events = [];

  Structured(this.title, this.overview,
      {this.id = 0,
      this.emoji = '',
      this.category = 'other',
      this.emotion,
      this.firstPersonObservation,
      List<String>? highlights,
      this.isHighlighted = false})
      : highlights = highlights ?? [];

  getEmoji() {
    try {
      if (emoji.isNotEmpty) return utf8.decode(emoji.toString().codeUnits);
      return ['🧠', '😎', '🧑‍💻', '🚀'][Random().nextInt(4)];
    } catch (e) {
      // return ['🧠', '😎', '🧑‍💻', '🚀'][Random().nextInt(4)];
      return emoji; // should return random?
    }
  }

  static Structured fromJson(Map<String, dynamic> json) {
    var structured = Structured(
      json['title'],
      json['overview'],
      emoji: json['emoji'],
      category: json['category'],
      emotion: json['emotion'],
      firstPersonObservation: json['first_person_observation'] ?? json['firstPersonObservation'],
      highlights: ((json['highlights'] ?? []) as List<dynamic>)
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toList(),
      // 硬件按钮高亮标记：老数据/后端未下发时缺省 false（不再由 highlights 推导）。
      isHighlighted: (json['is_highlighted'] ?? json['isHighlighted'] ?? false) == true,
    );
    var aItems = json['actionItems'] ?? json['action_items'];
    if (aItems != null) {
      for (dynamic item in aItems) {
        if (item.runtimeType == String) {
          if (item.isEmpty) continue;
          structured.actionItems.add(ActionItem(item));
        } else {
          structured.actionItems.add(ActionItem.fromJson(item));
        }
      }
    }

    if (json['events'] != null) {
      for (dynamic event in json['events']) {
        if (event.isEmpty) continue;
        structured.events.add(Event(
          event['title'],
          (event['startsAt'] ?? event['start']) is int
              ? DateTime.fromMillisecondsSinceEpoch((event['startsAt'] ?? event['start']) * 1000).toLocal()
              : DateTime.parse(event['startsAt'] ?? event['start']).toLocal(),
          event['duration'],
          description: event['description'] ?? '',
          created: event['created'] ?? false,
        ));
      }
    }
    return structured;
  }

  @override
  String toString() {
    var str = '';
    str += '${getEmoji()} $title\n\n$overview\n\n'; // ($category)
    if (actionItems.isNotEmpty) {
      str += 'Action Items:\n';
      for (var item in actionItems) {
        str += '- ${item.description}\n';
      }
    }
    if (events.isNotEmpty) {
      str += 'Events:\n';
      for (var event in events) {
        str += '- ${event.title} (${event.startsAt.toLocal()} for ${event.duration} minutes)\n';
      }
    }
    return str.trim();
  }

  toJson() {
    return {
      'title': title,
      'overview': overview,
      'emoji': emoji,
      'category': category,
      'emotion': emotion,
      'first_person_observation': firstPersonObservation,
      'highlights': highlights,
      'is_highlighted': isHighlighted,
      'actionItems': actionItems.map((item) => item.description).toList(),
      'events': events.map((event) => event.toJson()).toList(),
    };
  }
}

class ActionItem {
  int id = 0;

  String description;
  bool completed = false;
  bool deleted = false;

  /// 用户是否已把它确认为待办。LLM 新提取的是 false（待确认，只在 P-01 气泡卡出现），
  /// 老数据缺该字段时按 true 处理（沿用旧行为，不集体退回待确认）。
  bool confirmed = true;

  /// 截止日期。只在后端能确定到具体某天时才有值——「本周内」这类模糊说法一律为 null，
  /// 用于本地提醒与写入苹果提醒事项（宁可没时间，也不要错的时间）。
  DateTime? dueDate;

  /// 人说的时间原话（「本周内」「尽快」「周五前」），只作展示用的小标签。
  String dueHint;

  ActionItem(
    this.description, {
    this.id = 0,
    this.completed = false,
    this.deleted = false,
    this.confirmed = true,
    this.dueDate,
    this.dueHint = '',
  });

  static fromJson(Map<String, dynamic> json) {
    return ActionItem(
      json['description'],
      completed: json['completed'] ?? false,
      deleted: json['deleted'] ?? false,
      confirmed: json['confirmed'] ?? true,
      dueDate: json['due_date'] != null ? DateTime.tryParse(json['due_date'].toString())?.toLocal() : null,
      dueHint: json['due_hint'] ?? '',
    );
  }

  toJson() => {
        'description': description,
        'completed': completed,
        'deleted': deleted,
        'confirmed': confirmed,
        'due_date': dueDate?.toUtc().toIso8601String(),
        'due_hint': dueHint,
      };
}

class AppResponse {
  int id = 0;

  String? appId;
  String content;

  AppResponse(this.content, {this.id = 0, this.appId});

  toJson() => {'appId': appId, 'content': content};

  factory AppResponse.fromJson(Map<String, dynamic> json) {
    return AppResponse(json['content'], appId: json['appId'] ?? json['app_id']);
  }
}

class Event {
  int id = 0;

  String title;
  DateTime startsAt;
  int duration;

  String description;
  bool created = false;

  Event(this.title, this.startsAt, this.duration, {this.description = '', this.created = false, this.id = 0});

  toJson() {
    return {
      'title': title,
      'startsAt': startsAt.toUtc().toIso8601String(),
      'duration': duration,
      'description': description,
      'created': created,
    };
  }
}
