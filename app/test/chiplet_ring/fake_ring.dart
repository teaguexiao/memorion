import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:memorion/services/devices/chiplet_ring/health.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/services/devices/chiplet_ring/bridge.dart';
import 'package:memorion/services/devices/chiplet_ring/import_store.dart';
import 'package:memorion/services/devices/chiplet_ring/models.dart';
import 'package:memorion/services/devices/chiplet_ring/sync_controller.dart';

/// Synthetic PCM tone; no real person's audio, radio or network is used.
Future<File> syntheticWave(Directory root, {int seconds = 6, String name = 'source.wav'}) async {
  final length = seconds * 16000;
  final data = ByteData(44 + length);
  void text(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, length + 36, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, length, Endian.little);
  for (var i = 44; i < data.lengthInBytes; i += 2) {
    data.setInt16(i, (i ~/ 2 % 40 < 20 ? 1000 : -1000), Endian.little);
  }
  return File('${root.path}/$name').writeAsBytes(data.buffer.asUint8List(), flush: true);
}

RingRecording fixtureRecording(int i, {String type = '8', bool dated = true}) => RingRecording(
    name: 'fixture-$i.bin',
    size: 24000,
    type: type,
    deviceDate: 'raw-date-$i',
    startedAt: dated ? DateTime.utc(2026, 11, 1, 12).subtract(Duration(minutes: i)) : null);

class FakeRingTransport extends RingTransport {
  final Directory root;
  final stream = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  List<RingRecording> directory = [];
  int downloads = 0, disconnects = 0, starts = 0, failures = 0;
  int erases = 0, storageFailures = 0;
  int batteryLevel = 76;
  int batteryReads = 0;
  bool transportBusy = false;
  @override
  bool get busy => transportBusy || timer?.isActive == true;
  Completer<void>? batteryGate;
  int feedbackConfigurations = 0, healthReads = 0;
  bool failFeedback = false;
  Object? healthError;
  Completer<void>? healthGate;
  RingHealthSnapshot health = RingHealthSnapshot(0, {});
  Completer<void>? clockGate;
  bool failClock = false;
  int clockWrites = 0;
  @override
  Future<DateTime> synchronizeClock(Duration timezoneOffset) async {
    clockWrites++;
    await clockGate?.future;
    if (failClock) throw const FormatException('Injected clock failure');
    return DateTime.utc(2026, 11, 17, 8);
  }

  @override
  Future<Map<String, int>> configureRecordingFeedback() async {
    feedbackConfigurations++;
    if (failFeedback) throw StateError('Injected feedback mismatch');
    return {'start': 2, 'stop': 2};
  }

  @override
  Future<RingHealthSnapshot> healthSnapshot() async {
    healthReads++;
    await healthGate?.future;
    if (healthError != null) throw healthError!;
    return health;
  }

  bool failStorage = false, failErase = false, ineffectiveErase = false;
  Completer<void>? storageGate;
  bool shortRecording = false;
  Completer<void>? downloadGate, metadataGate;
  Timer? timer;
  int duration = 0;
  FakeRingTransport(this.root);
  @override
  Stream<Map<String, dynamic>> get events => stream.stream;
  @override
  Future<void> connect(String id) async {}
  @override
  Future<void> disconnect() async {
    disconnects++;
    timer?.cancel();
    stream.add({'event': 'connection', 'id': 'ring-fixture', 'connected': false});
  }

  @override
  Future<int> battery() async {
    batteryReads++;
    final value = batteryLevel;
    await batteryGate?.future;
    return value;
  }

  @override
  Future<String> firmware() async {
    await metadataGate?.future;
    return '6.0.1.8z62';
  }

  @override
  Future<String> hardware() async => '603v1.23.2';
  @override
  Future<List<RingRecording>> files() async => List.of(directory);
  @override
  Future<Map<String, int>> storageInfo() async {
    await storageGate?.future;
    if (storageFailures > 0) {
      storageFailures--;
      throw StateError('Injected transient storage failure');
    }
    if (failStorage) throw StateError('Injected storage failure');
    final used = directory.fold(0, (sum, file) => sum + file.size);
    return {'total': 16777216, 'used': used, 'free': 16777216 - used};
  }

  @override
  Future<void> clearDeviceFiles({required bool confirmed}) async {
    if (!confirmed) throw StateError('Unconfirmed erase');
    erases++;
    if (failErase) throw StateError('Injected erase failure');
    if (!ineffectiveErase) directory = [];
  }

  @override
  Future<({File file, Duration duration})> download(RingRecording recording) async {
    downloads++;
    await downloadGate?.future;
    if (failures > 0) {
      failures--;
      throw StateError('Injected interrupted transfer');
    }
    stream.add({'event': 'progress', 'name': recording.name, 'bytes': 24000});
    return (file: await syntheticWave(root, name: 'transfer-$downloads.wav'), duration: const Duration(seconds: 6));
  }

  @override
  Future<void> startRecording() async {
    starts++;
    duration = 0;
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      duration++;
      stream.add({'event': 'recording', 'durationMs': duration * 1000});
    });
  }

  @override
  Future<({File file, Duration duration})> stopRecording() async {
    timer?.cancel();
    final seconds = shortRecording ? 2 : duration.clamp(6, 100);
    return (
      file: await syntheticWave(root, seconds: seconds, name: 'live-$starts.wav'),
      duration: Duration(seconds: seconds)
    );
  }

  Future<void> close() async {
    timer?.cancel();
    await stream.close();
  }
}

class RingHarness {
  final Directory root;
  late final FakeRingTransport peer;
  late final RingImportStore store;
  late final RingSyncController sync;
  String owner = 'alice';
  bool connected = true, failLookup = false, processing = false, blockUpload = false;
  int uploads = 0, lookups = 0, retries = 0, quotaFailures = 0;
  Completer<void>? uploadGate;
  final cloud = <String, AudioRecordingUploadState>{};
  RingHarness(this.root) {
    peer = FakeRingTransport(root);
    store = RingImportStore(
        root: root,
        owner: 'alice',
        deviceId: 'ring-fixture',
        currentOwner: () => owner,
        upload: (file, time, id, progress) async {
          uploads++;
          await uploadGate?.future;
          if (quotaFailures > 0) {
            quotaFailures--;
            throw const AudioUploadFailure(AudioUploadIssue.quota);
          }
          progress?.call(await file.length(), await file.length());
          cloud[id] = state(conversation: 'conversation-$id', processing: processing);
          return RingReceipt('conversation-$id', processing: processing);
        });
    sync = RingSyncController(
        openTransport: () async => connected ? peer : null,
        openStore: () async => store,
        isCurrentOwner: () => owner == 'alice',
        lookup: (files) async {
          lookups++;
          if (failLookup) throw StateError('Cloud lookup offline');
          return {for (final file in files) file.id: cloud[file.id] ?? state(canUpload: !blockUpload)};
        },
        retryJob: (id) async {
          retries++;
        },
        reconnectTransport: () async {
          connected = true;
        });
  }
  static AudioRecordingUploadState state(
          {bool canUpload = true, String? conversation, bool processing = false, AudioProcessingJob? job}) =>
      AudioRecordingUploadState.fromJson({
        'can_upload': canUpload,
        'conversation_id': conversation,
        'processing': processing,
        'duration_seconds': 6,
        if (job != null)
          'job': {
            'id': job.id,
            'conversation_id': job.conversationId,
            'status': job.status,
            'stage': job.stage,
            'started_at': job.startedAt.toIso8601String(),
            'can_retry': job.canRetry
          }
      });
  Future<void> close() async {
    sync.dispose();
    await peer.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
