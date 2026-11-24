import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/utils/audio/wav_bytes.dart';
import 'package:path_provider/path_provider.dart';

/// Local audio buffer for file upload mode.
/// Accumulates audio frames and exports them to WAV or Opus format files.
class LocalAudioBuffer {
  final List<List<int>> _frames = [];
  final BleAudioCodec codec;
  final int sampleRate;
  DateTime? startedAt;
  int _totalBytes = 0;

  LocalAudioBuffer({
    required this.codec,
    required this.sampleRate,
  });

  /// Add an audio frame to the buffer
  void addFrame(List<int> frame) {
    startedAt ??= DateTime.now();
    _frames.add(List<int>.from(frame));
    _totalBytes += frame.length;
  }

  /// The instant the first frame arrived — this recording's time anchor.
  ///
  /// Non-null whenever the buffer holds audio (`addFrame` sets it before
  /// appending the frame), so a caller that already checked [isEmpty] can read
  /// it directly. Throws instead of falling back to `DateTime.now()`: this value
  /// becomes the upload's `started_at`, and transcript segments carry only
  /// offsets from it, so substituting "now" would silently relocate the whole
  /// recording to the upload moment. The backend rejects a missing anchor with
  /// 400 for the same reason.
  DateTime get recordingStartedAt {
    final at = startedAt;
    if (at == null) {
      throw StateError('LocalAudioBuffer holds ${_frames.length} frames but no startedAt — the time anchor was lost');
    }
    return at;
  }

  /// Get all buffered frames
  List<List<int>> getFrames() => List.unmodifiable(_frames);

  /// Get the number of frames in the buffer
  int get frameCount => _frames.length;

  /// Get total bytes in buffer
  int get totalBytes => _totalBytes;

  /// Check if buffer is empty
  bool get isEmpty => _frames.isEmpty;

  /// Clear the buffer
  void clear() {
    _frames.clear();
    _totalBytes = 0;
    startedAt = null;
  }

  /// Get duration in seconds based on actual elapsed time since recording started
  double get durationSeconds {
    if (_frames.isEmpty || startedAt == null) return 0;

    // Use real elapsed time for accurate duration display
    return DateTime.now().difference(startedAt!).inMilliseconds / 1000.0;
  }

  /// Export buffer to WAV file (for PCM codecs)
  Future<File> exportToWav() async {
    if (_frames.isEmpty) {
      throw Exception('Buffer is empty');
    }

    try {
      // Combine all frames into a single byte array
      final allBytes = <int>[];
      for (final frame in _frames) {
        allBytes.addAll(frame);
      }

      final pcmBytes = Uint8List.fromList(allBytes);

      // Convert PCM to WAV bytes
      final wavBytes = WavBytes.fromPcm(
        pcmBytes,
        sampleRate: sampleRate,
        numChannels: 1,
      ).asBytes();

      // Create a temporary file
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempPath = '${tempDir.path}/recording_$timestamp.wav';
      final file = File(tempPath);

      // Write WAV bytes to file
      await file.writeAsBytes(wavBytes);
      debugPrint('LocalAudioBuffer: Exported WAV file to $tempPath (${wavBytes.length} bytes)');
      return file;
    } catch (e) {
      debugPrint('LocalAudioBuffer: Error exporting to WAV: $e');
      rethrow;
    }
  }

  /// Export buffer to Opus binary file (length-prefixed frames)
  /// This format is compatible with the backend's decode_opus_to_wav function
  Future<File> exportToOpusBin({int frameSize = 160}) async {
    if (_frames.isEmpty) {
      throw Exception('Buffer is empty');
    }

    try {
      final data = <int>[];

      for (final frame in _frames) {
        // Format: <4-byte length prefix>|<opus frame data>
        final byteData = ByteData(4);
        byteData.setUint32(0, frame.length, Endian.little);
        data.addAll(byteData.buffer.asUint8List());
        data.addAll(frame);
      }

      // Create a temporary file with frame size in filename for backend
      // The filename's trailing timestamp is a time anchor too — `sync.py`'s
      // `get_timestamp_from_path` reads recording start out of it. So it comes
      // from the buffer, never from `now()`; the `isEmpty` check above
      // guarantees `recordingStartedAt` is available.
      final tempDir = await getTemporaryDirectory();
      final startTimestamp = recordingStartedAt.millisecondsSinceEpoch ~/ 1000;
      final tempPath = '${tempDir.path}/audio_fs${frameSize}_$startTimestamp.bin';
      final file = File(tempPath);

      // Write binary data to file
      await file.writeAsBytes(data);
      debugPrint('LocalAudioBuffer: Exported Opus bin file to $tempPath (${data.length} bytes)');
      return file;
    } catch (e) {
      debugPrint('LocalAudioBuffer: Error exporting to Opus bin: $e');
      rethrow;
    }
  }

  /// Export to the appropriate format based on codec
  Future<File> export({int frameSize = 160}) async {
    if (codec == BleAudioCodec.pcm8 || codec == BleAudioCodec.pcm16) {
      return exportToWav();
    } else {
      return exportToOpusBin(frameSize: frameSize);
    }
  }
}
