import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';
import 'package:memorion/services/devices/plaud/cipher.dart';
import 'package:memorion/services/devices/plaud/identity.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';

void main() {
  final data = jsonDecode(File('test/plaud/fixtures/synthetic.json').readAsStringSync()) as Map<String, dynamic>;
  Uint8List bytes(String name) => base64.decode(data[name] as String);
  PlaudIdentity identity() => PlaudIdentity.fromJson(jsonEncode(data['identity']));
  test('firmware version is binary little endian with a validated version marker', () {
    expect(plaudFirmwareVersion([0x56, 8, 2, 2]), '2.2.8');
    expect(plaudFirmwareVersion([0x56, 12, 3, 1]), '1.3.12');
    for (final invalid in [
      <int>[],
      [0x56, 8, 2],
      [0, 8, 2, 2],
      [0x56, 256, 2, 2]
    ]) {
      expect(plaudFirmwareVersion(invalid), null);
    }
  });
  test('manufacturer-only discovery preserves nine-byte serial and rejects lookalikes', () {
    final advert = bytes('advert');
    final parsed = PlaudAdvertisement.parse('PLAUD_NOTE', {89: advert})!;
    expect(parsed.serial, '888000000000000001');
    expect(parsed.supported, true);
    expect(parsed.toString(), isNot(contains(parsed.serial)));
    for (var i = 0; i < advert.length; i++) {
      expect(PlaudAdvertisement.parse('PLAUD_NOTE', {89: advert.sublist(0, i)}), null);
    }
    expect(PlaudAdvertisement.parse('Headphones', {89: advert}), null);
    expect(PlaudAdvertisement.parse('PLAUD_NOTE', {65535: advert}), null);
    advert[advert.length - 2] = 30;
    expect(PlaudAdvertisement.parse('PLAUD_NOTE', {89: advert})!.supported, false);
  });
  test('dangerous requests unavailable and account token is never truncated', () {
    for (final code in [4, 5, 8, 20, 21, 22, 23, 30, 31, 104, 107, 151]) {
      expect(() => plaudCommand(code), throwsA(isA<PlaudException>()));
    }
    expect(() => plaudCommand(29, [1]), throwsA(isA<PlaudException>()));
    expect(plaudHandshake(identity().bindToken), bytes('handshake'));
    expect(() => plaudHandshake('x' * 33), throwsA(isA<PlaudException>()));
  });
  test('PKCS8 identity matches RSA public key; errors never expose input', () {
    final valid = identity();
    expect(PlaudIdentity.fromJson(valid.toStorageJson()).serial, valid.serial);
    expect(valid.toString(), 'PlaudIdentity(redacted)');
    for (final patch in [
      {'publicKeyPem': data['otherIdentity']['publicKeyPem']},
      {'privateKeyPem': '${data['identity']['privateKeyPem']}secret suffix'},
      {'protocol': 30},
      {'serial': '8880'},
      {'bindToken': 'x' * 33},
      {
        'signature': base64.encode([1, 2])
      }
    ]) {
      expect(() => PlaudIdentity.fromJson(jsonEncode({...data['identity'], ...patch})),
          throwsA(isA<PlaudException>().having((e) => e.toString(), 'safe error', 'PlaudException(identityRequired)')));
    }
  });
  test('independent Python RSA and AEAD vectors; replay, tampering, wrong key reject', () {
    final cipher = PlaudSessionCipher.unlock(bytes('secret'), identity());
    expect(cipher.seal(plaudCommand(3)), bytes('firstCommand'));
    expect(cipher.open(bytes('reply')), plaudCommand(3, [1]));
    expect(() => cipher.open(bytes('reply')), throwsA(isA<PlaudException>()));
    final corrupted = bytes('reply')..[8] ^= 1;
    expect(
        () => PlaudSessionCipher.unlock(bytes('secret'), identity()).open(corrupted), throwsA(isA<PlaudException>()));
    expect(() => PlaudSessionCipher.unlock(bytes('secret'), PlaudIdentity.fromJson(jsonEncode(data['otherIdentity']))),
        throwsA(isA<PlaudException>()));
  });
  test('RSA phi and lambda private exponents work in both PKCS1 and PKCS8', () {
    final pem = data['identity']['privateKeyPem'] as String;
    final der = base64.decode(pem.split('\n').where((line) => !line.startsWith('-----')).join());
    final outer = ASN1Parser(der).nextObject() as ASN1Sequence;
    final inner = ASN1Parser((outer.elements![2] as ASN1OctetString).octets!).nextObject() as ASN1Sequence;
    final numbers = inner.elements!.map((item) => (item as ASN1Integer).integer!).toList();
    final p1 = numbers[4] - BigInt.one, q1 = numbers[5] - BigInt.one;
    final phi = p1 * q1, lambda = p1 * q1 ~/ p1.gcd(q1);
    final phiD = numbers[2].modInverse(phi);
    final alternativeD = phiD > lambda ? phiD - lambda : phiD + lambda;
    expect(alternativeD.modInverse(phi), isNot(numbers[2]));
    final plaintext = identity().decrypt(bytes('secret'));
    for (final d in [phiD, alternativeD]) {
      numbers[3] = d;
      numbers[6] = d % p1;
      numbers[7] = d % q1;
      final private = ASN1Sequence(elements: numbers.map(ASN1Integer.new).toList());
      final pkcs8 =
          ASN1Sequence(elements: [outer.elements![0], outer.elements![1], ASN1OctetString(octets: private.encode())]);
      for (final (label, encoded) in [('RSA PRIVATE KEY', private.encode()), ('PRIVATE KEY', pkcs8.encode())]) {
        final candidate = PlaudIdentity.fromJson(jsonEncode({
          ...data['identity'],
          'privateKeyPem': '-----BEGIN $label-----\n${base64.encode(encoded)}\n-----END $label-----\n'
        }));
        expect(candidate.decrypt(bytes('secret')), plaintext);
      }
    }
  });
  test('secret fragments accept reorder and identical duplicate, reject conflicting lengths', () {
    final chunks = plaudUnlockParts(0xfe12, bytes('secret'));
    final parts = PlaudSecretParts();
    for (final i in [2, 0, 0, 1]) {
      parts.add(chunks[i]);
    }
    expect(parts.ciphertext(), bytes('secret'));
    final conflict = Uint8List.fromList(chunks[1])..[10] ^= 1;
    expect(() => parts.add(conflict), throwsA(isA<PlaudException>()));
    expect(() => PlaudSecretParts().add(Uint8List.fromList([0x12, 0xfe, 2, 2, 1])), throwsA(isA<PlaudException>()));
    expect(() => PlaudSecretParts().ciphertext(), throwsA(isA<PlaudException>()));
  });
  test('list and file data parsers preserve unsigned values and exact framing', () {
    final (total, index, entries) = plaudListPage(bytes('listPage'));
    expect((total, index, entries.single.id, entries.single.byteSize), (1, 0, 1793512345, 24512));
    expect(() => plaudListPage(bytes('listPage').sublist(0, 20)), throwsA(isA<PlaudException>()));
    final packet = Uint8List.fromList([2, 123, 0, 0, 0, 100, 0, 0, 0, 3, 10, 11, 12]);
    final (offset, payload) = plaudFileData(packet, 123);
    expect(offset, 100);
    expect(payload, [10, 11, 12]);
    expect(() => plaudFileData(packet, 124), throwsA(isA<PlaudException>()));
    expect(() => plaudFileData(packet.sublist(0, 12), 123), throwsA(isA<PlaudException>()));
  });
}
