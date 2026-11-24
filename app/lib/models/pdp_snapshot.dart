class PdpSnapshot {
  final String date;
  final String language;
  final String primaryAnimalKey;
  final String secondaryAnimalKey;
  final String primaryTraitKey;
  final String secondaryTraitKey;
  final String heroAnimalKey;
  final String heroSummary;
  final List<String> insightLines;
  final List<PdpMetric> metrics;
  final List<PdpTrajectoryEntry> trajectory;
  final DateTime? updatedAt;

  PdpSnapshot({
    required this.date,
    required this.language,
    required this.primaryAnimalKey,
    required this.secondaryAnimalKey,
    required this.primaryTraitKey,
    required this.secondaryTraitKey,
    required this.heroAnimalKey,
    required this.heroSummary,
    required this.insightLines,
    required this.metrics,
    required this.trajectory,
    required this.updatedAt,
  });

  factory PdpSnapshot.fromJson(Map<String, dynamic> json) {
    return PdpSnapshot(
      date: json['date'] as String? ?? '',
      language: json['language'] as String? ?? 'en',
      primaryAnimalKey: json['primary_animal_key'] as String? ?? 'tiger',
      secondaryAnimalKey: json['secondary_animal_key'] as String? ?? 'peacock',
      primaryTraitKey: json['primary_trait_key'] as String? ?? 'control',
      secondaryTraitKey: json['secondary_trait_key'] as String? ?? 'expression',
      heroAnimalKey: json['hero_animal_key'] as String? ?? 'tiger',
      heroSummary: json['hero_summary'] as String? ?? '',
      insightLines: (json['insight_lines'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
      metrics: (json['metrics'] as List<dynamic>? ?? const [])
          .map((e) => PdpMetric.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      trajectory: (json['trajectory'] as List<dynamic>? ?? const [])
          .map((e) => PdpTrajectoryEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }
}

class PdpMetric {
  final String key;
  final int score;
  final int delta;

  PdpMetric({
    required this.key,
    required this.score,
    required this.delta,
  });

  factory PdpMetric.fromJson(Map<String, dynamic> json) {
    return PdpMetric(
      key: json['key'] as String? ?? 'control',
      score: (json['score'] as num?)?.toInt() ?? 0,
      delta: (json['delta'] as num?)?.toInt() ?? 0,
    );
  }
}

class PdpTrajectoryEntry {
  final String date;
  final String animalKey;

  PdpTrajectoryEntry({
    required this.date,
    required this.animalKey,
  });

  factory PdpTrajectoryEntry.fromJson(Map<String, dynamic> json) {
    return PdpTrajectoryEntry(
      date: json['date'] as String? ?? '',
      animalKey: json['animal_key'] as String? ?? 'tiger',
    );
  }
}
