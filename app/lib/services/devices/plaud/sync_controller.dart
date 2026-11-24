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
import 'identity.dart';
import '../recorder_wifi_activity.dart';
import 'wifi_connector.dart';

typedef PlaudConnectWifi = Future<PlaudWifiConnection> Function(PlaudSession session,
    {required bool Function() isActive, void Function(PlaudWifiPhase)? onPhase});

class PlaudSyncController extends ChangeNotifier {
  final Future<PlaudImportStore> Function() openStore;
  final Future<PlaudSession?> Function() openSession;
  final Future<PlaudSession?> Function()? reconnectSession;
  final bool Function() isCurrentOwner;
  final Future<AudioProcessingJob> Function(String)? fetchJob;
  final Future<OfflineDownload> Function(File)? decodeAudio;
  final Future<PlaudIdentity?> Function() readIdentity;
  final String? deviceId;
  final PlaudConnectWifi? connectWifi;
  bool get wifiAvailable => connectWifi != null;
  PlaudWifiPhase? wifiState;
  Object? wifiError;
  bool wifiNothingToDownload = false;
  bool _wifiCancelled = false;
  bool _reconnectForWifi = false;
  PlaudSession? _downloadingSession;
  PlaudWifiConnection? _wifi;
  Future<void> Function()? _wifiCleanup;
  VoidCallback? _releaseWifi;
  Future<void>? _wifiTask, _restoringWifi;
  Timer? _cleanupRetry;
  final _deviceRecords = <int, PlaudRecording>{};
  PlaudImportStore? _store;
  bool _disposed = false, _retired = false, _refreshingJobs = false;
  bool _updatingAuthorization = false;
  Future<void>? _importTask;
  int _jobCursor = 0;
  final _retryAfter = <int, DateTime>{};
  List<OfflineRecording> recordings = [];
  final stages = <int, OfflineImportStage>{};
  final details = <int, OfflineRecordingDetails>{};
  final errors = <int, Object>{};
  final processingJobs = <int, AudioProcessingJob>{};
  Object? error;
  bool loading = false, busy = false, connected = false;
  int? activeId, deviceFileCount;
  int bytes = 0, totalBytes = 0;
  double? uploadProgress;
  DateTime? lastRefresh;

  PlaudSyncController(
      {required this.openStore,
      required this.openSession,
      required this.readIdentity,
      required this.isCurrentOwner,
      this.deviceId,
      this.connectWifi,
      this.reconnectSession,
      this.fetchJob,
      this.decodeAudio});
  bool get ownerActive => !_retired && isCurrentOwner();
  bool get _allowed => !_disposed && ownerActive && !_updatingAuthorization;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _check() {
    if (!_allowed) throw const PlaudException(PlaudIssue.identityRequired);
  }

  Future<PlaudImportStore> _getStore() async {
    _check();
    return _store ??= await openStore();
  }

