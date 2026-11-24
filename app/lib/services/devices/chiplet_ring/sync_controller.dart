import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'bridge.dart';
import 'health.dart';
import 'models.dart';
import 'import_store.dart';

/// Account-scoped, app-lifetime queue. Navigating away does not destroy work.
class RingSyncController extends ChangeNotifier {
  final Future<RingTransport?> Function() openTransport;
  final Future<RingImportStore> Function() openStore;
  final Future<void> Function()? reconnectTransport;
  final bool Function() isCurrentOwner;
  final Future<Map<String, AudioRecordingUploadState>> Function(List<RingRecording>) lookup;
  final Future<void> Function(String)? retryJob;
  RingSyncController(
      {required this.openTransport,
      required this.openStore,
      required this.isCurrentOwner,
      required this.lookup,
      this.retryJob,
      this.reconnectTransport});
  List<RingRecording> recordings = [];
  final stages = <String, RingStage>{};
  final errors = <String, Object>{};
  final durations = <String, Duration>{};
  final receipts = <String, RingReceipt>{};
  final jobs = <String, AudioProcessingJob>{};
  final _removing = <String>{};
  final _attempts = <String, int>{};
  final _retryAt = <String, DateTime>{};
  RingImportStore? _store;
  Future<void>? _work;
  Future<void>? _poll;
  bool _refreshQueued = false, _disposed = false;
  bool loading = false, recording = false, recordBusy = false, connected = false;
  String? activeId;
  int bytes = 0, totalBytes = 0;
  int? deviceFileCount;
  DateTime? lastRefresh, recordingStartedAt;
  Duration recordingDuration = Duration.zero;
  Object? readError, recordingError;
  RingTransport? _captureTransport, _syncTransport;
  RingTransport? _managementTransport;
  int _managementEpoch = 0;
  bool maintenanceBusy = false;
  final localAudio = <String>{};
  StreamSubscription<Map<String, dynamic>>? _captureEvents;
  bool get busy => _work != null || recordBusy || recording || maintenanceBusy;
  bool get _valid => !_disposed && isCurrentOwner();
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  bool isRemoving(String id) => _removing.contains(id);
  bool canRemove(String id) => _valid && id != activeId && !isRemoving(id);
  bool reserveRemoval(String id) {
    if (!canRemove(id)) return false;
    _removing.add(id);
    _changed();
    return true;
  }

  void cancelRemoval(String id) {
    _removing.remove(id);
    _changed();
  }

  Future<bool> commitRemoval(String id) async {
    if (!_valid || !_removing.contains(id) || activeId == id) return false;
    try {
      await (await _getStore()).remove(id);
      if (!_valid) return false;
      recordings.removeWhere((r) => r.id == id);
      stages.remove(id);
      receipts.remove(id);
      jobs.remove(id);
      errors.remove(id);
      durations.remove(id);
      localAudio.remove(id);
      _removing.remove(id);
      _changed();
      return true;
    } catch (_) {
      _removing.remove(id);
      _changed();
      return false;
    }
  }

  Future<RingImportStore> _getStore() async {
    if (!_valid) throw StateError('Ring account changed');
    final store = _store ??= await openStore();
    store.checkOwner();
    return store;
  }

  Future<void> sync() {
    if (!_valid || recording || recordBusy || maintenanceBusy) return Future.value();
    if (_work != null) {
      _refreshQueued = true;
      return _work!;
    }
    final done = Completer<void>();
    _work = done.future;
    unawaited(() async {
      try {
        do {
          _refreshQueued = false;
          await _run();
        } while (_refreshQueued && _valid && !recording);
      } catch (error) {
        if (_valid) readError = error;
      } finally {
        loading = false;
        activeId = null;
        _syncTransport = null;
        _work = null;
        _changed();
        done.complete();
      }
    }());
    return done.future;
  }

