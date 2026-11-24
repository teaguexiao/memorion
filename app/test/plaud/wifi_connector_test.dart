import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/wifi_connector.dart';
import 'fake_device.dart';

void main() {
  test('DHCP readiness accepts only a client on the recorder subnet', () async {
    for (final address in ['::1', '10.0.0.1', '192.168.0.2', '192.168.84.1', '192.168.84.255']) {
      expect(PlaudWifiConnector.isRecorderAddress(address), isFalse);
    }
    var polls = 0;
    expect(
        await PlaudWifiConnector.waitForNetwork(
            joined: true,
            interval: Duration.zero,
            addresses: () async => ++polls < 3 ? ['192.168.0.3'] : ['192.168.84.188']),
        '192.168.84.188');
    expect(polls, 3);
  });
  for (final joined in [false, true]) {
    test('a stalled interface lookup has a deadline when joined=$joined', () async {
      final stalled = Completer<List<String>>();
      await expectLater(
          PlaudWifiConnector.waitForNetwork(
              joined: joined, addresses: () => stalled.future, timeout: const Duration(milliseconds: 20)),
          throwsA(isA<TimeoutException>()));
      stalled.completeError(StateError('Late OS error'));
      await Future<void>.delayed(Duration.zero);
    });
  }
  for (final cancel in [false, true]) {
    test('join ${cancel ? "cancelled while pending" : "refused"} always removes owned configuration', () async {
      final peer = Peer();
      await peer.connect();
      peer.handle = (_) => peer.emit(Uint8List.fromList([1, 10, 0, 0]));
      var active = true;
      final calls = <String>[];
      try {
        await expectLater(
            PlaudWifiConnector.connect(peer.session,
                startupDelay: Duration.zero,
                isActive: () => active,
                addresses: () async => [],
                native: (method, args) async {
                  calls.add(method);
                  if (method == 'join') {
                    if (cancel) {
                      active = false;
                    } else {
                      throw StateError('Join refused');
                    }
                  }
                }),
            throwsA(isA<PlaudWifiFailure>()));
        expect(calls, ['join', 'leave']);
        expect(peer.session.isClosed, isTrue);
      } finally {
        await peer.dispose();
      }
    });
  }
  test('failed cleanup stays retryable without restarting hotspot', () async {
    final peer = Peer();
    await peer.connect();
    peer.handle = (_) => peer.emit(Uint8List.fromList([1, 10, 0, 0]));
    var failCleanup = true;
    final calls = <String>[];
    try {
      try {
        await PlaudWifiConnector.connect(peer.session,
            startupDelay: Duration.zero,
            isActive: () => true,
            addresses: () async => [],
            native: (method, args) async {
              calls.add(method);
              if (method == 'join' || failCleanup) throw const PlaudException(PlaudIssue.timeout);
            });
        fail('Expected join failure');
      } on PlaudWifiFailure catch (failure) {
        expect(failure.cleanup, isNotNull);
        failCleanup = false;
        await failure.cleanup!();
      }
      expect(calls, ['join', 'leave', 'leave']);
    } finally {
      await peer.dispose();
    }
  });
}
