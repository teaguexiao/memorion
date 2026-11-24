import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/services/devices/device_connection.dart';
import 'package:memorion/services/devices/frame_connection.dart';
import 'package:memorion/services/devices/models.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/dingtalk_a1/protocol.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/utils/logger.dart';

enum BleAudioCodec {
  pcm16,
  pcm8,
  mulaw16,
  mulaw8,
  opus,
  opusFS320,
  unknown;

  @override
  String toString() => mapCodecToName(this);

  bool isOpusSupported() {
    return this == BleAudioCodec.opusFS320 || this == BleAudioCodec.opus;
  }

  int getFramesPerSecond() {
    return this == BleAudioCodec.opusFS320 ? 50 : 100;
  }

  int getFramesLengthInBytes() {
    return this == BleAudioCodec.opusFS320 ? 160 : 80;
  }

  // PDM frame size
  int getFrameSize() {
    return this == BleAudioCodec.opusFS320 ? 320 : 160;
  }
}

String mapCodecToName(BleAudioCodec codec) {
  switch (codec) {
    case BleAudioCodec.opusFS320:
      return 'opus_fs320';
    case BleAudioCodec.opus:
      return 'opus';
    case BleAudioCodec.pcm16:
      return 'pcm16';
    case BleAudioCodec.pcm8:
      return 'pcm8';
    default:
      return 'pcm8';
  }
}

BleAudioCodec mapNameToCodec(String codec) {
  switch (codec) {
    case 'opus_fs320':
      return BleAudioCodec.opusFS320;
    case 'opus':
      return BleAudioCodec.opus;
    case 'pcm16':
      return BleAudioCodec.pcm16;
    case 'pcm8':
      return BleAudioCodec.pcm8;
    default:
      return BleAudioCodec.pcm8;
  }
}

int mapCodecToSampleRate(BleAudioCodec codec) {
  switch (codec) {
    case BleAudioCodec.opusFS320:
      return 16000;
    case BleAudioCodec.opus:
      return 16000;
    case BleAudioCodec.pcm16:
      return 16000;
    case BleAudioCodec.pcm8:
      return 16000;
    default:
      return 16000;
  }
}

int mapCodecToBitDepth(BleAudioCodec codec) {
  switch (codec) {
    case BleAudioCodec.opusFS320:
      return 16;
    case BleAudioCodec.opus:
      return 16;
    case BleAudioCodec.pcm16:
      return 16;
    case BleAudioCodec.pcm8:
      return 8;
    default:
      return 16;
  }
}

Future<DeviceType?> getTypeOfBluetoothDevice(BluetoothDevice device) async {
  if (cachedDevicesMap.containsKey(device.remoteId.toString())) {
    return cachedDevicesMap[device.remoteId.toString()];
  }
  DeviceType? deviceType;
  await device.discoverServices();
  if (device.servicesList.where((s) => s.uuid == Guid(memorionServiceUuid)).isNotEmpty) {
    // Check if the device has the image data stream characteristic
    final hasImageStream = device.servicesList
        .where((s) => s.uuid == Guid.fromString(memorionServiceUuid))
        .expand((s) => s.characteristics)
        .any((c) => c.uuid.toString().toLowerCase() == imageDataStreamCharacteristicUuid.toLowerCase());
    deviceType = hasImageStream ? DeviceType.openglass : DeviceType.memorion;
  } else if (device.servicesList.where((s) => s.uuid == Guid(frameServiceUuid)).isNotEmpty) {
    deviceType = DeviceType.frame;
  } else if (device.servicesList.where((s) => s.uuid == Guid(soundcoreServiceUuid)).isNotEmpty) {
    deviceType = DeviceType.soundcore;
  } else if (device.servicesList.where((s) => s.uuid == Guid(a1ServiceUuid)).isNotEmpty) {
    deviceType = DeviceType.dingtalkA1;
  }
  if (deviceType != null) {
    cachedDevicesMap[device.remoteId.toString()] = deviceType;
  }
  return deviceType;
}

enum DeviceType {
  memorion,
  openglass,
  frame,
  // Append only: preferences persist the enum index for existing devices.
  soundcore,
  dingtalkA1,
  plaudNote,
  chipletRing,
}

Map<String, DeviceType> cachedDevicesMap = {};
final _cachedPlaudSerials = <String, String>{};

