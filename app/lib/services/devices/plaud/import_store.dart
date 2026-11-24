import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:opus_dart/opus_dart.dart';
import '../offline_recordings/import_store.dart';
import '../offline_recordings/models.dart';
import 'audio.dart';
import 'identity.dart';
import 'protocol.dart';

/// Raw Note files remain encrypted at rest, including unsupported recordings.
/// Only an entirely validated Ogg enters the shared import/receipt pipeline.
class PlaudImportStore extends OfflineImportStore {
  final _preparingPlayback = <int, Future<File?>>{};
  PlaudImportStore(
      {required super.root,
      required super.ownerId,
      required super.deviceId,
      required super.currentOwner,
      super.upload,
      super.uploadWithProgress})
      : super(source: 'plaud');
  void _owner() {
    if (ownerId.isEmpty || ownerId != currentOwner()) throw const PlaudException(PlaudIssue.identityRequired);
  }

  File _manifest(int id) => File('${directory.path}/$id.plaud.json');
  Future<Map<String, dynamic>?> _read(int id) async {
    _owner();
    final file = _manifest(id);
    if (!await file.exists()) return null;
    if (await file.length() > 4096) throw const PlaudException(PlaudIssue.protocol);
    final body = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _owner();
    if (body['id'] != id || body['durationHintMs'] is! int || body['byteSize'] is! int || body['sha256'] is! String) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    return body;
  }

  Future<void> _write(int id, Map<String, dynamic> body) async {
    _owner();
    final pending = File('${_manifest(id).path}.part');
    await pending.writeAsString(jsonEncode(body), flush: true);
    _owner();
    await pending.rename(_manifest(id).path);
  }

  Future<String> _hash(File file) async => (await sha256.bind(file.openRead()).first).toString();

  @override
  Future<List<OfflineRecording>> cachedRecordings() async {
    final all = {for (final r in await super.cachedRecordings()) r.id: r};
    if (!await directory.exists()) return all.values.toList();
    await for (final file in directory.list()) {
      if (file is! File || !file.path.endsWith('.plaud.json')) continue;
      final id = int.tryParse(file.uri.pathSegments.last.split('.').first);
      if (id == null) continue;
      final body = await _read(id);
      if (body != null) all.putIfAbsent(id, () => OfflineRecording(id, 0, body['durationHintMs'] as int));
    }
    _owner();
    return all.values.toList();
  }

  Future<PlaudIssue?> audioIssue(int id) async =>
      (await _read(id))?['issue'] == 'unsupportedAudio' ? PlaudIssue.unsupportedAudio : null;
  Future<void> markAudioIssue(int id, PlaudException error) async {
    final body = await _read(id);
    if (body == null) return;
    body['issue'] = error.issue.name;
    if (error.frameIndex != null) body['frameIndex'] = error.frameIndex;
    await _write(id, body);
  }

  Future<File?> cachedOriginal(int id, {int? expectedBytes}) async {
    _owner();
    final file = File('${directory.path}/$id.plaud');
    final manifest = await _read(id);
    if (manifest != null && await file.exists()) {
      if (await file.length() != manifest['byteSize'] ||
          (expectedBytes != null && expectedBytes != manifest['byteSize']) ||
          await _hash(file) != manifest['sha256']) {
        throw const PlaudException(PlaudIssue.protocol);
      }
      _owner();
      return file;
    }
    return null;
  }

  Future<File> original(OfflineRecording recording, Future<void> Function(File) download, {int? expectedBytes}) async {
    final cached = await cachedOriginal(recording.id, expectedBytes: expectedBytes);
    if (cached != null) return cached;
    await directory.create(recursive: true);
    final file = File('${directory.path}/${recording.id}.plaud');
    final pending = File('${file.path}.part');
    // A failed transfer is never renamed or treated as complete. The retained
    // partial is replaced from offset zero on an explicit retry.
    await download(pending);
    _owner();
    final length = await pending.length();
    if (length <= 512 || length > plaudMaxFileBytes || (expectedBytes != null && length != expectedBytes)) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    final hash = await _hash(pending);
    _owner();
    await pending.rename(file.path);
    await _write(recording.id,
        {'id': recording.id, 'durationHintMs': recording.reportedSize, 'byteSize': length, 'sha256': hash});
    return file;
  }

  Future<File?> playable(int id, PlaudIdentity identity) {
    _owner();
    final existing = _preparingPlayback[id];
    if (existing != null) return existing;
    final work = _preparePlayable(id, identity);
    _preparingPlayback[id] = work;
    return work.whenComplete(() => _preparingPlayback.remove(id));
  }

  Future<File?> _preparePlayable(int id, PlaudIdentity identity) async {
    _owner();
    if (!await File('${directory.path}/$id.ogg').exists()) return null;
    final raw = await original(
        OfflineRecording(id, 0, 0), (_) async => throw const PlaudException(PlaudIssue.unsupportedAudio));
    // iOS cannot reliably play Ogg. Generate a validated local PCM derivative
    // with the same 312/48k pre-skip as the uploaded Ogg (104 samples at 16k).
    final target = File('${directory.path}/$id.wav');
    if (await target.exists()) return target;
    final pending = File('${target.path}.part');
    final output = await pending.open(mode: FileMode.write);
    SimpleOpusDecoder? decoder;
    OfflineDownload? validation;
    var complete = false, skip = 104, bytes = 0;
    final buffer = BytesBuilder(copy: false);
    try {
      await output.writeFrom(Uint8List(44));
      decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
      validation = await PlaudAudio.toOgg(raw, identity, validatePacket: (packet) {
        _owner();
        final samples = decoder!.decode(input: packet);
        if (samples.length != 320) return samples.length;
        final pcm = Uint8List((samples.length - skip) * 2);
        final view = ByteData.sublistView(pcm);
        for (var i = skip; i < samples.length; i++) {
          view.setInt16((i - skip) * 2, samples[i], Endian.little);
        }
        skip = 0;
        buffer.add(pcm);
        bytes += pcm.length;
        if (buffer.length >= 32000) output.writeFromSync(buffer.takeBytes());
        return samples.length;
      });
      _owner();
      await output.writeFrom(buffer.takeBytes());
      final header = Uint8List(44)
        ..setAll(0, ascii.encode('RIFF'))
        ..setAll(8, ascii.encode('WAVEfmt '))
        ..setAll(36, ascii.encode('data'));
      ByteData.sublistView(header)
        ..setUint32(4, 36 + bytes, Endian.little)
        ..setUint32(16, 16, Endian.little)
        ..setUint16(20, 1, Endian.little)
        ..setUint16(22, 1, Endian.little)
        ..setUint32(24, 16000, Endian.little)
        ..setUint32(28, 32000, Endian.little)
        ..setUint16(32, 2, Endian.little)
        ..setUint16(34, 16, Endian.little)
        ..setUint32(40, bytes, Endian.little);
      await output.setPosition(0);
      await output.writeFrom(header);
      await output.flush();
      complete = true;
    } finally {
      decoder?.destroy();
      await output.close();
      await validation?.dispose();
      if (!complete && await pending.exists()) await pending.delete();
    }
    _owner();
    await pending.rename(target.path);
    return target;
  }
}
