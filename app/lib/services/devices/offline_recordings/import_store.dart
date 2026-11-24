import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';

import 'models.dart';

enum OfflineImportStage { downloading, downloaded, uploading, uploaded, processed }

class OfflineImportReceipt {
  final String conversationId;
  final bool processing;
  const OfflineImportReceipt(this.conversationId, {required this.processing});
}

class OfflineImportException implements Exception {
  // Preserve the persisted Soundcore codes used before the shared store.
  static const durationTooShort = 'soundcore_duration_too_short';
  static const durationTooLong = 'soundcore_duration_too_long';
  static const durationEstimateTooLong = 'soundcore_duration_estimate_too_long';
  final int? statusCode;
  final AudioUploadFailure? failure;
  final DateTime? failedAt;
  const OfflineImportException([this.statusCode, this.failure, this.failedAt]);
  String get diagnostic {
    final code = failure?.errorCode;
    if (code == durationEstimateTooLong) {
      return 'issue=duration source=estimate phase=validating reason=too_long';
    }
    if (code == durationTooShort || code == durationTooLong) {
      return 'issue=duration source=local phase=validating reason=${code == durationTooShort ? "too_short" : "too_long"}';
    }
    return failure?.diagnostic ?? 'http=${statusCode ?? "none"}';
  }
}

class OfflineRecordingDetails {
  final Duration duration;
  final int? sizeBytes;
  const OfflineRecordingDetails({required this.duration, this.sizeBytes});
}

/// Durable, account-scoped import. Audio is kept locally and on the
/// recorder; an upload receipt is committed only after the backend accepts it.
/// Retries reuse the original file and recording timestamp.
class OfflineImportStore {
  static final _active = <String>{};
  final Directory directory;
  final String ownerId;
  final String Function() currentOwner;
  final DateTime Function() now;
  final Future<OfflineImportReceipt> Function(File file, DateTime startedAt)? upload;
  final Future<OfflineImportReceipt> Function(File file, DateTime startedAt, AudioUploadProgress? onProgress)?
      uploadWithProgress;

  OfflineImportStore({
    required Directory root,
    required this.ownerId,
    required String deviceId,
    required this.currentOwner,
    DateTime Function()? now,
    String source = 'soundcore',
    this.upload,
    this.uploadWithProgress,
  })  : now = now ?? DateTime.now,
        directory = Directory('${root.path}/$source/${sha256.convert(utf8.encode(jsonEncode([ownerId, deviceId])))}') {
    if (!{'soundcore', 'dingtalk_a1', 'plaud'}.contains(source)) throw ArgumentError('Unknown recording source');
    if (upload == null && uploadWithProgress == null) {
      throw ArgumentError('An audio upload callback is required');
    }
  }

  Future<String?> conversationId(int id) async {
    _checkOwner();
    final data = await _metadata(id);
    _checkOwner();
    return data?['conversationId'] as String?;
  }

  Future<void> markProcessed(int id) async {
    _checkOwner();
    final data = await _metadata(id);
    _checkOwner();
    if (data == null) return;
    data['processing'] = false;
    await _save(id, data);
  }

  Future<void> restoreReceipt(OfflineRecording recording, OfflineImportReceipt receipt, {Duration? duration}) async {
    _checkOwner();
    if (receipt.conversationId.isEmpty) throw const FormatException('Missing cloud receipt');
    await directory.create(recursive: true);
    final data = await _metadata(recording.id) ??
        {
          'id': recording.id,
          'endTime': recording.endTime,
          'reportedSize': recording.reportedSize,
        };
    _checkOwner();
    data['conversationId'] = receipt.conversationId;
    data['processing'] = receipt.processing;
    if (duration != null) data['durationMs'] = duration.inMilliseconds;
    data.remove('rejectedStatus');
    data.remove('uploadFailure');
    await _save(recording.id, data);
  }

