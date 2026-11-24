import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';

void main() {
  test('unresolved voice identity survives the API and local cache round trip', () {
    for (final status in ['unknown', 'ambiguous', null]) {
      final segment = TranscriptSegment.fromJson({
        'id': 'synthetic', 'text': 'test', 'speaker_id': 1,
        'start': 99.03, 'end': 117.15, 'speaker_status': status,
        'speaker_assignment_source': 'manual',
      });
      final restored = TranscriptSegment.fromJson(segment.toJson());
      expect(restored.speakerStatus, status);
      expect(restored.speakerAssignmentSource, 'manual');
      expect(restored.isUser, isFalse);
      expect(restored.personId, isNull);
    }
  });

  test('display updates and cache round trips preserve original audio times', () {
    final segment = TranscriptSegment.fromJson({
      'id': 'test',
      'text': 'test',
      'speaker_id': 1,
      'start': 0.0,
      'end': 29.46,
      'original_start': 203.82,
      'original_end': 233.28,
      'timestamp_axis': 'display',
    });
    segment.start += 100;
    segment.end += 100;
    final restored = TranscriptSegment.fromJson(segment.toJson());
    expect(restored.originalStart, 203.82);
    expect(restored.originalEnd, 233.28);
    expect(restored.timestampAxis, 'display');
    expect(restored.start, 100);
  });

  test('legacy transcripts keep coordinates unresolved', () {
    final segment = TranscriptSegment.fromJson({
      'id': 'legacy', 'text': 'test', 'start': 0.0, 'end': 0.0,
    });
    expect(segment.originalStart, isNull);
    expect(segment.originalEnd, isNull);
    expect(segment.toJson().containsKey('original_start'), isFalse);
  });
}
