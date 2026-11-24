import 'dart:typed_data';
import 'dart:io';

const maxOfflineRecordingDuration = Duration(hours: 8);

/// A complete device stream exceeded the supported import duration. It is
/// distinct from a truncated/corrupt stream and carries no partial audio.
class OfflineRecordingTooLong implements Exception {
  final Duration duration;
  const OfflineRecordingTooLong(this.duration);
}

class OfflineRecording {
  final int id;
  final int endTime;

  /// Duration hint in milliseconds, never a trusted byte count.
  final int reportedSize;
  const OfflineRecording(this.id, this.endTime, this.reportedSize);

  DateTime get startedAt => DateTime.fromMillisecondsSinceEpoch(id * 1000, isUtc: true);

  /// Adapted from recording-bean-web (MIT). Some firmware returns stale end
  /// times; prefer the clock only when it agrees with the duration-like field.
  Duration? get estimatedDuration {
    final sizeEstimate = reportedSize > 0 ? reportedSize : null;
    if (endTime > id) {
      final clockEstimate = (endTime - id) * 1000;
      if (sizeEstimate == null || (clockEstimate / sizeEstimate >= 0.5 && clockEstimate / sizeEstimate <= 2)) {
        return Duration(milliseconds: clockEstimate);
      }
    }
    return sizeEstimate == null ? null : Duration(milliseconds: sizeEstimate);
  }

  bool hasValidTimestamp(DateTime now) =>
      startedAt.isAfter(DateTime.utc(2020)) && !startedAt.isAfter(now.toUtc().add(const Duration(minutes: 5)));
}

/// A complete transfer. Soundcore owns a temporary file; smaller device adapters
/// may still supply bytes. Consumers must dispose after caching, even on error.
class OfflineDownload {
  final Uint8List? ogg;
  final File? file;
  final Duration duration;
  const OfflineDownload(Uint8List bytes, this.duration)
      : ogg = bytes,
        file = null;

  /// [file] must be the only file in a newly created, owned temporary directory.
  const OfflineDownload.temporaryFile(File ownedFile, this.duration)
      : file = ownedFile,
        ogg = null;

  Future<Uint8List> readBytes() async => ogg ?? await file!.readAsBytes();

  Future<void> writeTo(File target) async {
    if (ogg != null) {
      await target.writeAsBytes(ogg!, flush: true);
      return;
    }
    final sink = target.openWrite();
    try {
      await sink.addStream(file!.openRead());
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<void> dispose() async {
    if (file == null) return;
    if (await file!.exists()) await file!.delete();
    if (await file!.parent.exists()) await file!.parent.delete();
  }
}
