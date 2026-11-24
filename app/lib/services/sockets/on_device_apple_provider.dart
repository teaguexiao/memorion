import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import 'package:memorion/models/stt_result.dart';
import 'package:memorion/services/sockets/pure_polling.dart';

/// On-device STT provider using iOS Apple Speech Framework in streaming mode.
///
/// Apple Speech returns the full accumulated text for the current session on
/// each callback.  This provider splits the stream into display segments using
/// **start-time jump detection only**:
///
///  - When Apple Speech's `segmentStart` jumps by more than
///    [_startJumpThreshold] seconds, we "seal" the previous segment and start
///    a new one.
///
///  - Between jumps the text is accumulated into a single running segment
///    whose ID stays stable so the UI updates it in-place.
///
/// Apple Speech frequently revises already-emitted text (retroactive
/// corrections).  Instead of tracking confirmed/pending text and trying to
/// match prefixes (which breaks constantly with Chinese), we simply re-emit
/// all sealed segments plus the current running segment on every callback.
/// The client's `updateSegments()` replaces matching IDs in-place, so old
/// text is silently corrected without flicker.
class OnDeviceAppleProvider implements ISttProvider {
  final String language;
  final int sampleRate;
  static const MethodChannel _channel = MethodChannel('com.memorion.ios/speech');

  bool _isStreaming = false;

  StreamController<SttTranscriptionResult>? _resultController;

  /// Track the audio offset for segment timestamps.
  double _audioOffsetSeconds = 0;

  /// All sealed (finalized) segments for the current Apple Speech session.
  final List<_SealedSegment> _sealedSegments = [];

  /// Segment index counter — only moves forward.
  int _segmentIndex = 0;

  /// Current running segment ID.
  String _runningId = 'ondevice_p0';

  /// Text covered by all sealed segments (used to extract running text).
  /// This is rebuilt from _sealedSegments when corrections happen.
  int _sealedCharCount = 0;

  /// Audio offset when the current running segment started.
  double _runningStartOffset = 0;

  /// The end time of the last sealed segment (used to detect silence gaps).
  double _lastSealedEnd = 0;

  /// The start time from the last Apple Speech callback.
  double _lastAppleStart = -1;

  /// The last full text received from Apple Speech.
  String _lastFullText = '';

  /// Threshold for start-time jumps that indicate a new utterance.
  static const double _startJumpThreshold = 1.0; // seconds

  /// Threshold for detecting long silence that should trigger offset reset.
  /// When the gap between segments exceeds this threshold (e.g., 2 minutes),
  /// we reset the audio offset so the next segment starts from 0.
  ///
  /// This prevents situations where a user records for hours with long pauses,
  /// resulting in segments with timestamps like [0-2s, 2897-2899s], which would
  /// incorrectly show a conversation duration of 48 minutes.
  ///
  /// The backend has its own 120s timeout that auto-flushes conversations when
  /// no new segments arrive for 2 minutes. This frontend reset is a defensive
  /// measure to ensure timestamp sanity even if the backend timeout fails.
  static const double _longSilenceThreshold = 120.0; // seconds (2 minutes)

  OnDeviceAppleProvider({
    this.language = 'en',
    this.sampleRate = 16000,
  });

  Stream<SttTranscriptionResult> startStreaming() {
    _resultController?.close();
    _resultController = StreamController<SttTranscriptionResult>.broadcast();

    _setupMethodCallHandler();
    _startNativeStreaming();

    return _resultController!.stream;
  }

  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSpeechResult') {
        final args = call.arguments as Map<dynamic, dynamic>;
        final fullText = args['text'] as String? ?? '';
        final isFinal = args['isFinal'] as bool? ?? false;
        final segmentStart = (args['segmentStart'] as num?)?.toDouble() ?? 0.0;
        // segmentEnd not needed - we track segment boundaries via _audioOffsetSeconds

        if (fullText.isEmpty) return;