  Future<OfflineImportException?> lastUploadFailure(int id) async {
    _checkOwner();
    final data = await _metadata(id);
    _checkOwner();
    final failure = data?['uploadFailure'];
    if (data?['conversationId'] != null || failure is! Map) return null;
    final issue = AudioUploadIssue.values
        .firstWhere((value) => value.name == failure['issue'], orElse: () => AudioUploadIssue.unknown);
    final status = failure['http'] is int ? failure['http'] as int : null;
    var errorCode = failure['code'] is String ? failure['code'] as String : null;
    // Older clients recorded local duration validation as HTTP 400/sending.
    // Recover its source from saved metadata; actual HTTP errors are confirming.
    final duration = data?['durationMs'];
    if (errorCode == null && issue == AudioUploadIssue.duration && failure['confirming'] == false && duration is int) {
      if (duration < 5000) errorCode = OfflineImportException.durationTooShort;
      if (duration > maxOfflineRecordingDuration.inMilliseconds) errorCode = OfflineImportException.durationTooLong;
    }
    final failedAt = failure['failedAt'] is String ? DateTime.tryParse(failure['failedAt'] as String) : null;
    return OfflineImportException(
      status,
      AudioUploadFailure(
        issue,
        statusCode: status,
        awaitingResponse: failure['confirming'] == true,
        errorCode: errorCode,
      ),
      failedAt,
    );
  }

  void _checkOwner() {
    if (ownerId.isEmpty || currentOwner() != ownerId) {
      throw StateError('Sign in to the same account before importing');
    }
  }