  Future<void> refresh() async {
    if (!_allowed || busy || loading || wifiState != null) return;
    loading = true;
    error = null;
    _notify();
    try {
      final store = await _getStore();
      final merged = {for (final r in await store.cachedRecordings()) r.id: r};
      _check();
      try {
        final session = await openSession();
        _check();
        connected = session != null && !session.isClosed;
        if (connected && !session!.busy) {
          final deviceRecords = await session.recordings();
          _check();
          deviceFileCount = deviceRecords.length;
          _deviceRecords.clear();
          for (final r in deviceRecords) {
            _deviceRecords[r.id] = r;
            merged[r.id] = OfflineRecording(r.id, 0, (r.byteSize - 512) ~/ 80 * 20);
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
        if (issue != null) errors[r.id] = PlaudException(issue);
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
      unawaited(importAll());
    }
  }

  /// Pause only while replacing credentials and reconnecting. Cancelling the
  /// setup page or a failed update must not leave automatic sync disabled.
  Future<void> updateAuthorization(Future<void> Function() update) async {
    _check();
    // The recordings page already disables its authorization button while busy
    // or loading. Also guard taps racing a background refresh: credentials must
    // stay stable until the current decode/upload finishes.
    if (busy || loading || wifiState != null) throw const PlaudException(PlaudIssue.busy);
    _updatingAuthorization = true;
    try {
      await update();
    } finally {
      _updatingAuthorization = false;
      if (_allowed) unawaited(refresh());
    }
  }

  Future<void> importAll() {
    if (_importTask != null) return _importTask!;
    if (!_allowed || busy || loading || wifiState != null) return Future<void>.value();
    return _importTask = _importPending().whenComplete(() => _importTask = null);
  }

  Future<void> _importPending() async {
    try {
      // Each successful item commits its own receipt. Leaving the page never
      // cancels the app-owned queue; switching account stops all subsequent work.
      for (final r in List<OfflineRecording>.of(recordings)) {
        if (!_allowed || loading || busy || wifiState != null) break;
        if ({OfflineImportStage.uploaded, OfflineImportStage.processed}.contains(stages[r.id])) continue;
        if (errors[r.id] is PlaudException &&
            {PlaudIssue.unsupportedAudio}.contains((errors[r.id] as PlaudException).issue)) {
          continue;
        }
        if (_retryAfter[r.id]?.isAfter(DateTime.now()) == true) continue;
        if (!r.hasValidTimestamp(DateTime.now())) continue;
        final store = await _getStore();
        if (await store.rejectionStatus(r.id) != null) {
          continue;
        }
        _check();
        await importOne(r);
        if (!connected &&
            !{OfflineImportStage.downloaded, OfflineImportStage.uploaded, OfflineImportStage.processed}
                .contains(stages[r.id])) {
          break;
        }
      }
    } catch (e) {
      if (_allowed) {
        error = e;
        _notify();
      }
    }
  }

  Future<void> importOne(OfflineRecording recording, {bool retry = false}) async {
    if (!_allowed || busy || loading || wifiState != null) return;
    busy = true;
    activeId = recording.id;
    bytes = totalBytes = 0;
    uploadProgress = null;
    errors.remove(recording.id);
    _notify();
    try {
      final store = await _getStore();
      await store.importRecording(recording, retryRejected: retry, download: () async {
        final raw = await store.original(recording, (file) async {
          _checkBluetoothDownload();
          final session = await openSession();
          _checkBluetoothDownload();
          connected = session != null && !session.isClosed;
          if (!connected) throw const PlaudException(PlaudIssue.disconnected);
          final source = _deviceRecords[recording.id];
          if (source == null) throw const PlaudException(PlaudIssue.disconnected);
          _downloadingSession = session;
          try {
            await session!.downloadTo(source, file, onProgress: (received, total) {
              if (!_allowed) {
                session.close();
                return;
              }
              bytes = received;
              totalBytes = total;
              _notify();
            });
          } finally {
            _downloadingSession = null;
          }
        }, expectedBytes: _deviceRecords[recording.id]?.byteSize);
        _check();
        try {
          final result = await (decodeAudio ?? _decode)(raw);
          if (!_allowed) {
            await result.dispose();
            _check();
          }
          return result;
        } on PlaudException catch (e) {
          if ({PlaudIssue.unsupportedAudio}.contains(e.issue)) {
            await store.markAudioIssue(recording.id, e);
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
        if (e is PlaudBluetoothInterrupted) {
          errors.remove(recording.id);
          _retryAfter.remove(recording.id);
        } else {
          errors[recording.id] = e;
          _retryAfter[recording.id] = DateTime.now().add(const Duration(minutes: 2));
        }
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

  Future<PlaudIdentity> _identity() async {
    _check();
    final identity = await readIdentity();
    _check();
    if (identity == null) throw const PlaudException(PlaudIssue.identityRequired);
    return identity;
  }

  Future<OfflineDownload> _decode(File source) async {
    final identity = await _identity();
    final decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
    try {
      return await PlaudAudio.toOgg(source, identity, validatePacket: (p) {
        _check();
        return decoder.decode(input: p).length;
      });
    } finally {
      decoder.destroy();
    }
  }

  Future<void> refreshProcessing() async {
    if (!_allowed || fetchJob == null || _refreshingJobs || wifiState != null) return;
    _refreshingJobs = true;
    try {
      final store = await _getStore();
      final candidates = recordings.where((r) => stages[r.id] == OfflineImportStage.uploaded).toList();
      if (candidates.isEmpty) return;
      for (var i = 0; i < candidates.length.clamp(0, 10); i++) {
        if (wifiState != null) break;
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

  Future<File?> playable(int id) async {
    final file = await (await _getStore()).playable(id, await _identity());
    _check();
    return file;
  }

  void _checkBluetoothDownload() {
    _check();
    // Also cover a Wi-Fi request during asynchronous store/session preparation,
    // before there is a BLE download available to interrupt.
    if (wifiState != null) throw const PlaudBluetoothInterrupted();
  }

  /// Interrupt BLE immediately, then authenticate a fresh control connection.
  /// On the AP, persist only complete originals. Cloud work resumes after exit.
  Future<void> syncOverWifi() {
    if (_wifiTask != null) return _wifiTask!;
    if (!_allowed || !wifiAvailable || wifiState != null) return Future.value();
    _wifiCancelled = false;
    wifiError = null;
    wifiNothingToDownload = false;
    wifiState = PlaudWifiPhase.preparing;
    if (deviceId != null) _releaseWifi = RecorderWifiActivity.acquire(deviceId!);
    if (_downloadingSession?.interruptBluetoothDownload() ?? false) {
      _reconnectForWifi = true;
      connected = false;
    }
    _notify();
    return _wifiTask = _syncWifi().whenComplete(() => _wifiTask = null);
  }

  bool get _wifiAllowed => _allowed && !_wifiCancelled;
  void _checkWifi() {
    if (!_wifiAllowed) throw const PlaudException(PlaudIssue.disconnected);
  }

  Future<PlaudSession> _reconnectBluetooth() async {
    _check();
    // Reusing the interrupted session or merely recreating its parser would
    // accept stale device packets. Production performs a physical disconnect.
    final session = await reconnectSession?.call();
    _check();
    if (session == null || session.isClosed) throw const PlaudException(PlaudIssue.disconnected);
    _reconnectForWifi = false;
    connected = true;
    return session;
  }

  Future<void> _syncWifi() async {
    var ownsProgress = false;
    try {
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (busy || loading || _refreshingJobs) {
        // Let the interrupted import release its file/store ownership even if
        // cancellation arrived in the same turn as the preparing notification.
        _check();
        if (DateTime.now().isAfter(deadline)) throw const PlaudException(PlaudIssue.timeout);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _checkWifi();
      ownsProgress = true;
      final store = await _getStore();
      final session = _reconnectForWifi ? await _reconnectBluetooth() : await openSession();
      _checkWifi();
      if (session == null || session.isClosed) throw const PlaudException(PlaudIssue.disconnected);
      final sources = await session.recordings();
      _checkWifi();
      _deviceRecords
        ..clear()
        ..addEntries(sources.map((r) => MapEntry(r.id, r)));
      deviceFileCount = sources.length;
      final merged = {for (final r in recordings) r.id: r};
      final pending = <PlaudRecording>[];
      for (final source in sources) {
        _checkWifi();
        final r = OfflineRecording(source.id, 0, (source.byteSize - 512) ~/ 80 * 20);
        merged[r.id] = r;
        final stage = await store.status(r.id);
        _checkWifi();
        if (stage != null) stages[r.id] = stage;
        if ({OfflineImportStage.uploaded, OfflineImportStage.processed}.contains(stage) ||
            !r.hasValidTimestamp(DateTime.now()) ||
            await store.rejectionStatus(r.id) != null) {
          continue;
        }
        if (await store.cachedOriginal(r.id, expectedBytes: source.byteSize) == null) pending.add(source);
      }
      _checkWifi();
      recordings = merged.values.toList()..sort((a, b) => b.id.compareTo(a.id));
      if (pending.isEmpty) {
        wifiNothingToDownload = true;
        return;
      }
      _wifi = await connectWifi!(session,
          isActive: () => _wifiAllowed,
          onPhase: (phase) {
            wifiState = phase;
            _notify();
          });
      _checkWifi();
      connected = false;
      final wifiSources = {for (final r in await _wifi!.session.recordings()) r.id: r};
      _checkWifi();
      wifiState = PlaudWifiPhase.downloading;
      final progressClock = Stopwatch()..start();
      for (final source in pending) {
        _checkWifi();
        final remote = wifiSources[source.id];
        if (remote == null || remote.byteSize != source.byteSize) throw const PlaudException(PlaudIssue.protocol);
        activeId = source.id;
        bytes = 0;
        totalBytes = source.byteSize;
        _notify();
        final r = merged[source.id]!;
        await store.original(
            r,
            (file) => _wifi!.session.downloadTo(remote, file, onProgress: (received, total) {
                  _checkWifi();
                  bytes = received;
                  totalBytes = total;
                  if (progressClock.elapsedMilliseconds >= 200 || received == total) {
                    progressClock.reset();
                    _notify();
                  }
                }),
            expectedBytes: source.byteSize);
        _checkWifi();
        _retryAfter.remove(source.id);
        errors.remove(source.id);
      }
    } catch (e) {
      if (e is PlaudWifiFailure) _wifiCleanup = e.cleanup;
      if (_allowed && !_wifiCancelled) wifiError = e;
    } finally {
      if (ownsProgress) activeId = null;
      await restoreWifi();
    }
  }

  Future<void> restoreWifi() => _restoringWifi ??= _restoreWifi().whenComplete(() => _restoringWifi = null);
  Future<void> _restoreWifi() async {
    wifiState = PlaudWifiPhase.restoring;
    _notify();
    try {
      await _wifi?.close();
      await _wifiCleanup?.call();
      _wifi = null;
      _wifiCleanup = null;
      if (_reconnectForWifi && _allowed) {
        // Cancellation can arrive before hotspot setup. Restore the interrupted
        // BLE generation so the queue can resume without an artificial backoff.
        try {
          await _reconnectBluetooth();
        } catch (_) {/* Normal device reconnection retries after releasing the radio. */}
      }
      _releaseWifi?.call();
      _releaseWifi = null;
      _cleanupRetry?.cancel();
      _cleanupRetry = null;
      wifiState = null;
      if (_allowed) unawaited(importAll());
      if (wifiError is PlaudWifiFailure && (wifiError as PlaudWifiFailure).phase == PlaudWifiPhase.restoring) {
        wifiError = null;
      }
    } catch (_) {
      wifiError = const PlaudWifiFailure(PlaudWifiPhase.restoring);
      _cleanupRetry ??= Timer.periodic(const Duration(seconds: 10), (_) => unawaited(restoreWifi()));
    } finally {
      _notify();
    }
  }

  void cancelWifi() {
    _wifiCancelled = true;
    // A pending system join retains its bounded deadline; its connector checks
    // cancellation before accepting the session and always runs cleanup.
    if (_wifi != null) unawaited(_wifi!.close().catchError((Object _) {}));
  }

  void retire() {
    _retired = true;
    cancelWifi();
    recordings = [];
    stages.clear();
    details.clear();
    errors.clear();
    processingJobs.clear();
    _deviceRecords.clear();
    connected = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    cancelWifi();
    super.dispose();
  }
}
