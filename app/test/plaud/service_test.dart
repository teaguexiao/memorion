import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/device_connection.dart';
import 'package:memorion/services/devices/plaud/sync_controller.dart';
import 'package:memorion/services/devices/plaud/sync_service.dart';

class Devices extends Fake implements IDeviceService {
  final subscriptions = <Object, IDeviceServiceSubsciption>{};
  BtDevice? active;
  int disconnects = 0;
  final connectionCalls = <String>[];
  void Function()? afterDisconnect;
  @override
  BtDevice? get connectedDevice => active;
  @override
  void subscribe(IDeviceServiceSubsciption subscription, Object context) => subscriptions[context] = subscription;
  @override
  void unsubscribe(Object context) => subscriptions.remove(context);
  @override
  Future<void> forceDisconnect(String id) async {
    connectionCalls.add('disconnect:$id');
    disconnects++;
    active = null;
    afterDisconnect?.call();
  }

  @override
  Future<DeviceConnection?> ensureConnection(String id, {bool force = false}) async {
    connectionCalls.add('connect:$id:$force');
    return null;
  }

  void connected() {
    for (final s in subscriptions.values) {
      s.onDeviceConnectionStateChanged(active!.id, DeviceConnectionState.connected);
    }
  }
}

class Probe extends PlaudSyncController {
  int refreshes = 0;
  Probe(bool Function() owner)
      : super(
            openStore: () async => throw StateError('No storage needed'),
            openSession: () async => null,
            readIdentity: () async => null,
            isCurrentOwner: owner);
  @override
  Future<void> refresh() async {
    refreshes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Wi-Fi handoff physically disconnects before its forced authenticated reconnect', () async {
    final devices = Devices();
    final device = BtDevice(id: 'note', name: 'PLAUD Note', type: DeviceType.plaudNote, rssi: -45);
    var owner = 'a';
    final service = PlaudSyncService(devices: devices, currentOwner: () => owner);
    final sync = service.controllerFor(device);
    addTearDown(sync.dispose);
    await sync.reconnectSession!();
    expect(devices.connectionCalls, ['disconnect:note', 'connect:note:true']);
    devices.connectionCalls.clear();
    devices.afterDisconnect = () => owner = 'b';
    await sync.reconnectSession!();
    expect(devices.connectionCalls, ['disconnect:note']);
    devices.connectionCalls.clear();
    await sync.reconnectSession!();
    expect(devices.connectionCalls, isEmpty);
  });
  test('app lifetime coordinator reacts to connection and retires old account sessions', () async {
    final devices = Devices();
    final device = BtDevice(id: 'a1', name: 'PLAUD Note', type: DeviceType.plaudNote, rssi: -45);
    devices.active = device;
    var owner = 'owner-a';
    final probes = <String, Probe>{};
    final service = PlaudSyncService(
        devices: devices,
        currentOwner: () => owner,
        pairedDevice: () => device,
        createController: (_, captured) => probes[captured] = Probe(() => owner == captured));
    service.start();
    await service.checkNow();
    final first = probes['owner-a']!;
    final before = first.refreshes;
    devices.connected();
    await Future<void>.delayed(Duration.zero);
    expect(first.refreshes, greaterThan(before));
    owner = 'owner-b';
    await service.checkNow();
    expect(first.ownerActive, isFalse);
    expect(devices.disconnects, 1);
    expect(probes['owner-b'], isNotNull);
    service.stop();
    expect(devices.subscriptions, isEmpty);
    for (final p in probes.values) {
      p.dispose();
    }
  });
  test('reconnect retries do not refresh the same disconnected directory repeatedly', () async {
    final devices = Devices();
    final device = BtDevice(id: 'note', name: 'PLAUD Note', type: DeviceType.plaudNote, rssi: -45);
    final probe = Probe(() => true);
    final service = PlaudSyncService(
        devices: devices, currentOwner: () => 'owner', pairedDevice: () => device, createController: (_, __) => probe);
    service.start();
    await Future<void>.delayed(Duration.zero);
    service.onDeviceConnectionStateChanged(device.id, DeviceConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    final before = probe.refreshes;
    for (var i = 0; i < 10; i++) {
      service.onDeviceConnectionStateChanged(device.id, DeviceConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
    }
    service.onDeviceConnectionStateChanged('unrelated', DeviceConnectionState.connected);
    await Future<void>.delayed(Duration.zero);
    expect(probe.refreshes, before);
    devices.active = device;
    devices.connected();
    await Future<void>.delayed(Duration.zero);
    expect(probe.refreshes, before + 1);
    await service.checkNow();
    expect(probe.refreshes, before + 2); // Periodic upload retry remains enabled.
    service.stop();
    probe.dispose();
  });
}
