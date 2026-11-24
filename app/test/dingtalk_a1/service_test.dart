import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/dingtalk_a1/sync_controller.dart';
import 'package:memorion/services/devices/dingtalk_a1/sync_service.dart';

class Devices extends Fake implements IDeviceService {
  final subscriptions = <Object, IDeviceServiceSubsciption>{};
  BtDevice? active;
  int disconnects = 0;
  @override
  BtDevice? get connectedDevice => active;
  @override
  void subscribe(IDeviceServiceSubsciption subscription, Object context) => subscriptions[context] = subscription;
  @override
  void unsubscribe(Object context) => subscriptions.remove(context);
  @override
  Future<void> forceDisconnect(String id) async {
    disconnects++;
    active = null;
  }

  void connected() {
    for (final s in subscriptions.values) {
      s.onDeviceConnectionStateChanged(active!.id, DeviceConnectionState.connected);
    }
  }
}

class Probe extends A1SyncController {
  int refreshes = 0;
  Probe(bool Function() owner)
      : super(
            openStore: () async => throw StateError('No storage needed'),
            openSession: () async => null,
            isCurrentOwner: owner,
            readAutoSync: () async => false,
            writeAutoSync: (_) async {});
  @override
  Future<void> refresh() async {
    refreshes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('app lifetime coordinator reacts to connection and retires old account sessions', () async {
    final devices = Devices();
    final device = BtDevice(id: 'a1', name: 'DingTalk A1', type: DeviceType.dingtalkA1, rssi: -45);
    devices.active = device;
    var owner = 'owner-a';
    final probes = <String, Probe>{};
    final service = A1SyncService(
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
}