  bool _retryable(Object error) =>
      error is! FormatException &&
      !(error is AudioUploadFailure &&
          !{AudioUploadIssue.network, AudioUploadIssue.timeout, AudioUploadIssue.server, AudioUploadIssue.inFlight}
              .contains(error.issue));
  Future<void> _run() async {
    await _poll;
    final store = await _getStore();
    loading = true;
    readError = null;
    _changed();
    final local = await store.cached();
    if (!_valid) return;
    final transport = await openTransport();
    if (!_valid) return;
    _syncTransport = transport;
    connected = transport != null;
    var remote = <RingRecording>[];
    if (transport != null) {
      try {
        remote = await transport.files();
        if (!_valid) return;
        deviceFileCount = remote.length;
      } catch (error) {
        readError = error;
      }
    }
    final all = {for (final file in remote) file.id: file, for (final file in local) file.id: file};
    recordings = [];
    for (final file in all.values) {
      if (!await store.removed(file.id)) recordings.add(file);
    }
    if (!_valid) return;
    recordings.sort((a, b) => (b.startedAt ?? DateTime.utc(1970)).compareTo(a.startedAt ?? DateTime.utc(1970)));
    for (final file in recordings) {
      final meta = await store.metadata(file.id);
      if (await store.audio(file.id).exists()) localAudio.add(file.id);
      if (meta?['durationMs'] is int) durations[file.id] = Duration(milliseconds: meta!['durationMs'] as int);
      if (meta?['conversationId'] is String) {
        receipts[file.id] = RingReceipt(meta!['conversationId'] as String,
            processing: meta['processing'] == true, jobId: meta['jobId'] as String?);
      }
      stages.putIfAbsent(file.id, () => file.supported ? RingStage.waiting : RingStage.unsupported);
    }
    lastRefresh = DateTime.now();
    loading = false;
    _changed();
    // Confirm cloud receipts before any transfer/upload, including ambiguous
    // HTTP outcomes and app restarts. Fail closed if lookup is unavailable.
    final dated = recordings.where((r) => r.startedAt != null && !isRemoving(r.id)).toList();
    for (var i = 0; i < dated.length; i += 100) {
      final batch = dated.sublist(i, (i + 100).clamp(0, dated.length));
      final states = await lookup(batch);
      if (!_valid) return;
      for (final file in batch) {
        final state = states[file.id];
        if (state == null) throw const FormatException('Incomplete ring upload lookup');
        if (isRemoving(file.id)) continue;
        if (state.conversationId != null) {
          final receipt = RingReceipt(state.conversationId!, processing: state.processing, jobId: state.job?.id);
          await store.receipt(file, receipt);
          if (!_valid) return;
          receipts[file.id] = receipt;
          if (state.duration != null) durations[file.id] = state.duration!;
          if (state.job != null) {
            jobs[file.id] = state.job!;
          } else {
            jobs.remove(file.id);
          }
          stages[file.id] = state.job?.needsAttention == true
              ? RingStage.failed
              : state.processing
                  ? RingStage.processing
                  : RingStage.completed;
          errors.remove(file.id);
        } else if (!state.canUpload) {
          stages[file.id] = RingStage.failed;
          errors[file.id] = const AudioUploadFailure(AudioUploadIssue.inFlight);
          _retryAt[file.id] = DateTime.now().add(const Duration(seconds: 30));
        }
      }
    }
    _changed();
    StreamSubscription<Map<String, dynamic>>? events;
    if (transport != null) {
      events = transport.events.listen((event) {
        final file = recordings.where((r) => r.id == activeId).firstOrNull;
        if (!_valid || file == null || event['event'] != 'progress' || event['name'] != file.name) return;
        bytes = (event['bytes'] as num?)?.toInt() ?? 0;
        totalBytes = file.size;
        _changed();
      });
    }
    try {
      for (final file in List<RingRecording>.of(recordings)) {
        if (!_valid) return;
        if (isRemoving(file.id) || receipts.containsKey(file.id)) continue;
        if (!file.supported) {
          stages[file.id] = RingStage.unsupported;
          continue;
        }
        if (stages[file.id] == RingStage.failed &&
            (errors[file.id] != null && (!_retryable(errors[file.id]!) || (_attempts[file.id] ?? 0) >= 3) ||
                (_retryAt[file.id]?.isAfter(DateTime.now()) ?? false))) {
          continue;
        }
        activeId = file.id;
        bytes = 0;
        totalBytes = file.size;
        try {
          if (!await store.verifiedAudio(file.id)) {
            if (transport == null) {
              stages[file.id] = RingStage.waiting;
              continue;
            }
            stages[file.id] = RingStage.downloading;
            _changed();
            final audio = await transport.download(file);
            try {
              if (!_valid || isRemoving(file.id)) return;
              await store.cache(file, audio.file);
              localAudio.add(file.id);
              durations[file.id] = await RingImportStore.validateWave(store.audio(file.id));
            } finally {
              await transport.releaseAudio(audio.file);
            }
          }
          if (!_valid || isRemoving(file.id)) return;
          if (file.startedAt == null) {
            stages[file.id] = RingStage.needsTime;
            _changed();
            continue;
          }
          stages[file.id] = RingStage.uploading;
          bytes = 0;
          totalBytes = 0;
          _changed();
          final receipt = await store.import(file, onProgress: (sent, total) {
            if (_valid && activeId == file.id) {
              bytes = sent;
              totalBytes = total;
              _changed();
            }
          });
          if (!_valid) return;
          receipts[file.id] = receipt;
          stages[file.id] = receipt.processing ? RingStage.processing : RingStage.completed;
          errors.remove(file.id);
          _attempts.remove(file.id);
          _retryAt.remove(file.id);
        } catch (error) {
          if (!_valid) return;
          stages[file.id] = RingStage.failed;
          errors[file.id] = error;
          _attempts[file.id] = (_attempts[file.id] ?? 0) + 1;
          _retryAt[file.id] = DateTime.now().add(Duration(seconds: 30 * _attempts[file.id]!));
        } finally {
          activeId = null;
          _changed();
        }
      }
    } finally {
      await events?.cancel();
    }
    await refreshProcessing(fromSync: true);
  }

