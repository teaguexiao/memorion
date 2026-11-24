import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'identity.dart';
import 'protocol.dart';
import 'wifi_protocol.dart';

/// Vendor protocol 20 uses a fixed nonce and sequence inside the plaintext.
/// A fresh instance is required on every BLE connection; never use this scheme
/// for Memorion's own encryption or reuse this object after a failed operation.
class PlaudSessionCipher {
  final Uint8List _key, _nonce, _aad;
  int _tx = 1, _rx = -1;
  PlaudSessionCipher._(this._key, this._nonce, this._aad);

  factory PlaudSessionCipher.unlock(Uint8List encrypted, PlaudIdentity identity) {
    try {
      final plain = identity.decrypt(encrypted);
      if (plain.length != 80) throw const FormatException();
      final result = PlaudSessionCipher._(plain.sublist(0, 32), plain.sublist(32, 44), plain.sublist(44, 56));
      if (ascii.decode(result._crypt(false, plain.sublist(56))) != 'PLAUD.AI') throw const FormatException();
      return result;
    } catch (_) {
      throw const PlaudException(PlaudIssue.authentication);
    }
  }

  Uint8List _crypt(bool encrypt, Uint8List bytes) {
    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
      ..init(encrypt, AEADParameters(KeyParameter(_key), 128, _nonce, _aad));
    // PointyCastle's AEAD process() neither finalizes nor verifies the tag.
    final output = Uint8List(cipher.getOutputSize(bytes.length));
    final count = cipher.processBytes(bytes, 0, bytes.length, output, 0);
    final total = count + cipher.doFinal(output, count);
    return Uint8List.sublistView(output, 0, total);
  }

  Uint8List seal(Uint8List packet) => _seal(packet, 492);

  /// Candidate Wi-Fi handoff keeps the authenticated session and counters, but
  /// permits larger messages. Hardware compatibility remains to be verified.
  Uint8List sealWifi(Uint8List packet) => _seal(packet, plaudWifiMaxPduBytes);

  Uint8List _seal(Uint8List packet, int limit) {
    if (_tx >= 0xffffffff || packet.isEmpty || packet.length > limit) throw const PlaudException(PlaudIssue.protocol);
    final plain = Uint8List(4 + packet.length)..setAll(4, packet);
    ByteData.sublistView(plain).setUint32(0, ++_tx, Endian.little);
    return _crypt(true, plain);
  }

  Uint8List open(Uint8List packet) => _open(packet, 512);

  Uint8List openWifi(Uint8List packet) => _open(packet, plaudWifiMaxPduBytes + 20);

  Uint8List _open(Uint8List packet, int limit) {
    try {
      if (packet.length < 21 || packet.length > limit) throw const FormatException();
      final plain = _crypt(false, packet);
      final seq = ByteData.sublistView(plain).getUint32(0, Endian.little);
      if (seq <= _rx) throw const FormatException();
      _rx = seq;
      return plain.sublist(4);
    } catch (_) {
      throw const PlaudException(PlaudIssue.authentication);
    }
  }
}
