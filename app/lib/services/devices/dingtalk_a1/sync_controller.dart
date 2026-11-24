import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:opus_dart/opus_dart.dart';
import '../offline_recordings/import_store.dart';
import '../offline_recordings/models.dart';
import 'audio.dart';
import 'import_store.dart';
import 'protocol.dart';
import 'session.dart';

class A1SyncController extends ChangeNotifier {
  final Future<A1ImportStore> Function() openStore;
  final Future<A1Session?> Function() openSession;
  final bool Function() isCurrentOwner;
  final Future<bool> Function() readAutoSync;
  final Future<void> Function(bool) writeAutoSync;
  final Future<AudioProcessingJob> Function(String)? fetchJob;
  final Future<OfflineDownload> Function(Uint8List)? decodeAudio;
  A1ImportStore? _store;
  bool _disposed = false, _retired = false, _refreshingJobs = false;
  int _jobCursor = 0;
  final _retryAfter = <int, DateTime>{};
  List<OfflineRecording> recordings = [];
  final stages = <int, OfflineImportStage>{};
  final details = <int, OfflineRecordingDetails>{};
  final errors = <int, Object>{};
  final processingJobs = <int, AudioProcessingJob>{};
  A1Info? info;
  Object? error;
  bool loading = false, busy = false, autoSync = false, connected = false;
  int? activeId, deviceFileCount;
  int bytes = 0, totalBytes = 0;
  double? uploadProgress;
  DateTime? lastRefresh;

  A1SyncController(
      {required this.openStore,
      required this.openSession,
      required this.isCurrentOwner,
      required this.readAutoSync,
      required this.writeAutoSync,
      this.fetchJob,
      this.decodeAudio});
  bool get ownerActive => !_retired && isCurrentOwner();
  bool get _allowed => !_disposed && ownerActive;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _check() {
    if (!_allowed) throw const A1Exception(A1Issue.identityRequired);
  }

  Future<A1ImportStore> _getStore() async {
    _check();
    return _store ??= await openStore();
  }

  Future<void> refresh() async {
    if (!_allowed || busy || loading) return;
    loading = true;
    error = null;
    _notify();
    try {
      final store = await _getStore();
      autoSync = await readAutoSync();
      final merged = {for (final r in await store.cachedRecordings()) r.id: r};
      _check();
      try {
        final session = await openSession();
        _check();
        connected = session != null && !session.isClosed;
        if (connected && !session!.busy) {
          info = await session.readInfo();
          final deviceRecords = await session.recordings();
          _check();
          deviceFileCount = deviceRecords.length;
          for (final r in deviceRecords) {
            merged[r.id] = r;
          }
        }
      } catch (e) {
        _check();
        connected = false;
        error = e;
      }
      recordings = merged.values.toList()..sort((a, b) => b.id.compareTo(a.id));
      for (final r in recordings) {
        final stage = await store.status(r.id);
        final detail = await store.recordingDetails(r.id);
        final issue = await store.audioIssue(r.id);
        _check();
        if (stage != null) stages[r.id] = stage;
        if (detail != null) details[r.id] = detail;
        if (issue != null) errors[r.id] = A1Exception(issue);
      }
      lastRefresh = DateTime.now();
    } catch (e) {
      if (_allowed) error = e;
    } finally {
      loading = false;
      _notify();
    }
    if (_allowed) {
      unawaited(refreshProcessing());
      if (autoSync) unawaited(importAll());
    }
  }

  Future<void> setAutoSync(bool enabled) async {
    _check();
    await writeAutoSync(enabled);
    _check();
    autoSync = enabled;
    _notify();
    if (enabled) unawaited(importAll());
  }

  Future<void> importAll() async {
    if (!_allowed || busy || loading || !autoSync) return;
    try {
      // Each successful item commits its own receipt. Leaving the page never
      // cancels the app-owned queue; switching account stops all subsequent work.
      for (final r in List<OfflineRecording>.of(recordings)) {
        if (!_allowed || !autoSync || loading || busy) break;
        if ({OfflineImportStage.uploaded, OfflineImportStage.processed}.contains(stages[r.id])) continue;
        if (errors[r.id] is A1Exception &&
            {A1Issue.encryptedAudio, A1Issue.unsupportedAudio}.contains((errors[r.id] as A1Exception).issue)) {
          continue;
        }
        if (_retryAfter[r.id]?.isAfter(DateTime.now()) == true) continue;
        if (!r.hasValidTimestamp(DateTime.now())) continue;
        final store = await _getStore();
        if (await store.rejectionStatus(r.id) != null) continue;
        _check();
        await importOne(r);
        if (!connected && stages[r.id] != OfflineImportStage.downloaded) break;
      }
    } catch (e) {
      if (_allowed) {
        error = e;
        _notify();
      }
    }
  }