  Future<String?> localAudioPath(String id) async {
    if (!_valid || isRemoving(id)) return null;
    final file = (await _getStore()).audio(id);
    return await file.exists() ? file.path : null;
  }

  Future<void> confirmTime(RingRecording file, DateTime time) async {
    if (busy || !_valid || isRemoving(file.id)) return;
    final corrected = file.withTime(time);
    await (await _getStore()).updateTime(corrected);
    if (!_valid) return;
    recordings = recordings.map((r) => r.id == file.id ? corrected : r).toList();
    stages[file.id] = RingStage.downloaded;
    errors.remove(file.id);
    _changed();
    await sync();
  }

  Future<void> retry(String id) async {
    if (!_valid || busy || isRemoving(id)) return;
    final job = jobs[id];
    if (job != null && job.needsAttention) {
      if (!job.canRetry || retryJob == null) return;
      await retryJob!(job.id);
      if (_valid) await refreshProcessing();
      return;
    }
    if (receipts.containsKey(id)) {
      await refreshProcessing();
      return;
    }
    _attempts.remove(id);
    _retryAt.remove(id);
    errors.remove(id);
    stages[id] = RingStage.waiting;
    await sync();
  }

  Future<void> refreshProcessing({bool fromSync = false}) {
    if (_work != null && !fromSync) return Future.value();
    if (!_valid || _poll != null) return _poll ?? Future.value();
    final done = Completer<void>();
    _poll = done.future;
    unawaited(() async {
      try {
        final pending = recordings
            .where((r) => receipts[r.id]?.processing == true && r.startedAt != null && !isRemoving(r.id))
            .toList();
        for (var i = 0; i < pending.length; i += 100) {
          final batch = pending.sublist(i, (i + 100).clamp(0, pending.length));
          final values = await lookup(batch);
          if (!_valid) return;
          for (final file in batch) {
            final value = values[file.id];
            if (value?.conversationId == null || isRemoving(file.id)) continue;
            final receipt = RingReceipt(value!.conversationId!, processing: value.processing, jobId: value.job?.id);
            await (await _getStore()).receipt(file, receipt);
            if (!_valid) return;
            receipts[file.id] = receipt;
            if (value.job != null) {
              jobs[file.id] = value.job!;
            } else {
              jobs.remove(file.id);
            }
            stages[file.id] = value.job?.needsAttention == true
                ? RingStage.failed
                : value.processing
                    ? RingStage.processing
                    : RingStage.completed;
          }
        }
      } catch (_) {/* Keep receipts; a poll error never restarts upload. */} finally {
        _poll = null;
        _changed();
        done.complete();
      }
    }());
    return done.future;
  }

