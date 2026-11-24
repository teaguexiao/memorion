import 'dart:async';
import 'devices/chiplet_ring/bridge.dart';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'devices/plaud/protocol.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices/device_connection.dart';
import 'package:memorion/services/devices/errors.dart';
import 'package:memorion/services/devices/models.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/dingtalk_a1/protocol.dart';
import 'package:memorion/services/devices/recorder_wifi_activity.dart';
import 'package:memorion/utils/bluetooth/bluetooth_adapter.dart';

abstract class IDeviceService {
  void start();
  void stop();
  Future<void> discover({String? desirableDeviceId, int timeout = 5});

  Future<DeviceConnection?> ensureConnection(String deviceId, {bool force = false});
  Future<void> forceDisconnect(String deviceId);

  /// Synchronously returns the currently-connected device, or null if none is
  /// connected. Does NOT touch the [ensureConnection] mutex, so it never blocks
  /// on an in-flight connect. Used to update the UI immediately when the BLE
  /// connection-state callback fires.
  BtDevice? get connectedDevice;

  void subscribe(IDeviceServiceSubsciption subscription, Object context);
  void unsubscribe(Object context);

  DateTime? getFirstConnectedAt();
}

enum DeviceServiceStatus {
  init,
  ready,
  scanning,
  stop,
}

enum DeviceConnectionState {
  connected,
  disconnected,
}

abstract class IDeviceServiceSubsciption {
  void onDevices(List<BtDevice> devices);
  void onStatusChanged(DeviceServiceStatus status);
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state);
}

class DeviceService implements IDeviceService {
  final DeviceConnection? Function(BtDevice, BluetoothDevice) _createConnection;

  DeviceService({DeviceConnection? Function(BtDevice, BluetoothDevice)? createConnection})
      : _createConnection = createConnection ?? DeviceConnectionFactory.create;

  DeviceServiceStatus _status = DeviceServiceStatus.init;
  List<BtDevice> _devices = [];
  List<ScanResult> _bleDevices = [];
  final _ringDevices = <String, BtDevice>{};
  StreamSubscription<Map<String, dynamic>>? _ringScan;
  Timer? _ringScanTimer;
  int _ringScanGeneration = 0;

  Future<void> _stopRingScan() async {
    _ringScanGeneration++;
    _ringScanTimer?.cancel();
    await _ringScan?.cancel();
    _ringScan = null;
    if (NativeRingTransport.available) {
      try {
        await NativeRingTransport.instance.stopScan();
      } catch (_) {}
    }
  }

  Future<void> _startRingScan(String? desired, int seconds) async {
    if (!NativeRingTransport.available) return;
    await _stopRingScan();
    final epoch = _ringScanGeneration;
    _ringDevices.clear();
    _ringScan = NativeRingTransport.instance.events.listen((event) {
      if (epoch != _ringScanGeneration || _status == DeviceServiceStatus.stop) return;
      if (event['event'] != 'devices') return;
      for (final value in event['devices'] as List) {
        final device = NativeRingTransport.discovered(value as Map);
        _ringDevices[device.id] = device;
      }
      _devices = [
        ..._devices.where((d) => d.type != DeviceType.chipletRing && !_ringDevices.containsKey(d.id)),
        ..._ringDevices.values,
      ]..sort((a, b) => b.rssi.compareTo(a.rssi));
      onDevices(_devices);
      if (desired != null && _ringDevices.containsKey(desired)) {
        unawaited(ensureConnection(desired, force: true).catchError((Object _) => null));
      }
    }, onError: (Object _) {});
    try {
      await NativeRingTransport.instance.scan();
      _ringScanTimer = Timer(Duration(seconds: seconds), () => unawaited(_stopRingScan()));
    } catch (_) {
      await _stopRingScan();
    }
  }

  final Map<Object, IDeviceServiceSubsciption> _subscriptions = {};

  DeviceConnection? _connection;

  List<BtDevice> get devices => _devices;

  DeviceServiceStatus get status => _status;

  @override
  BtDevice? get connectedDevice => _connection?.status == DeviceConnectionState.connected ? _connection?.device : null;

  DateTime? _firstConnectedAt;

