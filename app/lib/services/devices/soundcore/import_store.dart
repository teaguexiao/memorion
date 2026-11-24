// Compatibility facade for existing Soundcore integrations and cache paths.
import 'dart:io';

import '../offline_recordings/import_store.dart';
import 'protocol.dart';

typedef SoundcoreImportStage = OfflineImportStage;
typedef SoundcoreImportReceipt = OfflineImportReceipt;
typedef SoundcoreImportException = OfflineImportException;
typedef SoundcoreRecordingDetails = OfflineRecordingDetails;

class SoundcoreImportStore extends OfflineImportStore {
  SoundcoreImportStore(
      {required super.root,
      required super.ownerId,
      required super.deviceId,
      required super.currentOwner,
      super.now,
      super.upload,
      super.uploadWithProgress});

  @override
  Future<List<SoundcoreRecording>> cachedRecordings() async {
    final removed = await removedRecordingIds();
    return (await super.cachedRecordings())
        .where((r) => !removed.contains(r.id))
        .map((r) => SoundcoreRecording(r.id, r.endTime, r.reportedSize))
        .toList();
  }

  void _checkRemovalOwner() {
    if (ownerId.isEmpty || currentOwner() != ownerId) {
      throw StateError('Soundcore account changed');
    }
  }

  /// Account/device-scoped tombstones keep recorder discovery from reimporting
  /// a removed row. Each file is independent, so concurrent removals cannot
  /// overwrite each other's tombstones.
  Future<Set<int>> removedRecordingIds() async {
    _checkRemovalOwner();
    final ids = <int>{};
    if (await directory.exists()) {
      await for (final file in directory.list()) {
        if (file is! File || !file.path.endsWith('.removed')) continue;
        final id = int.tryParse(file.uri.pathSegments.last.replaceFirst('.removed', ''));
        if (id != null) ids.add(id);
      }
    }
    _checkRemovalOwner();
    return ids;
  }

  /// Removes local import history, never device originals or cloud content.
  /// The controller must reserve the row before calling this method so a
  /// queued download cannot start while its tombstone is being committed.
  Future<void> removeRecording(int id) async {
    _checkRemovalOwner();
    await directory.create(recursive: true);
    _checkRemovalOwner();
    final pending = File('${directory.path}/$id.removed.part');
    await pending.writeAsString('', flush: true);
    _checkRemovalOwner();
    await pending.rename('${directory.path}/$id.removed');
    for (final suffix in ['ogg', 'ogg.part', 'json', 'json.part']) {
      _checkRemovalOwner();
      try {
        final file = File('${directory.path}/$id.$suffix');
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // The durable removal already succeeded. A late status write or a
        // cache cleanup failure must not re-enable sync for this recording.
      }
    }
  }
}
