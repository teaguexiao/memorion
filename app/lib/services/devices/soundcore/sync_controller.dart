import '../offline_recordings/models.dart';
import 'dart:async';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'download_progress.dart';
import 'import_store.dart';
import 'protocol.dart';
import 'session.dart';
import 'wifi_connection.dart';
import 'wifi_activity.dart';
import 'wifi_transport.dart';

enum SoundcoreWifiState {
  preparing,
  reconnecting,
  openingHotspot,
  waitingForHotspot,
  joining,
  verifyingNetwork,
  connecting,
  downloading,
  restoring
}

enum SoundcoreSyncWaitReason {
  signIn,
  checkingCloud,
  cloudCheckRequired,
  wifi,
  recording,
  connection,
  retryDelay,
  queued
}

/// One serial queue per account and recorder, owned by the App service.
/// Screens only subscribe: removing a screen never cancels a transfer.
class SoundcoreSyncController extends ChangeNotifier {
  static const _monthlyQuotaCode = 'monthly_cloud_transcription_allowance_exceeded';
  static const _monthlyUploadTooLargeCode = 'monthly_cloud_transcription_upload_exceeds_remaining';
  final Future<SoundcoreImportStore> Function() openStore;
  final Future<SoundcoreSession?> Function() openSession;
  final Future<SoundcoreSession?> Function()? reconnectSession;
  final bool Function() isCurrentOwner;
  final DateTime Function() now;
  final String? deviceId;
  final Future<AudioProcessingJob> Function(String id)? fetchProcessingJob;
  final Future<void> Function(String id)? retryProcessingJob;
  final Future<Map<int, AudioRecordingUploadState>> Function(List<SoundcoreRecording>)? lookupRecordings;
  final _cloudChecked = <int, DateTime>{};
  final _checkingCloud = <int>{};
  Object? cloudLookupError;
  final processingJobs = <int, AudioProcessingJob>{};
  bool _refreshingJobs = false;
  final retryingProcessing = <int>{};
  void Function()? _releaseWifi;
  final Duration stopDelay;
  final Duration retryDelay;
  final Future<SoundcoreWifiConnection> Function(SoundcoreSession session, void Function(SoundcoreWifiPhase) onPhase)?
      openWifi;

  SoundcoreSyncController({
    this.deviceId,
    this.fetchProcessingJob,
    this.retryProcessingJob,
    this.lookupRecordings,
    required this.openStore,
    required this.openSession,
    this.reconnectSession,
    required this.isCurrentOwner,
    DateTime Function()? now,
    this.stopDelay = const Duration(seconds: 2),
    this.retryDelay = const Duration(seconds: 30),
    this.openWifi,
  }) : now = now ?? DateTime.now;

  List<SoundcoreRecording> recordings = [];
  final stages = <int, SoundcoreImportStage>{};
  final details = <int, SoundcoreRecordingDetails>{};
  final failures = <int, Object>{};
  final _retryAt = <int, DateTime>{};
  final _attempts = <int, int>{};
  final _manualRetries = <int>{};
  final _storedQuotaBypass = <int>{};
  bool _ignoreStoredQuota = false;
  final _permanent = <int>{};
  final _removed = <int>{};
  final _removing = <int>{};
  bool _excluded(int id) => _removed.contains(id) || _removing.contains(id);
  bool isRemoving(int id) => _removing.contains(id);

  bool canRemove(int id) =>
      _allowed &&
      !loading &&
      !_excluded(id) &&
      activeId != id &&
      !retryingProcessing.contains(id) &&
      !isCheckingCloud(id) &&
      recordings.any((recording) => recording.id == id);

  final _committingRemovals = <int>{};

  bool reserveRemoval(int id) {
    if (!canRemove(id)) return false;
    // Existing transfer queues must skip this ID throughout the Undo window.
    _removing.add(id);
    _notify();
    return true;
  }

  void cancelRemoval(int id) {
    if (_committingRemovals.contains(id)) return;
    if (_removing.remove(id)) _notify();
  }

  Future<void> removeRecording(int id) async {
    if (!reserveRemoval(id)) throw StateError('Soundcore recording is busy');
    await commitReservedRemoval(id);
  }

  Future<void> commitReservedRemoval(int id) async {
    if (!_allowed || !_removing.contains(id) || !_committingRemovals.add(id)) {
      throw StateError('Soundcore removal is no longer reserved');
    }
    try {
      final store = _store ??= await openStore();
      if (!_allowed) throw StateError('Soundcore account changed');
      await store.removeRecording(id);
      if (!_allowed) return;
      _removed.add(id);
      recordings = recordings.where((recording) => recording.id != id).toList();
      stages.remove(id);
      details.remove(id);
      failures.remove(id);
      processingJobs.remove(id);
      _terminalRefreshRequested.remove(id);
      _cloudChecked.remove(id);
      _retryAt.remove(id);
      _attempts.remove(id);
      _manualRetries.remove(id);
      _storedQuotaBypass.remove(id);
      _permanent.remove(id);
    } finally {
      _committingRemovals.remove(id);
      _removing.remove(id);
      _notify();
    }
  }