  @override
  Future<void> discover({
    String? desirableDeviceId,
    int timeout = 5,
  }) async {
    if (RecorderWifiActivity.isActive(desirableDeviceId)) return;
    debugPrint("Device discovering...");
    if (_status != DeviceServiceStatus.ready) {
      logCommonErrorMessage("Device service is not ready, may busying or stop");
      return;
    }

    if (!(await BluetoothAdapter.isSupported)) {
      logCommonErrorMessage("Bluetooth is not supported");
      return;
    }

    if (BluetoothAdapter.isScanningNow) {
      debugPrint("Device service is scanning...");
      return;
    }

    // Listen to scan results, always re-emits previous results
    var discoverSubscription = BluetoothAdapter.scanResults.listen(
      (results) async {
        await _onBleDiscovered(results, desirableDeviceId);
      },
      onError: (e) {
        debugPrint('bleFindDevices error: $e');
      },
    );
    BluetoothAdapter.cancelWhenScanComplete(discoverSubscription);

    // Include D3200 even when its advertisement has no local name.
    _status = DeviceServiceStatus.scanning;
    await BluetoothAdapter.adapterState.where((val) => val == BluetoothAdapterStateHelper.on).first;
    await _startRingScan(desirableDeviceId, timeout);
    await BluetoothAdapter.startScan(
      timeout: Duration(seconds: timeout),
      // Original Note advertises manufacturer data but no service UUID. iOS
      // background discovery still requires the existing service filters.
      withServices: (WidgetsBinding.instance.lifecycleState == null ||
              WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed)
          ? []
          : [
              BluetoothAdapter.createGuid(memorionServiceUuid),
              BluetoothAdapter.createGuid(frameServiceUuid),
              BluetoothAdapter.createGuid(soundcoreServiceUuid),
              BluetoothAdapter.createGuid(a1ServiceUuid),
            ],
    );
    _status = DeviceServiceStatus.ready;
  }

  Future<void> _onBleDiscovered(List<dynamic> results, String? desirableDeviceId) async {
    _bleDevices = results.cast<ScanResult>().where((r) {
      if (_ringDevices.containsKey(r.device.remoteId.str) ||
          cachedDevicesMap[r.device.remoteId.str] == DeviceType.chipletRing) {
        return false;
      }
      final plaud = PlaudAdvertisement.parse(r.advertisementData.advName, r.advertisementData.manufacturerData);
      if (plaud != null) return plaud.supported;
      return BtDevice.typeFromServices(r.advertisementData.serviceUuids.map((uuid) => uuid.str128)) != null ||
          cachedDevicesMap.containsKey(r.device.remoteId.str);
    }).toList();
    _bleDevices.sort((a, b) => b.rssi.compareTo(a.rssi));
    _devices = [..._bleDevices.map<BtDevice>((e) => BtDevice.fromScanResult(e)), ..._ringDevices.values];
    onDevices(devices);

    // Check desirable device
    if (desirableDeviceId != null &&
        desirableDeviceId.isNotEmpty &&
        !RecorderWifiActivity.isActive(desirableDeviceId)) {
      await ensureConnection(desirableDeviceId, force: true);
    }
  }

  Future<void> _connectToDevice(String id) async {
    // Disconnected adapters can still observe OS reconnects or be authenticating.
    // Retire them before replacing the object, regardless of its ready status.
    await _retireConnection();

    var bleDevice = _bleDevices.firstWhereOrNull((f) => f.device.remoteId.str == id);
    var device = _devices.firstWhereOrNull((f) => f.id == id);
    // Ring discovery belongs to the native bridge, so no FBP scan result is required.
    if (device?.type == DeviceType.chipletRing) {
      await _stopRingScan();
      _connection = _createConnection(device!, BluetoothDevice.fromId(id));
      try {
        await _connection?.connect(onConnectionStateChanged: onDeviceConnectionStateChanged);
      } catch (_) {
        await _retireConnection();
        rethrow;
      }
      return;
    }
    if (bleDevice == null || device == null) {
      debugPrint("bleDevice or device is null, trying direct connection via fromId");
      await _connectToKnownDevice(id);
      return;
    }

    // Check exist ble device connection, force disconnect
    if (bleDevice.device.isConnected) {
      await bleDevice.device.disconnect();
    }

    // Then create new connection
    _connection = _createConnection(device, bleDevice.device);
    try {
      await _connection?.connect(onConnectionStateChanged: onDeviceConnectionStateChanged);
    } catch (_) {
      await _retireConnection();
      rethrow;
    }
    return;
  }

