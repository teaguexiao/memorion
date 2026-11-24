import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/audio_jobs_page.dart';

AudioProcessingJob job(String status, {String? error, String stage = 'transcribe', bool retry = false}) =>
    AudioProcessingJob.fromJson({
      'id': 'job-1',
      'conversation_id': 'conversation-1',
      'status': status,
      'stage': stage,
      'started_at': '2026-09-19T03:00:00Z',
      'error_code': error,
      'can_retry': retry,
      if (status == 'retry_wait') 'next_attempt_at': 1790000000,
    });

class FakeApi extends AudioJobsApi {
  String owner = 'user';
  @override
  String get ownerId => owner;
  List<AudioProcessingJob> jobs = [];
  int retries = 0;
  bool fail = false;
  Completer<AudioJobsResult>? pending;
  @override
  Future<AudioJobsResult> list({String? before}) async {
    if (fail) throw StateError('offline');
    if (pending != null) return pending!.future;
    return AudioJobsResult(jobs, null);
  }

  @override
  Future<void> retry(String id) async {
    retries++;
    jobs = [job('queued')];
  }
}

Future<void> open(WidgetTester tester, FakeApi api, String language) async {
  tester.view.physicalSize = const Size(320, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    locale: Locale(language),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    home: AudioJobsPage(api: api),
  ));
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets('completed filtered job explains its status at 320px $language', (tester) async {
      final api = FakeApi()
        ..jobs = [
          AudioProcessingJob.fromJson({
            'id': 'filtered-job',
            'conversation_id': 'filtered-recording',
            'status': 'completed',
            'stage': 'publish',
            'discarded': true,
            'started_at': '2026-09-21T07:27:07Z',
          })
        ];
      await open(tester, api, language);
      expect(find.text(language == 'zh' ? '处理完成 · 已过滤' : 'Processed · filtered'), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '未生成时间线' : 'no timeline entry'), findsNothing);
      expect(find.byKey(const ValueKey('retry_job_filtered-job')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('failure is visible and retries cloud processing at 320px $language', (tester) async {
      final api = FakeApi()..jobs = [job('failed', stage: 'summarize', error: 'processing_unavailable', retry: true)];
      await open(tester, api, language);
      expect(find.text(language == 'zh' ? '处理失败' : 'Processing failed'), findsOneWidget);
      if (language == 'zh') {
        expect(find.text('处理暂时中断，云端音频及已完成的步骤均已保留。'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('retry_job_job-1')));
      await tester.pumpAndSettle();
      expect(api.retries, 1);
      expect(find.text(language == 'zh' ? '已保存到云端 · 排队中' : 'Saved to cloud · queued'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('permanent failure has no retry button $language', (tester) async {
      final api = FakeApi()..jobs = [job('failed', error: 'no_speech')];
      await open(tester, api, language);
      expect(find.byKey(const ValueKey('retry_job_job-1')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('server failure is not shown as an empty task list', (tester) async {
    final api = FakeApi()..fail = true;
    await open(tester, api, 'en');
    expect(find.text('Could not refresh processing status. Pull down to retry.'), findsOneWidget);
    expect(find.text('No recording tasks yet'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('retry queues a fresh load behind an in-flight poll', (tester) async {
    final failed = job('failed', error: 'processing_unavailable', retry: true);
    final api = FakeApi()..jobs = [failed];
    await open(tester, api, 'en');
    final poll = Completer<AudioJobsResult>();
    api.pending = poll;
    await tester.pump(const Duration(seconds: 15));
    await tester.tap(find.byKey(const ValueKey('retry_job_job-1')));
    await tester.pump();
    expect(api.retries, 1);
    api.pending = null;
    poll.complete(AudioJobsResult([failed], null));
    await tester.pumpAndSettle();
    expect(find.text('Saved to cloud · queued'), findsOneWidget);
    expect(find.text('Processing failed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('account change prevents displaying a late response', (tester) async {
    final api = FakeApi()..pending = Completer<AudioJobsResult>();
    await tester.pumpWidget(MaterialApp(home: AudioJobsPage(api: api)));
    api.owner = 'other';
    api.pending!.complete(AudioJobsResult([job('failed')], null));
    await tester.pumpAndSettle();
    expect(find.text('Processing failed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  test('unknown additive fields preserve compatibility', () {
    final value = AudioProcessingJob.fromJson({
      'id': 'id',
      'conversation_id': 'conv',
      'status': 'processing',
      'stage': 'future_stage',
      'started_at': '2026-09-19T00:00:00Z',
      'future_field': 1
    });
    expect(value.active, isTrue);
    expect(value.canRetry, isFalse);
  });
}
