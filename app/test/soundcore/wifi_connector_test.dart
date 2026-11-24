import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore/wifi_connector.dart';
import 'package:memorion/services/devices/soundcore/wifi_transport.dart';

import 'fake_device.dart';
import 'fake_wifi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('me.memorion.api/soundcore_wifi');

  for (final leaving in [false, true]) {
    test('network ${leaving ? "exit" : "readiness"} deadline bounds a stalled interface lookup', () async {
      final lookup = Completer<List<String>>();
      const endpoint = SoundcoreWifiEndpoint('192.168.43.1', 443);
      final work = leaving
          ? SoundcoreWifiConnector.waitForRecorderNetworkExit(endpoint,
              localAddresses: () => lookup.future, timeout: const Duration(milliseconds: 20))
          : SoundcoreWifiConnector.waitForRecorderNetwork(endpoint,
              localAddresses: () => lookup.future, timeout: const Duration(milliseconds: 20));
      await expectLater(
        work.timeout(const Duration(milliseconds: 300), onTimeout: () => throw StateError('Network deadline missing')),
        throwsA(isA<TimeoutException>()),
      );
      lookup.completeError(StateError('Late platform lookup failure'));
      await Future<void>.delayed(Duration.zero);
    });
  }

  test('network readiness rejects cellular, previous Wi-Fi and the recorder address itself', () async {
    const host = '192.168.43.1';
    expect(SoundcoreWifiConnector.hasRecorderAddress(host, ['10.2.0.1', '192.168.0.2', host, '::1']), isFalse);
    expect(SoundcoreWifiConnector.hasRecorderAddress(host, ['192.168.43.2']), isTrue);
    var polls = 0;
    await SoundcoreWifiConnector.waitForRecorderNetwork(
      const SoundcoreWifiEndpoint(host, 443),
      localAddresses: () async => ++polls < 3 ? ['192.168.0.2'] : ['192.168.43.2'],
      interval: Duration.zero,
    );
    expect(polls, 3);
  });

  for (final ready in [false, true]) {
    test('accepted system join ${ready ? "waits for DHCP before transport" : "without local network cleans up"}',
        () async {
      final peer = FakeSoundcoreDevice(1700000000);
      final phases = <SoundcoreWifiPhase>[];
      final calls = <String>[];
      final wifi = FakeSoundcoreWifi(peer);
      var transportOpened = false;
      final session = SoundcoreSession(
        notifications: peer.inbound.stream,
        send: (bytes) async {
          if (bytes[5] == 0x1a && bytes[6] == 5) {
            final frame = response(0x1a, 5, [1, 43, 168, 192, 187, 1]);
            frame[4] = 1;
            frame.last = frame.take(frame.length - 1).fold(0, (a, b) => (a + b) & 255);
            peer.emit(frame);
          } else {
            await peer.send(bytes);
          }
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      try {
        final work = SoundcoreWifiConnector.connect(
          session,
          startupDelay: Duration.zero,
          onPhase: phases.add,
          waitForNetwork: (endpoint) async {
            expect(calls, ['join']);
            expect(transportOpened, isFalse);
            await SoundcoreWifiConnector.waitForRecorderNetwork(
              endpoint,
              localAddresses: () async => [ready ? '192.168.43.2' : '192.168.0.2'],
              timeout: Duration.zero,
            );
          },
          connectTransport: (_, cleanup) async {
            transportOpened = true;
            wifi.leave = cleanup;
            return wifi;
          },
        );
        if (ready) {
          final connection = await work;
          expect(connection.transport, same(wifi));
          expect(phases.last, SoundcoreWifiPhase.connecting);
          await connection.close();
          expect(connection.session.isClosed, isTrue);
        } else {
          await expectLater(
              work,
              throwsA(
                  isA<SoundcoreWifiFailure>().having((e) => e.phase, 'phase', SoundcoreWifiPhase.verifyingNetwork)));
          expect(transportOpened, isFalse);
          expect(phases.last, SoundcoreWifiPhase.verifyingNetwork);
        }
        expect(calls, ['join', 'leave']);
        expect(peer.commands.any((c) => c[5] == 0x1a && c[6] == 2), isTrue);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        session.close();
        await wifi.close();
        await peer.inbound.close();
      }
    });
  }

  test('slow hotspot response uses its own timeout; join refusal has a stage and cleans up', () async {
    final peer = FakeSoundcoreDevice(1700000000);
    final calls = <String>[];
    final phases = <SoundcoreWifiPhase>[];
    final session = SoundcoreSession(
      notifications: peer.inbound.stream,
      commandTimeout: const Duration(milliseconds: 10),
      hotspotTimeout: const Duration(milliseconds: 300),
      send: (bytes) async {
        if (bytes[5] == 0x1a && bytes[6] == 5) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final frame = response(0x1a, 5, [1, 43, 168, 192, 187, 1]);
          frame[4] = 1;
          frame.last = frame.take(frame.length - 1).fold(0, (a, b) => (a + b) & 255);
          peer.emit(frame);
        } else {
          await peer.send(bytes);
        }
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'join') throw PlatformException(code: 'hotspot_join_timeout');
      return null;
    });
    try {
      await expectLater(
        SoundcoreWifiConnector.connect(session, onPhase: phases.add, startupDelay: Duration.zero),
        throwsA(isA<SoundcoreWifiFailure>()
            .having((e) => e.phase, 'phase', SoundcoreWifiPhase.joining)
            .having((e) => (e.cause as PlatformException).code, 'code', 'hotspot_join_timeout')),
      );
      expect(phases, [
        SoundcoreWifiPhase.openingHotspot,
        SoundcoreWifiPhase.waitingForHotspot,
        SoundcoreWifiPhase.joining,
      ]);
      expect(calls, ['join', 'leave']);
      expect(peer.commands.any((c) => c[5] == 0x1a && c[6] == 2), isTrue);
      expect(session.diagnostics, contains('reply 1a/5'));
      expect(session.diagnostics, isNot(contains('Memorion-SC-')));
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      session.close();
      await peer.inbound.close();
    }
  });
}