/// Legacy device name patterns used to map old brand names to Memorion branding.
/// These are kept for backward compatibility with devices that advertise older names.
const _legacyGlassNames = ['omi glass', 'openglass'];
const _legacyDevKitNames = ['friend devkit', 'omi devkit'];
const _legacyBrandNames = ['friend', 'omi'];
const _legacyDeviceNames = ['omi device', 'friend'];
const _legacyManufacturerNames = ['based hardware', 'omi', 'friend'];

class BtDevice {
  String name;
  String id;
  DeviceType type;
  int rssi;
  final String? plaudSerial;
  String? _modelNumber;
  String? _firmwareRevision;
  String? _hardwareRevision;
  String? _manufacturerName;

  BtDevice(
      {required this.name,
      required this.id,
      required this.type,
      required this.rssi,
      this.plaudSerial,
      String? modelNumber,
      String? firmwareRevision,
      String? hardwareRevision,
      String? manufacturerName}) {
    _modelNumber = modelNumber;
    _firmwareRevision = firmwareRevision;
    _hardwareRevision = hardwareRevision;
    _manufacturerName = manufacturerName;
  }

  // create an empty device
  BtDevice.empty()
      : name = '',
        id = '',
        type = DeviceType.memorion,
        rssi = 0,
        plaudSerial = null,
        _modelNumber = '',
        _firmwareRevision = '',
        _hardwareRevision = '',
        _manufacturerName = '';

  // getters
  String get modelNumber => _modelNumber ?? 'Unknown';
  String get firmwareRevision => _firmwareRevision ?? 'Unknown';
  String get hardwareRevision => _hardwareRevision ?? 'Unknown';
  String get manufacturerName => _manufacturerName ?? 'Unknown';

  bool get usesOfflineImport =>
      type == DeviceType.soundcore ||
      type == DeviceType.dingtalkA1 ||
      type == DeviceType.plaudNote ||
      type == DeviceType.chipletRing;

  /// Returns the display name for UI, mapping legacy device names to Memorion branding
  String get displayName {
    if (type == DeviceType.chipletRing) return 'ChipletRing';
    if (type == DeviceType.soundcore) return 'SOUNDCORE';
    if (type == DeviceType.dingtalkA1) return 'DingTalk A1';
    if (type == DeviceType.plaudNote) return 'PLAUD Note';
    final lowerName = name.toLowerCase();
    if (_legacyGlassNames.any((n) => lowerName.contains(n))) {
      return 'Memorion Earpod';
    }
    if (_legacyDevKitNames.any((n) => lowerName.contains(n))) {
      return 'Memorion DevKit';
    }
    if (_legacyBrandNames.contains(lowerName) || lowerName == 'memorion') {
      return 'Memorion';
    }
    return name;
  }

  /// Returns the display model number for UI, mapping legacy model names to Memorion branding
  String get displayModelNumber {
    if (type == DeviceType.chipletRing) return 'AI Ring';
    if (type == DeviceType.soundcore) return 'Soundcore Work';
    if (type == DeviceType.dingtalkA1) return 'DingTalk A1';
    if (type == DeviceType.plaudNote) return 'PLAUD Note';
    final lowerModel = modelNumber.toLowerCase();
    if (_legacyGlassNames.any((n) => lowerModel.contains(n))) {
      return 'Memorion Earpod';
    }
    if (_legacyDevKitNames.any((n) => lowerModel.contains(n))) {
      return 'Memorion DevKit';
    }
    if (_legacyDeviceNames.any((n) => lowerModel.contains(n))) {
      return 'Memorion Device';
    }
    return modelNumber;
  }

  /// Returns the display manufacturer name for UI, mapping legacy names to Memorion branding
  String get displayManufacturerName {
    final lowerMfr = manufacturerName.toLowerCase();
    if (_legacyManufacturerNames.any((n) => lowerMfr.contains(n))) {
      return 'Memorion';
    }
    return manufacturerName;
  }

  // set details
  set modelNumber(String modelNumber) => _modelNumber = modelNumber;
  set firmwareRevision(String firmwareRevision) => _firmwareRevision = firmwareRevision;
  set hardwareRevision(String hardwareRevision) => _hardwareRevision = hardwareRevision;
  set manufacturerName(String manufacturerName) => _manufacturerName = manufacturerName;

  String getShortId() => BtDevice.shortId(id);

