import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import 'plaud/identity_store.dart';
import 'plaud/protocol.dart';
import 'plaud/session.dart';
import 'offline_device_connection.dart';

/// Physical connection is ready only after the owner-specific Plaud handshake.
class PlaudDeviceConnection extends OfflineDeviceConnection {
  PlaudSession? _session;
  StreamSubscription<BluetoothConnectionState>? _disconnectListener;
  StreamSubscription<List<int>>? _batteryListener;
  int _batteryGeneration = 0;
  int _sessionGeneration = 0;
  bool _starting = false, _ready = false;
  static bool _licenseRegistered = false;

  PlaudDeviceConnection(super.device, super.bleDevice) {
    if (!_licenseRegistered) {
      _licenseRegistered = true;
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(
            ['plaude-archiver'], await rootBundle.loadString('lib/services/devices/plaud/THIRD_PARTY_LICENSE.txt'));
      });
    }
  }
  static String currentOwner() {
    final user = FirebaseAuth.instance.currentUser;
    final owner = getExternalUserId();
    return user != null && !user.isAnonymous && user.uid == owner && getAuthHeader().isNotEmpty ? owner : '';
  }

  PlaudSession get session {
    if (!_ready || _session == null || _session!.isClosed) throw const PlaudException(PlaudIssue.disconnected);
    return _session!;
  }

  @override
  DeviceConnectionState get status => _ready ? super.status : DeviceConnectionState.disconnected;

  @override
  Future<void> connect(
      {Function(String, DeviceConnectionState)? onConnectionStateChanged, bool isReconnect = false}) async {
    _starting = true;
    try {
      await super.connect(
          isReconnect: isReconnect,
          onConnectionStateChanged: (id, state) async {
            if (state == DeviceConnectionState.disconnected) {
              _clear();
              onConnectionStateChanged?.call(id, state);
            } else if (!_starting && !_ready) {
              _starting = true;
              try {
                await _initialize();
                onConnectionStateChanged?.call(id, state);
              } catch (_) {
                if (!isDisposed) await disconnect();
              } finally {
                _starting = false;
              }
            }
          });
      await _initialize();
      onConnectionStateChanged?.call(device.id, DeviceConnectionState.connected);
    } catch (_) {
      if (!isDisposed) await disconnect();
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> _initialize() async {
    _clear();
    final generation = _sessionGeneration;
    void ensureCurrent() {
      if (isDisposed || generation != _sessionGeneration || !bleDevice.isConnected) {
        throw const PlaudException(PlaudIssue.disconnected);
      }
    }

    ensureCurrent();
    final owner = currentOwner();
    if (owner.isEmpty) throw const PlaudException(PlaudIssue.identityRequired);
    final identity = await const PlaudIdentityStore().read(owner, device.id);
    ensureCurrent();
    if (identity == null || currentOwner() != owner) throw const PlaudException(PlaudIssue.identityRequired);
    final service = await getService(plaudService);
    ensureCurrent();
    if (service == null) throw const PlaudException(PlaudIssue.protocol);
    final write = getCharacteristic(service, plaudWrite);
    final notify = getCharacteristic(service, plaudNotify);
    if (write == null || notify == null || !write.properties.write || !notify.properties.notify) {
      throw const PlaudException(PlaudIssue.protocol);
    }
    final active = PlaudSession(
        identity: identity,
        notifications: notify.onValueReceived,
        send: (bytes) async {
          ensureCurrent();
          if (!bleDevice.isConnected || currentOwner() != owner) throw const PlaudException(PlaudIssue.disconnected);
          // Every encrypted command is one GATT value. Never fragment it into
          // independent writes, even when another family permits ATT chunking.
          if (bytes.length > bleDevice.mtuNow - 3) throw const PlaudException(PlaudIssue.protocol);
          await write.write(bytes, withoutResponse: false);
        });
    _session = active;
    await notify.setNotifyValue(true);
    ensureCurrent();
    await active.authenticate(device.plaudSerial ?? '');
    ensureCurrent();
    if (currentOwner() != owner || active.isClosed) throw const PlaudException(PlaudIssue.disconnected);
    device = device.copyWith(
        type: DeviceType.plaudNote,
        modelNumber: 'Note',
        manufacturerName: 'PLAUD',
        firmwareRevision: active.firmwareVersion ?? 'Unknown');
    _disconnectListener = bleDevice.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) _clear();
    });
    _ready = true;
  }

  void _clear() {
    _sessionGeneration++;
    _ready = false;
    _batteryGeneration++;
    _batteryListener?.cancel();
    _batteryListener = null;
    _session?.close();
    _session = null;
    _disconnectListener?.cancel();
    _disconnectListener = null;
  }

  @override
  Future<void> disconnect() async {
    _clear();
    await super.disconnect();
  }

  @override
  Future<bool> isConnected() async => _ready && _session?.isClosed == false && bleDevice.isConnected;
  @override
  Future<bool> ping() async => !_starting && _session?.isClosed == true ? false : await super.ping();
  @override
  Future<int> performRetrieveBatteryLevel() async {
    final service = await getService('0000180f-0000-1000-8000-00805f9b34fb');
    if (service == null) return -1;
    final characteristic = getCharacteristic(service, '00002a19-0000-1000-8000-00805f9b34fb');
    if (characteristic == null || !characteristic.properties.read) return -1;
    final value = await characteristic.read();
    return value.length == 1 && value.first <= 100 ? value.first : -1;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener(
      {void Function(int)? onBatteryLevelChange}) async {
    final generation = ++_batteryGeneration;
    await _batteryListener?.cancel();
    if (generation != _batteryGeneration) return null;
    _batteryListener = null;
    final service = await getService('0000180f-0000-1000-8000-00805f9b34fb');
    if (service == null || generation != _batteryGeneration) return null;
    final characteristic = getCharacteristic(service, '00002a19-0000-1000-8000-00805f9b34fb');
    if (characteristic == null || (!characteristic.properties.read && !characteristic.properties.notify)) return null;
    int? lastLevel;
    late final StreamSubscription<List<int>> listener;
    void publish(List<int> bytes) {
      if (generation != _batteryGeneration ||
          _batteryListener != listener ||
          bytes.length != 1 ||
          bytes.first < 0 ||
          bytes.first > 100) {
        return;
      }
      if (lastLevel == bytes.first) return;
      lastLevel = bytes.first;
      onBatteryLevelChange?.call(bytes.first);
    }

    // Note can notify immediately when CCCD is enabled. Subscribe first, then
    // read the initial value: a steady battery may otherwise never send a push.
    listener = characteristic.onValueReceived.listen(publish);
    _batteryListener = listener;
    var notifying = false;
    try {
      if (characteristic.properties.notify) notifying = await characteristic.setNotifyValue(true);
    } catch (_) {
      // A read still provides a useful snapshot if notifications are unavailable.
    }
    try {
      if (generation == _batteryGeneration && characteristic.properties.read) publish(await characteristic.read());
    } catch (_) {
      // Keep a successfully enabled subscription if the initial read fails.
    }
    if (!notifying || generation != _batteryGeneration || _batteryListener != listener) {
      await listener.cancel();
      if (_batteryListener == listener) _batteryListener = null;
      return null;
    }
    return listener;
  }

  @override
  Future<int> performReadChargingStatus() async => -1;
  @override
  Future<StreamSubscription?> performGetChargingStatusListener(
          {required void Function(int) onChargingStatusChange}) async =>
      null;
}