  SoundcoreImportStore? _store;
  SoundcoreSession? session;
  bool _controlConnected = false;
  StreamSubscription<int>? _recordSubscription;
  Timer? _stopTimer;
  Future<void>? _running;
  bool _requested = false;
  bool _disposed = false;
  bool loading = false;
  int? activeId;
  int bytes = 0;
  SoundcoreDownloadEstimator? _downloadEstimator;
  Timer? _progressTimer;
  SoundcoreDownloadEstimate? get downloadEstimate => _downloadEstimator?.estimate(now());
  SoundcoreDownloadEstimator? _uploadEstimator;
  int uploadBytes = 0;
  int uploadTotal = 0;
  bool get awaitingUploadConfirmation => uploadTotal > 0 && uploadBytes >= uploadTotal;
  SoundcoreDownloadEstimate? get uploadEstimate => _uploadEstimator?.estimate(now());
  Object? error;
  Object? cacheError;
  DateTime? lastRefresh;
  int? deviceFileCount;
  int? recordStatus;
  SoundcoreWifiState? wifiState;
  Object? wifiError;
  SoundcoreTransferStep? wifiFailedStep;
  int wifiFailedBytes = 0;
  String? _wifiFailureDiagnostics;
  bool wifiNothingToDownload = false;
  bool wifiAwaitingCloudCheck = false;
  final List<String> _wifiDiagnostics = [];
  final List<String> _uploadDiagnostics = [];
  String get diagnostics => [
        // i18n-ignore: Sanitized queue diagnostic, not product copy.
        'Sync busy=$busy allowed=$_allowed loading=$loading '
            'recordStatus=$recordStatus files=${recordings.length} '
            'manual=${_manualRetries.length} rejected=${_permanent.length} '
            'wifi=${wifiState?.name} cleanup=$_wifiCleanupPending', // i18n-ignore: Sanitized queue diagnostic.
        for (var row = 0; row < recordings.length && row < 100; row++)
          if (stages[recordings[row].id] != SoundcoreImportStage.uploaded &&
              stages[recordings[row].id] != SoundcoreImportStage.processed)
            _pendingDiagnostic(recordings[row], row + 1),
        if (session != null) session!.diagnostics,
        ..._wifiDiagnostics,
        ..._uploadDiagnostics,
        for (final entry in failures.entries)
          if (entry.value is SoundcoreImportException)
            'Upload failure: ${(entry.value as SoundcoreImportException).diagnostic}',
        if (_wifiFailureDiagnostics != null) 'Last Wi-Fi failure:\n$_wifiFailureDiagnostics',
      ].join('\n');
  bool _wifiRequested = false;
  bool _reconnectForWifi = false;
  bool _resumeBleAfterWifi = false;
  bool reconnectingBluetooth = false;
  SoundcoreWifiConnection? _activeWifi;
  bool _wifiCleanupPending = false;
  Future<void> Function()? _pendingWifiCleanup;
  bool get wifiAvailable => openWifi != null;
  bool get busy => _running != null;
  bool get _allowed => !_disposed && isCurrentOwner();

  bool isSyncRequested(int id) => _manualRetries.contains(id);
  bool isCheckingCloud(int id) => _checkingCloud.contains(id);

  bool needsCloudCheck(int id) =>
      lookupRecordings != null &&
      stages[id] != SoundcoreImportStage.uploaded &&
      stages[id] != SoundcoreImportStage.processed &&
      (_cloudChecked[id] == null || now().difference(_cloudChecked[id]!) > const Duration(minutes: 5));

  String _pendingDiagnostic(SoundcoreRecording recording, int row) {
    final id = recording.id;
    final failure = failures[id];
    // i18n-ignore: Row numbers and durations link state to the visible newest-first list without recording identifiers.
    return 'Pending row=$row stage=${stages[id]?.name ?? "queued"} '
        'active=${activeId == id} wait=${waitReason(id).name} rejected=${_permanent.contains(id)} '
        'estimatedMs=${recording.estimatedDuration?.inMilliseconds ?? "unknown"} '
        'cachedMs=${details[id]?.duration.inMilliseconds ?? "unknown"}'
        '${failure == null ? "" : " failure=${failure is SoundcoreImportException ? failure.diagnostic : failure.runtimeType}"}';
  }

