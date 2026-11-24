class HomeModuleUpdate {
  final String module;
  final String detail;
  final DateTime? updatedAt;

  HomeModuleUpdate({
    required this.module,
    required this.detail,
    required this.updatedAt,
  });

  factory HomeModuleUpdate.fromJson(Map<String, dynamic> json) {
    return HomeModuleUpdate(
      module: json['module'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
        'module': module,
        'detail': detail,
        'updated_at': updatedAt?.toIso8601String(),
      };
}
