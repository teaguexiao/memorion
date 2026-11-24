import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    SharedPreferencesUtil().givenName = 'Synthetic user';
    SharedPreferencesUtil().cachedPeople = [
      for (final entry in {'alpha': 'Synthetic Alpha', 'beta': 'Synthetic Beta'}.entries)
        Person(id: entry.key, name: entry.value, createdAt: DateTime(2026), updatedAt: DateTime(2026)),
    ];
  });

  ServerConversation conversation(String id, List<Map<String, dynamic>> speakers) => ServerConversation(
        id: id,
        createdAt: DateTime(2026, 10, 19, 10),
        startedAt: DateTime(2026, 10, 19, 10),
        finishedAt: DateTime(2026, 10, 19, 10, 30),
        structured: Structured('Synthetic record', 'Synthetic summary.'),
        transcriptSegments: [
          for (final (index, speaker) in speakers.indexed)
            TranscriptSegment.fromJson({
              'id': '$id-$index',
              'text': 'Synthetic transcript.',
              'start': index.toDouble(),
              'end': index + 1.0,
              ...speaker,
            }),
        ],
      );

  Widget page(List<ServerConversation> sources, {bool chinese = false, double textScale = 1}) => MaterialApp(
        locale: Locale(chinese ? 'zh' : 'en'),
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ChapterDetailPage(conversation: sources.first, sources: sources),
      );

  testWidgets('identified contacts and self precede unknowns; +N expands and collapses', (tester) async {
    final source = conversation('a', [
      {'speaker_id': 4},
      {'speaker_id': 5},
      {'speaker_id': 1, 'person_id': 'alpha', 'speaker_assignment_source': 'automatic'},
      {'speaker_id': 2, 'person_id': 'beta', 'speaker_assignment_source': 'manual'},
      {'speaker_id': 3, 'is_user': true},
    ]);
    await tester.pumpWidget(page([source]));
    await tester.pump();

    final row = find.ancestor(of: find.text('+2'), matching: find.byType(Wrap));
    final labels = tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)));
    expect(labels.map((text) => text.data).take(4), ['Synthetic Alpha', 'Synthetic Beta', 'Synthetic user', '+2']);
    expect(find.text('Speaker 4'), findsNothing);
    expect(find.text('Speaker 5'), findsNothing);

    await tester.tap(find.text('+2'));
    await tester.pump();
    expect(find.text('Speaker 4'), findsOneWidget);
    expect(find.text('Speaker 5'), findsOneWidget);
    expect(find.text('+2'), findsNothing);
    expect(find.text('Collapse'), findsOneWidget);

    await tester.tap(find.text('Collapse'));
    await tester.pump();
    expect(find.text('Speaker 4'), findsNothing);
    expect(find.text('Speaker 5'), findsNothing);
    expect(find.text('+2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('up to three participants need no overflow control', (tester) async {
    for (final count in [0, 1, 3]) {
      await tester.pumpWidget(page([
        conversation('a', [
          for (var i = 1; i <= count; i++) {'speaker_id': i}
        ]),
      ]));
      await tester.pump();
      for (var i = 1; i <= count; i++) {
        expect(find.text('Speaker $i'), findsOneWidget);
      }
      expect(find.textContaining(RegExp(r'^\+\d+$')), findsNothing);
      expect(find.text('Collapse'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('merged sources deduplicate identities, preserve same names and recording-local unknowns',
      (tester) async {
    SharedPreferencesUtil().cachedPeople = [
      for (final id in ['alpha', 'beta'])
        Person(id: id, name: 'Synthetic same name', createdAt: DateTime(2026), updatedAt: DateTime(2026)),
    ];
    final sources = [
      conversation('a', [
        {'speaker_id': 0},
        {'speaker_id': 1, 'person_id': 'alpha'},
      ]),
      conversation('b', [
        {'speaker_id': 0},
        {'speaker_id': 1, 'person_id': 'alpha'},
        {'speaker_id': 2, 'person_id': 'beta'},
      ]),
    ];
    await tester.pumpWidget(page(sources));
    await tester.pump();
    expect(find.text('Synthetic same name'), findsNWidgets(2));
    expect(find.text('Speaker 0'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    await tester.tap(find.text('+1'));
    await tester.pump();
    expect(find.text('Speaker 0'), findsNWidgets(2));
    expect(find.text('Synthetic same name'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chinese overflow and long names wrap on narrow screens with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const longName = 'Synthetic participant with a very long display name';
    SharedPreferencesUtil().cachedPeople = [
      Person(id: 'long', name: longName, createdAt: DateTime(2026), updatedAt: DateTime(2026)),
    ];
    await tester.pumpWidget(page([
      conversation('a', [
        {'speaker_id': 1},
        {'speaker_id': 2},
        {'speaker_id': 3},
        {'speaker_id': 4, 'person_id': 'long'},
      ]),
    ], chinese: true, textScale: 1.5));
    await tester.pump();
    expect(find.text(longName), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('+1'));
    await tester.pump();
    expect(find.text('说话人 3'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