  SoundcoreSyncWaitReason waitReason(int id) {
    if (!_allowed) return SoundcoreSyncWaitReason.signIn;
    if (isCheckingCloud(id)) return SoundcoreSyncWaitReason.checkingCloud;
    if (wifiState != null || _wifiCleanupPending) return SoundcoreSyncWaitReason.wifi;
    if (_retryAt[id]?.isAfter(now()) ?? false) return SoundcoreSyncWaitReason.retryDelay;
    if (needsCloudCheck(id)) return SoundcoreSyncWaitReason.cloudCheckRequired;
    if (details[id]?.sizeBytes == null) {
      if (!_controlConnected || session == null || session!.isClosed) return SoundcoreSyncWaitReason.connection;
      if (recordStatus == 1 || recordStatus == 2) return SoundcoreSyncWaitReason.recording;
    }
    return SoundcoreSyncWaitReason.queued;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Coalesce connect, timer, refresh and recording-stop events. A queued
  /// refresh runs after the current transfer, never alongside it.
  Future<void> sync() {
    if (!_allowed) return Future.value();
    _requested = true;
    return _running ??= Future<void>.microtask(() async {
      try {
        while (_requested && _allowed) {
          _requested = false;
          await _cycle();
        }
      } finally {
        _running = null;
        if (!_wifiCleanupPending) _releaseWifiActivity();
        if (_wifiRequested) {
          _wifiRequested = false;
          wifiState = null;
          wifiError = error ??
              cacheError ??
              StateError(
                  'Soundcore Wi-Fi setup did not start'); // i18n-ignore: Internal diagnostic; localized by the recording page.
          _traceWifi('setup did not start type=${wifiError.runtimeType}'); // i18n-ignore: Sanitized diagnostic.
        }
        _notify();
      }
    });
  }

  int _processingCursor = 0;
  int _processingEpoch = 0;
  final _terminalRefreshRequested = <int>{};
  bool get _cloudPollingPaused => _wifiRequested || wifiState != null || _wifiCleanupPending;

  Future<void> refreshProcessing({int? recordingId, bool includeTerminal = false}) async {
    if (!_allowed || fetchProcessingJob == null) return;
    if (includeTerminal) {
      _terminalRefreshRequested.addAll(processingJobs.entries
          .where((entry) => {'failed', 'cancelled'}.contains(entry.value.status))
          .map((entry) => entry.key));
    }
    // A BLE download or HTTP upload does not block another recording's status.
    // Recorder Wi-Fi still owns the network until its cleanup is complete.
    if (_cloudPollingPaused || _refreshingJobs) return;
    _refreshingJobs = true;
    final epoch = _processingEpoch;
    try {
      final store = _store ??= await openStore();
      final candidates = recordings.where((r) => recordingId == null || r.id == recordingId).toList();
      if (candidates.isEmpty) return;
      final offset = recordingId == null ? _processingCursor % candidates.length : 0;
      var requests = 0;
      // Bound each polling tick and rotate so older recordings are not starved.
      for (var checked = 0; checked < candidates.length && requests < 8; checked++) {
        final index = (offset + checked) % candidates.length;
        final recording = candidates[index];
        if (recordingId == null) _processingCursor = (index + 1) % candidates.length;
        if (!_allowed || _cloudPollingPaused) return;
        if (_excluded(recording.id) || stages[recording.id] == SoundcoreImportStage.processed) continue;
        if (recordingId == null &&
            processingJobs[recording.id]?.active == false &&
            !_terminalRefreshRequested.contains(recording.id)) {
          continue;
        }
        final id = await store.conversationId(recording.id);
        if (id == null || _excluded(recording.id)) continue;
        if (!_allowed || _cloudPollingPaused || epoch != _processingEpoch) return;
        requests++;
        try {
          final job = await fetchProcessingJob!(id);
          if (!_allowed || epoch != _processingEpoch) return;
          if (_excluded(recording.id)) continue;
          processingJobs[recording.id] = job;
          _terminalRefreshRequested.remove(recording.id);
          if (job.status == 'completed') {
            await store.markProcessed(recording.id);
            if (!_allowed) return;
            if (_excluded(recording.id)) continue;
            stages[recording.id] = SoundcoreImportStage.processed;
          }
        } catch (_) {
          // Offline or pre-queue server: retain the accepted upload receipt.
        }
      }
      if (_allowed) _notify();
    } catch (error) {
      // Timer callers are unawaited: expose local cache failures in the UI.
      if (_allowed) {
        cacheError = error;
        _notify();
      }
    } finally {
      _refreshingJobs = false;
    }
  }

  Future<void> retryProcessing(int recordingId) async {
    final job = processingJobs[recordingId];
    if (!_allowed ||
        _excluded(recordingId) ||
        job == null ||
        !job.canRetry ||
        retryProcessingJob == null ||
        !retryingProcessing.add(recordingId)) {
      return;
    }
    _notify();
    try {
      await retryProcessingJob!(job.id);
      if (!_allowed) return;
      // A pre-retry poll must not restore an obsolete failed response.
      _processingEpoch++;
      processingJobs.remove(recordingId);
      try {
        if (fetchProcessingJob != null) {
          final updated = await fetchProcessingJob!(job.id);
          if (!_allowed) return;
          processingJobs[recordingId] = updated;
          if (updated.status == 'completed') {
            final store = _store ??= await openStore();
            await store.markProcessed(recordingId);
            if (_allowed) stages[recordingId] = SoundcoreImportStage.processed;
          }
        }
      } catch (_) {
        // Retry was accepted; normal polling will recover an unavailable read.
      }
    } finally {
      retryingProcessing.remove(recordingId);
      if (_allowed) _notify();
    }
  }

  Future<void> retry(int id) async {
    if (!_allowed ||
        _excluded(id) ||
        activeId == id ||
        stages[id] == SoundcoreImportStage.uploaded ||
        stages[id] == SoundcoreImportStage.processed) return;
    if (needsCloudCheck(id)) {
      await sync();
      return;
    }
    final failure = failures[id];
    final bypassQuota = failure is SoundcoreImportException &&
        {_monthlyQuotaCode, _monthlyUploadTooLargeCode}.contains(failure.failure?.errorCode);
    if (bypassQuota) _storedQuotaBypass.add(id);
    _manualRetries.add(id);
    _retryAt.remove(id);
    _permanent.remove(id);
    failures.remove(id);
    _notify();
    await sync();
  }

  Future<bool> resumeAfterSubscriptionUpgrade() async {
    if (!_allowed) return false;
    _ignoreStoredQuota = true;
    _retryAt.removeWhere((id, _) {
      final failure = failures[id];
      return failure is SoundcoreImportException &&
          {_monthlyQuotaCode, _monthlyUploadTooLargeCode}.contains(failure.failure?.errorCode);
    });
    try {
      // When another cycle is active, sync() returns that same Future and sets
      // _requested so a second cycle runs before the Future completes. Keep
      // the bypass enabled across both cycles.
      await sync();
      if (!_allowed) return false;
      return !failures.values.whereType<SoundcoreImportException>().any(
            (failure) => {_monthlyQuotaCode, _monthlyUploadTooLargeCode}.contains(failure.failure?.errorCode),
          );
    } finally {
      _ignoreStoredQuota = false;
    }
  }

  Future<void> syncOverWifi() {
    if (!_allowed || !wifiAvailable || wifiState != null) return _running ?? Future.value();
    if (deviceId != null) _releaseWifi = SoundcoreWifiActivity.acquire(deviceId!);
    _wifiRequested = true;
    wifiError = null;
    wifiFailedStep = null;
    wifiFailedBytes = 0;
    _wifiFailureDiagnostics = null;
    wifiNothingToDownload = false;
    wifiAwaitingCloudCheck = false;
    wifiState = SoundcoreWifiState.preparing;
    _traceWifi('requested');
    if (session?.interruptBluetoothDownload() ?? false) {
      _endDownloadProgress();
      _reconnectForWifi = true;
      _traceWifi('interrupted BLE; partial audio discarded');
    }
    _notify();
    return sync();
  }

  void _releaseWifiActivity() {
    _releaseWifi?.call();
    _releaseWifi = null;
  }

  void _startDownloadProgress(SoundcoreRecording recording) {
    _endDownloadProgress();
    bytes = 0;
    _downloadEstimator = SoundcoreDownloadEstimator(duration: recording.estimatedDuration, startedAt: now());
    // Render progress at 4 Hz independently of the radio's packet rate. Keep
    // every byte/sample below; a busy BLE/Wi-Fi stream must not notify the
    // page hundreds of times a second. Queue ownership preserves navigation,
    // and periodic ticks still remove stale ETAs when packets stop arriving.
    _progressTimer = Timer.periodic(const Duration(milliseconds: 250), (_) => _notify());
    _notify();
  }

  void _downloadProgress(int value) {
    if (value == 0 && bytes > 0 && activeId != null) {
      final recording = recordings.where((file) => file.id == activeId).firstOrNull;
      if (recording != null) _startDownloadProgress(recording);
      _traceWifi(
          'connection interrupted; retrying current file from start'); // i18n-ignore: Sanitized technical diagnostic.
    }
    bytes = value;
    _downloadEstimator?.update(value, now());
  }

  void _endDownloadProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _downloadEstimator = null;
  }

