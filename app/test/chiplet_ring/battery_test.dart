import 'dart:async';
import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices/chiplet_ring_connection.dart';
import 'fake_ring.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeRingTransport peer;
  late RingDeviceConnection connection;
  setUp(() {
    root = Directory.systemTemp.createTempSync('ring-battery-');
    peer = FakeRingTransport(root);
    final device = BtDevice(id: 'ring-fixture', name: 'Ring', type: DeviceType.chipletRing, rssi: -40);
    connection = RingDeviceConnection(device, BluetoothDevice.fromId(device.id), transport: peer);
  });
  tearDown(() async {
    await connection.retire();
    await peer.stream.close();
    root.deleteSync(recursive: true);
  });

  test('initial query, push and later queries all update the normal battery listener', () async {
    await connection.connect();
    final values = <int>[];
    final listener = await connection.getBleBatteryLevelListener(onBatteryLevelChange: values.add);
    expect(values, [76]);
    expect(connection.pongAt, isNotNull);
    peer.stream.add({'event': 'battery', 'id': 'another-ring', 'value': 1});
    peer.stream.add({'event': 'battery', 'id': 'ring-fixture', 'value': 55});
    peer.batteryLevel = 91;
    expect(await connection.retrieveBatteryLevel(), 91);
    peer.batteryLevel = -1;
    expect(await connection.ping(), isTrue);
    expect(values, [76, 55, 91, -1]);
    await listener?.cancel();
  });

  test('concurrent initial listeners share one query and later listeners receive the cache', () async {
    await connection.connect();
    peer.batteryGate = Completer<void>();
    final a = <int>[], b = <int>[], cached = <int>[];
    final first = connection.getBleBatteryLevelListener(onBatteryLevelChange: a.add);
    final second = connection.getBleBatteryLevelListener(onBatteryLevelChange: b.add);
    await Future<void>.delayed(Duration.zero);
    expect(peer.batteryReads, 1);
    peer.batteryGate!.complete();
    final listeners = await Future.wait([first, second]);
    listeners.add(await connection.getBleBatteryLevelListener(onBatteryLevelChange: cached.add));
    expect(a, [76]);
    expect(b, [76]);
    expect(cached, [76]);
    expect(peer.batteryReads, 1);
    for (final listener in listeners) {
      await listener?.cancel();
    }
  });

  test('an old battery query cannot update a reconnected session', () async {
    await connection.connect();
    peer.batteryGate = Completer<void>();
    final oldValues = <int>[];
    final old = connection.getBleBatteryLevelListener(onBatteryLevelChange: oldValues.add);
    await Future<void>.delayed(Duration.zero);
    final oldGate = peer.batteryGate!;
    await connection.disconnect();
    peer.batteryGate = null;
    peer.batteryLevel = 34;
    await connection.connect();
    final newValues = <int>[];
    final current = await connection.getBleBatteryLevelListener(onBatteryLevelChange: newValues.add);
    oldGate.complete();
    await (await old)?.cancel();
    expect(oldValues, isEmpty);
    expect(newValues, [34]);
    await current?.cancel();
  });

  test('polling pauses in background and during operations, resumes, and stops on disconnect', () {
    fakeAsync((clock) {
      connection.connect();
      clock.flushMicrotasks();
      final values = <int>[];
      StreamSubscription<List<int>>? listener;
      connection.getBleBatteryLevelListener(onBatteryLevelChange: values.add).then((value) => listener = value);
      clock.flushMicrotasks();
      peer.batteryLevel = 83;
      clock.elapse(const Duration(seconds: 30));
      expect(values, [76, 83]);
      connection.didChangeAppLifecycleState(AppLifecycleState.paused);
      clock.elapse(const Duration(seconds: 60));
      expect(peer.batteryReads, 2);
      connection.ping();
      clock.flushMicrotasks();
      expect(peer.batteryReads, 2);
      connection.didChangeAppLifecycleState(AppLifecycleState.resumed);
      clock.flushMicrotasks();
      expect(peer.batteryReads, 3);
      peer.transportBusy = true;
      clock.elapse(const Duration(seconds: 30));
      connection.ping();
      clock.flushMicrotasks();
      expect(peer.batteryReads, 3);
      peer.transportBusy = false;
      connection.disconnect();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 60));
      expect(peer.batteryReads, 3);
      listener?.cancel();
      clock.flushMicrotasks();
    });
  });
}
