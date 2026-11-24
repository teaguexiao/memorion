class ChatSession {
  final String id;
  final List<String> messageIds;
  final String? appId;
  final String? pluginId;
  final DateTime createdAt;
  final String? title;
  final List<String> contextConversationIds;

  ChatSession({
    required this.id,
    required this.messageIds,
    this.appId,
    this.pluginId,
    required this.createdAt,
    this.title,
    this.contextConversationIds = const [],
  });

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] as String,
      messageIds: List<String>.from(json['message_ids'] ?? []),
      appId: json['app_id'] as String?,
      pluginId: json['plugin_id'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      title: json['title'] as String?,
      contextConversationIds: List<String>.from(json['context_conversation_ids'] ?? []),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'message_ids': messageIds,
      'app_id': appId,
      'plugin_id': pluginId,
      'created_at': createdAt.toIso8601String(),
      'title': title,
      'context_conversation_ids': contextConversationIds,
    };
  }

  ChatSession copyWith({
    String? id,
    List<String>? messageIds,
    String? appId,
    String? pluginId,
    DateTime? createdAt,
    String? title,
  }) {
    return ChatSession(
      id: id ?? this.id,
      messageIds: messageIds ?? this.messageIds,
      appId: appId ?? this.appId,
      pluginId: pluginId ?? this.pluginId,
      createdAt: createdAt ?? this.createdAt,
      title: title ?? this.title,
      contextConversationIds: contextConversationIds,
    );
  }

  static bool isDefaultTitle(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return true;
    return normalized.startsWith('New Chat') || normalized.startsWith('Chat Session'); // i18n-ignore
  }

  String get displayTitle => isDefaultTitle(title) ? '' : title!.trim();
}
