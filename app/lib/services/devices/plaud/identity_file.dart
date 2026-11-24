import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'identity.dart';

/// Reads only the selected authorization file, never a PLAUD account database.
Future<PlaudIdentity?> pickPlaudIdentityFile({
  Future<XFile?> Function()? pick,
  Future<void> Function(XFile)? removeCopy,
}) async {
  final file = await (pick ??
      () => openFile(acceptedTypeGroups: const [
            XTypeGroup(extensions: ['json'], mimeTypes: ['application/json'], uniformTypeIdentifiers: ['public.json']),
          ]))();
  if (file == null) return null;
  try {
    return await readPlaudIdentityFile(file);
  } finally {
    try {
      await (removeCopy ?? _removePickerCopy)(file);
    } catch (_) {
      // The OS can remove its copy concurrently. Cleanup is best effort and
      // cannot invalidate an already parsed identity or expose an I/O path.
    }
  }
}

Future<PlaudIdentity> readPlaudIdentityFile(XFile file) async {
  const maxBytes = 16384;
  final bytes = BytesBuilder(copy: false);
  try {
    if (await file.length() > maxBytes) throw const FormatException();
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > maxBytes) throw const FormatException();
      bytes.add(chunk);
    }
    return PlaudIdentity.fromJson(utf8.decode(bytes.takeBytes()));
  } catch (_) {
    // Platform and parser exceptions can contain paths or credential contents.
    throw const FormatException('Invalid Plaud authorization file');
  }
}

Future<void> _removePickerCopy(XFile selected) async {
  // The mobile plugins import a copy. Desktop pickers return the user's original.
  if (!Platform.isIOS && !Platform.isAndroid) return;
  final file = File(selected.path);
  if (!await file.exists()) return;
  final resolved = await file.resolveSymbolicLinks();
  final roots = [await getTemporaryDirectory()];
  if (Platform.isIOS) {
    roots.add(Directory.systemTemp);
    roots.add(Directory(path.join((await getApplicationDocumentsDirectory()).path, 'Inbox')));
  }
  for (final root in roots) {
    if (await root.exists() && path.isWithin(await root.resolveSymbolicLinks(), resolved)) {
      await file.delete();
      return;
    }
  }
}
