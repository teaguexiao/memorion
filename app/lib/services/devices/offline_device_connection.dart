import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'device_connection.dart';

abstract class OfflineDeviceConnection extends DeviceConnection {
  OfflineDeviceConnection(super.device, super.bleDevice);
  // Imported recorder files never enter the raw BLE/WAL audio path.
  @override
  Future<BleAudioCodec> performGetAudioCodec() async => BleAudioCodec.unknown;
  @override
  Future<List<int>> performGetButtonState() async => [];
  @override
  Future<StreamSubscription?> performGetBleAudioBytesListener({
    required void Function(List<int>) onAudioBytesReceived,
  }) async =>
      null;
  @override
  Future<StreamSubscription?> performGetBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async =>
      null;
  @override
  Future<List<int>> performGetStorageList() async => [];
  @override
  Future<bool> performWriteToStorage(int numFile, int command, int offset) async => false;
  @override
  Future<StreamSubscription?> performGetBleStorageBytesListener({
    required void Function(List<int>) onStorageBytesReceived,
  }) async =>
      null;
  @override
  Future<bool> performPlayToSpeakerHaptic(int mode) async => false;
  @override
  Future<void> performCameraStartPhotoController() async {}
  @override
  Future<void> performCameraStopPhotoController() async {}
  @override
  Future<void> performCameraTakePhoto() async {}
  @override
  Future<bool> performHasPhotoStreamingCharacteristic() async => false;
  @override
  Future<StreamSubscription?> performGetImageListener({
    required void Function(Uint8List) onImageReceived,
  }) async =>
      null;
  @override
  Future<StreamSubscription<List<int>>?> performGetAccelListener({
    void Function(int)? onAccelChange,
  }) async =>
      null;
  @override
  Future<int> performReadLedDimRatio() async => -1;
  @override
  Future<bool> performWriteLedDimRatio(int ratio) async => false;
}