  void _uploadProgress(int sent, int total) {
    if (!_allowed) return;
    _uploadEstimator ??= SoundcoreDownloadEstimator.bytes(expectedBytes: total, startedAt: now());
    uploadBytes = sent;
    uploadTotal = total;
    _uploadEstimator!.update(sent, now());
  }

  void _traceUpload(String value) {
    _uploadDiagnostics.add('${now().toIso8601String()} Upload $value');
    if (_uploadDiagnostics.length > 20) _uploadDiagnostics.removeAt(0);
  }

  void _traceWifi(String value) {
    _wifiDiagnostics.add('${now().toIso8601String()} Wi-Fi $value');
    if (_wifiDiagnostics.length > 30) _wifiDiagnostics.removeAt(0);
  }

  void _wifiPhase(SoundcoreWifiPhase phase) {
    if (!_allowed) throw StateError('Soundcore sync account changed');
    wifiState = switch (phase) {
      SoundcoreWifiPhase.openingHotspot => SoundcoreWifiState.openingHotspot,
      SoundcoreWifiPhase.waitingForHotspot => SoundcoreWifiState.waitingForHotspot,
      SoundcoreWifiPhase.joining => SoundcoreWifiState.joining,
      SoundcoreWifiPhase.verifyingNetwork => SoundcoreWifiState.verifyingNetwork,
      SoundcoreWifiPhase.connecting => SoundcoreWifiState.connecting,
      SoundcoreWifiPhase.downloading => SoundcoreWifiState.downloading,
      SoundcoreWifiPhase.restoring => SoundcoreWifiState.restoring,
    };
    _traceWifi(phase.name);
    _notify();
  }

  void _attach(SoundcoreSession value) {
    if (identical(session, value)) return;
    _recordSubscription?.cancel();
    _stopTimer?.cancel();
    session = value;
    _recordSubscription = value.recordStatusEvents.listen((status) {
      recordStatus = status;
      _notify();
      _stopTimer?.cancel();
      // Allow the firmware to finalize its file before asking for the list.
      if (status == 0) _stopTimer = Timer(stopDelay, () => unawaited(sync()));
    });
  }

