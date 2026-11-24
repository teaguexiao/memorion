class MoodPixelState {
  final String boardId;
  final int sampleIndex;
  final int totalSamples;
  final List<String> pattern;
  final List<String?> fills;
  final Map<String, int> remaining;
  final String? selectedMood;
  final bool isComplete;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  MoodPixelState({
    required this.boardId,
    required this.sampleIndex,
    required this.totalSamples,
    required this.pattern,
    required this.fills,
    required this.remaining,
    required this.selectedMood,
    required this.isComplete,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MoodPixelState.fromJson(Map<String, dynamic> json) {
    final rawRemaining = Map<String, dynamic>.from(json['remaining'] as Map? ?? const {});
    return MoodPixelState(
      boardId: json['board_id'] as String? ?? 'weekly_v2_heart',
      sampleIndex: (json['sample_index'] as num?)?.toInt() ?? 0,
      totalSamples: (json['total_samples'] as num?)?.toInt() ?? 1,
      pattern: (json['pattern'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
      fills: (json['fills'] as List<dynamic>? ?? const []).map((e) => e?.toString()).toList(),
      remaining: rawRemaining.map((key, value) => MapEntry(key, (value as num?)?.toInt() ?? 0)),
      selectedMood: json['selected_mood'] as String?,
      isComplete: json['is_complete'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }

  MoodPixelState copyWith({
    String? boardId,
    int? sampleIndex,
    int? totalSamples,
    List<String>? pattern,
    List<String?>? fills,
    Map<String, int>? remaining,
    String? selectedMood,
    bool clearSelectedMood = false,
    bool? isComplete,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return MoodPixelState(
      boardId: boardId ?? this.boardId,
      sampleIndex: sampleIndex ?? this.sampleIndex,
      totalSamples: totalSamples ?? this.totalSamples,
      pattern: pattern ?? this.pattern,
      fills: fills ?? this.fills,
      remaining: remaining ?? this.remaining,
      selectedMood: clearSelectedMood ? null : (selectedMood ?? this.selectedMood),
      isComplete: isComplete ?? this.isComplete,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toUpdatePayload() => {
        'board_id': boardId,
        'fills': fills,
        'selected_mood': selectedMood,
      };

  List<String> get cellTypes {
    final occupied = List<bool>.filled(225, false);
    // Guard against a malformed server pattern (rows/cols beyond the 15x15
    // board) so an oversized line can't throw a RangeError.
    final rowCount = pattern.length < 15 ? pattern.length : 15;
    for (var row = 0; row < rowCount; row++) {
      final line = pattern[row];
      final colCount = line.length < 15 ? line.length : 15;
      for (var col = 0; col < colCount; col++) {
        occupied[row * 15 + col] = line[col] == '#';
      }
    }

    final result = List<String>.filled(225, 'outside');
    for (var row = 0; row < 15; row++) {
      for (var col = 0; col < 15; col++) {
        final index = row * 15 + col;
        if (!occupied[index]) continue;
        final neighbors = <int>[];
        if (row > 0) neighbors.add((row - 1) * 15 + col);
        if (row < 14) neighbors.add((row + 1) * 15 + col);
        if (col > 0) neighbors.add(row * 15 + col - 1);
        if (col < 14) neighbors.add(row * 15 + col + 1);
        final isEdge = neighbors.any((neighbor) => !occupied[neighbor]);
        result[index] = isEdge ? 'edge' : 'fillable';
      }
    }
    return result;
  }

  int get remainingTotal => remaining.values.fold(0, (sum, value) => sum + value);
}
