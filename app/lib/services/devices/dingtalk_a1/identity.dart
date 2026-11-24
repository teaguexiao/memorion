import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Owner-supplied identity from their already activated A1. Never log this object
/// or persist its JSON in preferences, analytics, backups or an upload request.
class A1Identity {
  final String did;
  final String corpId;
  final String _secret;

  A1Identity(this.did, this.corpId, String deviceSecret) : _secret = deviceSecret {
    if (did.isEmpty ||
        corpId.isEmpty ||
        did.length > 256 ||
        corpId.length > 256 ||
        deviceSecret.length != 32 ||
        deviceSecret.codeUnits.any((c) => c < 33 || c > 126)) {
      throw const FormatException('Invalid A1 identity');
    }
  }

  factory A1Identity.fromJson(String value) {
    if (value.length > 16384) throw const FormatException('Invalid A1 identity');
    try {
      final body = jsonDecode(value) as Map<String, dynamic>;
      return A1Identity((body['did'] ?? body['deviceId']) as String, (body['corp_id'] ?? body['corpId']) as String,
          (body['device_secret'] ?? body['deviceSecret']) as String);
    } catch (_) {
      // JSON parsing errors may contain the supplied secret: replace entirely.
      throw const FormatException('Invalid A1 identity');
    }
  }

  String toStorageJson() => jsonEncode({'did': did, 'corp_id': corpId, 'device_secret': _secret});

  String token(String challenge) {
    if (challenge.length != 32 || challenge.codeUnits.any((c) => c > 127)) {
      throw const FormatException('Invalid A1 challenge');
    }
    final key = Uint8List.fromList(ascii.encode(_secret.substring(0, 16)));
    final cipher = CBCBlockCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(key), key));
    final input = Uint8List.fromList(ascii.encode(challenge));
    final output = Uint8List(32);
    cipher.processBlock(input, 0, output, 0);
    cipher.processBlock(input, 16, output, 16);
    return output.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  String toString() => 'A1Identity(redacted)';
}
