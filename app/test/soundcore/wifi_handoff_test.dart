import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore/wifi_connection.dart';
import 'package:memorion/services/devices/soundcore/wifi_connector.dart';

import 'fake_device.dart';
import 'fake_wifi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('me.memorion.api/soundcore_wifi');

  for (final disconnectAt in ['hotspot reply', 'system join', 'first download']) {
    test('real connector preserves decryption through BLE loss at $disconnectAt', () async {
      final id = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
      final peer = FakeSoundcoreDevice(id);
      final wifi = FakeSoundcoreWifi(peer);
      final gate = Completer<void>();
      if (disconnectAt == 'first download') wifi.gate = gate.future;
      late SoundcoreSession ble;
      void dropBluetooth() {
        peer.bleDisconnected = true;
        ble.close();
      }

      ble = SoundcoreSession(
        notifications: peer.inbound.stream,
        send: (bytes) async {
          await peer.send(bytes);
          if (bytes[5] == 0x1a && bytes[6] == 5 && disconnectAt == 'hotspot reply') dropBluetooth();
        },
      );
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'join' && disconnectAt == 'system join') dropBluetooth();
        return null;
      });
      SoundcoreWifiConnection? connection;
      try {
        connection = await SoundcoreWifiConnector.connect(
          ble,
          startupDelay: Duration.zero,
          waitForNetwork: (_) async {},
          connectTransport: (_, leave) async {
            wifi.leave = leave;
            return wifi;
          },
        );
        final commandsAtHandoff = peer.commands.length;
        final file = SoundcoreRecording(id, id + 6, 6000);
        final downloading = connection.download(file);
        if (disconnectAt == 'first download') {
          for (var i = 0; i < 100 && wifi.requested.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(wifi.requested, [id]);
          // UI battery polls must stay local during the handoff/batch.
          await ble.readInfo();
          await expectLater(ble.listRecordings(), throwsStateError);
          dropBluetooth();
          gate.complete();
        }
        final audio = await downloading;
        addTearDown(audio.dispose);
        expect(ascii.decode((await audio.readBytes()).take(4).toList()), 'OggS');
        expect(audio.duration, const Duration(seconds: 6));
        expect(ble.isClosed, isTrue);
        expect(ble.transferStep, isNull); // Matches the user's exact failure.
        expect(connection.session.isClosed, isFalse);
        // Control: reusing the released BLE session still fails, as it should.
        await expectLater(ble.download(file, transport: wifi), throwsStateError);
        final second = await connection.download(SoundcoreRecording(id + 1, id + 7, 6000));
        addTearDown(second.dispose);
        expect(second.duration, const Duration(seconds: 6));
        expect(peer.commands.length, commandsAtHandoff, reason: 'No GATT reads or new handshake after hotspot setup');
        expect(wifi.acks, 2);
        await connection.close();
        await connection.close();
        expect(connection.session.isClosed, isTrue);
        expect(nativeCalls, ['join', 'leave']);
        expect(wifi.closed, isTrue);
        await expectLater(connection.download(file), throwsStateError);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await connection?.close();
        await wifi.close();
        ble.close();
        await peer.inbound.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    });
  }
}
