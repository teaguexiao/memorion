/// 自定义词库词条（Phase 0：只存 term + 时间戳）。
///
/// 后端集合：developer_data/{developer_id}/users/{external_user_id}/vocabulary。
/// 未来接 LLM 后处理纠错时，后端可无痛加 pinyin/heard_text/source 等字段（Firestore
/// schemaless），此处 [fromJson] 已容忍缺省，届时补字段即可。
class VocabularyWord {
  final String id;
  final String term;
  final DateTime createdAt;
  final DateTime updatedAt;

  VocabularyWord({
    required this.id,
    required this.term,
    required this.createdAt,
    required this.updatedAt,
  });

  factory VocabularyWord.fromJson(Map<String, dynamic> json) {
    DateTime parse(String? s) => s != null ? DateTime.parse(s).toLocal() : DateTime.now();
    return VocabularyWord(
      id: json['id'] ?? '',
      term: json['term'] ?? '',
      createdAt: parse(json['created_at']),
      updatedAt: parse(json['updated_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'term': term,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }
}
