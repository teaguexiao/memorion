import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/device_connection.dart';
import 'package:memorion/services/devices/errors.dart';
import 'package:memorion/services/devices/live_subscription_registry.dart';
import 'package:memorion/services/devices/models.dart';
import 'package:memorion/utils/audio/wav_bytes.dart';
import 'package:memorion/utils/logger.dart';
import 'package:image/image.dart' as img;

class MemorionDeviceConnection extends DeviceConnection {
  BluetoothService? _batteryService;
  BluetoothService? _memorionService;
  BluetoothService? _storageService;
  BluetoothService? _accelService;
  BluetoothService? _buttonService;
  BluetoothService? _speakerService;
  BluetoothService? _settingsService;

  MemorionDeviceConnection(super.device, super.bleDevice);

  get deviceId => device.id;

  @override
  Future<void> connect({Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged, bool isReconnect = false}) async {
    await super.connect(onConnectionStateChanged: onConnectionStateChanged, isReconnect: isReconnect);

    // Services
    _memorionService = await getService(memorionServiceUuid);
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      throw DeviceConnectionException("Memorion ble service is not found");
    }

    _batteryService = await getService(batteryServiceUuid);
    if (_batteryService == null) {
      logServiceNotFoundError('Battery', deviceId);
    }

    _storageService = await getService(storageDataStreamServiceUuid);
    if (_storageService == null) {
      logServiceNotFoundError('Storage', deviceId);
    }

    _speakerService = await getService(speakerDataStreamServiceUuid);
    if (_speakerService == null) {
      logServiceNotFoundError('Speaker', deviceId);
    }

    _accelService = await getService(accelDataStreamServiceUuid);
    if (_accelService == null) {
      logServiceNotFoundError('Accelerometer', deviceId);
    }

    _buttonService = await getService(buttonServiceUuid);
    if (_buttonService == null) {
      logServiceNotFoundError('Button', deviceId);
    }

