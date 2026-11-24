import 'dart:io';

import 'package:flutter/material.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/sockets/composite_transcription_socket.dart';
import 'package:memorion/services/sockets/on_device_apple_provider.dart';
import 'package:memorion/services/sockets/pure_polling.dart';
import 'package:memorion/services/sockets/pure_socket.dart';
import 'package:memorion/services/sockets/transcription_connection.dart';

abstract class ISocketService {
  void start();

  void stop();

  /// Whether the last connection attempt failed due to 429 usage limit.
  bool get wasUsageLimitExceeded => false;

  Future<TranscriptSegmentSocketService?> conversation(
      {required BleAudioCodec codec, required int sampleRate, required String language, bool force = false, bool useOnDeviceStt = false});

  Future<TranscriptSegmentSocketService?> speechProfile(
      {required BleAudioCodec codec, required int sampleRate, required String language, bool force = false});
}

abstract interface class ISocketServiceSubsciption {}

class SocketServicePool extends ISocketService {
  TranscriptSegmentSocketService? _socket;
  bool _lastConnectionWasUsageLimited = false;
  DateTime? _lastSessionAttempt;
  int _consecutiveFailures = 0;

  /// Whether the last socket connection attempt failed due to 429 usage limit.
  bool get wasUsageLimitExceeded => _lastConnectionWasUsageLimited;

  @override
  void start() {}

  @override
  void stop() async {
    await _socket?.stop();
  }

  // Warn: Should use a better solution to prevent race conditions
  bool mutex = false;

  Future<TranscriptSegmentSocketService?> socket({
    required BleAudioCodec codec,
    required int sampleRate,
    required String language,
    bool force = false,
    bool useOnDeviceStt = false,
  }) async {
    while (mutex) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    mutex = true;

    try {
      if (!force &&
          _socket?.codec == codec &&
          _socket?.sampleRate == sampleRate &&
          _socket?.state == SocketServiceState.connected) {
        return _socket;
      }

      // Backoff: enforce minimum interval between session creation attempts
      // to prevent retry storms when the backend is unreachable or returning errors.
      final now = DateTime.now();
      if (_lastSessionAttempt != null) {
        final minInterval = Duration(seconds: 5 * (_consecutiveFailures + 1).clamp(1, 12));
        final elapsed = now.difference(_lastSessionAttempt!);
        if (elapsed < minInterval) {
          debugPrint("_connect throttled: ${elapsed.inSeconds}s < ${minInterval.inSeconds}s min interval (failures: $_consecutiveFailures)");
          return null;
        }
      }
      _lastSessionAttempt = now;

      debugPrint("_connect force ${force} state ${_socket?.state}");

      // new socket
      await _socket?.stop();

      if (useOnDeviceStt && Platform.isIOS) {
        // Composite mode: local Apple STT (primary) + backend WebSocket (secondary)
        _socket = await _createCompositeSocket(sampleRate, codec, language);
      } else {
        _socket = ConversationTranscriptSegmentSocketService.create(sampleRate, codec, language);
      }
      await _socket?.start();
      if (_socket?.state != SocketServiceState.connected) {
        _lastConnectionWasUsageLimited = _socket?.wasUsageLimitExceeded ?? false;
        _consecutiveFailures++;
        // 没连上就别把这个半死的 service 留在 _socket 里：下一轮 keepalive 会
        // 拿它的 codec/state 做判断，而调用方拿到的是 null，两边看到的状态不一致。
        await _socket?.stop();
        _socket = null;
        return null;
      }

      _lastConnectionWasUsageLimited = false;
      _consecutiveFailures = 0;
      return _socket;
    } finally {
      mutex = false;
    }

    return null;
  }

  /// Build a composite socket: local Apple STT as primary, backend WebSocket as secondary.
  Future<TranscriptSegmentSocketService?> _createCompositeSocket(
    int sampleRate,
    BleAudioCodec codec,
    String language,
  ) async {
    // Step 1: Create backend session via HTTP to get WebSocket URL
    final tempService = CustomSttTranscriptSegmentSocketService.create(sampleRate, codec, language);
    final wsUrl = await tempService.createSessionOnly();
    if (wsUrl == null) {
      debugPrint('[OnDeviceSTT] Failed to create backend session');
      return null;
    }

    // Step 2: Primary — on-device Apple Speech streaming socket
    // Map language codes to Apple Speech locale identifiers.
    // For Chinese variants, use zh-Hans which has better mixed-language tolerance.
    String appleLocale = language;
    if (language == 'zh' || language == 'zh-CN') {
      appleLocale = 'zh-Hans';
    } else if (language == 'zh-HK') {
      appleLocale = 'zh-HK';
    } else if (language == 'zh-TW') {
      appleLocale = 'zh-Hant';
    }

    final pollingSocket = PurePollingSocket(
      config: AudioPollingConfig(
        codec: codec,
        sampleRate: sampleRate,
        serviceId: 'AppleSTT',
      ),
      sttProvider: OnDeviceAppleProvider(language: appleLocale, sampleRate: sampleRate),
    );

    // Step 3: Secondary — PureSocket connecting to the backend WebSocket URL.
    // 重连要换新 session：/v1/listen 的 URL 一次性，复用会被后端顶掉自己。
    final backendSocket = PureSocket(wsUrl, urlProvider: tempService.createSessionOnly);

    // Step 4: Composite wraps both
    final compositeSocket = CompositeTranscriptionSocket(
      primarySocket: pollingSocket,
      secondarySocket: backendSocket,
    );

    // Step 5: Wrap composite in a TranscriptSegmentSocketService using withSocket constructor
    return TranscriptSegmentSocketService.withSocket(
      sampleRate,
      codec,
      language,
      compositeSocket,
      includeSpeechProfile: true,
      customSttMode: true,
    );
  }

  @override
  Future<TranscriptSegmentSocketService?> conversation(
      {required BleAudioCodec codec,
      required int sampleRate,
      required String language,
      bool force = false,
      bool useOnDeviceStt = false}) async {
    debugPrint("socket conversation > $codec $sampleRate $force useOnDeviceStt=$useOnDeviceStt");
    return await socket(codec: codec, sampleRate: sampleRate, language: language, force: force, useOnDeviceStt: useOnDeviceStt);
  }

  @override
  Future<TranscriptSegmentSocketService?> speechProfile(
      {required BleAudioCodec codec, required int sampleRate, required String language, bool force = false}) async {
    debugPrint("socket speech profile > $codec $sampleRate $force");
    return await socket(codec: codec, sampleRate: sampleRate, language: language, force: force);
  }
}
