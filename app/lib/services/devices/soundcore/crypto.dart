// D3200 interoperability implementation. See THIRD_PARTY_LICENSE.txt.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class SoundcoreCrypto {
  static final _curve = ECDomainParameters('prime256v1');
  final ECPrivateKey _privateKey;
  final ECPublicKey _publicKey;
  Uint8List? _sessionKey;
  Uint8List? _fileKey;
  Uint8List? _fileNonce;

  SoundcoreCrypto._(this._privateKey, this._publicKey);

  factory SoundcoreCrypto() {
    final random = Random.secure();
    final secureRandom = FortunaRandom()
      ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)))));
    final generator = ECKeyGenerator()..init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), secureRandom));
    final pair = generator.generateKeyPair();
    return SoundcoreCrypto._(pair.privateKey, pair.publicKey);
  }

  Uint8List get publicKey => _publicKey.Q!.getEncoded(false);
  bool get hasSession => _sessionKey != null;

  /// Independent file/key lifetime for a Wi-Fi batch. BLE teardown must not
  /// zero the key still needed by the already authenticated Wi-Fi connection.
  SoundcoreCrypto forkSession() {
    if (_sessionKey == null) throw StateError('D3200 session key is not ready');
    return SoundcoreCrypto._(_privateKey, _publicKey).._sessionKey = Uint8List.fromList(_sessionKey!);
  }

  void completeHandshake(Uint8List payload) {
    if (payload.length != 97) throw const FormatException('Invalid D3200 handshake');
    final point = _curve.curve.decodePoint(payload.sublist(0, 65));
    if (point == null || point.isInfinity) throw const FormatException('Invalid D3200 public key');
    final agreement = ECDHBasicAgreement()..init(_privateKey);
    final value = agreement.calculateAgreement(ECPublicKey(point, _curve));
    final shared = Uint8List(32);
    var remaining = value;
    for (var i = 31; i >= 0; i--) {
      shared[i] = (remaining & BigInt.from(255)).toInt();
      remaining >>= 8;
    }
    if (!_equals(shared, payload.sublist(65))) throw const FormatException('D3200 handshake mismatch');
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(shared, 32, Uint8List.fromList([1, 2, 3]), Uint8List.fromList([1, 2, 3])));
    _sessionKey = hkdf.process(Uint8List(0));
  }

  int prepareFile(Uint8List payload, int expectedId) {
    clearFile();
    if (_sessionKey == null || payload.length < 87) throw const FormatException('Missing D3200 file key');
    final data = ByteData.sublistView(payload);
    if (data.getUint32(0, Endian.little) != expectedId) {
      throw const FormatException(
          'D3200 returned a different recording'); // i18n-ignore: Internal diagnostic; the import page shows localized errors.
    }
    if (payload[86] != 0) throw StateError('D3200 rejected file transfer (${payload[86]})');
    final material = _aesCtr(payload.sublist(24, 70), _sessionKey!, payload.sublist(70, 86));
    final magic = ascii.encode('soundcored3200');
    if (!_equals(material.sublist(0, 14), magic)) throw const FormatException('Invalid D3200 file key');
    _fileKey = material.sublist(14, 46);
    _fileNonce = payload.sublist(8, 20);
    return data.getUint32(4, Endian.little);
  }

  Uint8List decryptChunk(int sequence, Uint8List bytes) {
    if (_fileKey == null || _fileNonce == null) throw StateError('D3200 file key is not ready');
    if (sequence < 0 || sequence > 0xffffffff ~/ 10 || bytes.length != 160) {
      throw const FormatException('Invalid D3200 audio slice');
    }
    final iv = Uint8List(16)..setAll(0, _fileNonce!);
    ByteData.sublistView(iv).setUint32(12, sequence * 10, Endian.big);
    return _aesCtr(bytes, _fileKey!, iv);
  }

  void clearFile() {
    _fileKey?.fillRange(0, _fileKey!.length, 0);
    _fileKey = null;
    _fileNonce = null;
  }

  void clear() {
    clearFile();
    _sessionKey?.fillRange(0, _sessionKey!.length, 0);
    _sessionKey = null;
  }

  static Uint8List _aesCtr(Uint8List data, Uint8List key, Uint8List iv) {
    final cipher = SICStreamCipher(AESEngine())..init(false, ParametersWithIV(KeyParameter(key), iv));
    return cipher.process(data);
  }

  static bool _equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}
