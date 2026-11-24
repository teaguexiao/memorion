import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'protocol.dart';

const _identityFormat = 'memorion-plaud-identity-v1'; // i18n-ignore: On-disk schema identifier.

/// Account/device credentials from the local probe, never sent with an audio
/// upload. The app's owner-scoped secure store is the only persistence target.
class PlaudIdentity {
  final String serial, bindToken;
  final Uint8List _signature;
  final String _privatePem, _publicPem;
  final RSAPrivateKey _key;
  PlaudIdentity._(this.serial, this.bindToken, this._signature, this._privatePem, this._publicPem, this._key);

  factory PlaudIdentity.fromJson(String text) {
    try {
      if (text.length > 16384) throw const FormatException();
      final data = jsonDecode(text) as Map<String, dynamic>;
      final serial = data['serial'] as String, token = data['bindToken'] as String;
      final signature = base64.decode(data['signature'] as String);
      if (data['format'] != _identityFormat ||
          data['protocol'] != 20 ||
          !RegExp(r'^888[0-9A-F]+$').hasMatch(serial) ||
          !{16, 18, 20}.contains(serial.length) ||
          !RegExp(r'^[\x21-\x7e]{1,32}$').hasMatch(token) ||
          signature.length != 256) {
        throw const FormatException();
      }
      final privatePem = data['privateKeyPem'] as String, publicPem = data['publicKeyPem'] as String;
      final (private, privatePublicExponent) = _private(privatePem);
      final public = _public(publicPem);
      if (private.modulus!.bitLength != 2048 ||
          private.modulus != public.modulus ||
          privatePublicExponent != public.exponent) {
        throw const FormatException();
      }
      return PlaudIdentity._(serial, token, signature, privatePem, publicPem, private);
    } catch (_) {
      // Parser and crypto exceptions may contain credentials. Replace them.
      throw const PlaudException(PlaudIssue.identityRequired);
    }
  }

  Uint8List get signature => Uint8List.fromList(_signature);
  Uint8List get publicKeyBytes => Uint8List.fromList(ascii.encode(_publicPem));
  Uint8List decrypt(Uint8List ciphertext) {
    try {
      if (ciphertext.length != 256) throw const FormatException();
      final cipher = PKCS1Encoding(RSAEngine())..init(false, PrivateKeyParameter<RSAPrivateKey>(_key));
      return cipher.process(ciphertext);
    } catch (_) {
      throw const PlaudException(PlaudIssue.authentication);
    }
  }

  String toStorageJson() => jsonEncode({
        'format': _identityFormat,
        'protocol': 20,
        'serial': serial,
        'bindToken': bindToken,
        'signature': base64.encode(_signature),
        'privateKeyPem': _privatePem,
        'publicKeyPem': _publicPem
      });
  @override
  String toString() => 'PlaudIdentity(redacted)';
}

ASN1Sequence _sequence(Uint8List bytes) {
  final parser = ASN1Parser(bytes);
  final value = parser.nextObject() as ASN1Sequence;
  if (parser.hasNext() || value.encode().length != bytes.length) throw const FormatException();
  return value;
}

(String, ASN1Sequence) _pem(String text) {
  final match = RegExp(
          r'^-----BEGIN (PRIVATE KEY|RSA PRIVATE KEY|PUBLIC KEY|RSA PUBLIC KEY)-----\s*([A-Za-z0-9+/=\s]+)-----END \1-----\s*$')
      .firstMatch(text.trim());
  if (match == null) throw const FormatException();
  return (match[1]!, _sequence(base64.decode(match[2]!.replaceAll(RegExp(r'\s'), ''))));
}

void _rsaAlgorithm(ASN1Object object) {
  final items = (object as ASN1Sequence).elements!;
  final oid = items.first as ASN1ObjectIdentifier;
  if (oid.objectIdentifierAsString != '1.2.840.113549.1.1.1' ||
      items.length > 2 ||
      (items.length == 2 && items[1] is! ASN1Null)) {
    throw const FormatException();
  }
}

(RSAPrivateKey, BigInt) _private(String pem) {
  final (label, parsed) = _pem(pem);
  var items = parsed.elements!;
  if (label == 'PRIVATE KEY') {
    if (items.length != 3 || (items[0] as ASN1Integer).integer != BigInt.zero) throw const FormatException();
    _rsaAlgorithm(items[1]);
    items = _sequence((items[2] as ASN1OctetString).octets!).elements!;
  } else if (label != 'RSA PRIVATE KEY') {
    throw const FormatException();
  }
  if (items.length != 9) throw const FormatException();
  final ints = items.map((v) => (v as ASN1Integer).integer!).toList();
  final n = ints[1], e = ints[2], d = ints[3], p = ints[4], q = ints[5];
  if (ints[0] != BigInt.zero ||
      n.bitLength != 2048 ||
      p.bitLength < 1000 ||
      q.bitLength < 1000 ||
      p * q != n ||
      e < BigInt.from(3) ||
      e.isEven ||
      d <= BigInt.one ||
      (d * e) % (p - BigInt.one) != BigInt.one ||
      (d * e) % (q - BigInt.one) != BigInt.one ||
      ints[6] != d % (p - BigInt.one) ||
      ints[7] != d % (q - BigInt.one) ||
      ints[8] != q.modInverse(p)) {
    throw const FormatException();
  }
  // Keep the DER public exponent: PointyCastle derives its value modulo phi,
  // which can differ for valid private exponents chosen modulo Carmichael lambda.
  // RSAEngine uses the validated private exponent and CRT factors to decrypt.
  return (RSAPrivateKey(n, d, p, q), e);
}

RSAPublicKey _public(String pem) {
  final (label, parsed) = _pem(pem);
  var items = parsed.elements!;
  if (label == 'PUBLIC KEY') {
    if (items.length != 2) throw const FormatException();
    _rsaAlgorithm(items[0]);
    final bits = items[1] as ASN1BitString;
    if (bits.unusedbits != 0) throw const FormatException();
    items = _sequence(Uint8List.fromList(bits.stringValues!)).elements!;
  } else if (label != 'RSA PUBLIC KEY') {
    throw const FormatException();
  }
  if (items.length != 2) throw const FormatException();
  return RSAPublicKey((items[0] as ASN1Integer).integer!, (items[1] as ASN1Integer).integer!);
}
