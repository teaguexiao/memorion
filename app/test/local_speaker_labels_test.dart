import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/pages/today_chapters/widgets/transcript_common.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('server split groups keep contact names off unresolved rows', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    SharedPreferencesUtil().givenName = 'Synthetic user';
    SharedPreferencesUtil().cachedPeople = [
      Person(id: 'synthetic', name: 'Synthetic contact',
          createdAt: DateTime(2026), updatedAt: DateTime(2026)),
    ];
    // Same mixed diarization group, partitioned by the backend into 10/11/1.
    final segments = [
      {'speaker_id': 10, 'is_user': true},
      {'speaker_id': 11, 'person_id': 'synthetic'},
      {'speaker_id': 1, 'speaker_status': 'unknown'},
      {'speaker_id': 1},
    ].asMap().entries.map((entry) => TranscriptSegment.fromJson({
      'id': 'row-${entry.key}', 'text': 'Synthetic', 'start': 0.0, 'end': 8.0,
      ...entry.value,
    })).map((s) => TranscriptSegment.fromJson(s.toJson())).toList();
    late Map<int, String> labels;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      labels = speakerLabels(context, segments);
      return const SizedBox();
    })));
    expect(labels[10], 'Synthetic user');
    expect(labels[11], 'Synthetic contact');
    expect(labels[1], 'Speaker 1');
    expect(segments.where((s) => s.speakerId == 1).every((s) => !s.isUser && s.personId == null), isTrue);
  });
}
