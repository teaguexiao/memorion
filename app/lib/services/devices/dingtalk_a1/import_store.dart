import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:opus_dart/opus_dart.dart';
import '../offline_recordings/import_store.dart';
import '../offline_recordings/models.dart';
import 'audio.dart';
import 'protocol.dart';

/// Retains the original DTYJ even when encrypted or unsupported. The generic
/// import store only receives fully decoded and validated Ogg files.
class A1ImportStore extends OfflineImportStore {
  final _preparingPlayback = <int, Future<File?>>{};
  A1ImportStore(
      {required super.root,
      required super.ownerId,
      required super.deviceId,
      required super.currentOwner,
      super.upload,
      super.uploadWithProgress})
      : super(source: 'dingtalk_a1');
  void _owner() {
    if (ownerId.isEmpty || ownerId != currentOwner()) throw const A1Exception(A1Issue.identityRequired);
  }

  File _manifest(int id) => File('${directory.path}/$id.a1.json');
  Future<Map<String, dynamic>?> _read(int id) async {
    _owner();
    final file = _manifest(id);
    if (!await file.exists()) return null;
    final body = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _owner();
    if (body['id'] != id) throw const A1Exception(A1Issue.protocol);
    return body;
  }

  Future<void> _write(int id, Map<String, dynamic> body) async {
    _owner();
    final pending = File('${_manifest(id).path}.part');
    await pending.writeAsString(jsonEncode(body), flush: true);
    _owner();
    await pending.rename(_manifest(id).path);
  }

  @override
  Future<List<OfflineRecording>> cachedRecordings() async {
    final all = {for (final r in await super.cachedRecordings()) r.id: r};
    if (!await directory.exists()) return all.values.toList();
    await for (final file in directory.list()) {
      if (file is! File || !file.path.endsWith('.a1.json')) continue;
      final id = int.tryParse(file.uri.pathSegments.last.split('.').first);
      if (id == null) continue;
      final body = await _read(id);
      if (body != null) all.putIfAbsent(id, () => OfflineRecording(id, 0, body['durationHintMs'] as int));
    }
    _owner();
    return all.values.toList();
  }

  Future<A1Issue?> audioIssue(int id) async {
    final body = await _read(id);
    return switch (body?['issue']) {
      'encryptedAudio' => A1Issue.encryptedAudio,
      'unsupportedAudio' => A1Issue.unsupportedAudio,
      _ => null,
    };
  }

  Future<void> markAudioIssue(int id, A1Issue issue) async {
    final body = await _read(id);
    if (body == null) return;
    body['issue'] = issue.name;
    await _write(id, body);
  }

  Future<Uint8List> original(OfflineRecording recording, Future<Uint8List> Function() download) async {
    _owner();
    await directory.create(recursive: true);
    final file = File('${directory.path}/${recording.id}.dtyj');
    final manifest = await _read(recording.id);
    if (manifest != null && await file.exists()) {
      final bytes = await file.readAsBytes();
      _owner();
      if (sha256.convert(bytes).toString() != manifest['sha256']) throw const A1Exception(A1Issue.protocol);
      return bytes;
    }
    final bytes = await download();
    _owner();
    final pending = File('${file.path}.part');
    await pending.writeAsBytes(bytes, flush: true);
    _owner();
    await pending.rename(file.path);
    await _write(recording.id,
        {'id': recording.id, 'durationHintMs': recording.reportedSize, 'sha256': sha256.convert(bytes).toString()});
    return bytes;
  }

  Future<File?> playable(int id) {
    _owner();
    final existing = _preparingPlayback[id];
    if (existing != null) return existing;
    final work = _preparePlayable(id);
    _preparingPlayback[id] = work;
    return work.whenComplete(() => _preparingPlayback.remove(id));
  }

  Future<File?> _preparePlayable(int id) async {
    _owner();
    if (!await File('${directory.path}/$id.ogg').exists()) return null;
    // AVFoundation does not reliably play Ogg/Opus. Listen to a local PCM WAV
    // derivative; the compact validated Ogg remains the upload source.
    final file = File('${directory.path}/$id.wav');
    if (await file.exists()) {
      _owner();
      return file;
    }
    final raw =
        await original(OfflineRecording(id, 0, 0), () async => throw const A1Exception(A1Issue.unsupportedAudio));
    final audio = A1Audio.parse(raw);
    final pending = File('${file.path}.part');
    final output = await pending.open(mode: FileMode.write);
    SimpleOpusDecoder? decoder;
    var bytes = 0;
    try {
      decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
      await output.writeFrom(Uint8List(44));
      final buffer = BytesBuilder(copy: false);
      for (var i = 0; i < audio.packets.length; i++) {
        _owner();
        final packet = audio.packets[i];
        final samples = decoder.decode(input: packet);
        if (samples.length * 3 != a1OpusSamples(packet)) throw const A1Exception(A1Issue.unsupportedAudio);
        final pcm = Uint8List(samples.length * 2);
        final view = ByteData.sublistView(pcm);
        for (var n = 0; n < samples.length; n++) {
          view.setInt16(n * 2, samples[n], Endian.little);
        }
        buffer.add(pcm);
        bytes += pcm.length;
        if (i % 50 == 49 || i == audio.packets.length - 1) await output.writeFrom(buffer.takeBytes());
      }
      final header = Uint8List(44);
      header.setAll(0, ascii.encode('RIFF'));
      header.setAll(8, ascii.encode('WAVEfmt '));
      header.setAll(36, ascii.encode('data'));
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
    } finally {
      decoder?.destroy();
      await output.close();
    }
    _owner();
    await pending.rename(file.path);
    return file;
  }
}
