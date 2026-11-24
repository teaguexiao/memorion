import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/wifi_connection.dart';
import 'package:memorion/services/devices/soundcore/wifi_transport.dart';
import 'fake_device.dart';
import 'fake_wifi.dart';

class StallingWifi extends FakeSoundcoreWifi {
  final Object failure;
  StallingWifi(super.peer, this.failure);
  @override
  Future<void> requestFile(int id) async {
    requested.add(id);
    frames.add(response(0x1a, 7, peer.fileHeader(id)));
    frames.add(response(0x1a, 8, peer.slice(0)));
    frames.addError(failure);
  }
}

void main() {
  for (final failure in [TimeoutException('synthetic stall'), SoundcoreWifiDisconnected()]) {
    test('${failure.runtimeType} restarts on a fresh socket with no partial result', () async {
      final peer =
          FakeSoundcoreDevice(DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000);
      final ble = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
      final first = StallingWifi(peer, failure);
      final next = FakeSoundcoreWifi(peer);
      final original = await openFakeSoundcoreWifi(ble, first);
      first.leave = null;
      var retries = 0;
      final connection = SoundcoreWifiConnection(original.session, first, reconnect: (old) async {
        retries++;
        await old.close();
        return next;
      });
      final progress = <int>[];
      try {
        final result = await connection.download(SoundcoreRecording(peer.fileId, peer.fileId + 6, 48000),
            onProgress: progress.add);
        addTearDown(result.dispose);
        expect(result.duration, const Duration(seconds: 6));
        expect(retries, 1);
        expect(first.requested, [peer.fileId]);
        expect(next.requested, [peer.fileId]);
        expect(progress, containsAllInOrder([160, 0, 1600]));
        expect(connection.diagnostics, contains('fresh socket retry'));
        expect(original.session.isClosed, isTrue);
      } finally {
        await connection.close();
        ble.close();
        await peer.inbound.close();
      }
    });
  }
}