  Future<void> _cycle() async {
    if (_wifiCleanupPending && !await _restoreWifi()) return;
    loading = true;
    error = null;
    cacheError = null;
    deviceFileCount = null;
    _notify();
    final files = <int, SoundcoreRecording>{};
    SoundcoreImportStore? store;
    SoundcoreSession? connected;
    try {
      try {
        store = _store ??= await openStore();
        _removed.addAll(await store.removedRecordingIds());
        for (final file in await store.cachedRecordings()) {
          files[file.id] = file;
        }
      } catch (e) {
        cacheError = e;
        // Never rediscover/import removed files when their tombstones are unreadable.
        return;
      }
      if (!_allowed) return;
      try {
        if (_reconnectForWifi) {
          _reconnectForWifi = false;
          wifiState = SoundcoreWifiState.reconnecting;
          _traceWifi('reconnecting BLE control channel');
          _notify();
          connected = await (reconnectSession ?? openSession)();
        } else if (_resumeBleAfterWifi && !_wifiRequested) {
          _resumeBleAfterWifi = false;
          connected = await _recoverBluetoothAfterWifi();
        } else {
          connected = await openSession();
        }
        if (!_allowed) return;
        if (connected != null && !connected.isClosed) {
          _controlConnected = true;
          _attach(connected);
          // A transport operation from elsewhere must finish first.
          if (connected.busy) return;
          await connected.readInfo();
          recordStatus = connected.recordStatus;
          final deviceFiles = await connected.listRecordings();
          deviceFileCount = deviceFiles.length;
          for (final file in deviceFiles) {
            files[file.id] = file;
          }
        } else {
          connected = null;
          _controlConnected = false;
          recordStatus = null;
        }
      } catch (e) {
        error = e;
        connected = null;
        _controlConnected = false;
        recordStatus = null;
      }
      if (!_allowed) return;
      // A missing connection is not an empty device directory. Keep the last
      // known entries until a successful device read can replace them.
      if (deviceFileCount == null) {
        for (final file in recordings) {
          files.putIfAbsent(file.id, () => file);
        }
      }
      recordings = files.values.where((file) => !_removed.contains(file.id)).toList()
        ..sort((a, b) => b.id.compareTo(a.id));
      for (final file in recordings) {
        if (!_allowed) return;
        if (_excluded(file.id)) continue;
        final stage = await store.status(file.id);
        if (stage != null) stages[file.id] = stage;
        await _loadDetails(store, file.id);
        final previousFailure = await store.lastUploadFailure(file.id);
        if (previousFailure != null) {
          failures.putIfAbsent(file.id, () => previousFailure);
          final code = previousFailure.failure?.errorCode;
          final boundary = _nextUtcMonth(previousFailure.failedAt ?? now());
          if (!_ignoreStoredQuota && !_storedQuotaBypass.contains(file.id) && code == _monthlyQuotaCode) {
            if (boundary.isAfter(now())) {
              for (final recording in recordings) {
                if (!_storedQuotaBypass.contains(recording.id)) {
                  _retryAt[recording.id] = boundary;
                }
              }
            }
          } else if (!_ignoreStoredQuota &&
              !_storedQuotaBypass.contains(file.id) &&
              code == _monthlyUploadTooLargeCode) {
            if (boundary.isAfter(now())) _retryAt[file.id] = boundary;
          }
        }
        final rejection = await store.rejectionStatus(file.id);
        if (stage != SoundcoreImportStage.uploaded &&
            stage != SoundcoreImportStage.processed &&
            rejection != null &&
            !_manualRetries.contains(file.id)) {
          _permanent.add(file.id);
          failures.putIfAbsent(file.id, () => SoundcoreImportException(rejection));
        }
      }
      _notify();
      await _restoreCloudReceipts(store);
      if (!_allowed) return;
      // Directory durations are hints: skip clearly unsupported files before
      // joining Wi-Fi, but let an explicit retry measure the actual stream.
      // Do not persist a rejection inferred only from recorder metadata.
      for (final file in recordings) {
        final previous = failures[file.id];
        if (previous is SoundcoreImportException &&
            previous.failure?.errorCode == SoundcoreImportException.durationEstimateTooLong) {
          _permanent.remove(file.id);
          failures.remove(file.id);
        }
        if (stages[file.id] == SoundcoreImportStage.uploaded ||
            stages[file.id] == SoundcoreImportStage.processed ||
            details[file.id]?.sizeBytes != null ||
            _manualRetries.contains(file.id) ||
            _permanent.contains(file.id)) continue;
        if ((file.estimatedDuration?.inMilliseconds ?? 0) > maxOfflineRecordingDuration.inMilliseconds) {
          _permanent.add(file.id);
          failures[file.id] = const SoundcoreImportException(
              400,
              AudioUploadFailure(AudioUploadIssue.duration,
                  errorCode: SoundcoreImportException.durationEstimateTooLong));
        }
      }
      loading = false;
      lastRefresh = now();
      _notify();
      if (_wifiRequested) {
        _wifiRequested = false;
        await _downloadWifiBatch(store, connected);
        if (_wifiCleanupPending) return;
      }
      // Oldest first avoids starving a backlog when new recordings arrive.
      final remaining = recordings.reversed.toList();
      while (remaining.isNotEmpty) {
        if (!_allowed) return;
        // Switch before starting another BLE download or upload.
        if (_wifiRequested) break;
        // A manual request made during a transfer runs immediately after it.
        // Preserve the active transfer and the oldest-first automatic queue.
        final priority = remaining.indexWhere((file) => _manualRetries.contains(file.id));
        final recording = remaining.removeAt(priority < 0 ? 0 : priority);
        final id = recording.id;
        if (_excluded(id)) continue;
        if (stages[id] == SoundcoreImportStage.uploaded || stages[id] == SoundcoreImportStage.processed) continue;
        if (needsCloudCheck(id)) continue;
        if (_permanent.contains(id) || (_retryAt[id]?.isAfter(now()) ?? false)) continue;
        final cached = details[id]?.sizeBytes != null;
        if (!cached && _resumeBleAfterWifi) {
          _resumeBleAfterWifi = false;
          if (connected == null || connected.isClosed) connected = await _recoverBluetoothAfterWifi();
          if (!_allowed) return;
        }
        // Cached audio can upload after Bluetooth disconnects or while recording.
        if (!cached &&
            (connected == null || connected.isClosed || connected.busy || recordStatus == 1 || recordStatus == 2)) {
          continue;
        }
        // BLE recovery above awaits I/O; the user may have removed this row meanwhile.
        if (_excluded(id)) continue;
        activeId = id;
        _storedQuotaBypass.remove(id);
        bytes = 0;
        failures.remove(id);
        _notify();
        try {
          await store.importRecording(
            recording,
            retryRejected: _manualRetries.remove(id),
            onUploadProgress: _uploadProgress,
            download: () async {
              // Covers a click while the store is preparing this download.
              if (_wifiRequested) throw const SoundcoreBluetoothInterrupted();
              if (!_allowed || connected == null || connected.isClosed) {
                throw StateError('Soundcore disconnected or account changed');
              }
              _startDownloadProgress(recording);
              try {
                return await connected.download(recording, onProgress: _downloadProgress);
              } finally {
                _endDownloadProgress();
              }
            },
            onStage: (stage) {
              if (!_allowed) throw StateError('Soundcore sync account is no longer active');
              stages[id] = stage;
              _notify();
              if (stage == SoundcoreImportStage.uploading) {
                _uploadEstimator = null;
                uploadBytes = uploadTotal = 0;
                _progressTimer?.cancel();
                _progressTimer = Timer.periodic(const Duration(milliseconds: 250), (_) => _notify());
                _traceUpload('started');
                unawaited(_loadDetails(store!, id).then((_) => _notify()));
              }
            },
          );
          _attempts.remove(id);
          _retryAt.remove(id);
          _permanent.remove(id);
          _traceUpload('accepted bytes=$uploadBytes total=$uploadTotal');
        } catch (e) {
          stages.remove(id);
          if (e is SoundcoreBluetoothInterrupted && _wifiRequested) {
            // Intentional switch is neither a failed import nor a retry delay.
            failures.remove(id);
            break;
          }
          failures[id] = e;
          if (e is SoundcoreImportException) {
            _traceUpload(
                'failed ${e.diagnostic} bytes=$uploadBytes total=$uploadTotal'); // i18n-ignore: Sanitized technical diagnostic.
          }
          if (e is SoundcoreImportException && {400, 413, 415, 422}.contains(e.statusCode)) {
            _permanent.add(id);
          } else if (e is SoundcoreImportException && e.failure?.errorCode == _monthlyQuotaCode) {
            _ignoreStoredQuota = false;
            final boundary = _nextUtcMonth(now());
            for (final file in recordings) {
              _retryAt[file.id] = boundary;
            }
          } else if (e is SoundcoreImportException && e.failure?.errorCode == _monthlyUploadTooLargeCode) {
            _ignoreStoredQuota = false;
            _retryAt[id] = _nextUtcMonth(now());
          } else {
            final attempt = _attempts.update(id, (value) => (value + 1).clamp(1, 5), ifAbsent: () => 1);
            _retryAt[id] = now().add(retryDelay * (1 << (attempt - 1)));
          }
          // Auth, quota and server/network failures affect the whole queue.
          // Do not hammer the endpoint once per recording.
          if (e is SoundcoreImportException &&
              e.failure?.errorCode != _monthlyUploadTooLargeCode &&
              e.statusCode != 409 &&
              !_permanent.contains(id)) {
            for (final file in recordings) {
              _retryAt[file.id] = _retryAt[id]!;
            }
            break;
          }
        } finally {
          _endDownloadProgress();
          _uploadEstimator = null;
          await _loadDetails(store, id);
          activeId = null;
          _notify();
        }
      }
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      _notify();
    }
  }