  Future<void> importOne(OfflineRecording recording, {bool retry = false}) async {
    if (!_allowed || busy || loading) return;
    busy = true;
    activeId = recording.id;
    bytes = totalBytes = 0;
    uploadProgress = null;
    errors.remove(recording.id);
    _notify();
    try {
      final store = await _getStore();
      await store.importRecording(recording, retryRejected: retry, download: () async {
        final raw = await store.original(recording, () async {
          final session = await openSession();
          _check();
          connected = session != null && !session.isClosed;
          if (!connected) throw const A1Exception(A1Issue.disconnected);
          return session!.download(recording.id, onProgress: (received, total) {
            if (!_allowed) {
              session.close();
              return;
            }
            bytes = received;
            totalBytes = total;
            _notify();
          });
        });
        _check();
        try {
          return await (decodeAudio ?? _decode)(raw);
        } on A1Exception catch (e) {
          if ({A1Issue.encryptedAudio, A1Issue.unsupportedAudio}.contains(e.issue)) {
            await store.markAudioIssue(recording.id, e.issue);
          }
          rethrow;
        }
      }, onStage: (stage) {
        if (_allowed) {
          stages[recording.id] = stage;
          _notify();
        }
      }, onUploadProgress: (sent, total) {
        if (_allowed) {
          uploadProgress = total > 0 ? sent / total : null;
          _notify();
        }
      });
      final detail = await store.recordingDetails(recording.id);
      _check();
      if (detail != null) details[recording.id] = detail;
      _retryAfter.remove(recording.id);
    } catch (e) {
      if (_allowed) {
        errors[recording.id] = e;
        _retryAfter[recording.id] = DateTime.now().add(const Duration(minutes: 2));
        try {
          final stage = await _store?.status(recording.id);
          if (_allowed) {
            if (stage != null) {
              stages[recording.id] = stage;
            } else {
              stages.remove(recording.id);
            }
          }
        } catch (_) {}
      }
    } finally {
      busy = false;
      activeId = null;
      _notify();
    }
    if (_allowed) unawaited(refreshProcessing());
  }

  static Future<OfflineDownload> _decode(Uint8List bytes) async {
    final audio = A1Audio.parse(bytes);
    final decoder = SimpleOpusDecoder(sampleRate: 48000, channels: 1);
    try {
      return await audio.toOgg(validatePacket: (p) => decoder.decode(input: p).length);
    } finally {
      decoder.destroy();
    }
  }

  Future<void> refreshProcessing() async {
    if (!_allowed || fetchJob == null || _refreshingJobs) return;
    _refreshingJobs = true;
    try {
      final store = await _getStore();
      final candidates = recordings.where((r) => stages[r.id] == OfflineImportStage.uploaded).toList();
      if (candidates.isEmpty) return;
      for (var i = 0; i < candidates.length.clamp(0, 10); i++) {
        final r = candidates[_jobCursor++ % candidates.length];
        final id = await store.conversationId(r.id);
        _check();
        if (id == null) continue;
        try {
          final job = await fetchJob!(id);
          _check();
          processingJobs[r.id] = job;
          if (job.status == 'completed') {
            await store.markProcessed(r.id);
            stages[r.id] = OfflineImportStage.processed;
          }
        } catch (_) {/* Retry on the next polling cycle; preserve existing state. */}
      }
    } catch (_) {/* Account changes stop polling. */} finally {
      _refreshingJobs = false;
      _notify();
    }
  }

  Future<void> recordingControl(String action) async {
    if (!_allowed || busy || loading) return;
    busy = true;
    error = null;
    _notify();
    try {
      final session = await openSession();
      _check();
      if (session == null) throw const A1Exception(A1Issue.disconnected);
      info = await session.recordingControl(action);
    } catch (e) {
      if (_allowed) error = e;
    } finally {
      busy = false;
      _notify();
    }
    if (_allowed && action == 'stop') await refresh();
  }

  Future<File?> playable(int id) async {
    final file = await (await _getStore()).playable(id);
    _check();
    return file;
  }

  void retire() {
    _retired = true;
    recordings = [];
    stages.clear();
    details.clear();
    errors.clear();
    processingJobs.clear();
    info = null;
    connected = false;
    autoSync = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
