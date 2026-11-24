import 'dart:convert';
import 'package:crypto/crypto.dart';

/// File identity never doubles as a timestamp; multiple recordings can start
/// in the same second. Vendor file names/extensions are not audio codecs.
class RingRecording {
  final String name;
  final int size;
  final String type;
  final String deviceDate;
  final DateTime? startedAt;
  const RingRecording(
      {required this.name, required this.size, required this.type, this.deviceDate = '', this.startedAt});
  String get id => sha256.convert(utf8.encode(jsonEncode([name, size, type, deviceDate]))).toString();
  bool get supported => {'8', 'B', 'D', 'LOCAL'}.contains(type);

  /// Calendar fields reported by the ring, for display/confirmation only.
  /// Z62 filenames have no time zone and its clock may be wrong. Showing them
  /// must never make an old recording eligible for upload without confirmation.
  DateTime? get unverifiedDeviceTime {
    final match = RegExp(r'^(\d{4})[-_](\d{2})[-_](\d{2})[T _:](\d{2}):(\d{2}):(\d{2})$').firstMatch(deviceDate);
    if (match == null) return null;
    final fields = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
    if (fields[0] < 2020 || fields[0] >= 2100) return null;
    final time = DateTime.utc(fields[0], fields[1], fields[2], fields[3], fields[4], fields[5]);
    if (time.year != fields[0] ||
        time.month != fields[1] ||
        time.day != fields[2] ||
        time.hour != fields[3] ||
        time.minute != fields[4] ||
        time.second != fields[5]) {
      return null;
    }
    return time;
  }

  RingRecording withTime(DateTime value) =>
      RingRecording(name: name, size: size, type: type, deviceDate: deviceDate, startedAt: value.toUtc());
  Map<String, dynamic> toJson() =>
      {'name': name, 'size': size, 'type': type, 'date': deviceDate, 'startedAt': startedAt?.toUtc().toIso8601String()};
  factory RingRecording.fromJson(Map<String, dynamic> value) => RingRecording(
      name: value['name'] as String,
      size: value['size'] as int,
      type: value['type'] as String,
      deviceDate: value['date'] as String? ?? '',
      startedAt: DateTime.tryParse(value['startedAt'] as String? ?? ''));
  factory RingRecording.fromNative(Map value, {DateTime? now}) {
    final name = value['name'] as String;
    final date = value['date'] as String? ?? '';
    // Only explicit zones are unambiguous. Let users correct unverified clock
    // metadata instead of assigning the phone's current time to old recordings.
    DateTime? time;
    if (RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(date)) time = DateTime.tryParse(date)?.toUtc();
    if (time != null &&
        (time.isBefore(DateTime.utc(2020)) ||
            time.isAfter((now ?? DateTime.now()).toUtc().add(const Duration(minutes: 5))))) {
      time = null;
    }
    return RingRecording(
        name: name,
        size: (value['size'] as num?)?.toInt() ?? 0,
        type: (value['type'] as String? ?? '').toUpperCase(),
        deviceDate: date,
        startedAt: time);
  }
}

enum RingStage { waiting, downloading, downloaded, uploading, processing, completed, failed, unsupported, needsTime }

class RingReceipt {
  final String conversationId;
  final bool processing;
  final String? jobId;
  const RingReceipt(this.conversationId, {required this.processing, this.jobId});
}

class RingDeviceSnapshot {
  final int total, used, free;
  final List<RingRecording> files;
  RingDeviceSnapshot(Map<String, int> capacity, List<RingRecording> directory)
      : total = capacity['total'] ?? 0,
        used = capacity['used'] ?? -1,
        free = capacity['free'] ?? -1,
        files = List.unmodifiable(directory) {
    if (total <= 0 || used < 0 || free < 0 || used + free > total) {
      throw const FormatException('Invalid ring capacity');
    }
  }
  bool get onlyRecordings => files.every((file) => {'8', '9', 'B', 'C', 'D'}.contains(file.type));
}