  static DateTime _nextUtcMonth(DateTime value) {
    final utc = value.toUtc();
    return utc.month == 12 ? DateTime.utc(utc.year + 1) : DateTime.utc(utc.year, utc.month + 1);
  }

  Future<void> _restoreCloudReceipts(SoundcoreImportStore store) async {
    if (lookupRecordings == null) return;
    final pending = recordings.where((file) => needsCloudCheck(file.id)).toList();
    if (pending.isEmpty) {
      wifiAwaitingCloudCheck = false;
      return;
    }
    cloudLookupError = null;
    try {
      for (var offset = 0; offset < pending.length; offset += 20) {
        final batch = pending.skip(offset).take(20).where((file) => !_excluded(file.id)).toList();
        if (batch.isEmpty) continue;
        _checkingCloud.addAll(batch.map((file) => file.id));
        _notify();
        final result = await lookupRecordings!(batch);
        if (!_allowed) return;
        for (final file in batch) {
          if (_excluded(file.id)) continue;
          final remote = result[file.id];
          if (remote == null) throw const FormatException('Incomplete cloud receipt lookup');
          if (remote.conversationId != null && remote.conversationId!.isNotEmpty) {
            await store.restoreReceipt(
                file, SoundcoreImportReceipt(remote.conversationId!, processing: remote.processing),
                duration: remote.duration);
            if (!_allowed) return;
            if (_excluded(file.id)) continue;
            stages[file.id] = remote.processing ? SoundcoreImportStage.uploaded : SoundcoreImportStage.processed;
            if (remote.job != null) processingJobs[file.id] = remote.job!;
            failures.remove(file.id);
            _permanent.remove(file.id);
            _manualRetries.remove(file.id);
            _retryAt.remove(file.id);
            await _loadDetails(store, file.id);
          } else if (remote.canUpload) {
            _cloudChecked[file.id] = now();
          } else {
            // i18n-ignore: Internal reconciliation state; the recorder page localizes failures.
            cloudLookupError = StateError('Cloud recording status is not ready');
          }
        }
        _checkingCloud.clear();
        _notify();
      }
    } catch (error) {
      if (_allowed) cloudLookupError = error;
    } finally {
      _checkingCloud.clear();
      if (_allowed && !recordings.any((file) => needsCloudCheck(file.id))) wifiAwaitingCloudCheck = false;
      _notify();
    }
  }

