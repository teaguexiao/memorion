import '../offline_recordings/models.dart';

/// A duration-based estimate, never a declaration that the file is complete.
class SoundcoreDownloadEstimate {
  final double? fraction;
  final Duration? remaining;
  final bool waitingForData;

  const SoundcoreDownloadEstimate({this.fraction, this.remaining, this.waitingForData = false});
}

/// Session progress counts decrypted 160-byte slots, each containing 20 ms of
/// audio. Device list sizes are duration-like values, not byte counts or Ogg
/// sizes. Keep the estimate in those same slot units for both BLE and Wi-Fi.
class SoundcoreDownloadEstimator {
  final int? _expectedBytes;
  final List<(DateTime, int)> _samples;
  DateTime _lastDataAt;
  int _bytes = 0;

  SoundcoreDownloadEstimator({required Duration? duration, required DateTime startedAt})
      : this.bytes(
            expectedBytes: duration != null && duration > Duration.zero && duration <= maxOfflineRecordingDuration
                ? ((duration.inMicroseconds + 19999) ~/ 20000) * 160
                : null,
            startedAt: startedAt);

  SoundcoreDownloadEstimator.bytes({required int? expectedBytes, required DateTime startedAt})
      : _expectedBytes = expectedBytes,
        _samples = [(startedAt, 0)],
        _lastDataAt = startedAt;

  void update(int bytes, DateTime at) {
    if (bytes <= _bytes) return;
    _bytes = bytes;
    _lastDataAt = at;
    if (at.isBefore(_samples.last.$1)) _samples.clear();
    if (_samples.isEmpty || at.difference(_samples.last.$1) >= const Duration(milliseconds: 250)) {
      _samples.add((at, bytes));
    }
    final cutoff = at.subtract(const Duration(seconds: 10));
    while (_samples.length > 2 && _samples[1].$1.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  SoundcoreDownloadEstimate estimate(DateTime at) {
    final expected = _expectedBytes;
    final fraction = expected == null ? null : (_bytes / expected).clamp(0.0, 0.99);
    final waiting = at.difference(_lastDataAt) >= const Duration(seconds: 5);
    final elapsed = at.difference(_samples.first.$1).inMilliseconds;
    final recentBytes = _bytes - _samples.first.$2;
    Duration? remaining;
    if (!waiting && expected != null && _bytes < expected && elapsed >= 2000 && recentBytes > 0) {
      remaining = Duration(milliseconds: ((expected - _bytes) * elapsed / recentBytes).ceil());
    }
    return SoundcoreDownloadEstimate(fraction: fraction, remaining: remaining, waitingForData: waiting);
  }
}
