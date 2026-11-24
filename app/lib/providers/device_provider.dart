import 'package:memorion/services/devices/dingtalk_a1_connection.dart';
import 'package:memorion/services/devices/dingtalk_a1/protocol.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/http/api/device.dart';
import 'package:memorion/main.dart';
import 'package:memorion/pages/today_chapters/firmware_update_page.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/soundcore_connection.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/recorder_wifi_activity.dart';
import 'package:memorion/services/notifications.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:memorion/utils/device.dart';
import 'package:memorion/utils/localization_helper.dart';
import 'package:memorion/utils/logger.dart';
import 'package:memorion/utils/notification_prefs.dart';
import 'package:memorion/utils/wear_tracking.dart';
import 'package:memorion/widgets/confirmation_dialog.dart';
import 'package:memorion/utils/platform/platform_manager.dart';
import 'package:memorion/utils/platform/platform_service.dart';

enum LedMode { standard, gentle, night }

class DeviceProvider extends ChangeNotifier implements IDeviceServiceSubsciption {
  CaptureProvider? captureProvider;
  final IDeviceService _deviceService;
  StreamSubscription? _offlineInfoListener;
  int caseBatteryLevel = -1;
  bool isCaseCharging = false;

  bool isConnecting = false;
  bool isConnected = false;
  bool isDeviceV2Connected = false;
  BtDevice? connectedDevice;
  BtDevice? pairedDevice;
  bool get canStreamAudio => isConnected && connectedDevice != null && !connectedDevice!.usesOfflineImport;
  StreamSubscription<List<int>>? _bleBatteryLevelListener;
  StreamSubscription? _bleChargingStatusListener;
  Timer? _chargingPollTimer;
  int batteryLevel = -1;
  bool isCharging = false;
  bool isBatteryDisconnected = false;
  bool _hasLowBatteryAlerted = false;
  Timer? _reconnectionTimer;
  DateTime? _reconnectAt;
  final int _connectionCheckSeconds = 7;

  LedMode _ledMode = LedMode.standard;
  LedMode get ledMode => _ledMode;

  bool _havingNewFirmware = false;
  bool get havingNewFirmware =>
      _havingNewFirmware && pairedDevice != null && !pairedDevice!.usesOfflineImport && isConnected;

  // Tracks whether the user dismissed the firmware update dialog in this session.
  // Resets on app restart or when a new firmware version is detected.
  bool _firmwareDialogDismissed = false;
  bool _firmwareDialogShowing = false;

  // Current and latest firmware versions for UI display
  String get currentFirmwareVersion => pairedDevice?.firmwareRevision ?? 'Unknown';
  String _latestFirmwareVersion = '';
  String get latestFirmwareVersion => _latestFirmwareVersion;

  Timer? _disconnectNotificationTimer;

  DeviceProvider({IDeviceService? deviceService}) : _deviceService = deviceService ?? ServiceManager.instance().device {
    // Restore pairedDevice from SharedPreferences so UI shows "Disconnected"
    // instead of "Find Device" when app starts with device offline.
    final stored = SharedPreferencesUtil().btDevice;
    if (stored.id.isNotEmpty) {
      pairedDevice = stored;
    }
    _deviceService.subscribe(this, this);
  }

  void setProviders(CaptureProvider provider) {
    captureProvider = provider;
    notifyListeners();
  }

  void setConnectedDevice(BtDevice? device) async {
    if (connectedDevice?.id != device?.id) {
      batteryLevel = -1;
      caseBatteryLevel = -1;
      isCharging = false;
      isCaseCharging = false;
      isBatteryDisconnected = false;
    }
    connectedDevice = device;
    if (device != null) {
      pairedDevice = device;
    } else {
      // Keep pairedDevice from SharedPreferences so UI knows device is paired but offline
      final stored = SharedPreferencesUtil().btDevice;
      pairedDevice = stored.id.isNotEmpty ? stored : null;
    }
    await getDeviceInfo();
    Logger.debug('setConnectedDevice: $device');
    notifyListeners();
  }

