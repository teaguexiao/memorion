import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'models.dart';
import 'health.dart';

abstract class RingTransport {
  bool get busy => false;
  Stream<Map<String, dynamic>> get events;
  Future<void> connect(String id);
  Future<void> disconnect();
  Future<int> battery();
  Future<String> firmware();
  Future<String> hardware();
  // i18n-ignore: Internal diagnostic is mapped to localized guide feedback.
  Future<DateTime> synchronizeClock(Duration timezoneOffset) => throw UnsupportedError('Ring clock unavailable');
  Future<List<RingRecording>> files();
  // i18n-ignore: Transport diagnostics are mapped to localized UI copy.
  Future<Map<String, int>> configureRecordingFeedback() => throw UnsupportedError('Ring feedback unavailable');
  // i18n-ignore: Transport diagnostics are mapped to localized UI copy.
  Future<RingHealthSnapshot> healthSnapshot() => throw UnsupportedError('Ring health unavailable');
  // i18n-ignore: Internal transport error; the storage card presents localized feedback.
  Future<Map<String, int>> storageInfo() => throw UnsupportedError('Ring storage unavailable');
  // i18n-ignore: Internal transport error; the storage card presents localized feedback.
  Future<void> clearDeviceFiles({required bool confirmed}) => throw UnsupportedError('Ring erase unavailable');
  Future<({File file, Duration duration})> download(RingRecording recording);
  Future<void> startRecording();
  Future<({File file, Duration duration})> stopRecording();
  Future<void> releaseAudio(File file) async {}
}

