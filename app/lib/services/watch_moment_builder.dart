/// Builds a reviewable moment strictly from transcript intervals around a saved mark.
/// Original timestamps take precedence when transcription removed silence.
Map<String, dynamic> watchMomentFromMark({
  required Map<String, dynamic> mark,
  required String recordingKey,
  String? conversationId,
  required String status,
  List<Map<String, dynamic>> transcript = const [],
}) {
  final offset = (mark['offsetSeconds'] as num).toDouble();
  final before = (mark['contextBeforeSeconds'] as num?)?.toDouble() ?? 15;
  final after = (mark['contextAfterSeconds'] as num?)?.toDouble() ?? 15;
  final nearby = transcript.where((segment) {
    final start = (segment['original_start'] as num? ?? segment['start'] as num?)?.toDouble();
    final end = (segment['original_end'] as num? ?? segment['end'] as num?)?.toDouble();
    return start != null &&
        end != null &&
        start.isFinite &&
        end.isFinite &&
        end >= offset - before &&
        start <= offset + after;
  }).toList()
    ..sort(
        (a, b) => ((a['original_start'] ?? a['start']) as num).compareTo((b['original_start'] ?? b['start']) as num));
  final text = nearby.map((s) => (s['text'] as String? ?? '').trim()).where((s) => s.isNotEmpty).join(' ');
  final result = <String, dynamic>{
    'id': mark['id'],
    'markedAtMs': mark['markedAtMs'],
    'offsetSeconds': offset,
    'recordingKey': recordingKey,
    'status': status == 'completed' ? (text.isEmpty ? 'noSpeech' : 'ready') : status,
    if (conversationId != null) 'conversationId': conversationId,
    if (status == 'completed' && text.isNotEmpty)
      'text': text.runes.length > 1200 ? '${String.fromCharCodes(text.runes.take(1200))}…' : text,
  };
  return result;
}
