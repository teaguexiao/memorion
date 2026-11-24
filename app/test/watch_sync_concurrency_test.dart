import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/audio_upload.dart';
import 'package:memorion/services/watch_moment_service.dart';
import 'package:memorion/services/watch_recording_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('com.memorion.ios/watch');
  late Directory directory;
  late List<Map<String, dynamic>> queue;
  late List<String> removed;
  late WatchMomentService moments;
  WatchRecordingService? service;

  Future<void> addRecording(int index) async {
    final file = File('${directory.path}/rec_$index.m4a');
    // Queue transport fixture. Upload is injected; these bytes never reach a server.
    await file.writeAsString('queue-fixture-$index');
    queue.add({'path': file.path, 'startedAtMs': index, 'durationSeconds': 9.0});
  }

  UploadAudioResponse accepted(String source) =>
      UploadAudioResponse(conversationId: source, status: 'processing', transcriptSegments: [], durationSeconds: 9);

  WatchRecordingService create(WatchAudioUploader upload) => WatchRecordingService.forTesting(
      authHeader: () => 'test-auth', account: () => 'account', upload: upload, moments: moments);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('watch-sync-concurrency-');
    queue = [];
    removed = [];
    moments = WatchMomentService.forTesting(account: () => 'account', fetchSource: (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(native, (call) async {
      switch (call.method) {
        case 'prepareLongRecordings':
          return <String>[];
        case 'getPendingRecordings':
          return queue.map((entry) => Map<String, dynamic>.from(entry)).toList();
        case 'markUploaded':
          final path = (call.arguments as Map)['path'] as String;
          removed.add(path);
          queue.removeWhere((entry) => entry['path'] == path);
          await File(path).delete();
          return true;
        case 'syncMoments':
          return true;
        default:
          throw StateError('Unexpected native method ${call.method}');
      }
    });
  });

  tearDown(() async {
    service?.cancelScheduledRetry();
    moments.cancelPolling();
    service = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
    await directory.delete(recursive: true);
  });

  test('simultaneous triggers before quota read never overlap uploads', () async {
    await addRecording(1000);
    var uploads = 0;
    service = create((item, _) async {
      uploads++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return accepted(item.key);
    });
    final first = service!.syncPending(reason: 'cold start');
    final second = await service!.syncPending(reason: 'file received');
    expect(second.outcome, WatchSyncOutcome.busy);
    expect((await first).uploaded, 1);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(uploads, 1);
    expect(removed.length, 1);
    expect(queue, isEmpty);
    expect(service!.isSyncing, isFalse);
  });

  test('a recording received during upload is drained without another foreground event', () async {
    await addRecording(1000);
    final started = Completer<void>();
    final releaseFirst = Completer<UploadAudioResponse?>();
    final finishedSecond = Completer<void>();
    final uploaded = <String>[];
    service = create((item, _) async {
      uploaded.add(item.key);
      if (uploaded.length == 1) {
        started.complete();
        return releaseFirst.future;
      }
      return accepted(item.key);
    });
    service!.onQueueChanged = () {
      if (removed.length == 2 && !finishedSecond.isCompleted) finishedSecond.complete();
    };
    final batch = service!.syncPending();
    await started.future;
    await addRecording(2000);
    expect((await service!.syncPending(reason: 'file received')).outcome, WatchSyncOutcome.busy);
    releaseFirst.complete(accepted('first'));
    await batch;
    await finishedSecond.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    expect(uploaded, ['rec_1000.m4a', 'rec_2000.m4a']);
    expect(queue, isEmpty);
  });

  test('a force-sync request during a batch preserves its quota override', () async {
    await addRecording(1000);
    final started = Completer<void>();
    final releaseFirst = Completer<UploadAudioResponse?>();
    final completed = Completer<void>();
    var attempts = 0;
    service = create((item, onError) async {
      attempts++;
      if (attempts == 1) {
        started.complete();
        await releaseFirst.future;
        onError(429, '{"detail":{"code":"monthly_cloud_transcription_allowance_exceeded"}}');
        return null;
      }
      return accepted('retried');
    });
    service!.onQueueChanged = () {
      if (removed.isNotEmpty && !completed.isCompleted) completed.complete();
    };
    final batch = service!.syncPending();
    await started.future;
    expect((await service!.syncPending(ignoreQuotaPause: true)).outcome, WatchSyncOutcome.busy);
    releaseFirst.complete(null);
    await batch;
    await completed.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 2);
    expect(queue, isEmpty);
  });
}
