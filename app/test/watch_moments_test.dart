import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/audio_upload.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/services/watch_moment_builder.dart';
import 'package:memorion/services/watch_moment_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> mark(String id, double offset) => {
      'id': id,
      'offsetSeconds': offset,
      'markedAtMs': 1790000000000 + offset * 1000,
      'contextBeforeSeconds': 15,
      'contextAfterSeconds': 15,
    };
String metadata(String id) => jsonEncode({
      'marks': [mark(id, 80)]
    });
UploadAudioResponse uploaded(String id) =>
    UploadAudioResponse(conversationId: id, status: 'processing', transcriptSegments: [], durationSeconds: 100);
ServerConversation source(String id) =>
    ServerConversation(id: id, createdAt: DateTime(2026), structured: Structured('Source', ''), transcriptSegments: [
      TranscriptSegment.fromJson({
        'id': 'segment',
        'start': 75.0,
        'end': 85.0,
        'text': 'Words actually spoken',
      })
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WatchMomentService.channel, (_) async => true);
  });
  test('saved marks cannot produce text before processing completes', () {
    final result = watchMomentFromMark(mark: mark('one', 80), recordingKey: 'audio', status: 'processing', transcript: [
      {'start': 75, 'end': 85, 'text': 'Known words'}
    ]);
    expect(result['status'], 'processing');
    expect(result.containsKey('text'), isFalse);
  });
  test('context uses original audio timestamps after silence removal', () {
    final result = watchMomentFromMark(
        mark: mark('one', 80),
        recordingKey: 'audio',
        conversationId: 'source',
        status: 'completed',
        transcript: [
          {'start': 8, 'end': 12, 'original_start': 77, 'original_end': 84, 'text': 'Selected actual words'},
          {'start': 80, 'end': 90, 'original_start': 180, 'original_end': 190, 'text': 'Unrelated words'},
        ]);
    expect(result['text'], 'Selected actual words');
    expect(result['conversationId'], 'source');
    expect(result['offsetSeconds'], 80);
  });
  test('no recognized speech is distinct from a reviewable moment', () {
    final result = watchMomentFromMark(mark: mark('one', 80), recordingKey: 'audio', status: 'completed', transcript: [
      {'start': 0, 'end': 10, 'text': 'Outside context'}
    ]);
    expect(result['status'], 'noSpeech');
    expect(result.containsKey('text'), isFalse);
  });
  test('processing journal survives restart after phone audio cleanup', () async {
    final first = WatchMomentService.forTesting(account: () => 'account', fetchSource: (_) async => null);
    await first.registerUpload('audio', metadata('one'), uploaded('source'));
    first.cancelPolling();
    final restarted = WatchMomentService.forTesting(account: () => 'account', fetchSource: (id) async => source(id));
    await restarted.refresh();
    restarted.cancelPolling();
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString('watch_moments_v1_account')!);
    expect(saved['jobs'], isEmpty);
    expect(saved['moments']['one']['status'], 'ready');
    expect(saved['moments']['one']['text'], 'Words actually spoken');
  });
  test('processing cannot overwrite a concurrent newly uploaded recording', () async {
    final waiting = Completer<ServerConversation?>();
    final began = Completer<void>();
    final service = WatchMomentService.forTesting(
        account: () => 'account',
        fetchSource: (_) {
          began.complete();
          return waiting.future;
        });
    await service.registerUpload('audioA', metadata('one'), uploaded('sourceA'));
    final refresh = service.refresh();
    await began.future;
    await service.registerUpload('audioB', metadata('two'), uploaded('sourceB'));
    waiting.complete(source('sourceA'));
    await refresh;
    service.cancelPolling();
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString('watch_moments_v1_account')!);
    expect(saved['moments']['one']['status'], 'ready');
    expect(saved['jobs']['audioB']['conversationId'], 'sourceB');
    expect(saved['moments']['two']['status'], 'processing');
  });
  test('account change and logout replace cached words without a new upload', () async {
    var account = 'first';
    var sourceReads = 0;
    final snapshots = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WatchMomentService.channel, (MethodCall call) async {
      snapshots.add(call.arguments as Map);
      return true;
    });
    final service = WatchMomentService.forTesting(
        account: () => account,
        fetchSource: (_) async {
          sourceReads++;
          return null;
        });
    await service.accountChanged();
    account = 'second';
    await service.accountChanged();
    expect(snapshots.last['accountId'], 'second');
    expect(jsonDecode(snapshots.last['json'] as String), isEmpty);
    account = '';
    await service.accountChanged();
    expect(snapshots.last['accountId'], '');
    expect(jsonDecode(snapshots.last['json'] as String), isEmpty);
    expect(sourceReads, 0);
    service.cancelPolling();
  });

  test('a stale response cannot publish another account on the watch', () async {
    var account = 'first';
    final pending = Completer<ServerConversation?>();
    final began = Completer<void>();
    final owners = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WatchMomentService.channel, (MethodCall call) async {
      owners.add((call.arguments as Map)['accountId'] as String);
      return true;
    });
    final service = WatchMomentService.forTesting(
        account: () => account,
        fetchSource: (_) {
          began.complete();
          return pending.future;
        });
    await service.registerUpload('audio', metadata('one'), uploaded('source'));
    owners.clear();
    final refresh = service.refresh();
    await began.future;
    account = 'second';
    pending.complete(source('source'));
    await refresh;
    service.cancelPolling();
    expect(owners, isEmpty);
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString('watch_moments_v1_first')!);
    expect(saved['jobs']['audio'], isNotNull);
  });
}
