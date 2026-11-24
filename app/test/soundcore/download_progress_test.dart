import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/soundcore/download_progress.dart';

void main() {
  final start = DateTime.utc(2026, 9, 16);
  test('audio slots and elapsed transfer time estimate fraction and remaining time', () {
    final progress = SoundcoreDownloadEstimator(duration: const Duration(seconds: 60), startedAt: start);
    expect(progress.estimate(start).fraction, 0);
    expect(progress.estimate(start).remaining, isNull);
    progress.update(240000, start.add(const Duration(seconds: 10)));
    final estimate = progress.estimate(start.add(const Duration(seconds: 10)));
    expect(estimate.fraction, 0.5);
    expect(estimate.remaining, const Duration(seconds: 10));
  });

  test('short startup, stalled transport and missing duration do not invent an ETA', () {
    final progress = SoundcoreDownloadEstimator(duration: const Duration(seconds: 60), startedAt: start);
    progress.update(8000, start.add(const Duration(seconds: 1)));
    expect(progress.estimate(start.add(const Duration(seconds: 1))).remaining, isNull);
    final stalled = progress.estimate(start.add(const Duration(seconds: 6)));
    expect(stalled.waitingForData, isTrue);
    expect(stalled.remaining, isNull);
    expect(stalled.fraction, closeTo(1 / 60, 0.0001));
    final unknown = SoundcoreDownloadEstimator(duration: null, startedAt: start);
    unknown.update(240000, start.add(const Duration(seconds: 10)));
    expect(unknown.estimate(start.add(const Duration(seconds: 10))).fraction, isNull);
    expect(unknown.estimate(start.add(const Duration(seconds: 10))).remaining, isNull);
  });

  test('underestimated length never declares 100% or zero seconds remaining', () {
    final progress = SoundcoreDownloadEstimator(duration: const Duration(seconds: 1), startedAt: start);
    progress.update(16000, start.add(const Duration(seconds: 2)));
    expect(progress.estimate(start.add(const Duration(seconds: 2))).fraction, 0.99);
    expect(progress.estimate(start.add(const Duration(seconds: 2))).remaining, isNull);
  });

  test('eight-hour directory estimate gives progress but over-limit estimates do not', () {
    final progress = SoundcoreDownloadEstimator(duration: const Duration(hours: 8), startedAt: start);
    progress.update(115200000, start.add(const Duration(seconds: 10)));
    expect(progress.estimate(start.add(const Duration(seconds: 10))).fraction, 0.5);
    final overlong = SoundcoreDownloadEstimator(duration: const Duration(hours: 9), startedAt: start);
    expect(overlong.estimate(start).fraction, isNull);
  });

  test('recent speed replaces an obsolete slow period', () {
    final progress = SoundcoreDownloadEstimator(duration: const Duration(seconds: 60), startedAt: start);
    for (var second = 1; second <= 30; second++) {
      final bytes = second <= 10 ? second * 1000 : 10000 + (second - 10) * 10000;
      progress.update(bytes, start.add(Duration(seconds: second)));
    }
    // 480 KB total, 210 KB received, recent 10 KB/s => about 27 seconds.
    expect(progress.estimate(start.add(const Duration(seconds: 30))).remaining, const Duration(seconds: 27));
  });
}
