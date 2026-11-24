import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/http/api/audio_upload.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/services/watch_moment_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persist the processing journal before native audio cleanup; resume after app restarts.
class WatchMomentService {
  WatchMomentService._()
      : _account = (() {
          final user = FirebaseAuth.instance.currentUser;
          return user != null && !user.isAnonymous ? user.uid : '';
        }),
        _fetchSource = getConversationById;
  @visibleForTesting
  WatchMomentService.forTesting(
      {required String Function() account, required Future<ServerConversation?> Function(String) fetchSource})
      : _account = account,
        _fetchSource = fetchSource;
  final String Function() _account;
  final Future<ServerConversation?> Function(String) _fetchSource;
  @visibleForTesting
  void cancelPolling() {
    _timer?.cancel();
  }

  static final instance = WatchMomentService._();
  static const channel = MethodChannel('com.memorion.ios/watch');
  Timer? _timer;
  bool _refreshing = false;
  Future<void> _journalTail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _journalTail.then((_) => operation());
    _journalTail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<Map<String, dynamic>> _load(String account) async {
    final raw = (await SharedPreferences.getInstance())
        .getString('watch_moments_v1_$account'); // i18n-ignore: persistent storage key, never displayed
    if (raw == null) return {'jobs': <String, dynamic>{}, 'moments': <String, dynamic>{}};
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  Future<void> _save(String account, Map<String, dynamic> journal) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
        'watch_moments_v1_$account', jsonEncode(journal)); // i18n-ignore: persistent storage key, never displayed
    if (!saved) throw StateError('Watch moment journal was not saved');
  }

  Map<String, dynamic>? parseMetadata(String? value) {
    if (value == null) return null;
    final map = (jsonDecode(value) as Map).cast<String, dynamic>();
    return (map['marks'] as List?)?.isNotEmpty == true ? map : null;
  }

  /// Called before markUploaded. A write failure keeps the phone audio in its inbox.
  Future<void> registerUpload(String key, String? metadataJSON, UploadAudioResponse response,
      {String? accountId}) async {
    final metadata = parseMetadata(metadataJSON);
    if (metadata == null) return;
    if (response.conversationId.isEmpty) throw StateError('Missing Watch source conversation');
    final account = accountId ?? _account();
    if (account != _account()) throw StateError('Watch upload account changed; phone audio retained');
    if (account.isEmpty) throw StateError('Missing Watch account');
    await _serialized(() async {
      final journal = await _load(account);
      final jobs = journal['jobs'] as Map;
      final moments = journal['moments'] as Map;
      final marks = (metadata['marks'] as List).map((m) => (m as Map).cast<String, dynamic>()).toList();
      // A completed job response can omit its transcript. Resolve the source before calling it reviewable.
      final processing = response.status == 'processing' || response.transcriptSegments.isEmpty;
      if (processing) jobs[key] = {'conversationId': response.conversationId, 'marks': marks};
      for (final mark in marks) {
        final previous = moments[mark['id']] as Map?;
        if (previous?['status'] == 'ready') continue;
        moments[mark['id']] = watchMomentFromMark(
            mark: mark,
            recordingKey: key,
            conversationId: response.conversationId,
            status: processing ? 'processing' : 'completed',
            transcript: response.transcriptSegments.map((s) => s.toJson().cast<String, dynamic>()).toList());
      }
      await _save(account, journal);
      await _publish(account, journal);
    });
  }

  Future<void> registerFailure(String key, String? metadataJSON, {String? accountId}) async {
    final metadata = parseMetadata(metadataJSON);
    final account = accountId ?? _account();
    if (account != _account()) throw StateError('Watch upload account changed; phone audio retained');
    if (metadata == null || account.isEmpty) return;
    await _serialized(() async {
      final journal = await _load(account);
      for (final raw in metadata['marks'] as List) {
        final mark = (raw as Map).cast<String, dynamic>();
        (journal['moments'] as Map)[mark['id']] = watchMomentFromMark(mark: mark, recordingKey: key, status: 'failed');
      }
      await _save(account, journal);
      await _publish(account, journal);
    });
  }

  Future<void> _publish(String account, Map<String, dynamic> journal) async {
    if (account != _account()) return;
    final values = (journal['moments'] as Map).values.map((v) => (v as Map).cast<String, dynamic>()).toList()
      ..sort((a, b) => (b['markedAtMs'] as num).compareTo(a['markedAtMs'] as num));
    final selected = values.take(100).map((m) {
      final copy = Map<String, dynamic>.from(m);
      if (copy['text'] is String) {
        final text = copy['text'] as String;
        if (text.runes.length > 420) copy['text'] = '${String.fromCharCodes(text.runes.take(420))}…';
      }
      return copy;
    }).toList();
    // Application contexts have a finite payload budget, including UTF-8 Chinese text.
    while (selected.isNotEmpty && utf8.encode(jsonEncode(selected)).length > 55 * 1024) {
      selected.removeLast();
    }
    try {
      await channel.invokeMethod('syncMoments', {'accountId': account, 'json': jsonEncode(selected)});
    } catch (e) {
      debugPrint('[Watch moments] snapshot will retry: $e');
    }
  }

  /// Publish an empty or account-specific snapshot even when no new recording exists.
  /// Auth changes must replace the phone's durable context before it can be replayed.
  Future<void> accountChanged() async {
    _timer?.cancel();
    final account = _account();
    await _serialized(() async {
      final journal =
          account.isEmpty ? {'jobs': <String, dynamic>{}, 'moments': <String, dynamic>{}} : await _load(account);
      await _publish(account, journal);
    });
    if (account.isNotEmpty) await refresh();
  }

  /// Network requests only read already uploaded conversations; audio is never re-uploaded here.
  Future<void> refresh() async {
    if (_refreshing) return;
    final account = _account();
    if (account.isEmpty) return;
    _refreshing = true;
    _timer?.cancel();
    try {
      final snapshot = await _load(account);
      final completed = <String, ServerConversation>{};
      for (final entry in (snapshot['jobs'] as Map).entries) {
        final job = entry.value as Map;
        final source = await _fetchSource(job['conversationId'] as String);
        if (account != _account()) return;
        if (source == null ||
            source.status == ConversationStatus.processing ||
            source.status == ConversationStatus.in_progress) {
          continue;
        }
        completed[entry.key as String] = source;
      }
      await _serialized(() async {
        // Reload after network reads so a concurrent upload cannot be overwritten.
        final journal = await _load(account);
        final jobs = journal['jobs'] as Map;
        final moments = journal['moments'] as Map;
        for (final entry in completed.entries) {
          final job = jobs[entry.key] as Map?;
          if (job == null || job['conversationId'] != entry.value.id) continue;
          for (final raw in job['marks'] as List) {
            final mark = (raw as Map).cast<String, dynamic>();
            moments[mark['id']] = watchMomentFromMark(
                mark: mark,
                recordingKey: entry.key,
                conversationId: entry.value.id,
                status: entry.value.status == ConversationStatus.failed ? 'failed' : 'completed',
                transcript: entry.value.transcriptSegments.map((s) => s.toJson().cast<String, dynamic>()).toList());
          }
          jobs.remove(entry.key);
        }
        final ordered = moments.keys.toList()
          ..sort(
              (a, b) => ((moments[b] as Map)['markedAtMs'] as num).compareTo((moments[a] as Map)['markedAtMs'] as num));
        final pendingIDs = jobs.values.expand((j) => (j as Map)['marks'] as List).map((m) => (m as Map)['id']).toSet();
        for (final id in ordered.skip(100)) {
          if (!pendingIDs.contains(id)) moments.remove(id);
        }
        await _save(account, journal);
        await _publish(account, journal);
        if (jobs.isNotEmpty) _timer = Timer(const Duration(seconds: 60), refresh);
      });
    } catch (e) {
      debugPrint('[Watch moments] retained processing journal: $e');
      _timer = Timer(const Duration(minutes: 2), refresh);
    } finally {
      _refreshing = false;
      if (account != _account() && _account().isNotEmpty) {
        _timer?.cancel();
        _timer = Timer(Duration.zero, refresh);
      }
    }
  }
}
