import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/wifi_protocol.dart';

import 'fake_wifi.dart';

void main() {
  late WifiPeer peer;
  late Directory folder;
  setUp(() {
    peer = WifiPeer();
    folder = Directory.systemTemp.createTempSync('plaud-wifi-test');
  });
  tearDown(() async {
    await peer.dispose();
    folder.deleteSync(recursive: true);
  });
  const recording = PlaudWifiRecording(123, 1024, 2);

  test('BLE counters continue through Wi-Fi hello, heartbeat, directory, file and close', () async {
    peer.handle = (p) {
      if (p.type == 11) {
        final tail = Uint8List(10);
        ByteData.sublistView(tail)
          ..setUint32(0, 123, Endian.little)
          ..setUint32(4, 1024, Endian.little)
          ..setUint16(8, 2, Endian.little);
        peer.emit(PlaudWifiPacket(11, {'status': 0, 'uid': 0, 'count': 1, 'offset': 0}, tail));
      } else if (p.type == 12) {
        expect(p.fields, {'session': 123, 'scene': 2, 'start': 0, 'end': 1024});
        peer.status();
        peer.chunk(0, 512, 0);
        peer.chunk(512, 512, 1);
      }
    };
    await peer.connect();
    peer.emit(PlaudWifiPacket(3, {'battery': 100}));
    final files = await peer.session.recordings();
    expect(files.single.scene, 2);
    final target = File('${folder.path}/recording.partial');
    final progress = <int>[];
    await peer.session.downloadTo(files.single, target, onProgress: (got, _) => progress.add(got));
    expect(await target.readAsBytes(), List.filled(1024, 7));
    expect(progress, [512, 1024]);
    await peer.session.requestClose();
    expect(peer.requests.map((p) => p.type), [1, 3, 11, 12, 4]);
    expect(peer.session.isClosed, true);
  });

  test('no hello times out and rejected account retires session', () async {
    await expectLater(
        peer.connect(hello: false), throwsA(isA<PlaudException>().having((e) => e.issue, 'issue', PlaudIssue.timeout)));
    expect(peer.requests, isEmpty);
    final other = WifiPeer()..handshakeStatus = 1;
    try {
      await expectLater(
          other.connect(), throwsA(isA<PlaudException>().having((e) => e.issue, 'issue', PlaudIssue.authentication)));
      expect(other.session.isClosed, true);
    } finally {
      await other.dispose();
    }
  });

  test('wrong device hello and plaintext never trigger account response', () async {
    final ready = peer.session.authenticate();
    peer.emit(PlaudWifiPacket(2, {'sn': 'wrong-device', 'pVer': 20}));
    await expectLater(ready, throwsA(isA<PlaudException>()));
    expect(peer.requests, isEmpty);
    final other = WifiPeer();
    try {
      final auth = other.session.authenticate();
      other.messages.add(PlaudWifiPacket(2, {'sn': other.identity.serial, 'pVer': 20}).encode());
      await expectLater(auth, throwsA(isA<PlaudException>()));
      expect(other.requests, isEmpty);
    } finally {
      await other.dispose();
    }
  });

  test('full byte count without final marker times out instead of succeeding', () async {
    await peer.connect();
    peer.handle = (p) {
      if (p.type == 12) {
        peer.status();
        peer.chunk(0, 1024, 0);
      }
    };
    await expectLater(peer.session.downloadTo(recording, File('${folder.path}/partial')),
        throwsA(isA<PlaudException>().having((e) => e.issue, 'issue', PlaudIssue.timeout)));
    expect(peer.session.isClosed, true);
  });

  test('out-of-order file fails and refuses reuse', () async {
    await peer.connect();
    peer.handle = (p) {
      if (p.type == 12) {
        peer.status();
        peer.chunk(512, 512, 1);
      }
    };
    await expectLater(
        peer.session.downloadTo(recording, File('${folder.path}/partial')), throwsA(isA<PlaudException>()));
    await expectLater(peer.session.recordings(), throwsA(isA<PlaudException>()));
  });

  test('closing pending request fails promptly and ignores late replies', () async {
    await peer.connect();
    final pending = peer.session.recordings();
    await Future<void>.delayed(Duration.zero);
    peer.session.dispose();
    peer.emit(PlaudWifiPacket(11, {'status': 0, 'uid': 0, 'count': 0, 'offset': 0}));
    await expectLater(pending, throwsA(isA<PlaudException>()));
  });
}
