import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:memorion/pages/today_chapters/day_timeline_planner.dart';
import 'package:memorion/pages/today_chapters/today_chapters_page.dart';
import 'package:memorion/pages/today_chapters/transcript_page.dart';
import 'package:memorion/pages/today_chapters/widgets/chapter_card.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/providers/conversation_audio_provider.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/providers/timeline_provider.dart';
import 'package:memorion/services/wals.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _Device extends ChangeNotifier implements DeviceProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => switch (invocation.memberName) {
        #isConnected || #isCharging => false,
        #batteryLevel => -1,
        _ => null,
      };
}

class _Capture extends ChangeNotifier implements CaptureProvider {
  @override
  bool get isRecording => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Audio extends ChangeNotifier implements ConversationAudioProvider {
  String? loadedId;
  @override
  Future<void> loadConversation(String conversationId) async => loadedId = conversationId;
  @override
  void clear({bool notify = true}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => switch (invocation.memberName) {
        #hasAudio || #isLoading || #isDownloading || #canPlaySegments => false,
        #isDownloadable => true,
        #alignment => null,
        _ => super.noSuchMethod(invocation),
      };
}

ServerConversation recording(String id, {bool discarded = false, bool deleted = false, int hour = 15}) =>
    ServerConversation(
      id: id,
      createdAt: DateTime(2026, 9, 22, 5),
      startedAt: DateTime(2026, 9, 21, hour),
      finishedAt: DateTime(2026, 9, 21, hour, 10),
      discarded: discarded,
      deleted: deleted,
      structured: Structured(discarded ? '' : 'Kept recording', ''),
      transcriptSegments: [
        TranscriptSegment(
          id: '$id-segment',
          text: 'Retained transcript',
          speaker: 'SPEAKER_00',
          isUser: false,
          personId: null,
          start: 0,
          end: 600,
          translations: const [],
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({'notifTaskReminder': false});
    await SharedPreferencesUtil.init();
  });

  test('initial load, pagination and refresh retain completed filtered recordings', () async {
    final requests = <({int offset, bool includeDiscarded})>[];
    var fresh = false;
    final provider = ConversationProvider(
      wal: _Wal(),
      fetch: (
          {int limit = 50,
          int offset = 0,
          List<ConversationStatus> statuses = const [],
          bool includeDiscarded = false}) async {
        requests.add((offset: offset, includeDiscarded: includeDiscarded));
        if (fresh) return [recording('fresh', discarded: true)];
        if (offset == 0) return [recording('normal'), recording('filtered', discarded: true)];
        if (offset == 2) return [recording('older', discarded: true, hour: 9)];
        return [];
      },
    );
    addTearDown(provider.dispose);
    await provider.fetchConversations();
    expect(provider.groupedConversations.values.expand((c) => c).map((c) => c.id), containsAll(['normal', 'filtered']));
    await provider.getMoreConversationsFromServer();
    expect(provider.groupedConversations.values.expand((c) => c).map((c) => c.id), contains('older'));
    await provider.getMoreConversationsFromServer();
    expect(provider.hasMoreConversations, isFalse);
    fresh = true;
    await provider.forceRefreshConversations();
    expect(provider.groupedConversations.values.expand((c) => c).map((c) => c.id), contains('fresh'));
    expect(requests.map((r) => r.offset), [0, 2, 3, 0]);
    expect(requests.every((r) => r.includeDiscarded), isTrue);
    expect(provider.conversations.where((c) => c.id != 'normal').every((c) => c.discarded), isTrue);
  });

  test('search and its next page include filtered recordings', () async {
    final requests = <bool>[];
    final provider = ConversationProvider(
      wal: _Wal(),
      search: (query, {int? page, int? limit, bool includeDiscarded = false}) async {
        requests.add(includeDiscarded);
        return ([recording('match-${page ?? 1}', discarded: true)], page ?? 1, 2);
      },
    );
    addTearDown(provider.dispose);
    await provider.searchConversations('retained');
    await provider.searchMoreConversations();
    expect(provider.groupedConversations.values.expand((c) => c), hasLength(2));
    expect(requests, [true, true]);
  });

  test('date filter and calendar use recording date for retained recordings', () async {
    final provider = ConversationProvider(wal: _Wal());
    addTearDown(provider.dispose);
    provider.conversations = [
      recording('filtered', discarded: true),
      recording('normal'),
      recording('deleted', discarded: true, deleted: true),
      recording('processing', discarded: true)..status = ConversationStatus.processing,
    ];
    await provider.filterConversationsByDate(DateTime(2026, 9, 21));
    expect(provider.groupedConversations.values.expand((c) => c).map((c) => c.id), ['filtered', 'normal']);
    expect(provider.conversationCountByDay, {DateTime(2026, 9, 21): 2});
    await provider.filterConversationsByDate(DateTime(2026, 9, 22));
    expect(provider.groupedConversations, isEmpty);
    await provider.clearDateFilter();
    expect(provider.groupedConversations.values.expand((c) => c), hasLength(2));
  });

  test('stale merged chapter cannot absorb a filtered recording or reuse its summary', () {
    final kept = recording('normal', hour: 14);
    final filtered = recording('filtered', discarded: true);
    final slots = planDayTimeline(completed: [
      kept,
      filtered
    ], chapters: [
      TimelineChapter(
        start: kept.startedAt!,
        end: filtered.finishedAt!,
        durationSeconds: 4200,
        speechSeconds: 1200,
        sourceConversationIds: [kept.id, filtered.id],
        title: 'Stale merged title',
        overview: 'Stale summary',
        emoji: '',
        firstPersonObservation: '',
        rolledUp: true,
      ),
    ]);
    expect(slots.map((slot) => slot.anchor.id), ['filtered', 'normal']);
    expect(slots.every((slot) => slot.chapter == null && !slot.isMerged), isTrue);
  });

  for (final language in ['zh', 'en']) {
    testWidgets('filtered card and empty-summary detail explain retention at 320px $language', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget wrap(Widget child) => MaterialApp(
            locale: Locale(language),
            supportedLocales: S.supportedLocales,
            localizationsDelegates: S.localizationsDelegates,
            home: child,
          );
      final status = language == 'zh' ? '处理完成 · 已过滤' : 'Processed · filtered';
      await tester.pumpWidget(wrap(const Scaffold(
          body: Padding(
        padding: EdgeInsets.all(16),
        child: ChapterCard(title: 'Recording', observation: '', discarded: true),
      ))));
      await tester.pumpAndSettle();
      expect(find.text(status), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(wrap(ChapterDetailPage(conversation: recording('filtered', discarded: true))));
      await tester.pumpAndSettle();
      expect(find.text(status), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '仍可从下方查看原文和录音' : 'open the transcript and audio below'),
          findsOneWidget);
      expect(find.byKey(const Key('view-transcript-row')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('filtered-only timeline opens retained transcript and audio $language', (tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = ConversationProvider(
        wal: _Wal(),
        fetch: (
                {int limit = 50,
                int offset = 0,
                List<ConversationStatus> statuses = const [],
                bool includeDiscarded = false}) async =>
            [recording('filtered', discarded: true)],
      );
      provider.addConversation(recording('filtered', discarded: true));
      provider.hasMoreConversations = false;
      var chapterRequests = 0;
      final timeline = TimelineProvider(fetch: ({required date, bool refresh = false}) async {
        chapterRequests++;
        return null;
      });
      final audio = _Audio();
      final device = _Device();
      final capture = _Capture();
      addTearDown(() {
        provider.dispose();
        timeline.dispose();
        audio.dispose();
        device.dispose();
        capture.dispose();
      });
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<ConversationProvider>.value(value: provider),
          ChangeNotifierProvider<TimelineProvider>.value(value: timeline),
          ChangeNotifierProvider<ConversationAudioProvider>.value(value: audio),
          ChangeNotifierProvider<DeviceProvider>.value(value: device),
          ChangeNotifierProvider<CaptureProvider>.value(value: capture),
        ],
        child: MaterialApp(
            locale: Locale(language),
            supportedLocales: S.supportedLocales,
            localizationsDelegates: S.localizationsDelegates,
            home: const TodayChaptersPage()),
      ));
      // The home mascot/recording indicator keeps animating; it never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final status = language == 'zh' ? '处理完成 · 已过滤' : 'Processed · filtered';
      expect(find.text(status), findsOneWidget);
      expect(find.byType(ChapterCard), findsOneWidget);
      expect(chapterRequests, 0, reason: 'Filtered audio does not need an AI chapter refresh');
      expect(tester.takeException(), isNull);
      await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
      await tester.pump();
      expect(find.text(status), findsOneWidget);
      expect(chapterRequests, 0, reason: 'Pull-to-refresh also skips AI chapter generation for filtered recordings');
      await tester.tap(find.byType(ChapterCard));
      await tester.pumpAndSettle();
      expect(find.byType(ChapterDetailPage), findsOneWidget);
      expect(find.text(status), findsOneWidget);
      expect(find.text(language == 'zh' ? '暂无内容' : 'Nothing yet'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('view-transcript-row')));
      await tester.tap(find.byKey(const Key('view-transcript-row')));
      await tester.pumpAndSettle();
      expect(find.byType(TranscriptPage), findsOneWidget);
      expect(find.text('Retained transcript'), findsOneWidget);
      expect(audio.loadedId, 'filtered');
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
      expect(provider.conversations.single.discarded, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
