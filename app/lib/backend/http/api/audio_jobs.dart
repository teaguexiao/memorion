import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/env/env.dart';

class AudioProcessingJob {
  final String id;
  final String conversationId;
  final String status;
  final String stage;
  final DateTime startedAt;
  final DateTime? nextAttemptAt;
  final String? errorCode;
  final bool canRetry;
  final bool discarded;
  final List<AudioProcessingJob> followups;

  AudioProcessingJob.fromJson(Map<String, dynamic> value)
      : id = value['id'] as String,
        conversationId = value['conversation_id'] as String,
        status = value['status'] as String,
        stage = value['stage'] as String,
        startedAt = DateTime.parse(value['started_at'] as String),
        nextAttemptAt = value['next_attempt_at'] is num
            ? DateTime.fromMillisecondsSinceEpoch(((value['next_attempt_at'] as num) * 1000).round())
            : null,
        errorCode = value['error_code'] as String?,
        canRetry = value['can_retry'] == true,
        discarded = value['discarded'] == true,
        followups = (value['followups'] as List<dynamic>? ?? [])
            .map((item) => AudioProcessingJob.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();

  bool get active => !{'completed', 'failed', 'cancelled'}.contains(status);
  bool get needsAttention => status == 'failed' || followups.any((job) => job.needsAttention);
}

class AudioJobsResult {
  final List<AudioProcessingJob> items;
  final String? nextCursor;
  const AudioJobsResult(this.items, this.nextCursor);
}

class AudioRecordingUploadState {
  final bool canUpload;
  final String? conversationId;
  final bool processing;
  final Duration? duration;
  final AudioProcessingJob? job;
  AudioRecordingUploadState.fromJson(Map<String, dynamic> value)
      : canUpload = value['can_upload'] == true,
        conversationId = value['conversation_id'] as String?,
        processing = value['processing'] == true,
        duration = value['duration_seconds'] is num && (value['duration_seconds'] as num) > 0
            ? Duration(milliseconds: ((value['duration_seconds'] as num) * 1000).round())
            : null,
        job = value['job'] is Map ? AudioProcessingJob.fromJson(Map<String, dynamic>.from(value['job'])) : null;
}

class AudioJobsApi {
  String get ownerId {
    final user = FirebaseAuth.instance.currentUser;
    final owner = getExternalUserId();
    return user != null && !user.isAnonymous && user.uid == owner ? owner : '';
  }

  Future<Map<String, dynamic>> _request(String path,
      {bool retry = false, String? before, Map<String, dynamic>? body}) async {
    final owner = ownerId;
    final key = getAuthHeader();
    if (owner.isEmpty || key.isEmpty) throw StateError('Not signed in');
    // makeApiCall appends the current external_user_id for our API.
    var url = Uri.parse('${Env.apiBaseUrl}v1/audio-jobs$path');
    if (before != null) url = url.replace(queryParameters: {'before': before});
    final response = await makeApiCall(
            url: url.toString(),
            headers: {'Authorization': key, if (retry || body != null) 'Content-Type': 'application/json'},
            method: retry || body != null ? 'POST' : 'GET',
            body: body != null
                ? jsonEncode(body)
                : retry
                    ? '{}'
                    : '')
        .timeout(const Duration(seconds: 20));
    if (ownerId != owner) throw StateError('Account changed');
    if (response == null || response.statusCode != 200) {
      throw StateError('Task request failed: ${response?.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<AudioJobsResult> list({String? before}) async {
    final data = await _request('', before: before);
    return AudioJobsResult(
        (data['items'] as List<dynamic>)
            .map((value) => AudioProcessingJob.fromJson(value as Map<String, dynamic>))
            .toList(),
        data['next_cursor'] as String?);
  }

  Future<AudioProcessingJob> get(String id) async =>
      AudioProcessingJob.fromJson(await _request('/${Uri.encodeComponent(id)}'));

  Future<List<AudioProcessingJob>> active() async {
    final data = await _request('/active');
    return (data['items'] as List<dynamic>)
        .map((value) => AudioProcessingJob.fromJson(value as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, AudioRecordingUploadState>> lookupRecordings(Map<String, DateTime> recordings) async {
    final data = await _request('/lookup', body: {
      'recordings': [
        for (final entry in recordings.entries)
          {'recording_key': entry.key, 'started_at': entry.value.toUtc().toIso8601String()}
      ]
    });
    final result = <String, AudioRecordingUploadState>{};
    for (final item in data['items'] as List<dynamic>) {
      final value = Map<String, dynamic>.from(item as Map);
      final key = value['recording_key'] as String;
      if (!recordings.containsKey(key) ||
          result.containsKey(key) ||
          value['can_upload'] is! bool ||
          DateTime.parse(value['started_at'] as String) != recordings[key]) {
        // i18n-ignore: Internal response validation; the recorder page localizes failures.
        throw const FormatException('Invalid recording lookup response');
      }
      result[key] = AudioRecordingUploadState.fromJson(value);
    }
    // i18n-ignore: Internal response validation; the recorder page localizes failures.
    if (result.length != recordings.length) throw const FormatException('Incomplete recording lookup response');
    return result;
  }

  Future<void> retry(String id) async =>
      _request('/${Uri.encodeComponent(id)}/retry', retry: true); // i18n-ignore: API path.
}