    _settingsService = await getService(settingsServiceUuid);
    if (_settingsService == null) {
      logServiceNotFoundError('Settings', deviceId);
    }
  }

  @override
  Future<bool> isConnected() async {
    return bleDevice.isConnected;
  }

  @override
  Future<int> performRetrieveBatteryLevel() async {
    if (_batteryService == null) {
      logServiceNotFoundError('Battery', deviceId);
      return -1;
    }

    var batteryLevelCharacteristic = getCharacteristic(_batteryService!, batteryLevelCharacteristicUuid);
    if (batteryLevelCharacteristic == null) {
      logCharacteristicNotFoundError('Battery level', deviceId);
      return -1;
    }

    var currValue = await batteryLevelCharacteristic.read();
    if (currValue.isNotEmpty) return currValue[0];
    return -1;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
  }) async {
    if (_batteryService == null) {
      logServiceNotFoundError('Battery', deviceId);
      return null;
    }

    var batteryLevelCharacteristic = getCharacteristic(_batteryService!, batteryLevelCharacteristicUuid);
    if (batteryLevelCharacteristic == null) {
      logCharacteristicNotFoundError('Battery level', deviceId);
      return null;
    }

    var currValue = await batteryLevelCharacteristic.read();
    if (currValue.isNotEmpty) {
      debugPrint('Battery level: ${currValue[0]}');
      onBatteryLevelChange!(currValue[0]);
    }

    try {
      await batteryLevelCharacteristic.setNotifyValue(true);
    } catch (e, stackTrace) {
      logSubscribeError('Battery level', deviceId, e, stackTrace);
      return null;
    }

    var listener = batteryLevelCharacteristic.lastValueStream.listen((value) {
      // debugPrint('Battery level listener: $value');
      if (value.isNotEmpty) {
        onDataReceived();
        debugPrint('Battery level changed: ${value[0]}');
        onBatteryLevelChange!(value[0]);
      }
    });

    final device = bleDevice;
    device.cancelWhenDisconnected(listener);

    return listener;
  }

  @override
  Future<StreamSubscription?> performGetChargingStatusListener({
    required void Function(int) onChargingStatusChange,
  }) async {
    if (_settingsService == null) {
      logServiceNotFoundError('Settings', deviceId);
      return null;
    }

    var chargingCharacteristic = getCharacteristic(_settingsService!, settingsChargingStatusCharacteristicUuid);
    if (chargingCharacteristic == null) {
      // Firmware may not support charging status yet — silently return null
      debugPrint('Charging status characteristic not found (firmware may not support it)');
      return null;
    }

    // Read initial value
    try {
      var currValue = await chargingCharacteristic.read();
      if (currValue.isNotEmpty) {
        // 0 = no USB, 1 = charging, 2 = USB powered but battery disconnected
        onChargingStatusChange(currValue[0]);
      }
    } catch (e) {
      debugPrint('Failed to read initial charging status: $e');
    }

    // Subscribe to notifications
    try {
      await chargingCharacteristic.setNotifyValue(true);
    } catch (e, stackTrace) {
      logSubscribeError('Charging status', deviceId, e, stackTrace);
      return null;
    }

    var listener = chargingCharacteristic.lastValueStream.listen((value) {
      if (value.isNotEmpty) {
        onChargingStatusChange(value[0]);
      }
    });

    bleDevice.cancelWhenDisconnected(listener);
    return listener;
  }

  @override
  Future<int> performReadChargingStatus() async {
    if (_settingsService == null) return -1;
    var chargingCharacteristic = getCharacteristic(_settingsService!, settingsChargingStatusCharacteristicUuid);
    if (chargingCharacteristic == null) return -1;
    try {
      var value = await chargingCharacteristic.read();
      if (value.isNotEmpty) return value[0];
    } catch (e) {
      debugPrint('Failed to poll charging status: $e');
    }
    return -1;
  }

  @override
  Future<List<int>> performGetButtonState() async {
    debugPrint('perform button state called');
    if (_buttonService == null) {
      return Future.value(<int>[]);
    }

    var buttonStateCharacteristic = getCharacteristic(_buttonService!, buttonTriggerCharacteristicUuid);
    if (buttonStateCharacteristic == null) {
      logCharacteristicNotFoundError('Button state', deviceId);
      return Future.value(<int>[]);
    }
    var value = await buttonStateCharacteristic.read();
    return value;
  }

  @override
  Future<StreamSubscription?> performGetBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async {
    if (_buttonService == null) {
      logServiceNotFoundError('Button', deviceId);
      return null;
    }

    var buttonDataStreamCharacteristic = getCharacteristic(_buttonService!, buttonTriggerCharacteristicUuid);
    if (buttonDataStreamCharacteristic == null) {
      logCharacteristicNotFoundError('Button data stream', deviceId);
      return null;
    }

    try {
      // TODO: Unknown GATT error here (code 133) on Android. StackOverflow says that it has to do with smaller MTU size
      // The creator of the plugin says not to use autoConnect
      // https://github.com/chipweinberger/flutter_blue_plus/issues/612
      final device = bleDevice;
      if (device.isConnected) {
        if (Platform.isAndroid && device.mtuNow < 512) {
          await device.requestMtu(512); // This might fix the code 133 error
        }
        if (device.isConnected) {
          try {
            await buttonDataStreamCharacteristic.setNotifyValue(true); // device could be disconnected here.
          } on PlatformException catch (e) {
            Logger.error('Error setting notify value for audio data stream $e');
          }
        } else {
          Logger.handle(Exception('Device disconnected before setting notify value'), StackTrace.current,
              message: 'Device is disconnected. Please reconnect and try again');
        }
      }
    } catch (e, stackTrace) {
      logSubscribeError('Button data stream', deviceId, e, stackTrace);
      return null;
    }

    debugPrint('Subscribed to button stream from Memorion Device');
    var listener = buttonDataStreamCharacteristic.lastValueStream.listen((value) {
      debugPrint("new button value $value");
      if (value.isNotEmpty) {
        onDataReceived();
        onButtonReceived(value);
      }
    });

    final device = bleDevice;
    device.cancelWhenDisconnected(listener);

    // This will cause a crash in OpenGlass devices
    // due to a race with discoverServices() that triggers
    // a bug in the device firmware.
    if (Platform.isAndroid && device.isConnected) await device.requestMtu(512);

    return listener;
  }

  /// ⚠️ **整个函数体包在 [bleAudioSubscriptions] 里，这不是装饰。** 底下那条通知流是
  /// 广播流，挂 N 个 listener 就会把同一帧音频发给服务器 N 遍（详见
  /// `live_subscription_registry.dart` 的类注释）。registry 负责两件调用方保证不了的事：
  /// 同一台设备上的并发调用排队、旧订阅在新订阅之前被取消。
  @override
  Future<StreamSubscription?> performGetBleAudioBytesListener({
    required void Function(List<int>) onAudioBytesReceived,
  }) {
    return bleAudioSubscriptions.replace<List<int>>(
      bleDevice.remoteId.str,
      () => _subscribeAudioBytes(onAudioBytesReceived: onAudioBytesReceived),
    );
  }

  Future<StreamSubscription<List<int>>?> _subscribeAudioBytes({
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return null;
    }

    var audioDataStreamCharacteristic = getCharacteristic(_memorionService!, audioDataStreamCharacteristicUuid);
    if (audioDataStreamCharacteristic == null) {
      logCharacteristicNotFoundError('Audio data stream', deviceId);
      return null;
    }

    try {
      // TODO: Unknown GATT error here (code 133) on Android. StackOverflow says that it has to do with smaller MTU size
      // The creator of the plugin says not to use autoConnect
      // https://github.com/chipweinberger/flutter_blue_plus/issues/612
      final device = bleDevice;
      if (device.isConnected) {
        if (Platform.isAndroid && device.mtuNow < 512) {
          await device.requestMtu(512); // This might fix the code 133 error
        }
        if (device.isConnected) {
          try {
            await audioDataStreamCharacteristic.setNotifyValue(true); // device could be disconnected here.
          } on PlatformException catch (e) {
            Logger.error('Error setting notify value for audio data stream $e');
          }
        } else {
          Logger.handle(Exception('Device disconnected before setting notify value'), StackTrace.current,
              message: 'Device is disconnected. Please reconnect and try again');
        }
      }
    } catch (e, stackTrace) {
      logSubscribeError('Audio data stream', deviceId, e, stackTrace);
      return null;
    }

    debugPrint('Subscribed to audioBytes stream from Memorion Device');
    // ⚠️ **用 `onValueReceived` 而不是 `lastValueStream`。** 后者在被 listen 的那一刻会
    // 把特征上缓存的 `lastValue` **重放**一遍（`bluetooth_characteristic.dart:68`
    // 的 `newStreamWithInitialValue`）—— 对电量/充电状态那种「订阅时想立刻知道当前值」
    // 的特征是对的，对音频这种数据流则是每次重新订阅都白插一帧旧音频。
    // 判据就是这个：**订阅时重放当前值有没有意义**。所以电量/充电那几处刻意不改。
    var listener = audioDataStreamCharacteristic.onValueReceived.listen((value) {
      if (value.isNotEmpty) {
        onDataReceived();
        onAudioBytesReceived(value);
      }
    });

    final device = bleDevice;
    device.cancelWhenDisconnected(listener);

    // This will cause a crash in OpenGlass devices
    // due to a race with discoverServices() that triggers
    // a bug in the device firmware.
    if (Platform.isAndroid && device.isConnected) await device.requestMtu(512);

    return listener;
  }

  @override
  Future<BleAudioCodec> performGetAudioCodec() async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return BleAudioCodec.pcm8;
    }

    var audioCodecCharacteristic = getCharacteristic(_memorionService!, audioCodecCharacteristicUuid);
    if (audioCodecCharacteristic == null) {
      logCharacteristicNotFoundError('Audio codec', deviceId);
      return BleAudioCodec.pcm8;
    }

    // Default codec is PCM8
    var codecId = 1;
    BleAudioCodec codec = BleAudioCodec.pcm8;

    var codecValue = await audioCodecCharacteristic.read();
    if (codecValue.isNotEmpty) {
      codecId = codecValue[0];
    }

    switch (codecId) {
      // case 0:
      //   codec = BleAudioCodec.pcm16;
      case 1:
        codec = BleAudioCodec.pcm8;
      // case 10:
      //   codec = BleAudioCodec.mulaw16;
      // case 11:
      //   codec = BleAudioCodec.mulaw8;
      case 20:
        codec = BleAudioCodec.opus;
      case 21:
        codec = BleAudioCodec.opusFS320;
      default:
        logErrorMessage('Unknown codec id: $codecId', deviceId);
    }

    // debugPrint('Codec is $codec');
    return codec;
  }

  @override
  Future<List<int>> getStorageList() async {
    if (await isConnected()) {
      debugPrint('storage list called');
      return await performGetStorageList();
    }
    // _showDeviceDisconnectedNotification();
    debugPrint('storage list error');
    return Future.value(<int>[]);
  }

  @override
  Future<List<int>> performGetStorageList() async {
    debugPrint(' perform storage list called');
    if (_storageService == null) {
      if (device.name == 'Memorion DevKit 2') {
        // Should only report incase of DevKit 2 because only DevKit 2 has storage service
        logServiceNotFoundError('Storage', deviceId);
      }
      return Future.value(<int>[]);
    }

    var storageListCharacteristic = getCharacteristic(_storageService!, storageReadControlCharacteristicUuid);
    if (storageListCharacteristic == null) {
      logCharacteristicNotFoundError('Storage List', deviceId);
      return Future.value(<int>[]);
    }

    List<int> storageValue;
    try {
      storageValue = await storageListCharacteristic.read();
    } catch (e, stackTrace) {
      logCrashMessage('Storage value', deviceId, e, stackTrace);
      return Future.value(<int>[]);
    }
    List<int> storageLengths = [];
    if (storageValue.isNotEmpty) {
      int totalEntries = (storageValue.length / 4).toInt();
      debugPrint('Storage list: $totalEntries items');

      for (int i = 0; i < totalEntries; i++) {
        int baseIndex = i * 4;
        var result = ((storageValue[baseIndex] |
                    (storageValue[baseIndex + 1] << 8) |
                    (storageValue[baseIndex + 2] << 16) |
                    (storageValue[baseIndex + 3] << 24)) &
                0xFFFFFFFF)
            .toSigned(32);
        storageLengths.add(result);
      }
    }
    debugPrint('storage list finished');
    debugPrint('Storage lengths: ${storageLengths.length} items: ${storageLengths.join(', ')}');
    return storageLengths;
  }

  @override
  Future<StreamSubscription?> performGetBleStorageBytesListener({
    required void Function(List<int>) onStorageBytesReceived,
  }) async {
    if (_storageService == null) {
      logServiceNotFoundError('Storage Write', deviceId);
      return null;
    }

    var storageDataStreamCharacteristic = getCharacteristic(_storageService!, storageDataStreamCharacteristicUuid);
    if (storageDataStreamCharacteristic == null) {
      logCharacteristicNotFoundError('Storage data stream', deviceId);
      return null;
    }

    try {
      await storageDataStreamCharacteristic.setNotifyValue(true); // device could be disconnected here.
    } catch (e, stackTrace) {
      logSubscribeError('Storage data stream', deviceId, e, stackTrace);
      return null;
    }

    debugPrint('Subscribed to StorageBytes stream from Memorion Device');
    var listener = storageDataStreamCharacteristic.lastValueStream.listen((value) {
      if (value.isNotEmpty) onStorageBytesReceived(value);
    });

    final device = bleDevice;
    device.cancelWhenDisconnected(listener);

    // await storageDataStreamCharacteristic.write([0x00,0x01]);

    // This will cause a crash in OpenGlass devices
    // due to a race with discoverServices() that triggers
    // a bug in the device firmware.
    if (Platform.isAndroid) await device.requestMtu(512);

    return listener;
  }

  // level
  //   1 - play 20ms
  //   2 - play 50ms
  //   3 - play 500ms
  @override
  Future<bool> performPlayToSpeakerHaptic(int level) async {
    if (_speakerService == null) {
      logServiceNotFoundError('Speaker Write', deviceId);
      return false;
    }

    var speakerDataStreamCharacteristic = getCharacteristic(_speakerService!, speakerDataStreamCharacteristicUuid);
    if (speakerDataStreamCharacteristic == null) {
      logCharacteristicNotFoundError('Speaker data stream', deviceId);
      return false;
    }
    debugPrint('About to play to speaker haptic');
    await speakerDataStreamCharacteristic.write([level & 0xFF]);
    return true;
  }

  @override
  Future<bool> performWriteToStorage(int numFile, int command, int offset) async {
    if (_storageService == null) {
      logServiceNotFoundError('Storage Write', deviceId);
      return false;
    }

    var storageDataStreamCharacteristic = getCharacteristic(_storageService!, storageDataStreamCharacteristicUuid);
    if (storageDataStreamCharacteristic == null) {
      logCharacteristicNotFoundError('Storage data stream', deviceId);
      return false;
    }
    debugPrint('About to write to storage bytes');
    debugPrint('about to send $numFile');
    debugPrint('about to send $command');
    debugPrint('about to send offset$offset');
    var offsetBytes = [
      (offset >> 24) & 0xFF,
      (offset >> 16) & 0xFF,
      (offset >> 8) & 0xFF,
      offset & 0xFF,
    ];

    await storageDataStreamCharacteristic
        .write([command & 0xFF, numFile & 0xFF, offsetBytes[0], offsetBytes[1], offsetBytes[2], offsetBytes[3]]);
    return true;
  }
  // Future<List<int>> performGetStorageList();

  @override
  Future performCameraStartPhotoController() async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return;
    }

    var imageCaptureControlCharacteristic = getCharacteristic(_memorionService!, imageCaptureControlCharacteristicUuid);
    if (imageCaptureControlCharacteristic == null) {
      logCharacteristicNotFoundError('Image capture control', deviceId);
      return;
    }

    // Capture photo once every 5s
    await imageCaptureControlCharacteristic.write([0x05]);

    print('cameraStartPhotoController');
  }

  @override
  Future performCameraStopPhotoController() async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return;
    }

    var imageCaptureControlCharacteristic = getCharacteristic(_memorionService!, imageCaptureControlCharacteristicUuid);
    if (imageCaptureControlCharacteristic == null) {
      logCharacteristicNotFoundError('Image capture control', deviceId);
      return;
    }

    await imageCaptureControlCharacteristic.write([0x00]);

    print('cameraStopPhotoController');
  }

  @override
  Future performCameraTakePhoto() async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return;
    }

    var imageCaptureControlCharacteristic = getCharacteristic(_memorionService!, imageCaptureControlCharacteristicUuid);
    if (imageCaptureControlCharacteristic == null) {
      logCharacteristicNotFoundError('Image capture control', deviceId);
      return;
    }

    // -1 tells the firmware to take a single photo
    await imageCaptureControlCharacteristic.write([-1]);

    print('cameraTakePhoto');
  }

  @override
  Future<bool> performHasPhotoStreamingCharacteristic() async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return false;
    }
    var imageCaptureControlCharacteristic = getCharacteristic(_memorionService!, imageDataStreamCharacteristicUuid);
    return imageCaptureControlCharacteristic != null;
  }

  /// Check if device supports preview streaming
  Future<bool> hasPreviewStreamingCharacteristic() async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return false;
    }
    var previewStreamCharacteristic = getCharacteristic(_memorionService!, previewStreamCharacteristicUuid);
    return previewStreamCharacteristic != null;
  }

  /// Start low-resolution preview stream (160x120 continuous capture)
  /// Command: 0x01 = start preview
  Future<void> startPreviewStream() async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return;
    }

    var imageCaptureControlCharacteristic = getCharacteristic(_memorionService!, imageCaptureControlCharacteristicUuid);
    if (imageCaptureControlCharacteristic == null) {
      logCharacteristicNotFoundError('Image capture control', deviceId);
      return;
    }

    // 0x01 = start preview mode (low-res continuous)
    await imageCaptureControlCharacteristic.write([0x01]);
    debugPrint('Preview stream started');
  }

  /// Stop preview stream
  /// Command: 0x02 = stop preview
  Future<void> stopPreviewStream() async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return;
    }

    var imageCaptureControlCharacteristic = getCharacteristic(_memorionService!, imageCaptureControlCharacteristicUuid);
    if (imageCaptureControlCharacteristic == null) {
      logCharacteristicNotFoundError('Image capture control', deviceId);
      return;
    }

    // 0x02 = stop preview mode
    await imageCaptureControlCharacteristic.write([0x02]);
    debugPrint('Preview stream stopped');
  }

  /// Get preview frame listener for low-resolution real-time preview
  /// Returns JPEG frames at 160x120 resolution, ~3-5 fps
  Future<StreamSubscription?> getPreviewListener({
    required void Function(Uint8List jpegFrame) onPreviewFrame,
  }) async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return null;
    }

    var previewStreamCharacteristic = getCharacteristic(_memorionService!, previewStreamCharacteristicUuid);
    if (previewStreamCharacteristic == null) {
      // Fallback to image data stream if preview-specific characteristic not available
      previewStreamCharacteristic = getCharacteristic(_memorionService!, imageDataStreamCharacteristicUuid);
      if (previewStreamCharacteristic == null) {
        logCharacteristicNotFoundError('Preview stream', deviceId);
        return null;
      }
    }

    try {
      await previewStreamCharacteristic.setNotifyValue(true);
    } catch (e, stackTrace) {
      logSubscribeError('Preview stream', deviceId, e, stackTrace);
      return null;
    }

    debugPrint('Subscribed to preview stream from Memorion Device');

    // Use same frame assembly logic as high-res images
    var buffer = BytesBuilder();
    var nextExpectedFrame = 0;
    var isTransferring = false;

    var listener = previewStreamCharacteristic.lastValueStream.listen((value) {
      if (value.isEmpty || value.length < 2) return;

      Uint8List chunk = Uint8List.fromList(value);
      int frameIndex = chunk[0] | (chunk[1] << 8);

      // End of frame marker 0xFFFF
      if (frameIndex == 0xFFFF) {
        if (isTransferring) {
          final frameBytes = buffer.toBytes();
          if (frameBytes.isNotEmpty) {
            try {
              onPreviewFrame(frameBytes);
            } catch (e) {
              debugPrint('Error processing preview frame: $e');
            }
          }
        }
        buffer.clear();
        nextExpectedFrame = 0;
        isTransferring = false;
        return;
      }

      // Start of new frame
      if (frameIndex == 0) {
        buffer.clear();
        nextExpectedFrame = 0;
        isTransferring = true;
      }

      // Validate frame order
      if (frameIndex != nextExpectedFrame) {
        debugPrint('Preview: Out of order frame received: expected $nextExpectedFrame, got $frameIndex');
        buffer.clear();
        nextExpectedFrame = 0;
        isTransferring = false;
        return;
      }

      // Add frame data (skip 2-byte header)
      buffer.add(chunk.sublist(2));
      nextExpectedFrame++;

      // Safety: limit buffer size to 50KB for preview frames
      if (buffer.length > 50 * 1024) {
        debugPrint('Preview: Buffer overflow, resetting');
        buffer.clear();
        nextExpectedFrame = 0;
        isTransferring = false;
      }
    });

    bleDevice.cancelWhenDisconnected(listener);
    return listener;
  }

  Future<StreamSubscription?> _getBleImageBytesListener({
    required void Function(List<int>) onImageBytesReceived,
  }) async {
    if (_memorionService == null) {
      logServiceNotFoundError('Memorion', deviceId);
      return null;
    }

    var imageStreamCharacteristic = getCharacteristic(_memorionService!, imageDataStreamCharacteristicUuid);
    if (imageStreamCharacteristic == null) {
      logCharacteristicNotFoundError('Image data stream', deviceId);
      return null;
    }

    try {
      await imageStreamCharacteristic.setNotifyValue(true); // device could be disconnected here.
    } catch (e, stackTrace) {
      logSubscribeError('Image data stream', deviceId, e, stackTrace);
      return null;
    }

    debugPrint('Subscribed to imageBytes stream from Memorion Device');
    var listener = imageStreamCharacteristic.lastValueStream.listen((value) {
      if (value.isNotEmpty) onImageBytesReceived(value);
    });

    final device = bleDevice;
    device.cancelWhenDisconnected(listener);

    // This will cause a crash in OpenGlass devices
    // due to a race with discoverServices() that triggers
    // a bug in the device firmware.
    // if (Platform.isAndroid) await device.requestMtu(512);

    return listener;
  }

  @override
  Future<StreamSubscription?> performGetImageListener({
    required void Function(Uint8List base64JpgData) onImageReceived,
  }) async {
    if (!await hasPhotoStreamingCharacteristic()) {
      return null;
    }
    print("OpenGlassDevice getImageListener called");

    var buffer = BytesBuilder();
    var nextExpectedFrame = 0;
    var isTransferring = false;

    var bleBytesStream = await _getBleImageBytesListener(
      onImageBytesReceived: (List<int> value) async {
        if (value.length < 2) return;

        Uint8List chunk = Uint8List.fromList(value);
        int frameIndex = chunk[0] | (chunk[1] << 8);

        // End of image marker 0xFFFF
        if (frameIndex == 0xFFFF) {
          if (isTransferring) {
            var imageBytes = buffer.toBytes();
            if (imageBytes.isNotEmpty) {
              debugPrint('[MemorionConnection] Raw image bytes length: ${imageBytes.length}');

              // Find JPEG start marker (FF D8) - firmware may prepend control bytes
              int jpegStartOffset = 0;
              for (int i = 0; i < imageBytes.length - 1; i++) {
                if (imageBytes[i] == 0xFF && imageBytes[i + 1] == 0xD8) {
                  jpegStartOffset = i;
                  break;
                }
              }

              // Strip any prefix bytes before JPEG header
              if (jpegStartOffset > 0) {
                debugPrint('[MemorionConnection] Found JPEG header at offset $jpegStartOffset, stripping ${jpegStartOffset} prefix bytes');
                imageBytes = imageBytes.sublist(jpegStartOffset);
              }

              debugPrint('[MemorionConnection] Final image bytes length: ${imageBytes.length}');

              // Validate JPEG structure
              if (imageBytes.length >= 4) {
                final firstBytes = imageBytes.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
                final lastBytes = imageBytes.sublist(imageBytes.length - 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
                debugPrint('[MemorionConnection] First 4 bytes: $firstBytes');
                debugPrint('[MemorionConnection] Last 4 bytes: $lastBytes');
                final isValidJpegHeader = imageBytes[0] == 0xFF && imageBytes[1] == 0xD8;
                final isValidJpegFooter = imageBytes[imageBytes.length - 2] == 0xFF && imageBytes[imageBytes.length - 1] == 0xD9;
                debugPrint('[MemorionConnection] Valid JPEG header (FFD8): $isValidJpegHeader, Valid JPEG footer (FFD9): $isValidJpegFooter');

                if (!isValidJpegHeader) {
                  debugPrint('[MemorionConnection] ERROR: Invalid JPEG header, discarding image');
                  buffer.clear();
                  isTransferring = false;
                  nextExpectedFrame = 0;
                  return;
                }
              }

              debugPrint('[MemorionConnection] Calling onImageReceived callback...');
              try {
                onImageReceived(Uint8List.fromList(imageBytes));
                debugPrint('[MemorionConnection] onImageReceived callback completed');
              } catch (e) {
                debugPrint('[MemorionConnection] Error processing image: $e');
              }
            }
          }
          // Reset for next image
          buffer.clear();
          isTransferring = false;
          nextExpectedFrame = 0;
          return;
        }

        // If we get frame 0, it's the start of a new image. Reset everything.
        if (frameIndex == 0) {
          buffer.clear();
          isTransferring = true;
          nextExpectedFrame = 0;
        }

        // If we are not in a transfer state, ignore the packet unless it's frame 0.
        if (!isTransferring) {
          debugPrint("Ignoring packet with frame $frameIndex, waiting for frame 0 to start transfer.");
          return;
        }

        // Check if the frame is the one we expect.
        if (frameIndex == nextExpectedFrame) {
          if (chunk.length > 2) {
            buffer.add(chunk.sublist(2));
          }
          nextExpectedFrame++;
        } else {
          // Out of order frame. The image is now corrupt.
          // We should discard everything and wait for the next frame 0.
          debugPrint('Frame out of order. Expected $nextExpectedFrame, got $frameIndex. Discarding image.');
          buffer.clear();
          isTransferring = false;
          nextExpectedFrame = 0;
        }

        // Safety break for oversized buffer
        if (buffer.length > 200 * 1024) {
          debugPrint("Buffer size exceeded 200KB without a complete image. Resetting.");
          buffer.clear();
          isTransferring = false;
          nextExpectedFrame = 0;
        }
      },
    );
    bleBytesStream?.onDone(() {
      debugPrint('Image listener done');
      cameraStopPhotoController();
    });
    return bleBytesStream;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetAccelListener({
    void Function(int)? onAccelChange,
  }) async {
    if (_accelService == null) {
      logServiceNotFoundError('Accelerometer', deviceId);
      return null;
    }

    var accelCharacteristic = getCharacteristic(_accelService!, accelDataStreamCharacteristicUuid);
    if (accelCharacteristic == null) {
      logCharacteristicNotFoundError('Accelerometer', deviceId);
      return null;
    }

    var currValue = await accelCharacteristic.read();
    if (currValue.isNotEmpty) {
      debugPrint('Accelerometer level: ${currValue[0]}');
      onAccelChange!(currValue[0]);
    }

    try {
      await accelCharacteristic.setNotifyValue(true);
    } catch (e, stackTrace) {
      logSubscribeError('Accelerometer level', deviceId, e, stackTrace);
      return null;
    }

    var listener = accelCharacteristic.lastValueStream.listen((value) {
      // debugPrint('Battery level listener: $value');

      if (value.length > 4) {
        //for some reason, the very first reading is four bytes

        if (value.isNotEmpty) {
          List<double> accelerometerData = [];
          onAccelChange!(value[0]);

          for (int i = 0; i < 6; i++) {
            int baseIndex = i * 8;
            var result = ((value[baseIndex] |
                        (value[baseIndex + 1] << 8) |
                        (value[baseIndex + 2] << 16) |
                        (value[baseIndex + 3] << 24)) &
                    0xFFFFFFFF)
                .toSigned(32);
            var temp = ((value[baseIndex + 4] |
                        (value[baseIndex + 5] << 8) |
                        (value[baseIndex + 6] << 16) |
                        (value[baseIndex + 7] << 24)) &
                    0xFFFFFFFF)
                .toSigned(32);
            double axisValue = result + (temp / 1000000);
            accelerometerData.add(axisValue);
          }
          debugPrint('Accelerometer x direction: ${accelerometerData[0]}');
          debugPrint('Gyroscope x direction: ${accelerometerData[3]}\n');

          debugPrint('Accelerometer y direction: ${accelerometerData[1]}');
          debugPrint('Gyroscope y direction: ${accelerometerData[4]}\n');

          debugPrint('Accelerometer z direction: ${accelerometerData[2]}');
          debugPrint('Gyroscope z direction: ${accelerometerData[5]}\n');
        }
      }
    });

    final device = bleDevice;
    device.cancelWhenDisconnected(listener);

    return listener;
  }

  @override
  Future<int> performReadLedDimRatio() async {
    if (_settingsService == null) {
      logServiceNotFoundError('Settings', deviceId);
      return -1;
    }

    var dimRatioCharacteristic = getCharacteristic(_settingsService!, settingsDimRatioCharacteristicUuid);
    if (dimRatioCharacteristic == null) {
      logCharacteristicNotFoundError('Dim ratio', deviceId);
      return -1;
    }

    var value = await dimRatioCharacteristic.read();
    if (value.isNotEmpty) return value[0];
    return -1;
  }

  @override
  Future<bool> performWriteLedDimRatio(int ratio) async {
    if (_settingsService == null) {
      logServiceNotFoundError('Settings', deviceId);
      return false;
    }

    var dimRatioCharacteristic = getCharacteristic(_settingsService!, settingsDimRatioCharacteristicUuid);
    if (dimRatioCharacteristic == null) {
      logCharacteristicNotFoundError('Dim ratio', deviceId);
      return false;
    }

    await dimRatioCharacteristic.write([ratio & 0xFF]);
    debugPrint('Written LED dim ratio: $ratio');
    return true;
  }
}
