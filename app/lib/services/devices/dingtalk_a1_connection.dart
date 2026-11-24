import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import 'dingtalk_a1/identity_store.dart';
import 'dingtalk_a1/protocol.dart';
import 'dingtalk_a1/session.dart';
import 'offline_device_connection.dart';

/// Physical connection is ready only after the owner-specific A1 handshake.
class A1DeviceConnection extends OfflineDeviceConnection {
  A1Session? _session;
  StreamSubscription<BluetoothConnectionState>? _disconnectListener;
  bool _starting = false, _ready = false;
  static bool _licenseRegistered = false;

  A1DeviceConnection(super.device, super.bleDevice) {
    if (!_licenseRegistered) {
      _licenseRegistered = true;
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(['dingtalk-a1-pc-tools'],
            await rootBundle.loadString('lib/services/devices/dingtalk_a1/THIRD_PARTY_LICENSE.txt'));
      });
    }
  }
  static String currentOwner() {
    final user = FirebaseAuth.instance.currentUser;
    final owner = getExternalUserId();
    return user != null && !user.isAnonymous && user.uid == owner && getAuthHeader().isNotEmpty ? owner : '';
  }

  A1Session get session {
    if (!_ready || _session == null || _session!.isClosed) throw const A1Exception(A1Issue.disconnected);
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
                await disconnect();
              } finally {
                _starting = false;
              }
            }
          });
      await _initialize();
      onConnectionStateChanged?.call(device.id, DeviceConnectionState.connected);
    } catch (_) {
      await disconnect();
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> _initialize() async {
    _clear();
    final owner = currentOwner();
    if (owner.isEmpty) throw const A1Exception(A1Issue.identityRequired);
    final identity = await const A1IdentityStore().read(owner, device.id);
    if (identity == null || currentOwner() != owner) throw const A1Exception(A1Issue.identityRequired);
    final service = await getService(a1ServiceUuid);
    if (service == null) throw const A1Exception(A1Issue.protocol);
    final write = getCharacteristic(service, a1WriteUuid);
    final notify = getCharacteristic(service, a1NotifyUuid);
    if (write == null || notify == null || !write.properties.write || !notify.properties.notify) {
      throw const A1Exception(A1Issue.protocol);
    }
    final active = A1Session(
        identity: identity,
        notifications: notify.onValueReceived,
        send: (bytes) async {
          if (!bleDevice.isConnected || currentOwner() != owner) throw const A1Exception(A1Issue.disconnected);
          // Stock clients use acknowledged writes, with <=180-byte ATT chunks.
          final size = (bleDevice.mtuNow - 3).clamp(20, 180);
          for (var offset = 0; offset < bytes.length; offset += size) {
            await write.write(bytes.sublist(offset, (offset + size).clamp(0, bytes.length)), withoutResponse: false);
          }
        });
    _session = active;
    await notify.setNotifyValue(true);
    await active.authenticate();
    final info = await active.readInfo();
    if (currentOwner() != owner || active.isClosed) throw const A1Exception(A1Issue.disconnected);
    device = device.copyWith(
        type: DeviceType.dingtalkA1,
        modelNumber: 'A1',
        manufacturerName: 'DingTalk',
        firmwareRevision: info.firmware.isEmpty ? 'Unknown' : info.firmware,
        hardwareRevision: 'Unknown');
    _disconnectListener = bleDevice.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) _clear();
    });
    _ready = true;
  }

  void _clear() {
    _ready = false;
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
  Future<int> performRetrieveBatteryLevel() async => session.info?.battery ?? -1;
  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener(
          {void Function(int)? onBatteryLevelChange}) async =>
      session.infoEvents.map((info) => [info.battery]).listen((bytes) {
        if (bytes.first >= 0) onBatteryLevelChange?.call(bytes.first);
      });
  // No verified charging flag in the status payload; don't infer it from power.
  @override
  Future<int> performReadChargingStatus() async => -1;
  @override
  Future<StreamSubscription?> performGetChargingStatusListener(
          {required void Function(int) onChargingStatusChange}) async =>
      null;
}
