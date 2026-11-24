import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'identity.dart';
import 'protocol.dart';

class A1IdentityStore {
  final FlutterSecureStorage storage;
  const A1IdentityStore(
      {this.storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true, sharedPreferencesName: 'MemorionA1Credentials'),
        iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
      )});
  String _key(String owner, String device) {
    if (owner.isEmpty || device.isEmpty) throw const A1Exception(A1Issue.identityRequired);
    return 'memorion.a1.${sha256.convert(utf8.encode(jsonEncode([
          owner,
          device
        ])))}'; // i18n-ignore: Internal storage key, never displayed.
  }

  Future<A1Identity?> read(String owner, String device) async {
    final value = await storage.read(key: _key(owner, device));
    return value == null ? null : A1Identity.fromJson(value);
  }

  Future<void> save(String owner, String device, A1Identity identity) =>
      storage.write(key: _key(owner, device), value: identity.toStorageJson());
  Future<void> remove(String owner, String device) => storage.delete(key: _key(owner, device));
  Future<bool> autoSync(String owner, String device) async =>
      await storage.read(key: '${_key(owner, device)}.auto') == 'true';
  Future<void> setAutoSync(String owner, String device, bool enabled) =>
      storage.write(key: '${_key(owner, device)}.auto', value: '$enabled');
}
