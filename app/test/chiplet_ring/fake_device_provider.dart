import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:memorion/providers/onboarding_provider.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/services/devices.dart';

class ManagementDevices extends Fake implements IDeviceService {
  @override
  void subscribe(IDeviceServiceSubsciption subscription, Object context) {}
  @override
  void unsubscribe(Object context) {}
}

class ManagementDeviceProvider extends DeviceProvider {
  ManagementDeviceProvider(BtDevice device, {bool connected = true}) : super(deviceService: ManagementDevices()) {
    pairedDevice = device;
    connectedDevice = connected ? device : null;
    isConnected = connected;
    batteryLevel = 76;
  }
  void updateConnection(BtDevice device, bool connected) {
    isConnected = connected;
    connectedDevice = connected ? device : null;
    notifyListeners();
  }

  @override
  Future<void> getDeviceInfo({bool forceRefresh = false}) async {}
  @override
  Future<void> readLedMode() async {}
}

class ManagementOnboarding extends ChangeNotifier implements OnboardingProvider {
  int scans = 0;
  @override
  List<BtDevice> get deviceList => [];
  @override
  void stopScanDevices() {}
  @override
  Future<void> scanDevices({required VoidCallback onShowDialog}) async {
    scans++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
