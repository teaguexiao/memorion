import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Bluetooth adapter — thin wrapper around flutter_blue_plus.
class BluetoothAdapter {
  static Future<bool> get isSupported => FlutterBluePlus.isSupported;

  static bool get isScanningNow => FlutterBluePlus.isScanningNow;

  static Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  static Stream<BluetoothAdapterState> get adapterState => FlutterBluePlus.adapterState;

  static Future<void> startScan({
    Duration? timeout,
    List<Guid>? withServices,
  }) {
    return FlutterBluePlus.startScan(
      timeout: timeout,
      withServices: withServices ?? <Guid>[],
    );
  }

  static Future<void> stopScan() => FlutterBluePlus.stopScan();

  static void cancelWhenScanComplete(StreamSubscription subscription) {
    FlutterBluePlus.cancelWhenScanComplete(subscription);
  }

  static Guid createGuid(String uuid) => Guid(uuid);

  static Type get flutterBluePlus => FlutterBluePlus;
}

/// Adapter state helpers.
class BluetoothAdapterStateHelper {
  static BluetoothAdapterState get on => BluetoothAdapterState.on;
  static BluetoothAdapterState get off => BluetoothAdapterState.off;
  static BluetoothAdapterState get unknown => BluetoothAdapterState.unknown;
}

/// Connection state helpers.
class BluetoothConnectionStateHelper {
  static BluetoothConnectionState get connected => BluetoothConnectionState.connected;
  static BluetoothConnectionState get disconnected => BluetoothConnectionState.disconnected;
}