  Future<void> reconnect() async {
    if (!_valid || busy || reconnectTransport == null) return;
    recordBusy = true;
    _changed();
    try {
      await reconnectTransport!();
    } catch (error) {
      if (_valid) readError = error;
    } finally {
      recordBusy = false;
      _changed();
    }
    if (_valid) await sync();
  }

  /// Owns the peripheral while inspecting or clearing its storage. Automatic
  /// imports and recording controls share this lock with the management page.
  Future<RingDeviceSnapshot> inspectDevice({bool clear = false, bool confirmed = false}) async {
    if (clear && !confirmed) throw ArgumentError('Ring deletion was not confirmed');
    if (!_valid || busy) throw StateError('Ring is busy or account changed');
    maintenanceBusy = true;
    final epoch = ++_managementEpoch;
    StreamSubscription<Map<String, dynamic>>? events;
    void check() {
      if (!_valid || epoch != _managementEpoch) throw StateError('Ring connection replaced');
    }

    _changed();
    try {
      final peer = await openTransport();
      check();
      connected = peer != null;
      if (peer == null) throw StateError('Connect ring first');
      _managementTransport = peer;
      events = peer.events.listen((event) {
        if (event['event'] == 'connection' && event['connected'] == false) _managementEpoch++;
      });
      Future<RingDeviceSnapshot> read() async {
        check();
        if (await openTransport() != peer) throw StateError('Ring connection replaced');
        check();
        final directory = await peer.files();
        check();
        final storage = await peer.storageInfo();
        check();
        return RingDeviceSnapshot(storage, directory);
      }

      final before = await read();
      if (!clear || before.files.isEmpty) {
        deviceFileCount = before.files.length;
        return before;
      }
      // Formatting clears the entire filesystem. Never erase unknown content.
      if (!before.onlyRecordings) throw const FormatException('Non-audio files on ring');
      check();
      await peer.clearDeviceFiles(confirmed: true);
      check();
      final after = await read();
      if (after.files.isNotEmpty || after.total != before.total || after.free <= before.free) {
        throw const FormatException('Ring erase could not be verified');
      }
      deviceFileCount = 0;
      recordings.removeWhere((file) => !localAudio.contains(file.id) && !receipts.containsKey(file.id));
      lastRefresh = DateTime.now();
      return after;
    } finally {
      await events?.cancel();
      _managementTransport = null;
      maintenanceBusy = false;
      _changed();
    }
  }

  /// Local detail-page read shares the peripheral lock with recording/import.
  Future<RingHealthSnapshot> inspectHealth() async {
    if (!_valid || busy) throw StateError('Ring is busy or account changed');
    maintenanceBusy = true;
    final epoch = ++_managementEpoch;
    StreamSubscription<Map<String, dynamic>>? events;
    void check() {
      if (!_valid || epoch != _managementEpoch) throw StateError('Ring connection replaced');
    }

    _changed();
    try {
      final peer = await openTransport();
      check();
      connected = peer != null;
      if (peer == null) throw StateError('Connect ring first');
      _managementTransport = peer;
      events = peer.events.listen((event) {
        if (event['event'] == 'connection' && event['connected'] == false) _managementEpoch++;
      });
      final snapshot = await peer.healthSnapshot();
      check();
      if (await openTransport() != peer) throw StateError('Ring connection replaced');
      check();
      return snapshot;
    } finally {
      await events?.cancel();
      _managementTransport = null;
      maintenanceBusy = false;
      _changed();
    }
  }

