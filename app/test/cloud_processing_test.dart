import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/today_chapters_page.dart';
import 'package:memorion/pages/today_chapters/widgets/processing_card.dart';
import 'package:memorion/providers/capture_provider.dart';
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

class _Jobs extends AudioJobsApi {
  String owner = 'user';
  List<AudioProcessingJob> jobs = [];
  Completer<List<AudioProcessingJob>>? pending;
  bool fail = false;
  int calls = 0;
  @override
  String get ownerId => owner;
  @override
  Future<List<AudioProcessingJob>> active() async {
    calls++;
    if (fail) throw StateError('offline');
    if (pending != null) return pending!.future;
    return jobs;
  }
}

class _Server {
  List<ServerConversation> recent = [];
  List<ServerConversation> pending = [];
  Map<String, ServerConversation> details = {};
  bool failDetails = false;
  final List<String> detailRequests = [];

  Future<List<ServerConversation>> fetch(
      {int limit = 50,
      int offset = 0,
      List<ConversationStatus> statuses = const [],
      bool includeDiscarded = false}) async {
    final rows = statuses.isEmpty ? recent : pending;
    return rows.skip(offset).take(limit).toList();
  }

  Future<ServerConversation?> get(String id) async {
    detailRequests.add(id);
    if (failDetails) throw StateError('offline');
    return details[id];
  }
}

ServerConversation _conversation(String id, ConversationStatus status, {int day = 21}) => ServerConversation(
      id: id,
      createdAt: DateTime(2026, 10, day, 10),
      startedAt: DateTime(2026, 10, day, 9),
      finishedAt: DateTime(2026, 10, day, 9, 10),
      structured: Structured(status == ConversationStatus.completed ? 'Finished $id' : '', ''),
      source: ConversationSource.audio_upload,
      status: status,
    );

AudioProcessingJob _job(String id, String status) => AudioProcessingJob.fromJson({
      'id': id,
      'conversation_id': id,
      'status': status,
      'stage': 'summarize',
      'started_at': '2026-10-20T00:00:00Z',
    });

ConversationProvider _provider(_Server server, _Jobs jobs) => ConversationProvider(
      wal: _Wal(),
      fetch: server.fetch,
      audioJobs: jobs,
      processingGet: server.get,
    );

ServerConversation _unfinishedApiConversation(String id, {bool hasTranscript = false}) => ServerConversation.fromJson({
      'id': id,
      'created_at': '2026-03-27T09:43:07Z',
      'started_at': '2026-03-27T09:43:07Z',
      'finished_at': null,
      'status': 'in_progress',
      'source': 'api',
      'structured': {'title': '', 'overview': '', 'emoji': '', 'category': 'other', 'action_items': [], 'events': []},
      'transcript_segments': hasTranscript
          ? [
              {'text': 'Unfinished recording', 'speaker_id': 0, 'start': 0.0, 'end': 1.0}
            ]
          : [],
    });

class _Device extends ChangeNotifier implements DeviceProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
  @override
  bool get isConnected => false;
  @override
  int get batteryLevel => 0;
  @override
  bool get isCharging => false;
}

class _Capture extends ChangeNotifier implements CaptureProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
  @override
  bool get isRecording => false;
}

