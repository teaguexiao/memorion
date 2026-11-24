import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

import 'package:memorion/models/stt_result.dart';
import 'package:memorion/services/sockets/pure_socket.dart';
import 'package:memorion/services/sockets/on_device_apple_provider.dart';
import 'package:memorion/utils/audio/wav_bytes.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';

/// Abstract interface for on-device STT providers (Apple Speech, Whisper, etc.)
abstract class ISttProvider {
  Future<SttTranscriptionResult?> transcribe(
    Uint8List audioData, {
    double audioOffsetSeconds = 0,
  });
  void dispose();
}

/// Configuration for the polling-based on-device STT.
class AudioPollingConfig {
  final Duration bufferDuration;
  final int minBufferSizeBytes;
  final String? serviceId;
  final BleAudioCodec codec;
  final int sampleRate;

  const AudioPollingConfig({
    this.bufferDuration = const Duration(seconds: 5),
    this.minBufferSizeBytes = 8000,
    this.serviceId,
    required this.codec,
    required this.sampleRate,
  });
}

/// A socket-like adapter that feeds audio to a local STT provider.
///
/// Supports two modes:
/// 1. **Streaming mode** (when sttProvider is OnDeviceAppleProvider):
///    Audio is decoded to PCM and fed continuously via appendAudio().
///    Results arrive via a stream from the provider.
/// 2. **Polling mode** (legacy, for other ISttProvider implementations):
///    Audio is buffered and periodically transcribed in batches.
///
/// Implements [IPureSocket] so it can be used as a drop-in replacement
/// for a real WebSocket in the CompositeTranscriptionSocket.
class PurePollingSocket implements IPureSocket {
  Timer? _bufferFlushTimer;

  final AudioPollingConfig config;
  final ISttProvider sttProvider;

  PureSocketStatus _status = PureSocketStatus.notConnected;

  @override
  PureSocketStatus get status => _status;

  IPureSocketListener? _listener;

  final List<Uint8List> _audioFrames = [];
  bool _isProcessing = false;
  double _audioOffsetSeconds = 0;

  // Streaming mode state
  bool _isStreamingMode = false;
  StreamSubscription<SttTranscriptionResult>? _streamSubscription;

  // Persistent Opus decoder for streaming mode (Opus is stateful — must reuse across frames)
  WavBytesUtil? _opusDecoder;

  PurePollingSocket({required this.config, required this.sttProvider});

  @override
  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() async {
    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      return false;
    }

    final serviceId = config.serviceId ?? 'Polling';
    debugPrint('[$serviceId] Connecting...');
    _status = PureSocketStatus.connecting;

