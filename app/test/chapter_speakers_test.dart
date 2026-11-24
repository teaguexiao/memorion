import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/chapter_speaker.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:memorion/pages/today_chapters/widgets/chapter_speakers.dart';
import 'package:memorion/providers/timeline_provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:memorion/widgets/jxb_toast.dart';
import 'package:memorion/utils/markdown_summary_selection.dart';
import 'package:memorion/widgets/summary_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/chapter_speaker_fixture.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });
  test('metadata roundtrip never leaks raw tokens and prose corrections preserve identities', () {
    final chapter = speakerFixture();
    final loaded = TimelineChapter.fromJson(chapter.toJson())!;
    expect(loaded.plainOverview(chinese: true), contains('涛哥'));
    expect(loaded.plainOverview(chinese: true), isNot(contains('[[speaker:')));
    expect(loaded.rawOverview, chapter.rawOverview);
    final markdown = loaded.attributedOverview(chinese: true);
    final doc = MarkdownSummarySource(markdown);
    final offset = doc.text.indexOf('两个兼容问题');
    final edited = doc.selection(offset, offset + 6, '两个兼容问题')!.replaceWith('三个兼容问题');
    expect(ChapterSpeakerDisplay.restoreTokens(edited!), chapter.rawOverview.replaceFirst('两个兼容问题', '三个兼容问题'));
    final special = ChapterSpeakerDisplay(
        speakers: const [ChapterSpeaker(id: 's', name: 'A[乙]*', status: 'confirmed')],
        mentions: {speakerEvidenceIds.first: 's'});
    final escaped = special.render('[[speaker:${speakerEvidenceIds.first}]]', links: true);
    expect(MarkdownSummarySource(escaped).text, 'A[乙]*');
    final missingMetadata = TimelineChapter.fromJson({...chapter.toJson(), 'speaker_display': null})!;
    expect(missingMetadata.attributedOverview(chinese: false), contains('Someone'));
    expect(missingMetadata.attributedOverview(chinese: false), isNot(contains('有人')));
    expect(missingMetadata.attributedOverview(chinese: false), isNot(contains('[[speaker:')));
  });

  test('identity correction cannot resurrect stale owner observation from source or disk cache', () {
    final base = speakerFixture().toJson();
    final corrected = TimelineChapter.fromJson({...base, 'observation_stale': true, 'first_person_observation': ''})!;
    final cached = TimelineChapter.fromJson(corrected.toJson())!;
    expect(cached.observationWithFallback('你承诺联系媒体'), isEmpty);
    final undone = TimelineChapter.fromJson({...base, 'first_person_observation': '待确认'})!;
    expect(undone.observationWithFallback('源观察'), '待确认');
    expect(speakerFixture().observationWithFallback('旧数据观察'), '旧数据观察');
  });

  test('partial source deletion preserves speaker targets through the provisional disk cache', () {
    final base = TimelineChapter.fromJson({
      ...speakerFixture().toJson(),
      'source_conversation_ids': ['kept', 'removed']
    })!;
    final remaining = TimelineChapter.fromJson(base.withoutConversations({'removed'})!.toJson())!;
    expect(remaining.sourceConversationIds, ['kept']);
    expect(remaining.rawOverview, base.rawOverview);
    expect(remaining.speakerRevision, base.speakerRevision);
    expect(remaining.attributedOverview(chinese: true), base.attributedOverview(chinese: true));
    expect(remaining.speakerDisplay!.usedIn(remaining.rawOverview).length, 3);
    expect(base.withoutConversations({'kept', 'removed'}), isNull);
  });

  Future<TimelineProvider> page(WidgetTester tester, FixtureSpeakerApi api, {TimelineDayFetcher? fetch}) async {
    final provider = TimelineProvider(fetch: fetch);
    final chapter = speakerFixture();
    provider.seedDay(TimelineDay(
        date: '2026-10-24',
        timezone: 'Asia/Shanghai',
        chapters: [chapter],
        sourceConversationIds: chapter.sourceConversationIds,
        cache: 'hit',
        computedAt: null));
    addTearDown(provider.dispose);
    final undo = UndoDeleteController();
    addTearDown(undo.dispose);
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider.value(value: undo),
        ],
        child: MaterialApp(
            navigatorObservers: [UndoDeleteNavigatorObserver(undo)],
            builder: (_, child) => UndoDeleteHost(child: child!),
            home: ChapterDetailPage(conversation: speakerSource(), chapter: chapter, speakerApi: api))));
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    return provider;
  }

  Future<void> tapVisible(WidgetTester tester, String label) async {
    final finder = find.text(label).last;
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
  }

  testWidgets('summary export uses readable names in the UI language without internal links', (tester) async {
    MethodCall? shared;
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      shared = call;
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await page(tester, FixtureSpeakerApi());
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await tapVisible(tester, 'Export Summary');
    final text = (shared!.arguments as Map)['text'] as String;
    expect(text, contains('涛哥'));
    expect(text, contains('Speaker A'));
    expect(text, contains('You'));
    expect(text, isNot(contains('说话人')));
    expect(text, isNot(contains('speaker:')));
    expect(text, isNot(contains('confirmed')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('source evidence, local correction, cache, body/header and undo agree', (tester) async {
    final api = FixtureSpeakerApi();
    final provider = await page(tester, api);
    await tapVisible(tester, 'Speaker A');
    expect(find.text(speakerQuotes[1]), findsOneWidget);
    expect(find.text('Audio unavailable or timing unverified'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    await tapVisible(tester, '涛哥');
    await tapVisible(tester, 'Save for this chapter');
    expect(api.corrections, 1);
    expect(api.enrollments, 0);
    expect(find.text('Speaker A'), findsNothing);
    expect(provider.chaptersFor('2026-10-24').single.plainOverview(chinese: true), contains('涛哥担心'));
    expect(provider.chaptersFor('2026-10-24').single.rawOverview, speakerFixture().rawOverview);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(JxbToast), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tapVisible(tester, 'Undo');
    expect(api.undos, 1);
    expect(find.text('Speaker A'), findsOneWidget);
    expect(provider.chaptersFor('2026-10-24').single.rawOverview, speakerFixture().rawOverview);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving chapter dismisses its undo action', (tester) async {
    final api = FixtureSpeakerApi();
    final provider = await page(tester, api);
    await tapVisible(tester, 'Speaker A');
    await tapVisible(tester, '涛哥');
    await tapVisible(tester, 'Save for this chapter');
    expect(find.text('Undo'), findsOneWidget);
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushReplacement(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Home'))));
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
    expect(api.undos, 0);
    expect(provider.chaptersFor('2026-10-24').single.plainOverview(chinese: true), contains('涛哥担心'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('undo already started completes in provider after leaving chapter', (tester) async {
    final gate = Completer<void>();
    final api = FixtureSpeakerApi()..undoGate = gate.future;
    final provider = await page(tester, api);
    await tapVisible(tester, 'Speaker A');
    await tapVisible(tester, '涛哥');
    await tapVisible(tester, 'Save for this chapter');
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(api.undos, 1);
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushReplacement(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Home'))));
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    gate.complete();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(provider.chaptersFor('2026-10-24').single.plainOverview(chinese: true),
        speakerFixture().plainOverview(chinese: true));
    expect(find.text('Undo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap attributed body name opens its own evidence, without entering prose edit', (tester) async {
    final api = FixtureSpeakerApi();
    await page(tester, api);
    final body = find.descendant(of: find.byType(SummaryMarkdown), matching: find.byType(RichText));
    final text = tester.widget<RichText>(body.first).text;
    TextSpan? name;
    text.visitChildren((span) {
      if (span is TextSpan && span.text == '涛哥') name = span;
      return true;
    });
    expect(name?.recognizer, isNotNull);
    // A text-span recognizer is the native tap target, not a separate full-width widget.
    (name!.recognizer as dynamic).onTap();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(find.text(speakerQuotes.first), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(api.evidenceCalls, 1);
  });

  testWidgets('failed evidence retries and never allows a blind correction', (tester) async {
    final api = FixtureSpeakerApi()..failEvidence = true;
    await page(tester, api);
    await tapVisible(tester, 'Speaker A');
    expect(api.corrections, 0);
    expect(find.byType(CheckboxListTile), findsNothing);
    final save = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save for this chapter'));
    expect(save.onPressed, isNull);
    api.failEvidence = false;
    await tapVisible(tester, 'Retry');
    expect(find.text(speakerQuotes[1]), findsOneWidget);
  });

  TimelineDay refreshedDay({bool removeSpeaker = false}) => TimelineDay(
      date: '2026-10-24',
      timezone: 'Asia/Shanghai',
      chapters: [
        TimelineChapter.fromJson({
          ...speakerFixture(count: removeSpeaker ? 0 : 3).toJson(),
          'speaker_revision': 'server-new',
        })!
      ],
      sourceConversationIds: speakerFixture().sourceConversationIds,
      cache: 'hit',
      computedAt: null);

  testWidgets('expired cached revision refreshes evidence, detail and disk before an explicit correction',
      (tester) async {
    final api = FixtureSpeakerApi()..requiredEvidenceRevision = 'server-new';
    final fetches = <bool>[];
    final provider = await page(tester, api, fetch: ({required date, refresh = false}) async {
      fetches.add(refresh);
      return refreshedDay();
    });
    await tapVisible(tester, 'Speaker A');
    expect(fetches, [false]);
    expect(api.evidenceRevisions, ['fixture-0', 'server-new']);
    expect(find.text(speakerQuotes[1]), findsOneWidget);
    expect(provider.chaptersFor('2026-10-24').single.speakerRevision, 'server-new');
    final cached = TimelineProvider();
    addTearDown(cached.dispose);
    expect(cached.chaptersFor('2026-10-24').single.speakerRevision, 'server-new');
    expect(api.corrections, 0);
    expect(api.enrollments, 0);
    await tapVisible(tester, '涛哥');
    await tapVisible(tester, 'Save for this chapter');
    expect(api.correctionRevision, 'server-new');
    expect(api.corrections, 1);
    expect(api.enrollments, 0);
  });

  testWidgets('a removed speaker never retargets another person or permits saving', (tester) async {
    final api = FixtureSpeakerApi()..requiredEvidenceRevision = 'server-new';
    final provider =
        await page(tester, api, fetch: ({required date, refresh = false}) async => refreshedDay(removeSpeaker: true));
    await tapVisible(tester, 'Speaker A');
    expect(api.evidenceCalls, 1);
    expect(find.text(speakerQuotes[1]), findsNothing);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save for this chapter')).onPressed, isNull);
    expect(provider.chaptersFor('2026-10-24').single.speakerDisplay!.speakers, isEmpty);
    expect(api.corrections, 0);
    expect(api.enrollments, 0);
  });

  testWidgets('a genuinely changed source stops after one read retry', (tester) async {
    final api = FixtureSpeakerApi()..alwaysStaleEvidence = true;
    var fetches = 0;
    await page(tester, api, fetch: ({required date, refresh = false}) async {
      fetches++;
      return refreshedDay();
    });
    await tapVisible(tester, 'Speaker A');
    expect(fetches, 1);
    expect(api.evidenceCalls, 2);
    expect(find.text(speakerQuotes[1]), findsNothing);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save for this chapter')).onPressed, isNull);
    expect(api.enrollments, 0);
  });

  testWidgets('failed chapter reload keeps the cache and Retry actually fetches again', (tester) async {
    final api = FixtureSpeakerApi()..requiredEvidenceRevision = 'server-new';
    var fetches = 0;
    final provider = await page(tester, api, fetch: ({required date, refresh = false}) async {
      return ++fetches == 1 ? null : refreshedDay();
    });
    await tapVisible(tester, 'Speaker A');
    expect(provider.chaptersFor('2026-10-24').single.speakerRevision, 'fixture-0');
    expect(find.text(speakerQuotes[1]), findsNothing);
    await tapVisible(tester, 'Retry');
    expect(fetches, 2);
    expect(find.text(speakerQuotes[1]), findsOneWidget);
    expect(api.enrollments, 0);
  });

  testWidgets('new person entry stays above keyboard and creates a stable identity on save', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final api = FixtureSpeakerApi()
      ..evidenceOverride = const [
        ChapterSpeakerEvidence(id: 'long', conversationId: 'c', text: 'Long quote', audioStart: 0, audioEnd: 18),
      ];
    final provider = await page(tester, api);
    await tapVisible(tester, 'Speaker A');
    await tapVisible(tester, '＋ Add or choose a person');
    tester.view.viewInsets = const FakeViewPadding(bottom: 329);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    final useName = find.widgetWithText(FilledButton, 'Add as a new person');
    expect(tester.getBottomLeft(useName).dy, lessThanOrEqualTo(844 - 329));
    await tester.enterText(find.byType(TextField), 'Lin');
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await tapVisible(tester, 'Add as a new person');
    tester.view.resetViewInsets();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(find.byType(CheckboxListTile), findsNothing);
    tester.widget<ChapterEvidencePlayer>(find.byType(ChapterEvidencePlayer)).onReviewed!();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    final consent = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(consent.onChanged, isNotNull);
    expect(consent.value, isFalse);
    await tapVisible(tester, 'Save for this chapter');
    expect(provider.chaptersFor('2026-10-24').single.plainOverview(chinese: true), contains('Lin担心'));
    expect(api.enrollments, 0);
    expect(api.createdName, 'Lin');
    expect(provider.chaptersFor('2026-10-24').single.speakerDisplay!.speakers[1].personId, 'created-person');
    await tapVisible(tester, 'Undo');
    expect(provider.chaptersFor('2026-10-24').single.plainOverview(chinese: true), contains('说话人 A'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed correction retains displayed identity and retry succeeds', (tester) async {
    final api = FixtureSpeakerApi()..failCorrection = true;
    final provider = await page(tester, api);
    await tapVisible(tester, 'Speaker A');
    await tapVisible(tester, 'You');
    await tapVisible(tester, 'Save for this chapter');
    expect(provider.chaptersFor('2026-10-24').single.plainOverview(chinese: true), contains('说话人 A'));
    api.failCorrection = false;
    await tapVisible(tester, 'Save for this chapter');
    expect(api.corrections, 1);
    expect(api.enrollments, 0);
  });

  testWidgets('learning is opt-in; its failure keeps chapter edit with retry and full undo', (tester) async {
    final api = FixtureSpeakerApi()
      ..evidenceOverride = [
        const ChapterSpeakerEvidence(
            id: 'long', conversationId: 'source', text: 'A longer quote', audioStart: 0, audioEnd: 18)
      ]
      ..failEnrollment = true;
    await page(tester, api);
    await tapVisible(tester, 'Speaker A');
    await tapVisible(tester, 'You');
    final check = find.byType(Checkbox);
    expect(check, findsNothing);
    expect(find.text('Listen to the whole clip before confirming it for voice learning.'), findsOneWidget);
    tester.widget<ChapterEvidencePlayer>(find.byType(ChapterEvidencePlayer)).onReviewed!();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(tester.widget<Checkbox>(check).value, isFalse);
    expect(tester.widget<Checkbox>(check).onChanged, isNotNull);
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await tapVisible(tester, 'Save and remember voice');
    expect(api.corrections, 1);
    expect(api.enrollments, 1);
    expect(api.enrolledEvidenceId, 'long');
    expect(find.text('Retry learning'), findsOneWidget);
    api.failEnrollment = false;
    await tapVisible(tester, 'Retry learning');
    expect(api.corrections, 1);
    expect(api.enrollments, 2);
    await tapVisible(tester, 'Undo');
    expect(api.undos, 1);
    expect(find.text('Speaker A'), findsOneWidget);
  });

  testWidgets('long quote recommended; switching clears voice consent and short audio stays ineligible',
      (tester) async {
    final api = FixtureSpeakerApi()
      ..evidenceOverride = const [
        ChapterSpeakerEvidence(id: 'short', conversationId: 'c', text: 'Short quote', audioStart: 0, audioEnd: 3),
        ChapterSpeakerEvidence(id: 'long', conversationId: 'c', text: 'Long quote', audioStart: 5, audioEnd: 23),
        ChapterSpeakerEvidence(id: 'other', conversationId: 'c', text: 'Another quote', audioStart: 30, audioEnd: 44),
      ];
    await page(tester, api);
    await tapVisible(tester, '涛哥');
    expect(find.text('Long quote'), findsOneWidget);
    expect(find.text('Short quote'), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    tester.widget<ChapterEvidencePlayer>(find.byType(ChapterEvidencePlayer)).onReviewed!();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    final tile = find.byType(CheckboxListTile);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(tester.widget<CheckboxListTile>(tile).value, isTrue); // Current person was preselected.
    await tapVisible(tester, 'Try another clip');
    expect(find.text('Another quote'), findsOneWidget);
    expect(tile, findsNothing); // An eligible but unreviewed clip still needs a full listen.
    await tapVisible(tester, 'Try another clip');
    expect(find.text('Short quote'), findsOneWidget);
    tester.widget<ChapterEvidencePlayer>(find.byType(ChapterEvidencePlayer)).onReviewed!();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(tile, findsNothing); // Listening cannot make a short clip eligible.
    await tapVisible(tester, 'Try another clip');
    expect(find.text('Long quote'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(tile).value, isFalse);
    await tapVisible(tester, 'Save for this chapter');
    expect(api.enrollments, 0);
  });

  testWidgets('reviewed audio needs a person; visible consent toggles and resets when person changes', (tester) async {
    final api = FixtureSpeakerApi()
      ..evidenceOverride = const [
        ChapterSpeakerEvidence(id: 'long', conversationId: 'c', text: 'Long quote', audioStart: 0, audioEnd: 18),
      ];
    await page(tester, api);
    await tapVisible(tester, 'Speaker A');
    final tile = find.byType(CheckboxListTile);
    expect(tile, findsNothing);
    tester.widget<ChapterEvidencePlayer>(find.byType(ChapterEvidencePlayer)).onReviewed!();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(tile, findsNothing);
    expect(find.text('Choose or add a person to remember their voice.'), findsOneWidget);
    await tapVisible(tester, '涛哥');
    expect(tester.widget<CheckboxListTile>(tile).value, isFalse);
    expect(tester.widget<CheckboxListTile>(tile).onChanged, isNotNull);
    await tester.ensureVisible(tile);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(tester.widget<CheckboxListTile>(tile).value, isTrue);
    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(tester.widget<CheckboxListTile>(tile).value, isFalse);
    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await tapVisible(tester, 'Unconfirmed');
    expect(tile, findsNothing);
    await tapVisible(tester, 'You');
    expect(tester.widget<CheckboxListTile>(tile).value, isFalse);
    await tapVisible(tester, 'Save for this chapter');
    expect(api.enrollments, 0);
  });

  testWidgets('overlapping speech never shows voice consent even after review and person selection', (tester) async {
    final api = FixtureSpeakerApi()
      ..evidenceOverride = const [
        ChapterSpeakerEvidence(
            id: 'overlap',
            conversationId: 'c',
            text: 'Overlapping quote',
            audioStart: 0,
            audioEnd: 18,
            learningBlockedReason: 'overlapping_speech'),
      ];
    await page(tester, api);
    await tapVisible(tester, '涛哥');
    tester.widget<ChapterEvidencePlayer>(find.byType(ChapterEvidencePlayer)).onReviewed!();
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('This clip has overlapping speech. Try another clip.'), findsOneWidget);
    await tapVisible(tester, 'Save for this chapter');
    expect(api.corrections, 1);
    expect(api.enrollments, 0);
  });

  testWidgets('namesake can select existing identity without creating another person', (tester) async {
    final api = FixtureSpeakerApi();
    final provider = await page(tester, api);
    await tapVisible(tester, 'Speaker A');
    await tapVisible(tester, '＋ Add or choose a person');
    await tester.enterText(find.byType(TextField), '涛哥');
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await tester.tap(find.byType(ListTile).last);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    await tapVisible(tester, 'Save for this chapter');
    expect(api.createdName, isNull);
    expect(provider.chaptersFor('2026-10-24').single.speakerDisplay!.speakers[1].personId, 'demo-tao');
  });

  for (final count in [0, 1, 5]) {
    testWidgets('$count speakers fit a narrow screen with large text; overflow is accessible', (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          builder: (c, child) =>
              MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.8)), child: child!),
          home: Scaffold(
              body: ChapterSpeakersRow(chapter: speakerFixture(count: count), duration: '20 min', onTap: (_, __) {}))));
      if (count == 5) {
        await tapVisible(tester, '+2');
        expect(find.text('Speaker B'), findsOneWidget);
        expect(find.text('Speaker C'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
