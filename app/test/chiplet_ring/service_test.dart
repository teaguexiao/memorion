import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/chiplet_ring/sync_controller.dart';
import 'package:memorion/services/devices/chiplet_ring/sync_service.dart';

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
    for (final listener in subscriptions.values) {
      listener.onDeviceConnectionStateChanged(active!.id, DeviceConnectionState.connected);
    }
  }
}

class Probe extends RingSyncController {
  int syncs = 0, cancels = 0, disposals = 0, resumes = 0;
  Completer<void>? retireGate;
  bool failRetire = false;
  Probe(bool Function() owner)
      : super(
            openStore: () async => throw StateError('No storage'),
            openTransport: () async => null,
            isCurrentOwner: owner,
            lookup: (_) async => {});
  @override
  Future<void> sync() async {
    syncs++;
  }

  @override
  Future<void> cancelForAccount() async {
    cancels++;
    await retireGate?.future;
    if (failRetire) throw StateError('Peripheral disconnect failed');
  }

  @override
  Future<void> resumeAfterSubscriptionUpgrade() async {
    resumes++;
  }

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

BtDevice device(DeviceType type) => BtDevice(id: type.name, name: type.name, type: type, rssi: -40);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('account startup leaves the paired ring connected without a guest import queue', () async {
    final ring = device(DeviceType.chipletRing);
    final devices = Devices()..active = ring;
    var created = 0;
    final service = RingSyncService(
        devices: devices,
        currentOwner: () => '',
        pairedDevice: () => ring,
        createController: (_, captured) {
          created++;
          return Probe(() => false);
        });
    service.start();
    devices.connected();
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await service.checkNow();
    expect(devices.active, same(ring));
    expect(devices.disconnects, 0);
    expect(created, 0);
    service.stop();
  });
  test('only the ring is synced or disconnected on account changes', () async {
    for (final type in DeviceType.values.where((t) => t != DeviceType.chipletRing)) {
      final devices = Devices()..active = device(type);
      var owner = 'alice';
      var created = 0;
      final service = RingSyncService(
          devices: devices,
          currentOwner: () => owner,
          pairedDevice: () => device(DeviceType.chipletRing),
          createController: (_, captured) {
            created++;
            return Probe(() => owner == captured);
          });
      service.start();
      await service.checkNow();
      await service.resumeAfterSubscriptionUpgrade();
      owner = '';
      await service.checkNow();
      service.stop();
      expect(created, 0, reason: type.name);
      expect(devices.disconnects, 0, reason: type.name);
      expect(devices.subscriptions, isEmpty);
    }
  });
  test('disconnect failure still retires the old account and allows later owners', () async {
    final ring = device(DeviceType.chipletRing);
    final devices = Devices()..active = ring;
    var owner = 'alice';
    final probes = <String, Probe>{};
    final service = RingSyncService(
        devices: devices,
        currentOwner: () => owner,
        pairedDevice: () => ring,
        createController: (_, captured) => probes[captured] = Probe(() => owner == captured));
    service.start();
    await service.checkNow();
    probes['alice']!.failRetire = true;
    owner = 'bob';
    await service.checkNow();
    expect(probes['alice']!.disposals, 1);
    expect(probes['bob']!.syncs, greaterThan(0));
    owner = 'charlie';
    await service.checkNow();
    expect(probes['bob']!.disposals, 1);
    expect(probes['charlie']!.syncs, greaterThan(0));
    service.stop();
  });
  test('connection, foreground and auth events use the app lifetime ring controller', () async {
    final ring = device(DeviceType.chipletRing);
    final devices = Devices()..active = ring;
    var owner = 'alice';
    final probes = <String, Probe>{};
    final auth = StreamController<User?>();
    final service = RingSyncService(
        devices: devices,
        currentOwner: () => owner,
        pairedDevice: () => ring,
        createController: (_, captured) => probes[captured] = Probe(() => owner == captured));
    service.start(authChanges: auth.stream);
    await service.checkNow();
    final first = probes['alice']!;
    final before = first.syncs;
    devices.connected();
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    auth.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(first.syncs, greaterThan(before));
    await service.resumeAfterSubscriptionUpgrade();
    expect(first.resumes, 1);
    owner = 'bob';
    await service.checkNow();
    expect(first.cancels, 1);
    expect(first.disposals, 1);
    expect(devices.disconnects, 1);
    expect(probes['bob'], isNotNull);
    service.stop();
    await auth.close();
    expect(devices.subscriptions, isEmpty);
  });
  test('concurrent account callbacks retire once before starting the new owner', () async {
    final ring = device(DeviceType.chipletRing);
    final devices = Devices()..active = ring;
    var owner = 'alice';
    final probes = <String, Probe>{};
    final service = RingSyncService(
        devices: devices,
        currentOwner: () => owner,
        pairedDevice: () => ring,
        createController: (_, captured) => probes[captured] = Probe(() => owner == captured));
    service.start();
    await service.checkNow();
    final first = probes['alice']!..retireGate = Completer<void>();
    owner = 'bob';
    final a = service.checkNow();
    final b = service.checkNow();
    await Future<void>.delayed(Duration.zero);
    expect(first.cancels, 1);
    expect(probes['bob'], isNull);
    first.retireGate!.complete();
    await Future.wait([a, b]);
    expect(first.disposals, 1);
    expect(devices.disconnects, 1);
    expect(probes['bob']!.syncs, greaterThan(0));
    service.stop();
  });
  test('logout retires the queue and disconnects the ring without creating a guest queue', () async {
    final ring = device(DeviceType.chipletRing);
    final devices = Devices()..active = ring;
    var owner = 'alice';
    final probes = <String, Probe>{};
    final service = RingSyncService(
        devices: devices,
        currentOwner: () => owner,
        pairedDevice: () => ring,
        createController: (_, captured) => probes[captured] = Probe(() => owner == captured));
    service.start();
    await service.checkNow();
    owner = '';
    await service.checkNow();
    expect(probes.keys, ['alice']);
    expect(devices.disconnects, 1);
    expect(probes['alice']!.disposals, 1);
    service.stop();
  });
}