  Future<Map<String, dynamic>?> _metadata(int id) async {
    final file = File('${directory.path}/$id.json');
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> || value['id'] != id) {
      throw const FormatException(
          'Invalid offline import metadata'); // i18n-ignore: Internal error, localized by the recording page.
    }
    // Reconsider only pre-upgrade duration rejections, once. A rejection from
    // the new policy (including an older server) must not create a retry loop.
    final failure = value['uploadFailure'];
    final duration = value['durationMs'];
    if (value['conversationId'] == null &&
        failure is Map &&
        failure['issue'] == AudioUploadIssue.duration.name &&
        duration is int &&
        duration > const Duration(hours: 2).inMilliseconds &&
        duration <= maxOfflineRecordingDuration.inMilliseconds &&
        (value['durationLimitMs'] as int? ?? 7200000) < maxOfflineRecordingDuration.inMilliseconds) {
      _checkOwner();
      value.remove('rejectedStatus');
      value.remove('uploadFailure');
      // Persist with the next import/receipt write, never from concurrent UI reads.
      value['durationLimitMs'] = maxOfflineRecordingDuration.inMilliseconds;
    }
    return value;
  }

  Future<void> _save(int id, Map<String, dynamic> value) async {
    final pending = File('${directory.path}/$id.json.part');
    await pending.writeAsString(jsonEncode(value), flush: true);
    await pending.rename('${directory.path}/$id.json');
  }

  Future<List<OfflineRecording>> cachedRecordings() async {
    _checkOwner();
    if (!await directory.exists()) return [];
    final result = <OfflineRecording>[];
    await for (final file in directory.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final id = int.tryParse(file.uri.pathSegments.last.replaceFirst('.json', ''));
      if (id == null) continue;
      final data = await _metadata(id);
      if (data == null) continue;
      result.add(OfflineRecording(id, data['endTime'] as int, data['reportedSize'] as int));
    }
    _checkOwner();
    return result;
  }

  Future<OfflineImportStage?> status(int id) async {
    _checkOwner();
    final data = await _metadata(id);
    _checkOwner();
    if (data == null) return null;
    if (data['conversationId'] == null) {
      final exists = await File('${directory.path}/$id.ogg').exists();
      _checkOwner();
      return exists ? OfflineImportStage.downloaded : null;
    }
    return data['processing'] == true ? OfflineImportStage.uploaded : OfflineImportStage.processed;
  }

  /// A permanent rejection survives restarts so automatic sync does not keep
  /// sending unsupported/silent audio. An explicit retry can override it.
  Future<int?> rejectionStatus(int id) async {
    _checkOwner();
    final data = await _metadata(id);
    _checkOwner();
    return data?['rejectedStatus'] as int?;
  }

  /// Works with existing imports: duration was already persisted, and stat()
  /// reads the actual Ogg size without loading audio or starting a BLE transfer.
  Future<OfflineRecordingDetails?> recordingDetails(int id) async {
    _checkOwner();
    final data = await _metadata(id);
    if (data == null) return null;
    final durationMs = data['durationMs'];
    if (durationMs is! int || durationMs <= 0) return null;
    final audio = await File('${directory.path}/$id.ogg').stat();
    _checkOwner();
    return OfflineRecordingDetails(
      duration: Duration(milliseconds: durationMs),
      sizeBytes: audio.type == FileSystemEntityType.file ? audio.size : null,
    );
  }

  Future<void> cacheRecording(
    OfflineRecording recording, {
    required Future<OfflineDownload> Function() download,
    void Function(OfflineImportStage)? onStage,
  }) async {
    _checkOwner();
    if (!_active.add(directory.path)) throw StateError('A offline import is already in progress');
    try {
      final metadata = await _cacheAudio(recording, download: download, onStage: onStage);
      _checkOwner();
      onStage?.call(metadata['conversationId'] == null
          ? OfflineImportStage.downloaded
          : metadata['processing'] == true
              ? OfflineImportStage.uploaded
              : OfflineImportStage.processed);
    } finally {
      _active.remove(directory.path);
    }
  }

  Future<Map<String, dynamic>> _cacheAudio(
    OfflineRecording recording, {
    required Future<OfflineDownload> Function() download,
    void Function(OfflineImportStage)? onStage,
  }) async {
    _checkOwner();
    if (!recording.hasValidTimestamp(now())) {
      throw const FormatException(
          'Invalid offline recording time'); // i18n-ignore: Internal diagnostic; localized by the recording page.
    }
    await directory.create(recursive: true);
    var metadata = await _metadata(recording.id);
    if (metadata?['conversationId'] != null) return metadata!;
    final audio = File('${directory.path}/${recording.id}.ogg');
    if (metadata == null || !await audio.exists()) {
      onStage?.call(OfflineImportStage.downloading);
      final OfflineDownload result;
      try {
        result = await download();
      } on OfflineRecordingTooLong catch (error) {
        _checkOwner();
        // No partial Ogg is saved. Persist the measured rejection so neither
        // transport downloads the same unsupported file again after restart.
        await _save(recording.id, {
          'id': recording.id,
          'endTime': recording.endTime,
          'reportedSize': recording.reportedSize,
          'durationMs': error.duration.inMilliseconds,
          'rejectedStatus': 400,
          'durationLimitMs': maxOfflineRecordingDuration.inMilliseconds,
          'uploadFailure': {
            'issue': AudioUploadIssue.duration.name,
            'http': 400,
            'code': OfflineImportException.durationTooLong,
            'failedAt': now().toUtc().toIso8601String(),
            'confirming': false,
          },
        });
        throw const OfflineImportException(
            400, AudioUploadFailure(AudioUploadIssue.duration, errorCode: OfflineImportException.durationTooLong));
      }
      final pending = File('${audio.path}.part');
      try {
        _checkOwner();
        await result.writeTo(pending);
        final input = await pending.open();
        try {
          final magic = await input.read(4);
          if (magic.length != 4 || ascii.decode(magic, allowInvalid: true) != 'OggS') {
            throw const FormatException(
                'Invalid offline audio container'); // i18n-ignore: Internal error, localized by the recording page.
          }
        } finally {
          await input.close();
        }
        final digest = (await sha256.bind(pending.openRead()).first).toString();
        _checkOwner();
        await pending.rename(audio.path);
        metadata = {
          'id': recording.id,
          'endTime': recording.endTime,
          'reportedSize': recording.reportedSize,
          'durationMs': result.duration.inMilliseconds,
          'sha256': digest,
        };
        await _save(recording.id, metadata);
      } finally {
        if (await pending.exists()) await pending.delete();
        await result.dispose();
      }
    }
    _checkOwner();
    return metadata;
  }

  Future<OfflineImportReceipt> importRecording(
    OfflineRecording recording, {
    required Future<OfflineDownload> Function() download,
    void Function(OfflineImportStage)? onStage,
    bool retryRejected = false,
    AudioUploadProgress? onUploadProgress,
  }) async {
    _checkOwner();
    if (!_active.add(directory.path)) throw StateError('A offline import is already in progress');
    try {
      var metadata = await _metadata(recording.id);
      final rejectedStatus = metadata?['rejectedStatus'];
      if (!retryRejected && rejectedStatus is int) {
        throw await lastUploadFailure(recording.id) ?? OfflineImportException(rejectedStatus);
      }
      metadata = await _cacheAudio(recording, download: download, onStage: onStage);
      final receiptId = metadata['conversationId'];
      if (receiptId is String && receiptId.isNotEmpty) {
        final processing = metadata['processing'] == true;
        onStage?.call(processing ? OfflineImportStage.uploaded : OfflineImportStage.processed);
        return OfflineImportReceipt(receiptId, processing: processing);
      }
      final audio = File('${directory.path}/${recording.id}.ogg');
      _checkOwner();
      final digest = (await sha256.bind(audio.openRead()).first).toString();
      if (digest != metadata['sha256']) {
        throw const FormatException(
            'Cached offline recording is incomplete'); // i18n-ignore: Internal diagnostic; the import page shows localized errors.
      }
      final duration = metadata['durationMs'] as int;
      if (duration < 5000 || duration > maxOfflineRecordingDuration.inMilliseconds) {
        throw OfflineImportException(
            400,
            AudioUploadFailure(AudioUploadIssue.duration,
                errorCode: duration < 5000
                    ? OfflineImportException.durationTooShort
                    : OfflineImportException.durationTooLong));
      }
      _checkOwner();
      onStage?.call(OfflineImportStage.uploading);
      final receipt = uploadWithProgress != null
          ? await uploadWithProgress!(audio, recording.startedAt, onUploadProgress)
          : await upload!(audio, recording.startedAt);
      _checkOwner();
      if (receipt.conversationId.isEmpty) {
        throw const OfflineImportException(null, AudioUploadFailure(AudioUploadIssue.invalidResponse));
      }
      metadata['conversationId'] = receipt.conversationId;
      metadata['processing'] = receipt.processing;
      metadata.remove('rejectedStatus');
      metadata.remove('uploadFailure');
      await _save(recording.id, metadata);
      onStage?.call(receipt.processing ? OfflineImportStage.uploaded : OfflineImportStage.processed);
      return receipt;
    } on OfflineImportException catch (error) {
      _checkOwner();
      final metadata = await _metadata(recording.id);
      if (metadata != null && metadata['conversationId'] == null) {
        metadata['durationLimitMs'] = maxOfflineRecordingDuration.inMilliseconds;
        metadata['uploadFailure'] = {
          'issue': error.failure?.issue.name ?? AudioUploadIssue.unknown.name,
          'http': error.statusCode,
          'code': error.failure?.errorCode,
          'failedAt': now().toUtc().toIso8601String(),
          'confirming': error.failure?.awaitingResponse ?? false,
        };
        if ({400, 413, 415, 422}.contains(error.statusCode)) {
          metadata['rejectedStatus'] = error.statusCode;
        }
        await _save(recording.id, metadata);
      }
      rethrow;
    } finally {
      _active.remove(directory.path);
    }
  }
}