  /// Explicit calibration only until 603/Z62 readback is physically verified.
  /// Never changes existing file names or their user-confirmed timestamps.
  Future<DateTime> synchronizeClock(Duration timezoneOffset) async {
    if (!_valid || busy) throw StateError('Ring is busy or account changed');
    maintenanceBusy = true;
    final epoch = ++_managementEpoch;
    StreamSubscription<Map<String, dynamic>>? events;
    void check() {
      if (!_valid || epoch != _managementEpoch) throw StateError('Ring connection replaced');
    }

    _changed();
    try {
      final peer = await openTransport();
      check();
      if (peer == null) throw StateError('Connect ring first');
      _managementTransport = peer;
      events = peer.events.listen((event) {
        if (event['event'] == 'connection' && event['connected'] == false) _managementEpoch++;
      });
      final time = await peer.synchronizeClock(timezoneOffset);
      check();
      if (await openTransport() != peer) throw StateError('Ring connection replaced');
      check();
      return time;
    } finally {
      await events?.cancel();
      _managementTransport = null;
      maintenanceBusy = false;
      _changed();
    }
  }

  Future<void> startRecording() async {
    if (busy || !_valid) return;
    recordBusy = true;
    recordingError = null;
    _changed();
    try {
      final transport = await openTransport();
      if (!_valid || transport == null) throw StateError('Connect ring first');
      _captureTransport = transport;
      recordingStartedAt = DateTime.now().toUtc();
      recordingDuration = Duration.zero;
      await _captureEvents?.cancel();
      _captureEvents = transport.events.listen((event) {
        if (!_valid) return;
        if (event['event'] == 'recording') {
          recordingDuration = Duration(milliseconds: (event['durationMs'] as num).toInt());
          _changed();
        }
        if (event['event'] == 'captureError' || event['event'] == 'connection' && event['connected'] == false) {
          // i18n-ignore: Internal capture diagnostic, localized by the page.
          recordingError = StateError('Ring recording interrupted');
          recording = false;
          connected = false;
          _changed();
        }
      });
      await transport.startRecording();
      if (recordingError != null) throw recordingError!;
      if (!_valid) {
        await transport.disconnect();
        return;
      }
      connected = true;
      recording = true;
    } catch (error) {
      if (_valid) recordingError = error;
      await _captureEvents?.cancel();
      _captureEvents = null;
      _captureTransport = null;
    } finally {
      recordBusy = false;
      _changed();
    }
  }

  Future<void> stopRecording() async {
    if (!recording || recordBusy || !_valid) return;
    recordBusy = true;
    _changed();
    final transport = _captureTransport!;
    try {
      final audio = await transport.stopRecording();
      try {
        if (!_valid) return;
        final file = RingRecording(
            name: 'live-${recordingStartedAt!.microsecondsSinceEpoch}.wav',
            size: await audio.file.length(),
            type: 'LOCAL',
            startedAt: recordingStartedAt);
        await (await _getStore()).cache(file, audio.file);
      } finally {
        await transport.releaseAudio(audio.file);
      }
    } catch (error) {
      if (_valid) recordingError = error;
    } finally {
      recording = false;
      recordBusy = false;
      _captureTransport = null;
      await _captureEvents?.cancel();
      _captureEvents = null;
    }
    // Start importing before notifying idle listeners. A management page still
    // mounted behind this route may otherwise acquire the storage lock first.
    if (_valid) {
      await sync();
    } else {
      _changed();
    }
  }

  Future<void> cancelForAccount() async {
    _managementEpoch++;
    final transport = _captureTransport ?? _syncTransport ?? _managementTransport;
    _captureTransport = null;
    _syncTransport = null;
    recording = false;
    recordBusy = false;
    await _captureEvents?.cancel();
    _captureEvents = null;
    await transport?.disconnect();
    _changed();
  }

  Future<void> resumeAfterSubscriptionUpgrade() async {
    for (final id in errors.keys.toList()) {
      if (errors[id] is AudioUploadFailure && (errors[id] as AudioUploadFailure).issue == AudioUploadIssue.quota) {
        errors.remove(id);
        _attempts.remove(id);
        _retryAt.remove(id);
        stages[id] = RingStage.waiting;
      }
    }
    await sync();
  }

  @override
  void dispose() {
    _disposed = true;
    _managementEpoch++;
    unawaited(_captureEvents?.cancel());
    unawaited(_captureTransport?.disconnect());
    super.dispose();
  }
}