class NativeRingTransport implements RingTransport {
  static final instance = NativeRingTransport();
  final MethodChannel channel;
  late final Stream<Map<String, dynamic>> _events;
  Future<void> _tail = Future.value();
  int _epoch = 0;
  int _commands = 0;
  bool _capturing = false;
  final _ownedAudio = <String>{};
  NativeRingTransport(
      {this.channel = const MethodChannel('memorion/chiplet_ring'), Stream<Map<String, dynamic>>? eventStream}) {
    _events = (eventStream ??
            const EventChannel('memorion/chiplet_ring/events')
                .receiveBroadcastStream()
                .map((event) => Map<String, dynamic>.from(event as Map)))
        .map((event) {
      if (event['event'] == 'captureError' || (event['event'] == 'connection' && event['connected'] == false)) {
        _capturing = false;
      }
      return event;
    });
  }
  static bool get available => Platform.isIOS;
  @override
  Stream<Map<String, dynamic>> get events => _events;
  @override
  bool get busy => _commands > 0 || _capturing;
  Future<T?> _command<T>(String method, [Map<String, dynamic>? args]) {
    final epoch = _epoch;
    _commands++;
    final result = _tail.then((_) async {
      if (epoch != _epoch) throw StateError('Ring connection replaced');
      try {
        final value = await channel.invokeMethod<T>(method, args);
        if (epoch != _epoch) throw StateError('Ring connection replaced');
        return value;
      } finally {
        // The vendor requires spacing even when a command fails. Disconnect
        // invalidates queued work immediately and needs no old-session delay.
        if (epoch == _epoch) await Future<void>.delayed(const Duration(milliseconds: 300));
        if (epoch != _epoch) throw StateError('Ring connection replaced');
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result.whenComplete(() => _commands--);
  }

  Future<void> scan() => channel.invokeMethod<void>('scan');
  Future<void> stopScan() => channel.invokeMethod<void>('stopScan');
  @override
  Future<void> connect(String id) async => _command<void>('connect', {'id': id});
  @override
  Future<void> disconnect() async {
    _epoch++;
    _capturing = false;
    await channel.invokeMethod<void>('disconnect');
  }

  @override
  Future<int> battery() async => (await _command<int>('battery')) ?? -1;
  @override
  Future<String> firmware() async => (await _command<String>('firmware')) ?? 'Unknown';
  @override
  Future<String> hardware() async => (await _command<String>('hardware')) ?? 'Unknown';

  @override
  Future<DateTime> synchronizeClock(Duration timezoneOffset) async {
    final minutes = timezoneOffset.inMinutes;
    if (minutes % 60 != 0 || minutes < -720 || minutes > 840) {
      throw const FormatException('Ring clock supports only whole-hour time zones'); // i18n-ignore: Localized by guide.
    }
    final value = await _command<Map>('synchronizeClock', {'timezoneMinutes': minutes});
    final milliseconds = value?['milliseconds'];
    if (milliseconds is! int ||
        value?['timezoneMinutes'] != minutes ||
        milliseconds < 1577836800000 ||
        milliseconds >= 4102444800000) {
      throw const FormatException('Invalid ring clock readback'); // i18n-ignore: Localized by guide.
    }
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }

  @override
  Future<Map<String, int>> configureRecordingFeedback() async {
    final value = await _command<Map>('configureRecordingFeedback');
    if (value == null || value['start'] != 2 || value['stop'] != 2) {
      throw const FormatException(
          'Ring recording feedback was not configured'); // i18n-ignore: Internal diagnostic localized by recording page.
    }
    return {'start': 2, 'stop': 2, 'readbackVerified': value['readbackVerified'] == 1 ? 1 : 0};
  }

  @override
  Future<RingHealthSnapshot> healthSnapshot() async {
    final value = await _command<Map>('healthSnapshot');
    if (value == null) throw const FormatException('Missing ring health snapshot');
    return RingHealthSnapshot.fromNative(value);
  }

  /// Capacity counters in bytes, verified against the 603/Z62 physical device.
  @override
  Future<Map<String, int>> storageInfo() async {
    final value = await _command<Map>('storageInfo');
    // i18n-ignore: Internal diagnostic, never displayed directly in product UI.
    if (value == null) throw const FormatException('Missing ring storage information');
    return {
      for (final key in ['total', 'used', 'free']) key: (value[key] as num).toInt()
    };
  }

  /// Irreversible device operation. Call only after explicit user confirmation.
  @override
  Future<void> clearDeviceFiles({required bool confirmed}) async {
    // i18n-ignore: Internal diagnostic; product UI provides the confirmation.
    if (!confirmed) throw ArgumentError('Device file deletion was not confirmed');
    await _command<void>('formatFileSystem', {'confirmed': true});
  }

  @override
  Future<List<RingRecording>> files() async {
    final values = await _command<List>('files');
    if (values == null) throw const FormatException('Missing ring directory');
    return values.map((value) => RingRecording.fromNative(value as Map)).toList();
  }

  Future<({File file, Duration duration})> _audio(String command, [Map<String, dynamic>? args]) async {
    final value = await _command<Map>(command, args);
    // i18n-ignore: Internal diagnostic; the page maps exceptions to bilingual copy.
    if (value == null) throw const FormatException('Missing completed ring audio');
    final file = File(value['path'] as String);
    if (file.path.endsWith('.part')) throw const FormatException('Incomplete ring audio');
    _ownedAudio.add(file.path);
    return (file: file, duration: Duration(milliseconds: value['durationMs'] as int));
  }

  @override
  Future<({File file, Duration duration})> download(RingRecording recording) =>
      _audio('download', {'name': recording.name, 'type': recording.type, 'size': recording.size});
  @override
  Future<void> startRecording() async {
    await _command<void>('startRecording');
    _capturing = true;
  }

  @override
  Future<({File file, Duration duration})> stopRecording() async {
    try {
      return await _audio('stopRecording');
    } finally {
      _capturing = false;
    }
  }

  @override
  Future<void> releaseAudio(File file) async {
    if (!_ownedAudio.remove(file.path)) return;
    // i18n-ignore: Temporary directory prefix, never displayed.
    if (file.parent.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith('memorion-ring-')) {
      try {
        await file.parent.delete(recursive: true);
      } catch (_) {}
    }
  }

  static BtDevice discovered(Map value) {
    final id = value['id'] as String;
    cachedDevicesMap[id] = DeviceType.chipletRing;
    return BtDevice(
        id: id,
        name: value['name'] as String? ?? 'ChipletRing',
        type: DeviceType.chipletRing,
        rssi: (value['rssi'] as num?)?.toInt() ?? -100);
  }
}