  static shortId(String id) {
    try {
      return id.replaceAll(':', '').split('-').last.substring(0, 6);
    } catch (e) {
      return id.length > 6 ? id.substring(0, 6) : id;
    }
  }

  BtDevice copyWith(
      {String? name,
      String? id,
      DeviceType? type,
      int? rssi,
      String? plaudSerial,
      String? modelNumber,
      String? firmwareRevision,
      String? hardwareRevision,
      String? manufacturerName}) {
    return BtDevice(
      name: name ?? this.name,
      id: id ?? this.id,
      type: type ?? this.type,
      rssi: rssi ?? this.rssi,
      plaudSerial: plaudSerial ?? this.plaudSerial,
      modelNumber: modelNumber ?? _modelNumber,
      firmwareRevision: firmwareRevision ?? _firmwareRevision,
      hardwareRevision: hardwareRevision ?? _hardwareRevision,
      manufacturerName: manufacturerName ?? _manufacturerName,
    );
  }

  Future updateDeviceInfo(DeviceConnection? conn) async {
    if (conn == null) {
      return this;
    }
    return await getDeviceInfo(conn);
  }

  Future<BtDevice> getDeviceInfo(DeviceConnection? conn) async {
    if (conn == null) {
      if (SharedPreferencesUtil().btDevice.id.isNotEmpty) {
        var device = SharedPreferencesUtil().btDevice;
        return copyWith(
          id: device.id,
          name: device.name,
          type: device.type,
          rssi: device.rssi,
          plaudSerial: device.plaudSerial,
          modelNumber: device.modelNumber,
          firmwareRevision: device.firmwareRevision,
          hardwareRevision: device.hardwareRevision,
          manufacturerName: device.manufacturerName,
        );
      } else {
        return BtDevice.empty();
      }
    }

    if (usesOfflineImport) {
      return conn.device;
    } else if (type == DeviceType.memorion) {
      return await _getDeviceInfoFromMemorion(conn);
    } else if (type == DeviceType.openglass) {
      return await _getDeviceInfoFromMemorion(conn);
    } else if (type == DeviceType.frame) {
      return await _getDeviceInfoFromFrame(conn as FrameDeviceConnection);
    } else {
      return await _getDeviceInfoFromMemorion(conn);
    }
  }

  Future _getDeviceInfoFromMemorion(DeviceConnection conn) async {
    var modelNumber = 'Memorion Device';
    var firmwareRevision = '1.0.2';
    var hardwareRevision = 'Seeed Xiao BLE Sense';
    var manufacturerName = 'Memorion';
    var t = DeviceType.memorion;
    try {
      var deviceInformationService = await conn.getService(deviceInformationServiceUuid);
      if (deviceInformationService != null) {
        var modelNumberCharacteristic = conn.getCharacteristic(deviceInformationService, modelNumberCharacteristicUuid);
        if (modelNumberCharacteristic != null) {
          modelNumber = String.fromCharCodes(await modelNumberCharacteristic.read());
        }

        var firmwareRevisionCharacteristic =
            conn.getCharacteristic(deviceInformationService, firmwareRevisionCharacteristicUuid);
        if (firmwareRevisionCharacteristic != null) {
          firmwareRevision = String.fromCharCodes(await firmwareRevisionCharacteristic.read());
        }

        var hardwareRevisionCharacteristic =
            conn.getCharacteristic(deviceInformationService, hardwareRevisionCharacteristicUuid);
        if (hardwareRevisionCharacteristic != null) {
          hardwareRevision = String.fromCharCodes(await hardwareRevisionCharacteristic.read());
        }

        var manufacturerNameCharacteristic =
            conn.getCharacteristic(deviceInformationService, manufacturerNameCharacteristicUuid);
        if (manufacturerNameCharacteristic != null) {
          manufacturerName = String.fromCharCodes(await manufacturerNameCharacteristic.read());
        }
      }

      if (type == DeviceType.openglass) {
        t = DeviceType.openglass;
      } else {
        final deviceService = await conn.getService(memorionServiceUuid);
        if (deviceService != null) {
          var imageCaptureControlCharacteristic =
              conn.getCharacteristic(deviceService, imageDataStreamCharacteristicUuid);
          if (imageCaptureControlCharacteristic != null) {
            t = DeviceType.openglass;
          }
        }
      }
    } on PlatformException catch (e) {
      Logger.error('Device Disconnected while getting device info: $e');
    }

    return copyWith(
      modelNumber: modelNumber,
      firmwareRevision: firmwareRevision,
      hardwareRevision: hardwareRevision,
      manufacturerName: manufacturerName,
      type: t,
    );
  }