  Future<SoundcoreSession?> _recoverBluetoothAfterWifi() async {
    if (!_allowed || _wifiCleanupPending || wifiState != null) return null;
    reconnectingBluetooth = true;
    _traceWifi('restoring BLE after hotspot exit'); // i18n-ignore: Sanitized transport diagnostic.
    _notify();
    try {
      SoundcoreSession? recovered;
      try {
        recovered = await openSession();
      } catch (_) {
        // DeviceService may still report a closed control generation.
      }
      if (!_allowed) return null;
      if (recovered == null || recovered.isClosed) recovered = await reconnectSession?.call();
      if (!_allowed) return null;
      if (recovered == null || recovered.isClosed) {
        throw StateError('Soundcore BLE recovery unavailable');
      }
      _attach(recovered);
      if (!recovered.busy) await recovered.readInfo();
      if (!_allowed) return null;
      recordStatus = recovered.recordStatus;
      _controlConnected = true;
      error = null;
      _traceWifi('BLE sync restored'); // i18n-ignore: Sanitized transport diagnostic.
      return recovered;
    } catch (failure) {
      error = failure;
      _controlConnected = false;
      recordStatus = null;
      _traceWifi('BLE recovery failed ${soundcoreWifiErrorCode(failure)}'); // i18n-ignore: Sanitized diagnostic.
      return null;
    } finally {
      reconnectingBluetooth = false;
      _notify();
    }
  }

