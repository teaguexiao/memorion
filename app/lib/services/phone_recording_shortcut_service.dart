import 'dart:async';

import 'package:flutter/services.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/utils/enums.dart';

/// A start action, never a toggle. Concurrent shortcuts share one startup and
/// only report success after the recorder confirms microphone activation.
class PhoneRecordingShortcutController {
  PhoneRecordingShortcutController({
    required this.capture,
    required this.isAuthenticated,
    required this.isForeground,
    required this.requestMicrophonePermission,
    this.waitForForeground,
    this.startTimeout = const Duration(seconds: 30),
  });

  final CaptureProvider capture;
  final bool Function() isAuthenticated;
  final bool Function() isForeground;
  final Future<bool> Function() requestMicrophonePermission;
  final Future<void> Function()? waitForForeground;
  final Duration startTimeout;
  Future<bool>? _inFlight;

  /// Returns true only when this request started a new recording.
  Future<bool> start() {
    final pending = _inFlight;
    if (pending != null) return pending.then((_) => false);
    return _inFlight ??= _start().whenComplete(() => _inFlight = null);
  }

  void _checkAccess() {
    if (!isAuthenticated()) throw PlatformException(code: 'sign_in_required');
    if (!isForeground()) throw PlatformException(code: 'foreground_required');
  }

  Future<bool> _start() async {
    await waitForForeground?.call();
    _checkAccess();
    if (capture.recordingState == RecordingState.record && !capture.isPaused) return false;
    if (capture.isDeviceRecordingStarting ||
        capture.isPaused ||
        (capture.recordingState != RecordingState.stop && capture.recordingState != RecordingState.error)) {
      throw PlatformException(code: 'recording_busy');
    }

    capture.phoneRecordingShortcutStarting = true;
    var active = true;
    Future<void>? startup;
    Timer? timer;
    final confirmed = Completer<void>();
    void onState() {
      if (confirmed.isCompleted) return;
      if (capture.recordingState == RecordingState.record && !capture.isPaused) {
        try {
          _checkAccess();
          confirmed.complete();
        } catch (error) {
          confirmed.completeError(error);
        }
      } else if (capture.recordingState == RecordingState.stop || capture.recordingState == RecordingState.error) {
        confirmed.completeError(PlatformException(code: 'start_failed'));
      }
    }

    try {
      // Permission may present a system prompt. Start the timeout afterwards.
      if (!await requestMicrophonePermission()) throw PlatformException(code: 'microphone_permission');
      // iOS permission sheets briefly make the app inactive. Wait for the
      // resume event before judging whether recording can begin.
      await waitForForeground?.call();
      _checkAccess();
      capture.addListener(onState);
      timer = Timer(startTimeout, () {
        if (!confirmed.isCompleted) confirmed.completeError(PlatformException(code: 'start_failed'));
      });
      startup = capture.streamRecording(shouldStart: () => active && isAuthenticated() && isForeground());
      await Future.wait<void>([startup, confirmed.future], eagerError: true);
      return true;
    } catch (error) {
      active = false;
      if (startup != null) {
        // Drain setup before releasing ownership. An expired request must not
        // start the mic later or clean up a subsequent request's socket.
        var startupFailed = false;
        try {
          await startup;
        } catch (_) {
          // CaptureProvider has already reset and cleaned failed startup.
          startupFailed = true;
        }
        if (!startupFailed) await capture.stopStreamRecording();
      }
      if (error is PlatformException) rethrow;
      throw PlatformException(code: 'start_failed');
    } finally {
      active = false;
      timer?.cancel();
      capture.removeListener(onState);
      capture.phoneRecordingShortcutStarting = false;
      unawaited(capture.restoreDeferredDeviceRecording());
    }
  }
}

class PhoneRecordingShortcutService {
  static const channel = MethodChannel('com.memorion.ios/phone_recording');

  void attach(Future<void> Function() start) {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'startPhoneRecording') throw MissingPluginException();
      await start();
      return true;
    });
  }

  Future<void> markReady() => channel.invokeMethod<void>('ready');
  Future<void> markNotReady() => channel.invokeMethod<void>('notReady');

  void dispose() {
    channel.setMethodCallHandler(null);
    unawaited(markNotReady());
  }
}