  /// Connect to a previously known device by ID without requiring a scan.
  /// This is the key reconnection path when the device is not found via scan.
  Future<void> _connectToKnownDevice(String id) async {
    try {
      final knownBleDevice = BluetoothDevice.fromId(id);

      // Use the stored device from preferences, or build a minimal BtDevice
      var storedDevice = _devices.firstWhereOrNull((f) => f.id == id);
      if (storedDevice == null) {
        var saved = SharedPreferencesUtil().btDevice;
        if (saved.id == id) {
          storedDevice = saved;
        } else {
          storedDevice = BtDevice(
            id: id,
            name: knownBleDevice.platformName.isNotEmpty ? knownBleDevice.platformName : id,
            type: DeviceType.memorion,
            rssi: -1,
          );
        }
      }

      // Force disconnect stale connection if any
      if (storedDevice.type == DeviceType.chipletRing) await _stopRingScan();
      if (storedDevice.type != DeviceType.chipletRing && knownBleDevice.isConnected) {
        await knownBleDevice.disconnect();
      }

      _connection = _createConnection(storedDevice, knownBleDevice);
      await _connection?.connect(onConnectionStateChanged: onDeviceConnectionStateChanged, isReconnect: true);
    } on DeviceConnectionException catch (e) {
      debugPrint("Direct connection to known device failed: $e");
      await _retireConnection();
    } catch (e) {
      debugPrint("Unexpected error connecting to known device: $e");
      await _retireConnection();
    }
  }

  Future<void> _retireConnection() async {
    final previous = _connection;
    _connection = null;
    await previous?.retire();
  }

  @override
  void subscribe(IDeviceServiceSubsciption subscription, Object context) {
    _subscriptions.remove(context.hashCode);
    _subscriptions.putIfAbsent(context.hashCode, () => subscription);

    // Retains
    subscription.onDevices(_devices);
    subscription.onStatusChanged(_status);
  }

  @override
  void unsubscribe(Object context) {
    _subscriptions.remove(context.hashCode);
  }

  @override
  void start() {
    _status = DeviceServiceStatus.ready;

    // TODO: Start watchdog to discover automatically, re-connect automatically
  }

  @override
  void stop() {
    unawaited(_stopRingScan());
    _ringDevices.clear();
    _status = DeviceServiceStatus.stop;
    onStatusChanged(_status);

    if (BluetoothAdapter.isScanningNow) {
      BluetoothAdapter.stopScan();
    }
    _subscriptions.clear();
    _devices.clear();
    _bleDevices.clear();
  }

  void onStatusChanged(DeviceServiceStatus status) {
    for (var s in _subscriptions.values) {
      s.onStatusChanged(status);
    }
  }

  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) {
    debugPrint("device connection state changed...$deviceId...$state");
    for (var s in _subscriptions.values) {
      s.onDeviceConnectionStateChanged(deviceId, state);
    }
  }

  void onDevices(List<BtDevice> devices) {
    for (var s in _subscriptions.values) {
      s.onDevices(devices);
    }
  }

  // Warn: Should use a better solution to prevent race conditions
  bool mutex = false;
  @override
  Future<DeviceConnection?> ensureConnection(String deviceId, {bool force = false}) async {
    while (mutex) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    mutex = true;

    debugPrint("ensureConnection ${_connection?.device.id} ${_connection?.status} $force");
    try {
      // A manual handoff performs one explicit forced control reconnect. All
      // background callers must leave its radio/session alone until teardown.
      if (!force && RecorderWifiActivity.isActive(deviceId)) {
        return _connection?.device.id == deviceId && _connection?.status == DeviceConnectionState.connected
            ? _connection
            : null;
      }
      // Not force
      if (!force && _connection != null) {
        if (_connection?.device.id != deviceId || _connection?.status != DeviceConnectionState.connected) {
          return null;
        }

        // connected
        var pongAt = _connection?.pongAt;
        var shouldPing = (pongAt == null || pongAt.isBefore(DateTime.now().subtract(const Duration(seconds: 5))));
        if (shouldPing) {
          var ok = await _connection?.ping() ?? false;
          if (!ok) {
            await _connection?.disconnect();
            return null;
          }
        }

        return _connection;
      }

      // Force
      if (deviceId == _connection?.device.id && _connection?.status == DeviceConnectionState.connected) {
        var pongAt = _connection?.pongAt;
        var shouldPing = (pongAt == null || pongAt.isBefore(DateTime.now().subtract(const Duration(seconds: 5))));
        if (shouldPing) {
          var ok = await _connection?.ping() ?? false;
          if (!ok) {
            await _connection?.disconnect();
            return null;
          }
        }

        return _connection;
      }

      // connect
      try {
        await _connectToDevice(deviceId);
      } on DeviceConnectionException catch (e) {
        debugPrint(e.toString());
        return null;
      }

      _firstConnectedAt ??= DateTime.now();
      return _connection;
    } finally {
      mutex = false;
    }
  }

  @override
  Future<void> forceDisconnect(String deviceId) async {
    if (_connection?.device.id == deviceId) {
      await _retireConnection();
    }
  }

  @override
  DateTime? getFirstConnectedAt() {
    return _firstConnectedAt;
  }
}