  Future getDeviceInfo({bool forceRefresh = false}) async {
    final device = connectedDevice;
    final preferences = SharedPreferencesUtil();
    final stored = preferences.btDevice;
    if (device != null) {
      if (!forceRefresh && pairedDevice?.firmwareRevision != null && pairedDevice?.firmwareRevision != 'Unknown') {
        return;
      }
      final connection = await _deviceService.ensureConnection(device.id);
      if (connectedDevice != device || preferences.btDevice.id != stored.id) return;
      final details = await device.getDeviceInfo(connection);
      if (connectedDevice != device || preferences.btDevice.id != stored.id) return;
      pairedDevice = details;
      preferences.btDevice = details;
    } else {
      pairedDevice = stored.id.isEmpty ? null : stored;
    }
    notifyListeners();
  }

  // TODO: thinh, use connection directly
  Future _bleDisconnectDevice(BtDevice btDevice) async {
    var connection = await _deviceService.ensureConnection(btDevice.id);
    if (connection == null) {
      return Future.value(null);
    }
    return await connection.disconnect();
  }

  Future<StreamSubscription<List<int>>?> _getBleBatteryLevelListener(
    String deviceId, {
    void Function(int)? onBatteryLevelChange,
  }) async {
    {
      var connection = await _deviceService.ensureConnection(deviceId);
      if (connection == null) {
        return Future.value(null);
      }
      return connection.getBleBatteryLevelListener(onBatteryLevelChange: onBatteryLevelChange);
    }
  }

  Future<List<int>> _getStorageList(String deviceId) async {
    var connection = await _deviceService.ensureConnection(deviceId);
    if (connection == null) {
      return [];
    }
    return connection.getStorageList();
  }

  Future<BtDevice?> _getConnectedDevice() async {
    var deviceId = SharedPreferencesUtil().btDevice.id;
    if (deviceId.isEmpty) {
      return null;
    }
    var connection = await _deviceService.ensureConnection(deviceId);
    return SharedPreferencesUtil().btDevice.id == deviceId ? connection?.device : null;
  }

  initiateBleBatteryListener() async {
    if (connectedDevice == null) {
      return;
    }
    _bleBatteryLevelListener?.cancel();
    _offlineInfoListener?.cancel();
    _offlineInfoListener = null;
    final id = connectedDevice!.id;
    final ringBattery = connectedDevice!.type == DeviceType.chipletRing;
    final connection = await _deviceService.ensureConnection(id);
    if (connectedDevice?.id != id) return;
    if (connection is SoundcoreDeviceConnection) {
      // The first device-info response precedes the listener. Apply the cached
      // snapshot immediately, then keep both batteries current on poll/push.
      void apply(SoundcoreInfo info) {
        if (connectedDevice?.id != id) return;
        batteryLevel = info.battery;
        caseBatteryLevel = info.caseBattery ?? -1;
        isCharging = info.charging;
        isCaseCharging = info.caseCharging ?? false;
        isBatteryDisconnected = false;
        notifyListeners();
      }

      _offlineInfoListener = connection.session.infoEvents.listen(apply);
      final current = connection.session.info;
      if (current != null) apply(current);
      return;
    }
    if (connection is A1DeviceConnection) {
      void apply(A1Info info) {
        if (connectedDevice?.id != id) return;
        batteryLevel = info.battery;
        caseBatteryLevel = -1;
        isCharging = false;
        isCaseCharging = false;
        isBatteryDisconnected = false;
        notifyListeners();
      }

      _offlineInfoListener = connection.session.infoEvents.listen(apply);
      final current = connection.session.info;
      if (current != null) apply(current);
      return;
    }
    _bleBatteryLevelListener = await _getBleBatteryLevelListener(
      connectedDevice!.id,
      onBatteryLevelChange: (int value) {
        if (ringBattery) {
          if (connectedDevice?.id != id) return;
          batteryLevel = value;
          if (value < 0) {
            notifyListeners();
            return;
          }
        } else if (batteryLevel > 0 && (value - batteryLevel).abs() > 5) {
          batteryLevel = batteryLevel + (value > batteryLevel ? 3 : -3);
        } else {
          batteryLevel = value;
        }
        if (batteryLevel < 20 && !_hasLowBatteryAlerted) {
          _hasLowBatteryAlerted = true;
          NotificationService.instance.createNotification(
            title: appT((s) => s.pushLowBatteryTitle, 'Low Battery Alert'),
            body: appT(
              (s) => s.pushLowBatteryBody,
              'Your device is running low on battery. Time for a recharge! 🔋',
            ),
          );
        } else if (batteryLevel > 20) {
          _hasLowBatteryAlerted = true;
        }
        notifyListeners();
      },
    );
    notifyListeners();
  }

