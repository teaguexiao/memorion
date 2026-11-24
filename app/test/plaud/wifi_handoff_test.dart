import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'fake_device.dart';

void main() {
  late Peer peer;
  setUp(() => peer = Peer());
  tearDown(() => peer.dispose());

  test('AP acknowledgement survives immediate BLE loss and preserves exact cipher counters', () async {
    await peer.connect();
    peer.handle = (request) {
      expect(plaudCommandId(request), 10);
      expect(request.sublist(3), [0, ...peer.identity.serial.substring(peer.identity.serial.length - 8).codeUnits]);
      peer.emit(Uint8List.fromList([1, 10, 0, 0]));
      peer.session.close();
    };
    final handoff = await peer.session.openWifi();
    expect(peer.session.isClosed, true);
    final cipher = handoff.takeCipher();
    final payload = Uint8List.fromList([1, 2, 3]);
    expect(cipher.openWifi(peer.cipher.sealWifi(payload)), payload);
    expect(peer.cipher.openWifi(cipher.sealWifi(payload)), payload);
    expect(() => handoff.takeCipher(), throwsA(isA<PlaudException>()));
  });

  test('disconnect without success acknowledgement never produces a handoff', () async {
    await peer.connect();
    peer.handle = (_) => peer.session.close();
    await expectLater(peer.session.openWifi(), throwsA(isA<PlaudException>()));
  });

  test('recording-busy AP response fails and closes the BLE session', () async {
    await peer.connect();
    peer.handle = (_) => peer.emit(Uint8List.fromList([1, 10, 0, 4]));
    await expectLater(peer.session.openWifi(), throwsA(isA<PlaudException>()));
    expect(peer.session.isClosed, true);
  });

  test('only bounded AP controls are exposed', () {
    expect(plaudWifiCommand(10, [0]).toList(), [1, 10, 0, 0]);
    expect(plaudWifiCommand(13).toList(), [1, 13, 0]);
    for (final code in [14, 16, 17, 30]) {
      expect(() => plaudWifiCommand(code), throwsA(isA<PlaudException>()));
    }
    expect(() => plaudWifiCommand(10, [2]), throwsA(isA<PlaudException>()));
  });
}
