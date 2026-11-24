import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'models.dart';

/// Independent cache format: existing Soundcore/A1/PLAUD Ogg stores are untouched.
class RingImportStore {
  final String owner;
  final String Function() currentOwner;
  final Directory directory;
  final Future<RingReceipt> Function(File, DateTime, String, AudioUploadProgress?) upload;
  RingImportStore(
      {required Directory root,
      required this.owner,
      required String deviceId,
      required this.currentOwner,
      required this.upload})
      : directory =
            Directory('${root.path}/chiplet_ring/${sha256.convert(utf8.encode(jsonEncode([owner, deviceId])))}');
  void checkOwner() {
    if (owner.isEmpty || currentOwner() != owner) throw StateError('Ring account changed');
  }

  String _id(String id) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) throw const FormatException('Invalid ring cache id');
    return id;
  }

  File audio(String id) => File('${directory.path}/${_id(id)}.wav');
  File _meta(String id) => File('${directory.path}/${_id(id)}.json');
  Future<Map<String, dynamic>?> metadata(String id) async {
    checkOwner();
    if (!await _meta(id).exists()) return null;
    final value = jsonDecode(await _meta(id).readAsString()) as Map<String, dynamic>;
    if (RingRecording.fromJson(Map<String, dynamic>.from(value['recording'] as Map)).id != id) {
      throw const FormatException('Ring cache identity mismatch');
    }
    checkOwner();
    return value;
  }

  Future<void> save(String id, Map<String, dynamic> value) async {
    checkOwner();
    if (await removed(id)) throw StateError('Ring history removed');
    await directory.create(recursive: true);
    checkOwner();
    final pending = File('${_meta(id).path}.part');
    await pending.writeAsString(jsonEncode(value), flush: true);
    checkOwner();
    if (await removed(id)) {
      await pending.delete();
      throw StateError('Ring history removed');
    }
    await pending.rename(_meta(id).path);
  }

  Future<List<RingRecording>> cached() async {
    checkOwner();
    if (!await directory.exists()) return [];
    final result = <RingRecording>[];
    await for (final file in directory.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final id = file.uri.pathSegments.last.replaceFirst('.json', '');
      if (await removed(id)) continue;
      final data = await metadata(id);
      if (data != null) result.add(RingRecording.fromJson(Map<String, dynamic>.from(data['recording'] as Map)));
    }
    checkOwner();
    return result;
  }

  Future<bool> removed(String id) async {
    checkOwner();
    return File('${directory.path}/${_id(id)}.removed').exists();
  }

  Future<void> remove(String id) async {
    checkOwner();
    _id(id);
    await directory.create(recursive: true);
    checkOwner();
    await File('${directory.path}/$id.removed').writeAsString('', flush: true);
    for (final suffix in ['wav', 'wav.part', 'json', 'json.part']) {
      checkOwner();
      final file = File('${directory.path}/$id.$suffix');
      if (await file.exists()) await file.delete();
    }
  }

  /// Validate actual WAV data length, PCM format and duration without loading
  /// whole recordings. The native SDK supplies only completed files.
  static Future<Duration> validateWave(File file) async {
    final length = await file.length();
    final handle = await file.open();
    try {
      final bytes = await handle.read(44);
      if (bytes.length != 44 ||
          ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
          ascii.decode(bytes.sublist(8, 16), allowInvalid: true) != 'WAVEfmt ' ||
          ascii.decode(bytes.sublist(36, 40), allowInvalid: true) != 'data') {
        throw const FormatException('Invalid ring WAV');
      }
      final data = ByteData.sublistView(bytes);
      final rate = data.getUint32(24, Endian.little);
      final channels = data.getUint16(22, Endian.little);
      final size = data.getUint32(40, Endian.little);
      if (data.getUint16(20, Endian.little) != 1 ||
          data.getUint16(34, Endian.little) != 16 ||
          !{8000, 16000}.contains(rate) ||
          !{1, 2}.contains(channels) ||
          data.getUint32(16, Endian.little) != 16 ||
          data.getUint16(32, Endian.little) != channels * 2 ||
          data.getUint32(28, Endian.little) != rate * channels * 2 ||
          data.getUint32(4, Endian.little) != length - 8 ||
          size != length - 44 ||
          size % (channels * 2) != 0) {
        throw const FormatException('Incomplete or unsupported ring WAV');
      }
      final duration = Duration(microseconds: size * 1000000 ~/ (rate * channels * 2));
      if (duration < const Duration(seconds: 5) || duration > const Duration(hours: 8)) {
        // i18n-ignore: Internal validation diagnostic, localized by the page.
        throw const FormatException('Ring recording duration must be 5 seconds to 8 hours');
      }
      return duration;
    } finally {
      await handle.close();
    }
  }

  Future<void> cache(RingRecording recording, File source) async {
    checkOwner();
    if (source.path.endsWith('.part')) throw const FormatException('Incomplete ring file');
    if (await removed(recording.id)) throw StateError('Ring history removed');
    final duration = await validateWave(source);
    checkOwner();
    await directory.create(recursive: true);
    final pending = File('${audio(recording.id).path}.part');
    try {
      final sink = pending.openWrite();
      try {
        await sink.addStream(source.openRead());
        await sink.flush();
      } finally {
        await sink.close();
      }
      await validateWave(pending);
      final digest = (await sha256.bind(pending.openRead()).first).toString();
      checkOwner();
      await pending.rename(audio(recording.id).path);
      final prior = await metadata(recording.id);
      await save(recording.id,
          {...?prior, 'recording': recording.toJson(), 'durationMs': duration.inMilliseconds, 'sha256': digest});
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }

  Future<bool> verifiedAudio(String id) async {
    checkOwner();
    final file = audio(id);
    if (!await file.exists()) return false;
    final data = await metadata(id);
    try {
      await validateWave(file);
      final digest = (await sha256.bind(file.openRead()).first).toString();
      checkOwner();
      if (data == null || digest != data['sha256']) throw const FormatException('Ring cache checksum mismatch');
      return true;
    } on FormatException {
      checkOwner();
      await file.delete();
      return false;
    }
  }

  Future<void> updateTime(RingRecording recording) async {
    final data = await metadata(recording.id);
    if (data?['conversationId'] != null) throw StateError('Already uploaded');
    await save(recording.id, {...?data, 'recording': recording.toJson()});
  }

  Future<void> receipt(RingRecording recording, RingReceipt receipt) async {
    final data = await metadata(recording.id) ?? {'recording': recording.toJson()};
    await save(recording.id,
        {...data, 'conversationId': receipt.conversationId, 'processing': receipt.processing, 'jobId': receipt.jobId});
  }

  Future<RingReceipt> import(RingRecording recording, {AudioUploadProgress? onProgress}) async {
    checkOwner();
    final data = await metadata(recording.id);
    if (data == null) throw StateError('Download first');
    if (data['conversationId'] is String) {
      return RingReceipt(data['conversationId'] as String,
          processing: data['processing'] == true, jobId: data['jobId'] as String?);
    }
    final time = recording.startedAt;
    if (time == null ||
        time.isBefore(DateTime.utc(2020)) ||
        time.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 5)))) {
      // i18n-ignore: Internal validation diagnostic, localized by the page.
      throw const FormatException('Confirm recording time first');
    }
    final file = audio(recording.id);
    await validateWave(file);
    final digest = (await sha256.bind(file.openRead()).first).toString();
    if (digest != data['sha256']) throw const FormatException('Ring cache checksum mismatch');
    checkOwner();
    final result = await upload(file, time, recording.id, onProgress);
    checkOwner();
    if (result.conversationId.isEmpty) throw const FormatException('Missing upload receipt');
    await receipt(recording, result);
    return result;
  }
}
