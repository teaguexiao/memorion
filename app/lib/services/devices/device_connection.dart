import 'package:memorion/services/devices/soundcore/wifi_activity.dart';
import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/frame_connection.dart';
import 'package:memorion/services/devices/memorion_connection.dart';
import 'package:memorion/services/devices/soundcore_connection.dart';
import 'package:memorion/services/devices/dingtalk_a1_connection.dart';
import 'plaud_connection.dart';
import 'chiplet_ring_connection.dart';
import 'package:memorion/services/notifications.dart';
import 'package:memorion/utils/bluetooth/bluetooth_adapter.dart';
import 'package:memorion/utils/localization_helper.dart';

class DeviceConnectionFactory {
  static DeviceConnection? create(
    BtDevice device,
    BluetoothDevice bleDevice,
  ) {
    if (device.type == null) {
      return null;
    }
    switch (device.type!) {
      case DeviceType.memorion:
        return MemorionDeviceConnection(device, bleDevice);
      case DeviceType.openglass:
        return MemorionDeviceConnection(device, bleDevice);
      case DeviceType.frame:
        return FrameDeviceConnection(device, bleDevice);
      case DeviceType.soundcore:
        return SoundcoreDeviceConnection(device, bleDevice);
      case DeviceType.plaudNote:
        return PlaudDeviceConnection(device, bleDevice);
      case DeviceType.chipletRing:
        return RingDeviceConnection(device, bleDevice);
      case DeviceType.dingtalkA1:
        return A1DeviceConnection(device, bleDevice);
      default:
        return null;
    }
  }
}

class DeviceConnectionException implements Exception {
  String cause;
  DeviceConnectionException(this.cause);
}

abstract class DeviceConnection {
  BtDevice device;
  BluetoothDevice bleDevice;
  DateTime? _pongAt;
  DateTime? _lastDataReceivedAt;

  DateTime? get lastDataReceivedAt => _lastDataReceivedAt;

  void onDataReceived() {
    _lastDataReceivedAt = DateTime.now();
  }

  Future<bool> isHealthy({Duration dataTimeout = const Duration(seconds: 20)}) async {
    if (_lastDataReceivedAt != null && _lastDataReceivedAt!.isAfter(DateTime.now().subtract(dataTimeout))) {
      return true;
    }
    return await ping();
  }

  DeviceConnectionState _connectionState = DeviceConnectionState.disconnected;

  List<BluetoothService> _services = [];

  DeviceConnectionState get status => _connectionState;

  DeviceConnectionState get connectionState => _connectionState;

  Function(String deviceId, DeviceConnectionState state)? _connectionStateChangedCallback;

  DateTime? get pongAt => _pongAt;

  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  int _stateGeneration = 0;
  bool _disposed = false;

  /// A replaced connection must never resume work on the shared BLE device.
  bool get isDisposed => _disposed;

  DeviceConnection(
    this.device,
    this.bleDevice,
  );

  Future<void> connect({
    Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged,
    bool isReconnect = false,
  }) async {
    if (_disposed) throw DeviceConnectionException('Connection has been disposed');
    if (_connectionState == DeviceConnectionState.connected) {
      throw DeviceConnectionException("Connection already established, please disconnect before start new connection");
    }

    // Connect
    await _connectionStateSubscription?.cancel();
    if (_disposed) throw DeviceConnectionException('Connection has been disposed');
    _connectionStateChangedCallback = onConnectionStateChanged;
    _connectionStateSubscription = bleDevice.connectionState.listen(_onBleConnectionStateChanged);

    try {
      await BluetoothAdapter.adapterState.where((val) => val == BluetoothAdapterStateHelper.on).first;
      if (_disposed) throw DeviceConnectionException('Connection has been disposed');
      // On iOS, use autoConnect for reconnection attempts so the OS monitors
      // for the device in the background and connects when it becomes available.
      // On Android, autoConnect is avoided due to GATT error 133 issues.
      final useAutoConnect = isReconnect && Platform.isIOS;
      await bleDevice.connect(
        autoConnect: useAutoConnect,
        timeout: useAutoConnect ? const Duration(seconds: 30) : const Duration(seconds: 15),
      );
      await bleDevice.connectionState
          .where((val) => val == BluetoothConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 30), onTimeout: () => throw DeviceConnectionException("Connection timeout"));
      if (_disposed) throw DeviceConnectionException('Connection has been disposed');
    } on FlutterBluePlusException catch (e) {
      throw DeviceConnectionException("FlutterBluePlusException: ${e.toString()}");
    }

    // Mtu
    if (Platform.isAndroid && bleDevice.mtuNow < 512) {
      await bleDevice.requestMtu(512); // This might fix the code 133 error
    }

    // Check connection
    await ping();

