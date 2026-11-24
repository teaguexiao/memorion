enum MemoryCategory { interesting, system }

enum MemoryVisibility { private, public }

class Memory {
  String id;
  String uid;
  String content;
  MemoryCategory category;
  DateTime createdAt;
  DateTime updatedAt;
  String? conversationId;
  bool reviewed;
  bool? userReview;
  bool manuallyAdded;
  bool edited;
  bool deleted;
  MemoryVisibility visibility;

  Memory({
    required this.id,
    required this.uid,
    required this.content,
    required this.category,
    required this.createdAt,
    required this.updatedAt,
    this.conversationId,
    this.reviewed = false,
    this.userReview,
    this.manuallyAdded = false,
    this.edited = false,
    this.deleted = false,
    required this.visibility,
  });

  factory Memory.fromJson(Map<String, dynamic> json) {
    // Extract conversation_id from metadata if not at top level
    String? conversationId = json['conversation_id'];
    if (conversationId == null && json['metadata'] is Map) {
      conversationId = json['metadata']['conversation_id'];
    }

    return Memory(
      id: json['id'],
      uid: json['uid'] ?? '',  // uid may not be returned by the API
      content: json['content'],
      category: MemoryCategory.values.firstWhere(
        (e) => e.toString().split('.').last == json['category'],
        orElse: () => MemoryCategory.interesting,
      ),
      createdAt: DateTime.parse(json['created_at']).toLocal(),
      updatedAt: DateTime.parse(json['updated_at']).toLocal(),
      conversationId: conversationId,
      reviewed: json['reviewed'] ?? false,
      userReview: json['user_review'],
      manuallyAdded: json['manually_added'] ?? false,
      edited: json['edited'] ?? false,
      deleted: json['deleted'] ?? false,
      visibility: json['visibility'] != null
          ? (MemoryVisibility.values.asNameMap()[json['visibility']] ?? MemoryVisibility.private)
          : MemoryVisibility.private,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'uid': uid,
      'content': content,
      'category': category.toString().split('.').last,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'memory_id': conversationId,
      'reviewed': reviewed,
      'user_review': userReview,
      'manually_added': manuallyAdded,
      'edited': edited,
      'deleted': deleted,
      'visibility': visibility.name,
    };
  }
}