        // Detect implicit session restart: Apple Speech sometimes restarts
        // its recognition task (60s limit) without sending isFinal. The new
        // task's fullText is completely different from the old one.
        // If the new text is much shorter AND shares no common prefix with
        // the old accumulated text, treat it as a session restart.
        if (_lastFullText.isNotEmpty && !isFinal) {
          final oldTotal = _sealedSegments.map((s) => s.text).join() +
              _getRunningText(_lastFullText);
          if (_isImplicitRestart(oldTotal, fullText)) {
            debugPrint('[OnDeviceApple] Implicit session restart detected: '
                '"${oldTotal.length > 20 ? '${oldTotal.substring(0, 20)}...' : oldTotal}" → '
                '"${fullText.length > 20 ? '${fullText.substring(0, 20)}...' : fullText}"');
            _handleSessionRestart();
            // Now process fullText as the start of a fresh session
            _lastFullText = fullText;
            _lastAppleStart = segmentStart;
            _emitAll();
            return;
          }
        }

        // Detect start-time jump → seal the current running segment
        if (_lastAppleStart >= 0 &&
            _lastFullText.isNotEmpty &&
            (segmentStart - _lastAppleStart).abs() > _startJumpThreshold) {
          _sealCurrentRunning();
          debugPrint('[OnDeviceApple] Start jump: ${_lastAppleStart.toStringAsFixed(1)} → ${segmentStart.toStringAsFixed(1)}, sealed segment');
        }

        _lastFullText = fullText;
        _lastAppleStart = segmentStart;

        // Check if Apple retroactively changed sealed text — if so, redistribute
        _handlePossibleCorrection(fullText);

