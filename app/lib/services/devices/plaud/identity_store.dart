import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'identity.dart';
import 'protocol.dart';

class PlaudIdentityStore {
  final FlutterSecureStorage storage;
  const PlaudIdentityStore(
      {this.storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true, sharedPreferencesName: 'MemorionPlaudCredentials'),
        iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
      )});
  String _key(String owner, String device) {
    if (owner.isEmpty || device.isEmpty) throw const PlaudException(PlaudIssue.identityRequired);
    return 'memorion.plaud.${sha256.convert(utf8.encode(jsonEncode([
          owner,
          device
        ])))}'; // i18n-ignore: Internal storage key, never displayed.
  }

  Future<PlaudIdentity?> read(String owner, String device) async {
    final value = await storage.read(key: _key(owner, device));
    return value == null ? null : PlaudIdentity.fromJson(value);
  }

  Future<void> save(String owner, String device, PlaudIdentity identity) =>
      storage.write(key: _key(owner, device), value: identity.toStorageJson());
  Future<void> remove(String owner, String device) => storage.delete(key: _key(owner, device));
}
