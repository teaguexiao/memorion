import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/services/wals.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:memorion/pages/today_chapters/speaker_mark_page.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/people_provider.dart';
import 'package:memorion/providers/timeline_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/chapter_speaker_fixture.dart';

class _Syncs extends Fake implements WalSyncs {
  @override
  Future<List<Wal>> getMissingWals() async => [];
}

class _Wal extends Fake implements IWalService {
  @override
  void subscribe(IWalServiceListener subscription, Object context) {}
  @override
  void unsubscribe(Object context) {}
  @override
  WalSyncs getSyncs() => _Syncs();
}

void main({bool configureTestView = true}) {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });
  TimelineDay day(String title, {String cache = 'computed'}) => TimelineDay(
      date: '2026-10-24',
      timezone: 'Asia/Shanghai',
      chapters: [
        TimelineChapter.fromJson({...speakerFixture().toJson(), 'title': title})!
      ],
      sourceConversationIds: speakerFixture().sourceConversationIds,
      cache: cache,
      computedAt: null);

  test('saved identities refresh historical cached dates with unchanged source IDs', () async {
    final calls = <String>[];
    final provider = TimelineProvider(fetch: ({required date, refresh = false}) async {
      calls.add('$date:$refresh');
      return day('new');
    })
      ..seedDay(day('old'));
    await provider.syncDays({'2026-10-24': speakerFixture().sourceConversationIds.toSet()});
    expect(calls, isEmpty);
    await provider.refreshConversations(speakerFixture().sourceConversationIds.toSet(), fallbackDate: '2026-10-25');
    expect(calls, ['2026-10-24:true']);
    expect(provider.chaptersFor('2026-10-24').single.title, 'new');
    final reopened = TimelineProvider();
    expect(reopened.chaptersFor('2026-10-24').single.title, 'new');
    provider.dispose();
    reopened.dispose();
  });

  test('old in-flight response cannot overwrite a saved correction', () async {
    final old = Completer<TimelineDay?>();
    var calls = 0;
    final provider = TimelineProvider(fetch: ({required date, refresh = false}) {
      calls++;
      return calls == 1 ? old.future : Future.value(day('corrected'));
    });
    final initial = provider.syncDays({
      '2026-10-24': {'source-a'}
    });
    final corrected = provider.refreshConversations({'source-a'}, fallbackDate: '2026-10-24');
    expect(calls, 1);
    old.complete(day('stale'));
    await Future.wait([initial, corrected]);
    expect(calls, 2);
    expect(provider.chaptersFor('2026-10-24').single.title, 'corrected');
    provider.dispose();
  });

  test('failed refresh preserves cached content and retries on next sync', () async {
    var calls = 0;
    final provider = TimelineProvider(fetch: ({required date, refresh = false}) async {
      calls++;
      return calls == 1 ? null : day('corrected');
    })
      ..seedDay(day('old'));
    final ids = speakerFixture().sourceConversationIds.toSet();
    await provider.refreshConversations(ids, fallbackDate: '2026-10-24');
    expect(provider.chaptersFor('2026-10-24').single.title, 'old');
    await provider.syncDays({'2026-10-24': ids});
    expect(calls, 2);
    expect(provider.chaptersFor('2026-10-24').single.title, 'corrected');
    provider.dispose();
  });

  test('logout discards queued refresh and its old response', () async {
    final old = Completer<TimelineDay?>();
    var calls = 0;
    final provider = TimelineProvider(fetch: ({required date, refresh = false}) {
      calls++;
      return old.future;
    });
    final initial = provider.syncDays({
      '2026-10-24': {'source-a'}
    });
    final refresh = provider.refreshConversations({'source-a'}, fallbackDate: '2026-10-24');
    provider.clear();
    old.complete(day('old-account'));
    await Future.wait([initial, refresh]);
    expect(calls, 1);
    expect(provider.hasDay('2026-10-24'), isFalse);
    provider.dispose();
  });

  test('pending server correction retries without accepting stale cached identity', () async {
    var calls = 0;
    final provider = TimelineProvider(fetch: ({required date, refresh = false}) async {
      calls++;
      return calls == 1 ? day('stale', cache: 'pending') : day('corrected');
    })
      ..seedDay(day('old'));
    final refresh =
        provider.refreshConversations(speakerFixture().sourceConversationIds.toSet(), fallbackDate: '2026-10-24');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(provider.chaptersFor('2026-10-24').single.title, 'old');
    await refresh;
    expect(calls, 2);
    expect(provider.chaptersFor('2026-10-24').single.title, 'corrected');
    provider.dispose();
  });

  test('long server rollup refreshes automatically after foreground retries', () {
    fakeAsync((time) {
      var calls = 0;
      final provider = TimelineProvider(fetch: ({required date, refresh = false}) async {
        calls++;
        return calls <= 6 ? day('stale', cache: 'locked') : day('corrected');
      })
        ..seedDay(day('old'));
      var finished = false;
      provider
          .refreshConversations(speakerFixture().sourceConversationIds.toSet(), fallbackDate: '2026-10-24')
          .then((_) => finished = true);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 14));
      expect(finished, isTrue);
      expect(calls, 6);
      expect(provider.chaptersFor('2026-10-24').single.title, 'old');
      time.elapse(const Duration(seconds: 30));
      expect(calls, 7);
      expect(provider.chaptersFor('2026-10-24').single.title, 'corrected');
      provider.dispose();
    });
  });

  test('logout and disposal cancel a pending server rollup retry', () {
    for (final logout in [true, false]) {
      fakeAsync((time) {
        var calls = 0;
        final provider = TimelineProvider(fetch: ({required date, refresh = false}) async {
          calls++;
          return day('stale', cache: 'pending');
        })
          ..seedDay(day('old'));
        unawaited(
            provider.refreshConversations(speakerFixture().sourceConversationIds.toSet(), fallbackDate: '2026-10-24'));
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 14));
        expect(calls, 6);
        if (logout) {
          provider.clear();
        } else {
          provider.dispose();
        }
        time.elapse(const Duration(minutes: 2));
        expect(calls, 6);
        if (logout) provider.dispose();
      });
    }
  });

  testWidgets('open chapter updates when recording identities refresh its cached projection', (tester) async {
    final provider = TimelineProvider(fetch: ({required date, refresh = false}) async => day('已更新的总结'))
      ..seedDay(day('原来的总结'));
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
            home:
                ChapterDetailPage(conversation: speakerSource(), chapter: provider.chaptersFor('2026-10-24').single))));
    await tester.pumpAndSettle();
    expect(find.text('原来的总结'), findsOneWidget);
    await provider.refreshConversations(speakerFixture().sourceConversationIds.toSet(), fallbackDate: '2026-10-24');
    await tester.pumpAndSettle();
    expect(find.text('已更新的总结'), findsOneWidget);
    expect(find.text('原来的总结'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    provider.dispose();
  });

  testWidgets('speaker save failure stays editable; retry persists before updating calendar', (tester) async {
    if (configureTestView) {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    final now = DateTime(2026, 10, 24);
    SharedPreferencesUtil().cachedPeople = [Person(id: 'p', name: '阿宁', createdAt: now, updatedAt: now)];
    final people = PeopleProvider();
    final conversations = ConversationProvider(wal: _Wal());
    var fetches = 0;
    final timeline = TimelineProvider(fetch: ({required date, refresh = false}) async {
      fetches++;
      return day('阿宁提出建议');
    });
    final fixture = speakerSource();
    final source = ServerConversation(
        id: fixture.id,
        createdAt: fixture.createdAt,
        startedAt: fixture.startedAt,
        finishedAt: fixture.finishedAt,
        structured: fixture.structured,
        transcriptSegments: List.generate(
            2,
            (i) => TranscriptSegment.fromJson({
                  'id': 'segment-$i',
                  'text': speakerQuotes[i],
                  'speaker_id': 0,
                  'is_user': false,
                  'person_id': null,
                  'start': i * 10.0,
                  'end': i * 10.0 + 5,
                })));
    final original = source.transcriptSegments.map((s) => s.personId).toList();
    final pending = Completer<bool>();
    var saves = 0;
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: people),
          ChangeNotifierProvider.value(value: conversations),
          ChangeNotifierProvider.value(value: timeline),
        ],
        child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: S.supportedLocales,
            localizationsDelegates: S.localizationsDelegates,
            home: Builder(
                builder: (context) => Scaffold(
                        body: TextButton(
                      child: const Text('打开标记'),
                      onPressed: () => showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => SpeakerMarkSheet(
                              conversation: source,
                              speakerId: source.transcriptSegments.first.speakerId,
                              assignSpeaker: (id, ids, {isUser, personId}) {
                                saves++;
                                return saves == 1 ? pending.future : Future.value(true);
                              })),
                    ))))));
    await tester.tap(find.text('打开标记'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('阿宁'));
    await tester.tap(find.text('阿宁'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.check_rounded).first);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.check_rounded).first, warnIfMissed: false);
    await tester.pump();
    expect(saves, 1);
    expect(source.transcriptSegments.map((s) => s.personId), original);
    expect(fetches, 0);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(SpeakerMarkSheet), findsOneWidget);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(find.byType(SpeakerMarkSheet), findsOneWidget);
    expect(source.transcriptSegments.map((s) => s.personId), original);
    await tester.tap(find.byIcon(Icons.check_rounded).first);
    await tester.pumpAndSettle();
    expect(saves, 2);
    expect(fetches, 1);
    expect(
        source.transcriptSegments
            .where((s) => s.speakerId == source.transcriptSegments.first.speakerId)
            .every((s) => s.personId == 'p'),
        isTrue);
    expect(find.byType(SpeakerMarkSheet), findsNothing);
    await tester.pumpWidget(const SizedBox());
    people.dispose();
    conversations.dispose();
    timeline.dispose();
  });
}