        if (isFinal) {
          _sealCurrentRunning();
          _emitAll();
          _handleSessionRestart();
          debugPrint('[OnDeviceApple] isFinal, next session at ${_audioOffsetSeconds.toStringAsFixed(1)}s');
        } else {
          _emitAll();
        }
      }
    });
  }

  /// Detect if a new fullText represents an implicit Apple Speech session
  /// restart rather than a retroactive correction.
  ///
  /// Heuristics:
  /// 1. New text is significantly shorter than old accumulated text
  /// 2. New text shares no common prefix with old text (not a minor trim)
  bool _isImplicitRestart(String oldText, String newText) {
    if (oldText.isEmpty) return false;

    // If new text is longer or equal, it's not a restart
    if (newText.length >= oldText.length) return false;

    // Check common prefix length
    int commonPrefix = 0;
    final minLen = newText.length < oldText.length ? newText.length : oldText.length;
    for (int i = 0; i < minLen; i++) {
      if (newText[i] == oldText[i]) {
        commonPrefix++;
      } else {
        break;
      }
    }

    // If the new text shares less than half its length as a common prefix
    // with the old text, AND old text was substantially longer, it's a restart.
    // For very short texts (1-2 chars), any prefix mismatch is suspicious.
    if (commonPrefix == 0 && oldText.length >= 2) {
      return true;
    }

    // New text is less than half the old text and has very little overlap
    if (newText.length < oldText.length * 0.5 && commonPrefix < newText.length * 0.5) {
      return true;
    }

    return false;
  }

  /// Reset state for a new Apple Speech session, preserving sealed segments
  /// so previously recognized text is not lost.
  void _handleSessionRestart() {
    // Seal any current running text before resetting
    if (_lastFullText.isNotEmpty) {
      final runningText = _getRunningText(_lastFullText);
      if (runningText.isNotEmpty) {
        _sealCurrentRunning();
      }
    }

    _sealedSegments.clear();
    _sealedCharCount = 0;
    _lastFullText = '';
    _lastAppleStart = -1;
    _runningStartOffset = _audioOffsetSeconds;
    _lastSealedEnd = _audioOffsetSeconds;  // Update last sealed end on session restart
    _runningId = 'ondevice_p$_segmentIndex';
  }

  /// Seal the current running text into a permanent segment.
  ///
  /// Detects long silence periods (> 2 minutes) between the last sealed segment
  /// and the current running segment, and resets timestamp offsets to prevent
  /// incorrect conversation duration calculation. This matches the behavior of
  /// cloud STT where the backend auto-flushes conversations after 120 seconds.
  void _sealCurrentRunning() {
    final runningText = _getRunningText(_lastFullText);
    if (runningText.isEmpty) return;

    _segmentIndex++;
    final start = _runningStartOffset;
    final end = _audioOffsetSeconds;

    // Calculate the actual silence gap between the last sealed segment and
    // the current one. If this is the first segment, use start (which would
    // be the initial offset from recording start to first speech).
    final silenceGap = start - _lastSealedEnd;

    // Detect long silence: if the gap between the last speech and current
    // speech exceeds the threshold, the user paused for an extended period.
    // Apple Speech keeps returning timestamps relative to the recording start,
    // so without this reset, a few seconds of speech after hours of silence
    // would show an incorrect conversation duration.
    if (silenceGap > _longSilenceThreshold) {
      debugPrint('[OnDeviceApple] Long silence gap detected: ${silenceGap.toStringAsFixed(1)}s between last segment (${_lastSealedEnd.toStringAsFixed(1)}s) and current (${start.toStringAsFixed(1)}s)');
      debugPrint('[OnDeviceApple] Backend should have auto-flushed previous conversation via 120s timeout.');
      debugPrint('[OnDeviceApple] Resetting offsets for new conversation.');

      // Clear old sealed segments — they belong to a previous conversation
      // that should have been flushed by the backend's 120s timeout.
      // Keeping them would mix timestamps from different conversations.
      if (_sealedSegments.isNotEmpty) {
        debugPrint('[OnDeviceApple] Clearing ${_sealedSegments.length} old sealed segments from previous conversation.');
        _sealedSegments.clear();
        _sealedCharCount = 0;
      }

      // Calculate actual speech duration (estimated from text length)
      final estimatedSpeechDuration = runningText.length * 0.1; // ~0.1s per character
      final segmentDuration = estimatedSpeechDuration.clamp(1.0, 10.0);

      // Add the current segment starting from 0 (new conversation)
      _sealedSegments.add(_SealedSegment(
        id: _runningId,
        text: runningText,
        start: 0.0,
        end: segmentDuration,
      ));

      // Reset offsets for next segment
      _audioOffsetSeconds = segmentDuration;
      _runningStartOffset = segmentDuration;
      _lastSealedEnd = segmentDuration;

      debugPrint('[OnDeviceApple] Sealed with reset: "$runningText" (0.0s-${segmentDuration.toStringAsFixed(1)}s).');
    } else {
      // Normal seal without reset
      final segmentEnd = end > start ? end : start + 1.0;
      _sealedSegments.add(_SealedSegment(
        id: _runningId,
        text: runningText,
        start: start,
        end: segmentEnd,
      ));
      _lastSealedEnd = segmentEnd;
      debugPrint('[OnDeviceApple] Sealed #$_segmentIndex: "$runningText" (${start.toStringAsFixed(1)}s-${segmentEnd.toStringAsFixed(1)}s)');
    }

    _sealedCharCount = _lastFullText.length;

    // Rotate to next ID
    _runningId = 'ondevice_p$_segmentIndex';
    _runningStartOffset = _audioOffsetSeconds;
  }

  /// When Apple Speech retroactively changes text that's already been sealed,
  /// update sealed segment texts to match the corrected fullText.
  ///
  /// Strategy: keep segment boundaries (IDs, timestamps) but re-slice the
  /// corrected fullText across segments.  Each segment keeps its proportional
  /// share of characters.  If a segment would end up empty (due to large
  /// corrections shortening the text), it retains its old text to avoid data
  /// loss — the next `isFinal` reset will clean up any drift.
  void _handlePossibleCorrection(String fullText) {
    if (_sealedSegments.isEmpty) return;

    // Rebuild what we think the sealed portion of fullText should be
    final sealedText = _sealedSegments.map((s) => s.text).join();

    // If fullText starts with exactly the sealed text, no correction happened
    if (fullText.length >= sealedText.length &&
        fullText.substring(0, sealedText.length) == sealedText) {
      return;
    }

    // Apple changed something in the sealed region.
    final totalSealedChars = sealedText.length;
    if (totalSealedChars == 0) return;

    // How many characters in fullText belong to the sealed region.
    // Use the old sealed length as the target, clamped to what's available.
    final availableForSealed = fullText.length;
    final targetSealedLen = totalSealedChars.clamp(0, availableForSealed);

    int consumed = 0;
    bool anyChanged = false;

    for (int i = 0; i < _sealedSegments.length; i++) {
      final seg = _sealedSegments[i];
      final oldLen = seg.text.length;

      int newLen;
      if (i == _sealedSegments.length - 1) {
        // Last segment absorbs the remainder
        newLen = targetSealedLen - consumed;
      } else {
        // Proportional share: (oldLen / totalSealedChars) * targetSealedLen
        newLen = (oldLen * targetSealedLen / totalSealedChars).round();
        // Don't exceed what's left
        newLen = newLen.clamp(0, targetSealedLen - consumed);
      }

      // Safety: never let a segment become empty — keep old text instead
      if (newLen <= 0) {
        debugPrint('[OnDeviceApple] Correction would empty segment ${seg.id}, keeping old text');
        continue;
      }

      if (consumed + newLen > availableForSealed) {
        newLen = (availableForSealed - consumed).clamp(0, availableForSealed);
      }
      if (newLen <= 0) continue;

      final newText = fullText.substring(consumed, consumed + newLen);
      if (newText != seg.text) {
        seg.text = newText;
        anyChanged = true;
      }
      consumed += newLen;
    }

    _sealedCharCount = consumed;

    if (anyChanged) {
      debugPrint('[OnDeviceApple] Retroactive correction: updated ${_sealedSegments.length} sealed segments, consumed $consumed chars');
    }
  }

  /// Extract the running (not-yet-sealed) portion of fullText.
  String _getRunningText(String fullText) {
    if (fullText.length <= _sealedCharCount) return '';
    return fullText.substring(_sealedCharCount).trim();
  }

  /// Emit all sealed segments + current running segment.
  /// The client uses ID-based updateSegments() to replace in-place.
  void _emitAll() {
    final segments = <SttSegment>[];

    // Sealed segments — always re-emit so corrections propagate
    for (final seg in _sealedSegments) {
      if (seg.text.trim().isEmpty) continue;
      segments.add(SttSegment(
        id: seg.id,
        text: seg.text,
        start: seg.start,
        end: seg.end,
        speakerId: 0,
      ));
    }

    // Running segment
    final runningText = _getRunningText(_lastFullText);
    if (runningText.isNotEmpty) {
      final runningEnd = _audioOffsetSeconds;
      segments.add(SttSegment(
        id: _runningId,
        text: runningText,
        start: _runningStartOffset,
        end: runningEnd > _runningStartOffset ? runningEnd : _runningStartOffset + 1.0,
        speakerId: 0,
      ));
    }

    if (segments.isEmpty) return;

    _resultController?.add(SttTranscriptionResult(
      segments: segments,
      rawText: _lastFullText,
    ));
  }

  Future<void> _startNativeStreaming() async {
    try {
      String effectiveLanguage = language;
      if (effectiveLanguage == 'multi') {
        effectiveLanguage = 'en';
      }

      _sealedSegments.clear();
      _sealedCharCount = 0;
      _lastFullText = '';
      _lastAppleStart = -1;
      _runningStartOffset = _audioOffsetSeconds;
      _lastSealedEnd = _audioOffsetSeconds;

      await _channel.invokeMethod('startStreaming', {
        'language': effectiveLanguage,
        'sampleRate': sampleRate,
      });
      _isStreaming = true;
      debugPrint('[OnDeviceApple] Streaming started (lang: $effectiveLanguage, rate: $sampleRate)');
    } catch (e) {
      debugPrint('[OnDeviceApple] Failed to start streaming: $e');
      _isStreaming = false;
    }
  }

  Future<void> appendAudio(Uint8List pcmData) async {
    if (!_isStreaming) return;

    try {
      await _channel.invokeMethod('appendAudio', {
        'audioData': pcmData,
        'sampleRate': sampleRate,
      });
    } catch (e) {}
  }

  void updateAudioOffset(double offset) {
    _audioOffsetSeconds = offset;
  }

  @override
  Future<SttTranscriptionResult?> transcribe(
    Uint8List audioData, {
    double audioOffsetSeconds = 0,
    String? language,
  }) async {
    return null;
  }

  Future<void> stopStreaming() async {
    if (!_isStreaming) return;
    try {
      await _channel.invokeMethod('stopStreaming');
    } catch (e) {
      debugPrint('[OnDeviceApple] Error stopping streaming: $e');
    }
    _isStreaming = false;
    _sealedSegments.clear();
    _sealedCharCount = 0;
    _lastFullText = '';
    _lastAppleStart = -1;
    _lastSealedEnd = 0;
    _channel.setMethodCallHandler(null);
  }

  @override
  void dispose() {
    stopStreaming();
    _resultController?.close();
    _resultController = null;
  }
}

class _SealedSegment {
  final String id;
  String text;
  final double start;
  double end;

  _SealedSegment({
    required this.id,
    required this.text,
    required this.start,
    required this.end,
  });
}