Future<void> _open(WidgetTester tester, ConversationProvider provider, {String language = 'zh'}) async {
  final timeline = TimelineProvider(
      fetch: ({String date = '', bool refresh = false}) async =>
          TimelineDay.fromJson({'date': date, 'chapters': []}, fallbackDate: date));
  addTearDown(timeline.dispose);
  await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<ConversationProvider>.value(value: provider),
        ChangeNotifierProvider<TimelineProvider>.value(value: timeline),
        ChangeNotifierProvider<DeviceProvider>(create: (_) => _Device()),
        ChangeNotifierProvider<CaptureProvider>(create: (_) => _Capture()),
      ],
      child: MaterialApp(
          locale: Locale(language),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          home: const TodayChaptersPage())));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  for (final omitSegments in [true, false]) {
    test('processing without segments does not create a server placeholder (omitted: $omitSegments)', () async {
      expect(await processInProgressConversation(segments: omitSegments ? null : [], sessionId: 'empty'), isNull);
    });
  }

  test('unfinished API records do not keep the banner after a durable job completes', () async {
    final placeholders = List.generate(19, (i) => _unfinishedApiConversation('placeholder-$i', hasTranscript: i < 2));
    final server = _Server()
      ..pending = placeholders
      ..recent = placeholders.take(3).toList();
    final jobs = _Jobs()..jobs = [_job('today', 'processing')];
    final provider = _provider(server, jobs);
    addTearDown(provider.dispose);
    await provider.refreshCloudProcessing();
    expect(provider.hasCloudProcessing, isTrue);

    jobs.jobs = [];
    server.recent = [_conversation('today', ConversationStatus.completed)];
    await provider.refreshCloudProcessing();
    expect(provider.hasCloudProcessing, isFalse);
    expect(provider.conversations.first.status, ConversationStatus.completed);
    expect(provider.processingConversations, hasLength(19));
    expect(SharedPreferencesUtil().cachedConversations.single.id, 'today');

    // An unavailable detail for an unfinished capture is not a pending publication.
    server.pending = [];
    server.failDetails = true;
    await provider.refreshCloudProcessing();
    expect(provider.hasCloudProcessing, isFalse);
    expect(server.detailRequests, isEmpty);
  });

  test('explicit processing without a finish time still shows cloud work', () async {
    final server = _Server()
      ..pending = [
        ServerConversation(
            id: 'upload',
            createdAt: DateTime.now(),
            structured: Structured('', ''),
            status: ConversationStatus.processing),
      ];
    final provider = _provider(server, _Jobs());
    addTearDown(provider.dispose);
    await provider.refreshCloudProcessing();
    expect(provider.hasCloudProcessing, isTrue);
  });

  testWidgets('unfinished API placeholders do not show the card on app startup or restart', (tester) async {
    final server = _Server()
      ..pending = [_unfinishedApiConversation('empty'), _unfinishedApiConversation('recording', hasTranscript: true)]
      ..recent = [_conversation('today', ConversationStatus.completed)];
    for (var launch = 0; launch < 2; launch++) {
      final provider = _provider(server, _Jobs());
      await _open(tester, provider);
      await tester.pump();
      expect(provider.hasCloudProcessing, isFalse);
      expect(find.byType(ProcessingCard), findsNothing);
      await tester.pumpWidget(const SizedBox());
      provider.dispose();
    }
  });

  for (final status in [ConversationStatus.processing, ConversationStatus.in_progress]) {
    test('refresh replaces paginated $status with its completed conversation', () async {
      final server = _Server()
        ..recent = [_conversation('seed', ConversationStatus.completed), _conversation('old', status)];
      final provider = _provider(server, _Jobs());
      addTearDown(provider.dispose);
      provider.addConversation(server.recent.first);
      await provider.getMoreConversationsFromServer();
      expect(provider.hasCloudProcessing, isTrue);
      server.recent = [_conversation('old', ConversationStatus.completed)];
      await provider.forceRefreshConversations();
      expect(provider.hasCloudProcessing, isFalse);
      expect(provider.conversations.where((c) => c.id == 'old').single.status, ConversationStatus.completed);
    });
  }

  test('offline job completion loads an old recording outside the newest page', () async {
    final server = _Server();
    final jobs = _Jobs()..jobs = [_job('old-recording', 'retry_wait')];
    final provider = _provider(server, jobs);
    addTearDown(provider.dispose);
    await provider.refreshCloudProcessing();
    expect(provider.hasCloudProcessing, isTrue);
    expect(provider.conversations, isEmpty);
    jobs.jobs = [];
    server.details['old-recording'] = _conversation('old-recording', ConversationStatus.completed, day: 1);
    await provider.refreshCloudProcessing();
    expect(provider.hasCloudProcessing, isFalse);
    expect(server.detailRequests, ['old-recording']);
    expect(provider.conversations.single.structured.title, 'Finished old-recording');
    expect(SharedPreferencesUtil().cachedConversations.single.id, 'old-recording');
  });

  test('pending conversations beyond the first 500 are included', () async {
    final server = _Server()
      ..pending = List.generate(501, (i) => _conversation('pending-$i', ConversationStatus.processing));
    final provider = _provider(server, _Jobs());
    addTearDown(provider.dispose);
    await provider.refreshCloudProcessing();
    expect(provider.processingConversations, hasLength(501));
    expect(provider.hasCloudProcessing, isTrue);
  });

  test('old cloud rows do not move pagination past unseen conversations', () async {
    final server = _Server()
      ..recent = List.generate(100, (i) => _conversation('row-$i', ConversationStatus.completed))
      ..pending = [_conversation('row-80', ConversationStatus.processing)];
    final jobs = _Jobs()..jobs = [_job('old-recording', 'processing')];
    final provider = _provider(server, jobs);
    addTearDown(provider.dispose);
    for (final c in server.recent.take(50)) {
      provider.addConversation(c);
    }
    await provider.refreshCloudProcessing();
    jobs.jobs = [];
    server.details['old-recording'] = _conversation('old-recording', ConversationStatus.completed, day: 1);
    await provider.refreshCloudProcessing();
    await provider.getMoreConversationsFromServer();
    expect(provider.conversations.map((c) => c.id).toSet(), {...server.recent.map((c) => c.id), 'old-recording'});
    expect(provider.conversations.where((c) => c.id == 'row-80'), hasLength(1));
    await provider.getMoreConversationsFromServer();
    expect(provider.hasMoreConversations, isFalse);
  });

  test('outages preserve processing and retry fetching completed results', () async {
    final server = _Server();
    final jobs = _Jobs()..jobs = [_job('recording', 'processing')];
    final provider = _provider(server, jobs);
    addTearDown(provider.dispose);
    await provider.refreshCloudProcessing();
    jobs.fail = true;
    await provider.refreshCloudProcessing();
    expect(provider.hasCloudProcessing, isTrue);
    jobs
      ..fail = false
      ..jobs = [];
    server.failDetails = true;
    await provider.refreshCloudProcessing();
    expect(provider.hasCloudProcessing, isTrue);
    server
      ..failDetails = false
      ..details['recording'] = _conversation('recording', ConversationStatus.completed);
    await provider.refreshCloudProcessing();
    expect(provider.hasCloudProcessing, isFalse);
    expect(provider.conversations.single.status, ConversationStatus.completed);
  });

  test('failed or cancelled unpublished jobs stop the processing indicator', () async {
    final server = _Server();
    final jobs = _Jobs()..jobs = [_job('failed', 'queued'), _job('cancelled', 'processing')];
    final provider = _provider(server, jobs);
    addTearDown(provider.dispose);
    await provider.refreshCloudProcessing();
    jobs.jobs = [];
    await provider.refreshCloudProcessing();
    expect(provider.hasCloudProcessing, isFalse);
    expect(provider.conversations, isEmpty);
  });

  test('concurrent refreshes share one request and late account responses are ignored', () async {
    final server = _Server()..recent = [_conversation('private', ConversationStatus.completed)];
    final jobs = _Jobs()..pending = Completer<List<AudioProcessingJob>>();
    final provider = _provider(server, jobs);
    addTearDown(provider.dispose);
    final first = provider.refreshCloudProcessing();
    final second = provider.refreshCloudProcessing();
    expect(jobs.calls, 1);
    jobs.owner = 'other';
    jobs.pending!.complete([_job('private', 'processing')]);
    await Future.wait([first, second]);
    expect(provider.hasCloudProcessing, isFalse);
    expect(provider.conversations, isEmpty);
  });

  for (final language in ['zh', 'en']) {
    testWidgets('one indicator for multiple days, ordinary conversations and offline jobs ($language)', (tester) async {
      final server = _Server()
        ..pending = [
          _conversation('today', ConversationStatus.processing),
          _conversation('yesterday', ConversationStatus.in_progress, day: 20),
        ];
      final jobs = _Jobs()..jobs = [_job('soundcore', 'queued'), _job('watch', 'processing')];
      final provider = _provider(server, jobs);
      addTearDown(provider.dispose);
      provider.addConversation(server.pending.first);
      await _open(tester, provider, language: language);
      expect(find.byType(ProcessingCard), findsOneWidget);
      expect(find.text(language == 'zh' ? '我还在整理刚才那段对话…' : "I'm still organizing that conversation…"), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('completion removes the card and displays the finished conversation automatically', (tester) async {
    final pending = _conversation('phone', ConversationStatus.processing);
    final server = _Server()
      ..pending = [pending]
      ..recent = [pending];
    final jobs = _Jobs();
    final provider = _provider(server, jobs);
    addTearDown(provider.dispose);
    provider.addConversation(pending);
    await _open(tester, provider);
    expect(find.byType(ProcessingCard), findsOneWidget);
    server
      ..pending = []
      ..recent = [_conversation('phone', ConversationStatus.completed)];
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.byType(ProcessingCard), findsNothing);
    expect(find.text('Finished phone'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('foreground resume refreshes immediately and background polling stops', (tester) async {
    final server = _Server()..recent = [_conversation('seed', ConversationStatus.completed)];
    final jobs = _Jobs()..jobs = [_job('watch', 'queued')];
    final provider = _provider(server, jobs);
    addTearDown(provider.dispose);
    provider.addConversation(server.recent.first);
    await _open(tester, provider);
    final calls = jobs.calls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(jobs.calls, calls);
    jobs.jobs = [];
    server.details['watch'] = _conversation('watch', ConversationStatus.completed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(jobs.calls, calls + 1);
    expect(find.byType(ProcessingCard), findsNothing);
    expect(provider.conversations.any((c) => c.id == 'watch'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
