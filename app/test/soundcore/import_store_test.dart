import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/services/devices/soundcore/import_store.dart';
import 'package:memorion/services/devices/soundcore/ogg_opus.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/offline_recordings/models.dart';

void main() {
  late Directory root;
  late String owner;
  late SoundcoreRecording recording;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('memorion_soundcore_test_');
    owner = 'test-owner';
    final id = DateTime.now().toUtc().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
    recording = SoundcoreRecording(id, id + 6, 48000);
  });
  tearDown(() async => root.delete(recursive: true));

  SoundcoreImportStore store(Future<SoundcoreImportReceipt> Function(File, DateTime) upload) => SoundcoreImportStore(
        root: root,
        ownerId: owner,
        deviceId: 'test-device',
        currentOwner: () => owner,
        upload: upload,
      );

  Future<SoundcoreDownload> download() async => SoundcoreDownload(
        soundcoreOggOpus(List.generate(300, (_) => Uint8List(160)..setAll(0, [0xf8, 0xff, 0xfe]))),
        const Duration(seconds: 6),
      );

  test('completed import survives restart and never downloads or uploads twice', () async {
    var downloads = 0, uploads = 0;
    final stages = <SoundcoreImportStage>[];
    final first = store((file, startedAt) async {
      uploads++;
      expect(file.path.endsWith('.ogg'), isTrue);
      expect(startedAt, recording.startedAt);
      expect(await file.exists(), isTrue);
      return const SoundcoreImportReceipt('conversation-test', processing: true);
    });
    await first.importRecording(recording, download: () async {
      downloads++;
      return download();
    }, onStage: stages.add);
    expect(stages, [SoundcoreImportStage.downloading, SoundcoreImportStage.uploading, SoundcoreImportStage.uploaded]);
    final restarted = store((_, __) async => throw StateError('must not upload twice'));
    final receipt =
        await restarted.importRecording(recording, download: () async => throw StateError('must not download twice'));
    expect(receipt.conversationId, 'conversation-test');
    expect(uploads, 1);
    expect(downloads, 1);
    expect(await restarted.status(recording.id), SoundcoreImportStage.uploaded);
    expect(await File('${first.directory.path}/${recording.id}.ogg').exists(), isTrue);
    final details = await restarted.recordingDetails(recording.id);
    expect(details!.duration, const Duration(seconds: 6));
    expect(details.sizeBytes, await File('${first.directory.path}/${recording.id}.ogg').length());
    expect(details.sizeBytes, isNot(recording.reportedSize));
  });

  test('failed upload retains audio and retry works without the recorder', () async {
    final first = store((_, __) async => throw const SoundcoreImportException(503));
    await expectLater(first.importRecording(recording, download: download), throwsA(isA<SoundcoreImportException>()));
    expect(await first.status(recording.id), SoundcoreImportStage.downloaded);
    expect((await first.recordingDetails(recording.id))!.duration, const Duration(seconds: 6));
    final retried = store((_, time) async {
      expect(time, recording.startedAt);
      return const SoundcoreImportReceipt('retried', processing: false);
    });
    await retried.importRecording(recording, download: () async => throw StateError('recorder is offline'));
    expect(await retried.status(recording.id), SoundcoreImportStage.processed);
    expect((await retried.cachedRecordings()).single.id, recording.id);
  });

  test('incomplete downloads never reach the backend', () async {
    final first = store((_, __) async => throw StateError('must not upload'));
    await expectLater(
        first.importRecording(recording, download: () async => throw const FormatException('sequence gap')),
        throwsFormatException);
    expect(await first.cachedRecordings(), isEmpty);
  });

  test('drained long recording rejection survives restart without a partial audio cache', () async {
    final first = store((_, __) async => throw StateError('must not upload'));
    await expectLater(
        first.cacheRecording(recording, download: () async {
          throw const OfflineRecordingTooLong(Duration(hours: 9));
        }),
        throwsA(isA<SoundcoreImportException>()));
    final restarted = store((_, __) async => throw StateError('must not upload'));
    await expectLater(restarted.importRecording(recording, download: () async => throw StateError('must not download')),
        throwsA(isA<SoundcoreImportException>().having((e) => e.statusCode, 'status', 400)));
    expect(await restarted.status(recording.id), isNull);
    expect((await restarted.lastUploadFailure(recording.id))!.diagnostic,
        'issue=duration source=local phase=validating reason=too_long');
    final details = (await restarted.recordingDetails(recording.id))!;
    expect(details.sizeBytes, isNull);
    expect(details.duration, const Duration(hours: 9));
  });

  for (final seconds in [7201, 14400, 28800]) {
    test('upgraded duration policy accepts $seconds seconds and restores old rejected cache', () async {
      final first = store((_, __) async => const SoundcoreImportReceipt('long', processing: true));
      final bytes = await download();
      await first.cacheRecording(recording,
          download: () async => SoundcoreDownload(bytes.ogg!, Duration(seconds: seconds)));
      final meta = File('${first.directory.path}/${recording.id}.json');
      final data = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      data['rejectedStatus'] = 400;
      data['uploadFailure'] = {'issue': 'duration', 'http': 400, 'confirming': false};
      await meta.writeAsString(jsonEncode(data));
      expect(await first.rejectionStatus(recording.id), isNull);
      expect(await first.lastUploadFailure(recording.id), isNull);
      await first.importRecording(recording, download: () async => throw StateError('must reuse cached audio'));
      expect(await first.status(recording.id), SoundcoreImportStage.uploaded);
    });
  }

  test('old measured rejection without a cached prefix is downloaded again after upgrade', () async {
    final first = store((_, __) async => const SoundcoreImportReceipt('recovered', processing: true));
    await first.directory.create(recursive: true);
    await File('${first.directory.path}/${recording.id}.json').writeAsString(jsonEncode({
      'id': recording.id,
      'endTime': recording.endTime,
      'reportedSize': recording.reportedSize,
      'durationMs': 14400000,
      'rejectedStatus': 400,
      'uploadFailure': {'issue': 'duration', 'code': SoundcoreImportException.durationTooLong}
    }));
    var downloads = 0;
    await first.importRecording(recording, download: () async {
      downloads++;
      return download();
    });
    expect(downloads, 1);
    expect(await first.status(recording.id), SoundcoreImportStage.uploaded);
  });

  test('new server duration rejection is not repeatedly cleared by migration', () async {
    var uploads = 0;
    final first = store((_, __) async {
      uploads++;
      throw const SoundcoreImportException(400, AudioUploadFailure(AudioUploadIssue.duration));
    });
    final bytes = await download();
    await expectLater(
        first.importRecording(recording, download: () async => SoundcoreDownload(bytes.ogg!, const Duration(hours: 4))),
        throwsA(isA<SoundcoreImportException>()));
    expect(await first.rejectionStatus(recording.id), 400);
    await expectLater(first.importRecording(recording, download: download), throwsA(isA<SoundcoreImportException>()));
    expect(uploads, 1);
  });

  for (final outcome in ['success', 'invalid', 'account-change']) {
    test('temporary file is released after cache $outcome', () async {
      final folder = await root.createTemp('transfer-');
      final source = File('${folder.path}/audio.ogg');
      final bytes = await download();
      await source.writeAsBytes(outcome == 'invalid' ? [1, 2, 3, 4] : bytes.ogg!);
      final first = store((_, __) async => const SoundcoreImportReceipt('file-backed', processing: true));
      final future = first.cacheRecording(recording, download: () async {
        if (outcome == 'account-change') owner = 'another-owner';
        return SoundcoreDownload.temporaryFile(source, const Duration(hours: 8));
      });
      if (outcome == 'success') {
        await future;
        expect(await File('${first.directory.path}/${recording.id}.ogg').readAsBytes(), bytes.ogg);
        expect((await first.recordingDetails(recording.id))!.duration, const Duration(hours: 8));
      } else {
        await expectLater(future, outcome == 'invalid' ? throwsFormatException : throwsStateError);
        expect(await File('${first.directory.path}/${recording.id}.ogg').exists(), isFalse);
      }
      expect(await folder.exists(), isFalse);
      expect(await File('${first.directory.path}/${recording.id}.ogg.part').exists(), isFalse);
    });
  }

  test('invalid success response does not mark an upload completed', () async {
    final first = store((_, __) async => const SoundcoreImportReceipt('', processing: true));
    await expectLater(first.importRecording(recording, download: download), throwsA(isA<SoundcoreImportException>()));
    expect(await first.status(recording.id), SoundcoreImportStage.downloaded);
  });

  test('cache corruption is detected before a retry uploads anything', () async {
    final first = store((_, __) async => throw const SoundcoreImportException(503));
    await expectLater(first.importRecording(recording, download: download), throwsA(isA<SoundcoreImportException>()));
    await File('${first.directory.path}/${recording.id}.ogg').writeAsBytes([1, 2, 3]);
    final retried = store((_, __) async => throw StateError('must not upload'));
    await expectLater(retried.importRecording(recording, download: download), throwsFormatException);
  });

  test('account changes cannot upload or expose the previous account cache', () async {
    final first = store((_, __) async => throw StateError('must not upload'));
    owner = 'other-owner';
    await expectLater(first.cachedRecordings(), throwsStateError);
    await expectLater(first.recordingDetails(recording.id), throwsStateError);
    await expectLater(first.importRecording(recording, download: download), throwsStateError);
    expect(first.directory.path, isNot(store((_, __) async => throw StateError('unused')).directory.path));
  });

  test('account changes during download prevent upload', () async {
    final first = store((_, __) async => throw StateError('must not upload'));
    await expectLater(
        first.importRecording(recording, download: () async {
          owner = 'other-owner';
          return download();
        }),
        throwsStateError);
  });

  test('only one import can run for the same account and device', () async {
    final gate = Completer<SoundcoreDownload>();
    final first = store((_, __) async => const SoundcoreImportReceipt('done', processing: true));
    final active = first.importRecording(recording, download: () => gate.future);
    final second = store((_, __) async => throw StateError('must not upload'));
    await expectLater(second.importRecording(recording, download: download), throwsStateError);
    gate.complete(await download());
    await active;
  });

  for (final seconds in [1, 28801]) {
    test('out-of-range duration $seconds stays local with an accurate persisted rejection', () async {
      final first = store((_, __) async => throw StateError('must not upload'));
      await expectLater(
          first.importRecording(recording, download: () async {
            final bytes = await download();
            return SoundcoreDownload(bytes.ogg!, Duration(seconds: seconds));
          }),
          throwsA(isA<SoundcoreImportException>()));
      expect(await File('${first.directory.path}/${recording.id}.ogg').exists(), isTrue);
      final rejection = await first.lastUploadFailure(recording.id);
      expect(rejection!.diagnostic,
          'issue=duration source=local phase=validating reason=${seconds < 5 ? "too_short" : "too_long"}');
      expect(await first.rejectionStatus(recording.id), 400);

      // Read the same metadata format produced by the user's older build.
      final metadata = File('${first.directory.path}/${recording.id}.json');
      final value = jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
      (value['uploadFailure'] as Map).remove('code');
      await metadata.writeAsString(jsonEncode(value));
      final restarted = store((_, __) async => throw StateError('must not upload'));
      expect((await restarted.lastUploadFailure(recording.id))!.diagnostic, rejection.diagnostic);
      await expectLater(
          restarted.importRecording(recording, download: download), throwsA(isA<SoundcoreImportException>()));
    });
  }
}