  Future<void> _downloadWifiBatch(SoundcoreImportStore store, SoundcoreSession? connected) async {
    SoundcoreWifiConnection? wifi;
    try {
      if (!_allowed || connected == null || connected.isClosed || recordStatus == 1 || recordStatus == 2) {
        throw StateError('Connect the recorder and finish recording before Wi-Fi transfer');
      }
      final pending = recordings.reversed
          .where((file) =>
              stages[file.id] != SoundcoreImportStage.uploaded &&
              stages[file.id] != SoundcoreImportStage.processed &&
              !needsCloudCheck(file.id) &&
              details[file.id]?.sizeBytes == null &&
              !_permanent.contains(file.id))
          .toList();
      wifiAwaitingCloudCheck = recordings.any((file) => needsCloudCheck(file.id));
      if (pending.isEmpty) {
        wifiNothingToDownload = !wifiAwaitingCloudCheck &&
            !recordings.any((file) =>
                stages[file.id] != SoundcoreImportStage.uploaded &&
                stages[file.id] != SoundcoreImportStage.processed &&
                details[file.id]?.sizeBytes == null);
        _traceWifi('no pending device downloads'); // i18n-ignore: Sanitized diagnostic.
        return;
      }
      wifiState = SoundcoreWifiState.openingHotspot;
      _notify();
      wifi = await openWifi!(connected, _wifiPhase);
      _activeWifi = wifi;
      if (!_allowed) return;
      wifiState = SoundcoreWifiState.downloading;
      _traceWifi('WebSocket established; starting downloads');
      var hotspotRestarts = 0;
      for (final file in pending) {
        if (!_allowed) return;
        if (_excluded(file.id)) continue;
        activeId = file.id;
        bytes = 0;
        failures.remove(file.id);
        _notify();
        try {
          await store.cacheRecording(
            file,
            download: () async {
              _startDownloadProgress(file);
              try {
                try {
                  return await wifi!.download(file, onProgress: _downloadProgress);
                } catch (failure) {
                  // A fresh socket can connect while the recorder's export
                  // task remains stuck. Rebuild the AP and key exchange once
                  // per batch before abandoning Wi-Fi. Keep completed cache.
                  if (!_allowed ||
                      reconnectSession == null ||
                      hotspotRestarts >= 1 ||
                      !soundcoreWifiCanRetry(failure)) {
                    rethrow;
                  }
                  hotspotRestarts++;
                  _wifiFailureDiagnostics = wifi!.diagnostics;
                  _traceWifi('restarting hotspot step=${wifi!.session.transferStep?.name} '
                      'bytes=$bytes ${soundcoreWifiErrorCode(failure)}'); // i18n-ignore: Sanitized diagnostic.
                  wifiState = SoundcoreWifiState.restoring;
                  _notify();
                  // Do not release Wi-Fi ownership between attempts: normal
                  // device monitoring must not race this explicit reconnect.
                  await wifi!.close();
                  _activeWifi = null;
                  wifi = null;
                  if (!_allowed) throw StateError('Soundcore sync account changed');
                  wifiState = SoundcoreWifiState.reconnecting;
                  _notify();
                  connected?.close();
                  connected = await reconnectSession!();
                  if (!_allowed) throw StateError('Soundcore sync account changed');
                  if (connected == null || connected!.isClosed) {
                    throw StateError('Soundcore Wi-Fi control recovery unavailable');
                  }
                  _attach(connected!);
                  wifi = await openWifi!(connected!, _wifiPhase);
                  _activeWifi = wifi;
                  if (!_allowed) throw StateError('Soundcore sync account changed');
                  wifiState = SoundcoreWifiState.downloading;
                  _traceWifi('hotspot rebuilt; retrying current file from start'); // i18n-ignore: Sanitized diagnostic.
                  _startDownloadProgress(file);
                  return await wifi!.download(file, onProgress: _downloadProgress);
                }
              } finally {
                _endDownloadProgress();
              }
            },
            onStage: (stage) {
              if (!_allowed) throw StateError('Soundcore sync account changed');
              stages[file.id] = stage;
              _notify();
            },
          );
          _retryAt.remove(file.id);
        } catch (error) {
          stages.remove(file.id);
          failures[file.id] = error;
          if (error is SoundcoreImportException &&
              error.failure?.errorCode == SoundcoreImportException.durationTooLong) {
            _permanent.add(file.id);
            _manualRetries.remove(file.id);
            _retryAt.remove(file.id);
            _traceWifi('file exceeds duration limit; continuing batch'); // i18n-ignore: Sanitized diagnostic.
            continue;
          }
          _retryAt[file.id] = now().add(retryDelay);
          rethrow;
        } finally {
          await _loadDetails(store, file.id);
          activeId = null;
          _notify();
        }
      }
    } catch (error) {
      // Enabling the AP can close BLE even when system join/DHCP fails.
      // Recover once for this handoff, after verified hotspot teardown; normal
      // connection monitoring owns any later retries if the recorder is away.
      if (connected?.isClosed == true) _resumeBleAfterWifi = true;
      if (error is SoundcoreWifiFailure) _pendingWifiCleanup = error.cleanup;
      wifiFailedBytes = wifi == null ? 0 : bytes;
      wifiFailedStep = wifi?.session.transferStep;
      wifiError = wifi == null ? error : SoundcoreWifiFailure(SoundcoreWifiPhase.downloading, error);
      if (wifi != null) {
        // Leave the hotspot before retrying another uncached file on BLE.
        // Completed cache can still upload immediately after network teardown.
        for (final file in recordings) {
          if (details[file.id]?.sizeBytes == null) _retryAt[file.id] = now().add(retryDelay);
        }
      }
      // Do not copy exception strings: a network/platform error can contain
      // hotspot credentials or other identifiers.
      final cause = error is SoundcoreWifiFailure ? error.cause : error;
      // i18n-ignore: Sanitized technical diagnostic; localized separately by the page.
      _traceWifi('failed stage=${wifiState?.name} step=${wifiFailedStep?.name} '
          'bytes=$wifiFailedBytes ${soundcoreWifiErrorCode(cause)}'); // i18n-ignore: Sanitized diagnostic.
      if (cause is PlatformException && RegExp(r'^hotspot_[a-z_]+$').hasMatch(cause.code)) {
        _traceWifi('platform=${cause.code}${cause.details is int ? " code=${cause.details}" : ""}');
      }
      _wifiFailureDiagnostics = [
        if (_wifiFailureDiagnostics != null) _wifiFailureDiagnostics!,
        if (connected != null) connected!.diagnostics,
        if (wifi != null) wifi!.diagnostics,
      ].join('\n');
    } finally {
      // Device AP has no Internet. Close it and remove the temporary system
      // configuration before the normal upload queue is allowed to continue.
      await _restoreWifi();
    }
  }

  Future<bool> _restoreWifi() async {
    final recoveringCleanup = _wifiCleanupPending;
    wifiState = SoundcoreWifiState.restoring;
    _notify();
    try {
      await _activeWifi?.close();
      await _pendingWifiCleanup?.call();
      _pendingWifiCleanup = null;
      _activeWifi = null;
      if (recoveringCleanup ||
          (wifiError is SoundcoreWifiFailure &&
              (wifiError as SoundcoreWifiFailure).phase == SoundcoreWifiPhase.restoring)) {
        wifiError = null;
      }
      _wifiCleanupPending = false;
      wifiState = null;
      _releaseWifiActivity();
      _traceWifi('recorder network disconnected; uploads may resume'); // i18n-ignore: Sanitized technical diagnostic.
      return true;
    } catch (error) {
      _wifiCleanupPending = true;
      wifiError ??= SoundcoreWifiFailure(SoundcoreWifiPhase.restoring, error);
      // i18n-ignore: Numeric transport diagnostics only.
      _traceWifi('cleanup pending ${soundcoreWifiErrorCode(error)}');
      return false;
    } finally {
      _notify();
    }
  }

  Future<void> _loadDetails(SoundcoreImportStore store, int id) async {
    try {
      final value = await store.recordingDetails(id);
      if (_allowed && !_excluded(id) && value != null) details[id] = value;
    } catch (e) {
      // Account changes or a storage error must not leave activeId stuck.
      cacheError = e;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_activeWifi?.close().catchError((_) {}));
    unawaited(_pendingWifiCleanup?.call().catchError((_) {}));
    _endDownloadProgress();
    _stopTimer?.cancel();
    _recordSubscription?.cancel();
    // The transport is owned by DeviceService; page disposal never reaches here.
    super.dispose();
  }
}