  Future _getDeviceInfoFromFrame(FrameDeviceConnection conn) async {
    await conn.init();
    return copyWith(
      modelNumber: conn.modelNumber,
      firmwareRevision: conn.firmwareRevision,
      hardwareRevision: conn.hardwareRevision,
      manufacturerName: conn.manufacturerName,
      type: DeviceType.frame,
    );
  }

  // from BluetoothDevice
  Future fromBluetoothDevice(BluetoothDevice device) async {
    var rssi = await device.readRssi();
    return BtDevice(
      name: device.platformName,
      id: device.remoteId.str,
      type: DeviceType.memorion,
      rssi: rssi,
    );
  }

  // from ScanResult
  static fromScanResult(ScanResult result) {
    return fromAdvertisement(
      id: result.device.remoteId.str,
      name: result.device.platformName.isNotEmpty ? result.device.platformName : result.advertisementData.advName,
      serviceUuids: result.advertisementData.serviceUuids.map((uuid) => uuid.str128),
      rssi: result.rssi,
      manufacturerData: result.advertisementData.manufacturerData,
      advertisedName: result.advertisementData.advName,
    );
  }

  /// Service identity, not a brand-name substring: soundcore headphones must
  /// never be treated as D3200 recorders. D3200 may advertise no name at all.
  static DeviceType? typeFromServices(Iterable<String> serviceUuids) {
    final uuids = serviceUuids.map((uuid) => uuid.toLowerCase()).toSet();
    if (uuids.contains(soundcoreServiceUuid)) return DeviceType.soundcore;
    if (uuids.contains(a1ServiceUuid)) return DeviceType.dingtalkA1;
    if (uuids.contains(memorionServiceUuid)) return DeviceType.memorion;
    if (uuids.contains(frameServiceUuid.toLowerCase())) return DeviceType.frame;
    return null;
  }

  static BtDevice fromAdvertisement({
    required String id,
    required String name,
    required Iterable<String> serviceUuids,
    required int rssi,
    Map<int, List<int>> manufacturerData = const {},
    String? advertisedName,
  }) {
    final plaud = PlaudAdvertisement.parse(advertisedName ?? name, manufacturerData);
    final serial = plaud?.supported == true
        ? plaud!.serial
        : plaud == null && cachedDevicesMap[id] == DeviceType.plaudNote
            ? _cachedPlaudSerials[id]
            : null;
    if (serial != null) _cachedPlaudSerials[id] = serial;
    DeviceType? deviceType = serial != null ? DeviceType.plaudNote : typeFromServices(serviceUuids);
    if (deviceType != null) {
      cachedDevicesMap[id] = deviceType;
    } else if (plaud == null && cachedDevicesMap.containsKey(id)) {
      deviceType = cachedDevicesMap[id];
    }
    return BtDevice(
      name: name.isNotEmpty
          ? name
          : (deviceType == DeviceType.soundcore
              ? 'soundcore Work'
              : deviceType == DeviceType.dingtalkA1
                  ? 'DingTalk A1'
                  : deviceType == DeviceType.plaudNote
                      ? 'PLAUD Note'
                      : 'Memorion'),
      id: id,
      type: deviceType ?? DeviceType.memorion,
      plaudSerial: serial,
      rssi: rssi,
    );
  }

  // from json
  static fromJson(Map<String, dynamic> json) {
    return BtDevice(
      name: json['name'],
      id: json['id'],
      type: DeviceType.values[json['type']],
      rssi: json['rssi'],
      plaudSerial: json['plaudSerial'] as String?,
      modelNumber: json['modelNumber'],
      firmwareRevision: json['firmwareRevision'],
      hardwareRevision: json['hardwareRevision'],
      manufacturerName: json['manufacturerName'],
    );
  }

  // to json
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'id': id,
      'type': type.index,
      'rssi': rssi,
      if (plaudSerial != null) 'plaudSerial': plaudSerial,
      'modelNumber': modelNumber,
      'firmwareRevision': firmwareRevision,
      'hardwareRevision': hardwareRevision,
      'manufacturerName': manufacturerName,
    };
  }
}