    // Discover services
    final services = await bleDevice.discoverServices();
    if (_disposed) throw DeviceConnectionException('Connection has been disposed');
    _services = services;
  }

  void _onBleConnectionStateChanged(BluetoothConnectionState state) async {
    if (_disposed) return;
    if (state == BluetoothConnectionState.disconnected && _connectionState == DeviceConnectionState.connected) {
      _stateGeneration++;
      _connectionState = DeviceConnectionState.disconnected;
      // Notify callback but do NOT call bleDevice.disconnect() or cancel subscription.
      // The device is already disconnected; calling disconnect() is redundant and
      // cancelling the subscription prevents detecting OS-level auto-reconnection.
      if (_connectionStateChangedCallback != null) {
        _connectionStateChangedCallback!(device.id, _connectionState);
      }
      _services.clear();
      return;
    }

    if (state == BluetoothConnectionState.connected && _connectionState == DeviceConnectionState.disconnected) {
      final generation = ++_stateGeneration;
      _connectionState = DeviceConnectionState.connected;
      // Re-discover services after reconnection
      try {
        final services = await bleDevice.discoverServices();
        if (_disposed || generation != _stateGeneration) return;
        _services = services;
      } catch (e) {
        debugPrint('Error re-discovering services after reconnect: $e');
      }
      if (!_disposed && generation == _stateGeneration && _connectionStateChangedCallback != null) {
        _connectionStateChangedCallback!(device.id, _connectionState);
      }
    }
  }

  /// User-initiated disconnect. Cleans up all resources.
  Future<void> disconnect() async {
    _stateGeneration++;
    _connectionState = DeviceConnectionState.disconnected;
    if (_connectionStateChangedCallback != null) {
      _connectionStateChangedCallback!(device.id, _connectionState);
      _connectionStateChangedCallback = null;
    }
    final subscription = _connectionStateSubscription;
    _connectionStateSubscription = null;
    await subscription?.cancel();
    try {
      await bleDevice.disconnect();
    } catch (e) {
      debugPrint('Error during explicit disconnect: $e');
    }
    _services.clear();
  }

  /// Permanently retire an object before its replacement touches the radio.
  Future<void> retire() async {
    _disposed = true;
    await disconnect();
  }

  Future<bool> ping() async {
    try {
      int rssi = await bleDevice.readRssi();
      device.rssi = rssi;
      _pongAt = DateTime.now();
      return true;
    } catch (e) {
      debugPrint('Error reading RSSI: $e');
    }

    return false;
  }

  void read() {}

  void write() {}

  Future<BluetoothService?> getService(String uuid) async {
    return _services.firstWhereOrNull((service) => service.uuid.str128.toLowerCase() == uuid);
  }

  BluetoothCharacteristic? getCharacteristic(BluetoothService service, String uuid) {
    return service.characteristics.firstWhereOrNull(
      (characteristic) => characteristic.uuid.str128.toLowerCase() == uuid.toLowerCase(),
    );
  }

  // Mimic @app/lib/utils/device_base.dart
  Future<bool> isConnected();

  Future<int> retrieveBatteryLevel() async {
    if (await isConnected()) {
      return await performRetrieveBatteryLevel();
    }
    _showDeviceDisconnectedNotification();
    return -1;
  }

  Future<int> performRetrieveBatteryLevel();

  Future<StreamSubscription<List<int>>?> getBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
  }) async {
    if (await isConnected()) {
      return await performGetBleBatteryLevelListener(onBatteryLevelChange: onBatteryLevelChange);
    }
    _showDeviceDisconnectedNotification();
    return null;
  }

  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
  });

  Future<StreamSubscription?> getChargingStatusListener({
    required void Function(int) onChargingStatusChange,
  }) async {
    if (await isConnected()) {
      return await performGetChargingStatusListener(onChargingStatusChange: onChargingStatusChange);
    }
    return null;
  }

  Future<StreamSubscription?> performGetChargingStatusListener({
    required void Function(int) onChargingStatusChange,
  }) async {
    // Default: no charging status support. Override in subclass.
    return null;
  }

  /// Read current charging status synchronously (poll).
  /// Returns 0 (no USB), 1 (charging), 2 (battery disconnected), or -1 on error.
  Future<int> readChargingStatus() async {
    if (await isConnected()) {
      return await performReadChargingStatus();
    }
    return -1;
  }

  Future<int> performReadChargingStatus() async {
    // Default: no charging status support. Override in subclass.
    return -1;
  }

  Future<StreamSubscription?> getBleAudioBytesListener({
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    if (await isConnected()) {
      return await performGetBleAudioBytesListener(onAudioBytesReceived: onAudioBytesReceived);
    }
    _showDeviceDisconnectedNotification();
    return null;
  }

  Future<List<int>> getBleButtonState() async {
    if (await isConnected()) {
      debugPrint('button state called');
      return await performGetButtonState();
    }
    debugPrint('button state error');
    return Future.value(<int>[]);
  }

  Future<List<int>> performGetButtonState();

  Future<StreamSubscription?> getBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async {
    if (await isConnected()) {
      return await performGetBleButtonListener(onButtonReceived: onButtonReceived);
    }
    return null;
  }

  Future<StreamSubscription?> performGetBleAudioBytesListener({
    required void Function(List<int>) onAudioBytesReceived,
  });

  Future<StreamSubscription?> performGetBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  });

  Future<BleAudioCodec> getAudioCodec() async {
    if (await isConnected()) {
      return await performGetAudioCodec();
    }
    _showDeviceDisconnectedNotification();
    return BleAudioCodec.pcm8;
  }

  Future<BleAudioCodec> performGetAudioCodec();

  Future<bool> performPlayToSpeakerHaptic(int mode);

  // storage here

  Future<List<int>> getStorageList() async {
    if (await isConnected()) {
      return await performGetStorageList();
    }
    _showDeviceDisconnectedNotification();
    return Future.value(<int>[]);
  }

  Future<List<int>> performGetStorageList();

  Future<bool> performWriteToStorage(int numFile, int command, int offset);

  Future<bool> writeToStorage(int numFile, int command, int offset) async {
    if (await isConnected()) {
      return await performWriteToStorage(numFile, command, offset);
    }
    _showDeviceDisconnectedNotification();
    return Future.value(false);
  }

  Future<StreamSubscription?> getBleStorageBytesListener({
    required void Function(List<int>) onStorageBytesReceived,
  }) async {
    if (await isConnected()) {
      return await performGetBleStorageBytesListener(onStorageBytesReceived: onStorageBytesReceived);
    }
    _showDeviceDisconnectedNotification();
    return null;
  }

  Future<StreamSubscription?> performGetBleStorageBytesListener({
    required void Function(List<int>) onStorageBytesReceived,
  });

  Future cameraStartPhotoController() async {
    if (await isConnected()) {
      return await performCameraStartPhotoController();
    }
    _showDeviceDisconnectedNotification();
    return null;
  }

  Future performCameraStartPhotoController();

  Future cameraStopPhotoController() async {
    if (await isConnected()) {
      return await performCameraStopPhotoController();
    }
    _showDeviceDisconnectedNotification();
    return null;
  }

  Future performCameraStopPhotoController();

  Future cameraTakePhoto() async {
    if (await isConnected()) {
      return await performCameraTakePhoto();
    }
    _showDeviceDisconnectedNotification();
    return null;
  }

  Future performCameraTakePhoto();

  Future<bool> hasPhotoStreamingCharacteristic() async {
    if (await isConnected()) {
      return await performHasPhotoStreamingCharacteristic();
    }
    _showDeviceDisconnectedNotification();
    return false;
  }

  Future<bool> performHasPhotoStreamingCharacteristic();

  Future<StreamSubscription?> getImageListener({
    required void Function(Uint8List base64JpgData) onImageReceived,
  }) async {
    if (await isConnected()) {
      return await performGetImageListener(onImageReceived: onImageReceived);
    }
    _showDeviceDisconnectedNotification();
    return null;
  }

  Future<StreamSubscription?> performGetImageListener({
    required void Function(Uint8List base64JpgData) onImageReceived,
  });

  Future<StreamSubscription<List<int>>?> getAccelListener({
    void Function(int)? onAccelChange,
  }) async {
    if (await isConnected()) {
      return await performGetAccelListener(onAccelChange: onAccelChange);
    }
    _showDeviceDisconnectedNotification();
    return null;
  }

  Future<StreamSubscription<List<int>>?> performGetAccelListener({
    void Function(int)? onAccelChange,
  });

  Future<int> readLedDimRatio() async {
    if (await isConnected()) {
      return await performReadLedDimRatio();
    }
    return -1;
  }

  Future<int> performReadLedDimRatio();

  Future<bool> writeLedDimRatio(int ratio) async {
    if (await isConnected()) {
      return await performWriteLedDimRatio(ratio);
    }
    _showDeviceDisconnectedNotification();
    return false;
  }

  Future<bool> performWriteLedDimRatio(int ratio);

  void _showDeviceDisconnectedNotification() {
    if (SoundcoreWifiActivity.isActive(device.id)) return;
    final deviceName = device.displayName;
    NotificationService.instance.createNotification(
      title: appT(
        (s) => s.pushDeviceDisconnectedTitle(deviceName),
        '$deviceName Disconnected',
      ),
      body: appT(
        (s) => s.pushDeviceDisconnectedBody(deviceName),
        'Please reconnect to continue using your $deviceName.',
      ),
    );
  }
}