    try {
      // Determine if we should use streaming mode
      _isStreamingMode = sttProvider is OnDeviceAppleProvider;

      if (_isStreamingMode) {
        final appleProvider = sttProvider as OnDeviceAppleProvider;

        // Start the streaming recognition session
        final stream = appleProvider.startStreaming();

        // Listen for streaming results
        _streamSubscription = stream.listen(
          (result) {
            if (result.isNotEmpty) {
              _handleStreamingResult(result);
            }
          },
          onError: (e, trace) {
            debugPrint('[$serviceId] Streaming error: $e');
            onError(e, trace);
          },
        );

        // Initialize Opus decoder if needed
        if (config.codec.isOpusSupported()) {
          _opusDecoder = WavBytesUtil(
            codec: config.codec,
            framesPerSecond: config.codec == BleAudioCodec.opusFS320 ? 50 : 100,
          );
        }

        debugPrint('[$serviceId] Streaming mode activated');
      } else {
        // Legacy polling mode
        _startBufferFlushTimer();
        debugPrint('[$serviceId] Polling mode activated');
      }

      _status = PureSocketStatus.connected;
      debugPrint('[$serviceId] Connected');
      onConnected();
      return true;
    } catch (e) {
      debugPrint('[$serviceId] Connection error: $e');
      _status = PureSocketStatus.notConnected;
      return false;
    }
  }

  void _handleStreamingResult(SttTranscriptionResult result) {
    if (result.segments.isEmpty) return;

    // The provider assigns segment IDs:
    //   - Sealed segments: permanent IDs like "ondevice_p0", "ondevice_p1"
    //   - Running segment: current ID (updates in-place via ID matching)
    final segmentsJson = result.segments
        .where((s) => s.text.trim().isNotEmpty)
        .map((s) => {
              'id': s.id ?? '',
              'text': s.text.trim(),
              'speaker': 'SPEAKER_0',
              'speaker_id': 0,
              'is_user': false,
              'start': s.start,
              'end': s.end,
            })
        .toList();

    if (segmentsJson.isNotEmpty) {
      onMessage(jsonEncode(segmentsJson));
    }
  }

  void _startBufferFlushTimer() {
    _bufferFlushTimer?.cancel();
    _bufferFlushTimer = Timer.periodic(config.bufferDuration, (_) {
      _flushBuffer();
    });
  }

  int get _totalBufferBytes => _audioFrames.fold<int>(0, (sum, frame) => sum + frame.length);

  /// Legacy polling mode: batch transcribe accumulated audio frames
  Future<void> _flushBuffer() async {
    if (_audioFrames.isEmpty || _status != PureSocketStatus.connected) {
      return;
    }

    if (_totalBufferBytes < config.minBufferSizeBytes || _isProcessing) {
      return;
    }

    _isProcessing = true;

    final frames = List<Uint8List>.from(_audioFrames);
    _audioFrames.clear();

    try {
      // Transcode accumulated frames to WAV bytes for STT
      final wavBytes = _transcodeToWav(frames);

      final result = await sttProvider.transcribe(
        wavBytes,
        audioOffsetSeconds: _audioOffsetSeconds,
      );

      if (result != null && result.isNotEmpty) {
        if (result.segments.isNotEmpty) {
          _audioOffsetSeconds = result.segments.last.end;
        }

        // Format as JSON matching the server's transcript segment format
        final segmentsJson = result.segments
            .where((s) => s.text.trim().isNotEmpty)
            .map((s) => {
                  'text': s.text.trim(),
                  'speaker': 'SPEAKER_0',
                  'speaker_id': 0,
                  'is_user': false,
                  'start': s.start,
                  'end': s.end,
                })
            .toList();

        if (segmentsJson.isNotEmpty) {
          onMessage(jsonEncode(segmentsJson));
        }
      }
    } catch (e, trace) {
      debugPrint('[${config.serviceId ?? "Polling"}] Transcription error: $e');
      onError(e, trace);
    } finally {
      _isProcessing = false;
    }
  }

  /// Convert raw audio frames (PCM or Opus) to WAV bytes for the STT provider.
  Uint8List _transcodeToWav(List<Uint8List> frames) {
    final codec = config.codec;

    if (codec == BleAudioCodec.pcm16 || codec == BleAudioCodec.pcm8) {
      // Raw PCM — just merge and wrap with WAV header
      final totalLength = frames.fold<int>(0, (sum, f) => sum + f.length);
      final merged = Uint8List(totalLength);
      int offset = 0;
      for (final frame in frames) {
        merged.setRange(offset, offset + frame.length, frame);
        offset += frame.length;
      }
      final sampleRate = codec == BleAudioCodec.pcm8 ? 8000 : 16000;
      return WavBytes.fromPcm(merged, sampleRate: sampleRate, numChannels: 1).asBytes();
    }

    if (codec.isOpusSupported()) {
      // Decode Opus frames to PCM, then wrap with WAV header
      final wavUtil = WavBytesUtil(
        codec: codec,
        framesPerSecond: codec == BleAudioCodec.opusFS320 ? 50 : 100,
      );
      for (final frame in frames) {
        wavUtil.frames.add(frame.toList());
      }
      final Int16List samples = wavUtil.getPcmSamples(wavUtil.frames);
      return WavBytesUtil.getUInt8ListBytes(samples, 16000);
    }

    // Fallback: just merge bytes
    final totalLength = frames.fold<int>(0, (sum, f) => sum + f.length);
    final merged = Uint8List(totalLength);
    int offset = 0;
    for (final frame in frames) {
      merged.setRange(offset, offset + frame.length, frame);
      offset += frame.length;
    }
    return merged;
  }

  @override
  Future disconnect() async {
    _bufferFlushTimer?.cancel();
    _streamSubscription?.cancel();
    _streamSubscription = null;

    // In polling mode, flush remaining audio
    if (!_isStreamingMode && _audioFrames.isNotEmpty && !_isProcessing) {
      await _flushBuffer();
    }

    _status = PureSocketStatus.disconnected;
    debugPrint('[${config.serviceId ?? "Polling"}] Disconnected');
    onClosed();
  }

  @override
  Future stop() async {
    await disconnect();
    _bufferFlushTimer?.cancel();
    _audioFrames.clear();
    _audioOffsetSeconds = 0;
    sttProvider.dispose();
  }

  @override
  void send(dynamic message) {
    Uint8List? audioFrame;
    if (message is Uint8List) {
      audioFrame = message;
    } else if (message is List<int>) {
      audioFrame = Uint8List.fromList(message);
    }

    if (audioFrame == null) return;

    if (_isStreamingMode) {
      // Streaming mode: decode to PCM if needed, then feed directly to Apple Speech
      _feedAudioToStreaming(audioFrame);
    } else {
      // Polling mode: buffer frames for batch processing
      _audioFrames.add(audioFrame);
    }
  }

  void _feedAudioToStreaming(Uint8List frame) {
    final appleProvider = sttProvider as OnDeviceAppleProvider;
    final codec = config.codec;

    Uint8List pcmData;

    if (codec == BleAudioCodec.pcm16 || codec == BleAudioCodec.pcm8) {
      // Already PCM — send directly
      pcmData = frame;
    } else if (codec.isOpusSupported()) {
      // Decode Opus to PCM using the persistent decoder (Opus is stateful)
      try {
        if (_opusDecoder == null) return;
        final decoded = _opusDecoder!.opusDecoder.decode(input: frame);
        // Convert Int16 samples to raw PCM16 bytes (little-endian)
        final byteData = ByteData(decoded.length * 2);
        for (int i = 0; i < decoded.length; i++) {
          byteData.setInt16(i * 2, decoded[i], Endian.little);
        }
        pcmData = byteData.buffer.asUint8List();
      } catch (e) {
        debugPrint('[PurePolling] Opus decode error: $e');
        return; // Skip corrupted frames
      }
    } else {
      pcmData = frame;
    }

    // Update audio offset based on PCM data size
    // 16-bit mono: 2 bytes per sample at sampleRate Hz
    final durationSeconds = pcmData.length / (2.0 * config.sampleRate);
    _audioOffsetSeconds += durationSeconds;
    appleProvider.updateAudioOffset(_audioOffsetSeconds);

    // Feed to Apple Speech
    appleProvider.appendAudio(pcmData);
  }

  @override
  void onConnected() {
    _listener?.onConnected();
  }

  @override
  void onMessage(dynamic message) {
    _listener?.onMessage(message);
  }

  @override
  void onClosed([int? closeCode]) {
    _status = PureSocketStatus.disconnected;
    _listener?.onClosed(closeCode);
  }

  @override
  void onError(Object err, StackTrace trace) {
    _listener?.onError(err, trace);
  }

  @override
  void onInternetSatusChanged(InternetStatus status) {
    // No-op: local STT doesn't depend on internet
  }
}
