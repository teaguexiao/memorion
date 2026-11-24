import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';

import 'device_connection.dart';
import 'offline_device_connection.dart';
import 'soundcore/protocol.dart';
import 'soundcore/session.dart';

class SoundcoreDeviceConnection extends OfflineDeviceConnection {
  SoundcoreSession? _session;
  StreamSubscription<BluetoothConnectionState>? _disconnectListener;
  bool _starting = false;
  bool _ready = false;
  static bool _licenseRegistered = false;

  SoundcoreDeviceConnection(super.device, super.bleDevice) {
    if (!_licenseRegistered) {
      _licenseRegistered = true;
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(
          ['recording-bean-web'], // i18n-ignore: Third-party package identifier.
          await rootBundle.loadString('lib/services/devices/soundcore/THIRD_PARTY_LICENSE.txt'),
        );
      });
    }
  }

  SoundcoreSession get session {
    if (!_ready || _session == null) throw StateError('Connect soundcore Work before importing');
    return _session!;
  }

  @override
  DeviceConnectionState get status => _ready ? super.status : DeviceConnectionState.disconnected;

  @override
  Future<void> connect({
    Function(String, DeviceConnectionState)? onConnectionStateChanged,
    bool isReconnect = false,
  }) async {
    _starting = true;
    try {
      await super.connect(
        isReconnect: isReconnect,
        onConnectionStateChanged: (id, state) async {
          if (state == DeviceConnectionState.disconnected) {
            _clearSession();
            onConnectionStateChanged?.call(id, state);
          } else if (!_starting && !_ready) {
            try {
              await _initializeSession();
              onConnectionStateChanged?.call(id, state);
            } catch (error) {
              debugPrint('[Soundcore] reconnect failed: $error');
              await disconnect();
            }
          }
        },
      );
      await _initializeSession();
      onConnectionStateChanged?.call(device.id, DeviceConnectionState.connected);
    } catch (error) {
      await disconnect();
      throw DeviceConnectionException(
          'Soundcore connection failed: $error'); // i18n-ignore: Internal connection diagnostic.
    } finally {
      _starting = false;
    }
  }

  Future<void> _initializeSession() async {
    _clearSession();
    final service = await getService(soundcoreServiceUuid);
    if (service == null) {
      throw const FormatException(
          'The device does not expose D3200 services'); // i18n-ignore: Internal connection diagnostic.
    }
    final write = getCharacteristic(service, soundcoreWriteUuid);
    final notify = getCharacteristic(service, soundcoreNotifyUuid);
    if (write == null || notify == null || (!write.properties.write && !write.properties.writeWithoutResponse)) {
      throw const FormatException(
          'D3200 characteristics are unavailable'); // i18n-ignore: Internal connection diagnostic.
    }
    final session = SoundcoreSession(
      notifications: notify.onValueReceived,
      send: (bytes) async {
        if (!bleDevice.isConnected) throw StateError('Soundcore disconnected');
        // A command can exceed one ATT write (notably the 75-byte handshake).
        final chunkSize = (bleDevice.mtuNow - 3).clamp(20, 512);
        for (var offset = 0; offset < bytes.length; offset += chunkSize) {
          await write.write(bytes.sublist(offset, (offset + chunkSize).clamp(0, bytes.length)),
              withoutResponse: write.properties.writeWithoutResponse);
        }
      },
    );
    _session = session;
    await notify.setNotifyValue(true);
    final info = await session.readInfo();
    device = device.copyWith(
      type: DeviceType.soundcore,
      modelNumber: 'D3200',
      manufacturerName: 'soundcore',
      firmwareRevision: info.firmware.isEmpty ? 'Unknown' : info.firmware,
      hardwareRevision: 'Unknown',
    );
    _disconnectListener = bleDevice.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) _clearSession();
    });
    _ready = true;
  }

  void _clearSession() {
    _ready = false;
    _session?.close();
    _session = null;
    _disconnectListener?.cancel();
    _disconnectListener = null;
  }

  @override
  Future<void> disconnect() async {
    _clearSession();
    await super.disconnect();
  }

  @override
  Future<bool> isConnected() async => _ready && bleDevice.isConnected;

  @override
  Future<bool> ping() async {
    if (!_starting && _session?.isClosed == true) return false;
    // Firmware can pause GATT while handing off to Wi-Fi. Do not turn an RSSI
    // probe into a forced disconnect of the authenticated transfer generation.
    if (_session?.wifiActive == true) return bleDevice.isConnected;
    return super.ping();
  }

  @override
  Future<int> performRetrieveBatteryLevel() async => session.info?.battery ?? -1;

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
  }) async =>
      session.batteryEvents.listen((bytes) {
        if (bytes.isNotEmpty) onBatteryLevelChange?.call(bytes.first);
      });

  @override
  Future<StreamSubscription?> performGetChargingStatusListener({
    required void Function(int) onChargingStatusChange,
  }) async =>
      session.chargingEvents.listen(onChargingStatusChange);

  @override
  Future<int> performReadChargingStatus() async {
    try {
      final current = session;
      final info = current.busy ? current.info : await current.readInfo();
      return info == null ? -1 : (info.charging ? 1 : 0);
    } catch (error) {
      debugPrint('[Soundcore] status unavailable: $error');
      return -1;
    }
  }
}