  Future<void> initiateChargingStatusListener() async {
    if (connectedDevice == null) return;
    _bleChargingStatusListener?.cancel();
    _chargingPollTimer?.cancel();
    var connection = await _deviceService.ensureConnection(connectedDevice!.id);
    if (connection == null) return;
    if (connectedDevice?.type == DeviceType.dingtalkA1 ||
        connectedDevice?.type == DeviceType.plaudNote ||
        connectedDevice?.type == DeviceType.chipletRing) {
      isCharging = false;
      isCaseCharging = false;
      caseBatteryLevel = -1;
      isBatteryDisconnected = false;
      notifyListeners();
      return;
    }
    _bleChargingStatusListener = await connection.getChargingStatusListener(
      onChargingStatusChange: (int chargingState) {
        // 0 = no USB, 1 = charging, 2 = USB powered but battery disconnected
        _updateChargingState(chargingState);
      },
    );
    // Poll charging status every 3 seconds as a fallback in case BLE
    // notifications are missed (common on iOS due to GATT caching).
    // Shorter interval ensures more responsive UI updates for charging state changes.
    _chargingPollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (connectedDevice == null) return;
      var conn = await _deviceService.ensureConnection(connectedDevice!.id);
      if (conn == null) return;
      var value = await conn.readChargingStatus();
      if (value >= 0) {
        _updateChargingState(value);
      }
    });
  }

  void _updateChargingState(int chargingState) {
    final newCharging = (chargingState == 1);
    final newBatteryDisconnected = (chargingState == 2);
    if (isCharging != newCharging || isBatteryDisconnected != newBatteryDisconnected) {
      isCharging = newCharging;
      isBatteryDisconnected = newBatteryDisconnected;
      notifyListeners();
    }
  }

  static LedMode dimRatioToLedMode(int ratio) {
    if (ratio <= 0) return LedMode.night;
    if (ratio <= 25) return LedMode.gentle;
    return LedMode.standard;
  }

  static int ledModeToDimRatio(LedMode mode) {
    switch (mode) {
      case LedMode.standard:
        return 50;
      case LedMode.gentle:
        return 15;
      case LedMode.night:
        return 0;
    }
  }

  Future<void> readLedMode() async {
    if (connectedDevice?.usesOfflineImport == true) return;
    if (connectedDevice == null) {
      debugPrint('[LED] readLedMode: no connected device');
      return;
    }
    try {
      var connection = await _deviceService.ensureConnection(connectedDevice!.id);
      if (connection == null) {
        debugPrint('[LED] readLedMode: connection is null');
        return;
      }
      var ratio = await connection.readLedDimRatio();
      debugPrint('[LED] readLedMode: got ratio=$ratio');
      if (ratio >= 0) {
        _ledMode = dimRatioToLedMode(ratio);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[LED] readLedMode error: $e');
    }
  }

  String? _lastLedError;
  String? get lastLedError => _lastLedError;

  Future<bool> setLedMode(LedMode mode) async {
    if (connectedDevice?.usesOfflineImport == true) return false;
    _lastLedError = null;
    debugPrint('[LED] setLedMode: $mode, connectedDevice=${connectedDevice?.id}');
    if (connectedDevice == null) {
      _lastLedError = appT((s) => s.ledNoConnectedDevice, 'No connected device');
      debugPrint('[LED] setLedMode: $_lastLedError');
      return false;
    }
    try {
      var connection = await _deviceService.ensureConnection(connectedDevice!.id);
      if (connection == null) {
        _lastLedError = appT((s) => s.ledCouldNotConnect, 'Could not establish connection');
        debugPrint('[LED] setLedMode: $_lastLedError');
        return false;
      }
      var ratio = ledModeToDimRatio(mode);
      debugPrint('[LED] setLedMode: writing ratio=$ratio');
      var success = await connection.writeLedDimRatio(ratio);
      debugPrint('[LED] setLedMode: write result=$success');
      if (success) {
        _ledMode = mode;
        notifyListeners();
      } else {
        _lastLedError = appT(
          (s) => s.ledBleWriteFailed,
          'BLE write failed (Settings service not found on device)',
        );
      }
      return success;
    } catch (e) {
      _lastLedError = e.toString();
      debugPrint('[LED] setLedMode error: $e');
      return false;
    }
  }

  bool get _recorderWifiActive =>
      RecorderWifiActivity.isActive(connectedDevice?.id ?? pairedDevice?.id ?? SharedPreferencesUtil().btDevice.id);

  Future periodicConnect(String printer) async {
    if (PlatformService.isIosSimulator) {
      // iOS simulator has no BLE stack — skip to avoid endless scan loops and
      // "Communicating on a dead channel" log spam from flutter_blue_plus.
      debugPrint('[DeviceProvider] Skipping periodicConnect on iOS simulator ($printer)');
      return;
    }
    _reconnectionTimer?.cancel();
    _reconnectionTimer = Timer.periodic(Duration(seconds: _connectionCheckSeconds), (t) async {
      debugPrint("Period connect seconds: $_connectionCheckSeconds, triggered timer at ${DateTime.now()}");
      if (SharedPreferencesUtil().btDevice.id.isEmpty) {
        t.cancel();
        return;
      }
      if (_recorderWifiActive) return;
      if (_reconnectAt != null && _reconnectAt!.isAfter(DateTime.now())) {
        return;
      }
      Logger.debug("isConnected: $isConnected, isConnecting: $isConnecting, connectedDevice: $connectedDevice");

      // Improved condition: also check if we should verify the connection status
      if (!isConnected || connectedDevice == null) {
        if (isConnecting) {
          return;
        }
        await scanAndConnectToDevice();
      } else if (isConnected && connectedDevice != null) {
        // Even if we think we're connected, verify it's actually working
        var actualDevice = await _getConnectedDevice();
        if (actualDevice == null) {
          Logger.debug("Connection state mismatch detected - app shows connected but device is not reachable");
          // Force state update and reconnect
          setIsConnected(false);
          setConnectedDevice(null);
          await scanAndConnectToDevice();
        } else {
          // Connection verified, stop periodic timer
          t.cancel();
        }
      }
    });
  }

  Future<BtDevice?> _scanAndConnectDevice({bool autoConnect = true, bool timeout = false}) async {
    var device = await _getConnectedDevice();
    if (device != null) {
      return device;
    }

    int timeoutCounter = 0;
    while (true) {
      final deviceId = SharedPreferencesUtil().btDevice.id;
      if (deviceId.isEmpty || _recorderWifiActive) return null;
      if (timeout && timeoutCounter >= 10) return null;
      await _deviceService.discover(desirableDeviceId: deviceId);
      if (connectedDevice != null) {
        return connectedDevice;
      }

      // If the device is not found, wait for a bit before retrying.
      await Future.delayed(const Duration(seconds: 2));
      timeoutCounter += 2;
    }
  }

  Future scanAndConnectToDevice() async {
    if (_recorderWifiActive) return;
    updateConnectingStatus(true);
    if (isConnected) {
      if (connectedDevice == null) {
        final device = await _getConnectedDevice();
        if (device == null) {
          updateConnectingStatus(false);
          return;
        }
        connectedDevice = device;
        SharedPreferencesUtil().deviceName = device.name;
        MixpanelManager().deviceConnected();
      }

      setIsConnected(true);
      updateConnectingStatus(false);
      notifyListeners();
      return;
    }

    // else
    var device = await _scanAndConnectDevice();
    Logger.debug('inside scanAndConnectToDevice $device in device_provider');
    if (device != null) {
      var cDevice = await _getConnectedDevice();
      if (cDevice != null) {
        setConnectedDevice(cDevice);
        setIsDeviceV2Connected();
        SharedPreferencesUtil().deviceName = cDevice.name;
        MixpanelManager().deviceConnected();
        setIsConnected(true);
      }
      Logger.debug('device is not null $cDevice');
    }
    updateConnectingStatus(false);

    notifyListeners();
  }

  void updateConnectingStatus(bool value) {
    isConnecting = value;
    notifyListeners();
  }

  void setIsConnected(bool value) {
    isConnected = value;
    if (isConnected) {
      _reconnectionTimer?.cancel();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _offlineInfoListener?.cancel();
    _bleBatteryLevelListener?.cancel();
    _bleChargingStatusListener?.cancel();
    _chargingPollTimer?.cancel();
    _reconnectionTimer?.cancel();
    _deviceService.unsubscribe(this);
    super.dispose();
  }

  void onDeviceDisconnected() async {
    final disconnectedId = connectedDevice?.id ?? pairedDevice?.id;
    Logger.debug('onDisconnected inside: $connectedDevice');
    // 佩戴时段（P-01 首页「未佩戴」空档条）：闭合当前 BLE 连接时段并落本地。
    WearTracking.onDisconnected();
    _havingNewFirmware = false;
    _offlineInfoListener?.cancel();
    _offlineInfoListener = null;
    _bleBatteryLevelListener?.cancel();
    _bleBatteryLevelListener = null;
    batteryLevel = -1;
    caseBatteryLevel = -1;
    isCaseCharging = false;
    isCharging = false;
    isBatteryDisconnected = false;
    _bleChargingStatusListener?.cancel();
    _bleChargingStatusListener = null;
    _chargingPollTimer?.cancel();
    _chargingPollTimer = null;
    setConnectedDevice(null);
    setIsDeviceV2Connected();
    setIsConnected(false);
    updateConnectingStatus(false);

    captureProvider?.updateRecordingDevice(null);

    // Wals
    ServiceManager.instance().wal.getSyncs().sdcard.setDevice(null);

    PlatformManager.instance.instabug.logInfo('Memorion Device Disconnected');
    _disconnectNotificationTimer?.cancel();
    _disconnectNotificationTimer = Timer(const Duration(seconds: 30), () {
      if (isConnected || RecorderWifiActivity.isActive(disconnectedId)) return;
      // 「暂停提醒」开关 + 静默时段网关（P-30N）。
      if (!NotificationPrefs.shouldSendPauseReminder()) return;
      NotificationService.instance.createNotification(
        title: appT((s) => s.deviceNotificationDisconnectedTitle, 'Your Memorion Device Disconnected'),
        body: appT(
          (s) => s.deviceNotificationDisconnectedBody,
          'Please reconnect to continue using your Memorion.',
        ),
      );
    });
    MixpanelManager().deviceDisconnected();

    // Retired 1s to prevent the race condition made by standby power of ble device
    Future.delayed(const Duration(seconds: 1), () {
      periodicConnect('coming from onDisconnect');
    });
  }

  Future<(String, bool, String)> shouldUpdateFirmware() async {
    if ((connectedDevice ?? pairedDevice)?.usesOfflineImport == true) return ('', false, '');
    if (pairedDevice == null || connectedDevice == null) {
      return (appT((s) => s.deviceFirmwareNoPaired, 'No paired device is connected'), false, '');
    }

    var device = pairedDevice!;
    var latestFirmwareDetails = await getLatestFirmwareVersion(
      deviceModelNumber: device.modelNumber,
      firmwareRevision: device.firmwareRevision,
      hardwareRevision: device.hardwareRevision,
      manufacturerName: device.manufacturerName,
    );

    return await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: device.firmwareRevision, latestFirmwareDetails: latestFirmwareDetails);
  }

  void _onDeviceConnected(BtDevice device) async {
    Logger.debug('_onConnected inside: $connectedDevice');
    // 佩戴时段（P-01 首页「未佩戴」空档条）：开启一个 BLE 连接时段。
    WearTracking.onConnected();
    _disconnectNotificationTimer?.cancel();
    NotificationService.instance.clearNotification(1);
    setConnectedDevice(device);

    if (captureProvider != null) {
      captureProvider?.updateRecordingDevice(device.usesOfflineImport ? null : device);
    }

    setIsDeviceV2Connected();
    setIsConnected(true);

    await initiateBleBatteryListener();
    await initiateChargingStatusListener();
    if (batteryLevel != -1 && batteryLevel < 20) {
      _hasLowBatteryAlerted = false;
    }
    await readLedMode();
    updateConnectingStatus(false);
    if (!device.usesOfflineImport) {
      try {
        final started = await captureProvider?.streamDeviceRecording(device: device);
        if (started == false) Logger.debug('Device connected; phone recording retains the audio path');
      } catch (error) {
        Logger.debug('Device connected; audio startup failed: $error');
      }
    }

    await getDeviceInfo(forceRefresh: true);
    SharedPreferencesUtil().deviceName = device.name;

    // Wals
    ServiceManager.instance().wal.getSyncs().sdcard.setDevice(device.usesOfflineImport ? null : device);

    notifyListeners();

    // Check firmware updates
    if (!device.usesOfflineImport) _checkFirmwareUpdates();
  }

  void _checkFirmwareUpdates() async {
    await checkFirmwareUpdates();

    // Show firmware update dialog if needed
    if (_havingNewFirmware) {
      // Use a small delay to ensure the UI is ready
      Future.delayed(const Duration(milliseconds: 500), () {
        final context = MyApp.navigatorKey.currentContext;
        if (context != null) {
          showFirmwareUpdateDialog(context);
        }
      });
    }
  }

  Future checkFirmwareUpdates() async {
    int retryCount = 0;
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 3);

    while (retryCount < maxRetries) {
      try {
        var (message, hasUpdate, version) = await shouldUpdateFirmware();
        _havingNewFirmware = hasUpdate;
        _latestFirmwareVersion = version.isNotEmpty ? version : message;
        notifyListeners();
        return hasUpdate; // Return whether there's an update
      } catch (e) {
        retryCount++;
        Logger.debug('Error checking firmware update (attempt $retryCount): $e');

        if (retryCount == maxRetries) {
          Logger.debug('Max retries reached, giving up');
          _havingNewFirmware = false;
          notifyListeners();
          break;
        }

        await Future.delayed(retryDelay);
      }
    }
    return;
  }

  void showFirmwareUpdateDialog(BuildContext context) {
    if (!_havingNewFirmware ||
        !SharedPreferencesUtil().showFirmwareUpdateDialog ||
        _firmwareDialogDismissed ||
        _firmwareDialogShowing) {
      return;
    }

    _firmwareDialogShowing = true;
    showDialog(
      context: context,
      builder: (context) => ConfirmationDialog(
        title: S.of(context).firmwareDialogTitle,
        description: S.of(context).firmwareDialogDescription(_latestFirmwareVersion),
        confirmText: S.of(context).firmwareDialogConfirm,
        cancelText: S.of(context).firmwareDialogCancel,
        onConfirm: () {
          _firmwareDialogShowing = false;
          Navigator.of(context).pop();
          // 走浅色 P-04B 固件页（和设备详情页同一个页面、同一个 FirmwareMixin）。
          // 旧的深色 `FirmwareUpdate` 已删——它做的是同一件事，只是配色属于旧壳。
          final device = pairedDevice;
          // 这个门禁（`_havingNewFirmware`）本身不含判空，别把 null 断言留给用户。
          if (device == null) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => FirmwareUpdatePage(device: device),
            ),
          );
        },
        onCancel: () {
          _firmwareDialogDismissed = true;
          _firmwareDialogShowing = false;
          Navigator.of(context).pop();
        },
      ),
    ).then((_) {
      _firmwareDialogShowing = false;
    });
  }

  Future setIsDeviceV2Connected() async {
    if (connectedDevice == null) {
      isDeviceV2Connected = false;
    } else {
      var storageFiles = await _getStorageList(connectedDevice!.id);
      isDeviceV2Connected = storageFiles.isNotEmpty;
    }
    notifyListeners();
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) async {
    Logger.debug("provider > device connection state changed...$deviceId...$state...${connectedDevice?.id}");
    switch (state) {
      case DeviceConnectionState.connected:
        // Resolve the device WITHOUT awaiting ensureConnection here: the outer
        // connect flow still holds the ensureConnection mutex (ping +
        // discoverServices in flight), so awaiting would spin-block for several
        // seconds and delay the UI switching to "connected". The sync getter
        // reads the live connection state directly, so the UI updates instantly.
        var device = _deviceService.connectedDevice;
        if (device == null || device.id != deviceId) {
          return;
        }
        _onDeviceConnected(device);
        break;
      case DeviceConnectionState.disconnected:
        if (deviceId == connectedDevice?.id) {
          onDeviceDisconnected();
        }
      default:
        Logger.debug("Device connection state is not supported $state");
    }
  }

  @override
  void onDevices(List<BtDevice> devices) async {}

  @override
  void onStatusChanged(DeviceServiceStatus status) {}

  prepareDFU() {
    if (connectedDevice == null) {
      return;
    }
    _bleDisconnectDevice(connectedDevice!);
    _reconnectAt = DateTime.now().add(const Duration(seconds: 30));
  }

  /// Force disconnect, clear iOS GATT cache, and reconnect after DFU.
  /// iOS caches BLE GATT data aggressively, so after OTA the old firmware
  /// revision may persist unless we fully disconnect and re-discover services.
  Future<void> postDfuReconnect() async {
    if (connectedDevice != null) {
      await _deviceService.forceDisconnect(connectedDevice!.id);
    }
    setIsConnected(false);
    setConnectedDevice(null);
    // Give iOS time to release GATT cache before reconnecting
    await Future.delayed(const Duration(seconds: 3));
    await scanAndConnectToDevice();
  }

  // Called when app returns to foreground to verify connection state
  Future<void> verifyConnectionAfterResume() async {
    if (_recorderWifiActive) return;
    Logger.debug("Verifying connection after app resume...");

    if (SharedPreferencesUtil().btDevice.id.isEmpty) {
      Logger.debug("No paired device found");
      return;
    }

    // Check if we think we're connected
    if (isConnected && connectedDevice != null) {
      Logger.debug("App shows connected, verifying actual device connection...");

      // Verify the actual connection status
      var actualDevice = await _getConnectedDevice();

      if (actualDevice == null) {
        // Connection state mismatch - app thinks it's connected but device is not reachable
        Logger.debug("Connection state mismatch detected! Forcing reconnection...");

        // Reset state and trigger reconnection
        setIsConnected(false);
        setConnectedDevice(null);
        updateConnectingStatus(false);

        // Start reconnection
        await scanAndConnectToDevice();
      } else {
        Logger.debug("Connection verified and working correctly");
      }
    } else if (!isConnected) {
      // Not connected, try to reconnect
      Logger.debug("App shows disconnected, attempting to reconnect...");
      await scanAndConnectToDevice();
    }
  }

  // ── DEBUG ONLY：模拟设备连接状态（用于无真实 BLE 设备时测试 UI）─────────────
  // 全部包在 kDebugMode 内，release 构建这段逻辑为空，绝不影响 App Store 构建。
  // 长按顶栏设备芯片循环切换。iOS 模拟器 periodicConnect 本就跳过，不会覆盖这里的值。
  int _debugMockIndex = 0;

  /// 循环切换：未连接 → 已连接充电中 → 已连接未充电 → 低电量 → 未连接…
  void debugCycleMockDevice() {
    if (!kDebugMode) return;
    _debugMockIndex = (_debugMockIndex + 1) % 4;
    if (_debugMockIndex == 1) {
      _applyMock(connected: true, battery: 70, charging: true); // 已连接 + 充电中（闪电）
    } else if (_debugMockIndex == 2) {
      _applyMock(connected: true, battery: 45, charging: false); // 已连接 + 未充电
    } else if (_debugMockIndex == 3) {
      _applyMock(connected: true, battery: 15, charging: false); // 低电量
    } else {
      _applyMock(connected: false, battery: -1, charging: false); // 0：未连接（清除模拟）
    }
  }

  void _applyMock({required bool connected, required int battery, required bool charging}) {
    if (!kDebugMode) return;
    isConnected = connected;
    isConnecting = false;
    batteryLevel = battery;
    isCharging = charging;
    isBatteryDisconnected = false;
    if (connected) {
      final mock = BtDevice(
        id: 'DEBUG-MOCK-0001-Memorion',
        name: 'Memorion',
        type: DeviceType.memorion,
        rssi: -45,
      );
      mock.firmwareRevision = '2026.06.25';
      connectedDevice = mock;
      pairedDevice = mock;
    } else {
      connectedDevice = null;
    }
    notifyListeners();
  }
}
