import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:nordic_dfu/nordic_dfu.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/http/api/device.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/utils/device.dart';
import 'package:memorion/utils/manifest/manifest.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:mcumgr_flutter/mcumgr_flutter.dart' as mcumgr;
import 'package:flutter_archive/flutter_archive.dart';

mixin FirmwareMixin<T extends StatefulWidget> on State<T> {
  Map latestFirmwareDetails = {};
  bool isDownloading = false;
  bool isDownloaded = false;
  int downloadProgress = 1;
  bool isInstalling = false;
  bool isInstalled = false;
  int installProgress = 1;
  bool isLegacySecureDFU = true;
  List<String> otaUpdateSteps = [];
  final mcumgr.FirmwareUpdateManagerFactory? managerFactory = mcumgr.FirmwareUpdateManagerFactory();
  List<String> dfuLogs = [];

  void addDfuLog(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 23);
    debugPrint('[DFU] $message');
    setState(() {
      dfuLogs.add('[$timestamp] $message');
    });
  }

  /// Process ZIP file and return firmware image list
  Future<List<mcumgr.Image>> processZipFile(Uint8List zipFileData) async {
    // Create temporary directory
    final prefix = 'firmware_${Uuid().v4()}';
    final systemTempDir = await getTemporaryDirectory();
    final tempDir = Directory('${systemTempDir.path}/$prefix');
    await tempDir.create();

    try {
      // Write ZIP data to temporary file
      final firmwareFile = File('${tempDir.path}/firmware.zip');
      await firmwareFile.writeAsBytes(zipFileData);

      // Create destination directory for extraction
      final destinationDir = Directory('${tempDir.path}/firmware');
      await destinationDir.create();

      // Extract ZIP file
      await ZipFile.extractToDirectory(
        zipFile: firmwareFile,
        destinationDir: destinationDir,
      );

      // Read and parse manifest.json
      final manifestFile = File('${destinationDir.path}/manifest.json');
      final manifestString = await manifestFile.readAsString();
      final manifestJson = json.decode(manifestString);
      final manifest = Manifest.fromJson(manifestJson);

      // Process firmware files
      final List<mcumgr.Image> firmwareImages = [];
      for (final file in manifest.files) {
        final firmwareFile = File('${destinationDir.path}/${file.file}');
        final firmwareFileData = await firmwareFile.readAsBytes();
        final image = mcumgr.Image(
          image: file.image,
          data: firmwareFileData,
        );
        firmwareImages.add(image);
      }

      return firmwareImages;
    } catch (e) {
      throw Exception('Failed to process ZIP file: $e');
    } finally {
      // Cleanup: Delete temporary directory
      await tempDir.delete(recursive: true);
    }
  }

  Future<void> startDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    addDfuLog('DFU mode: ${isLegacySecureDFU ? "Legacy Nordic DFU" : "MCU Manager"}');
    addDfuLog('Device: ${btDevice.id} (${btDevice.name})');
    if (isLegacySecureDFU) {
      return startLegacyDfu(btDevice, fileInAssets: fileInAssets);
    }
    return startMCUDfu(btDevice, fileInAssets: fileInAssets, zipFilePath: zipFilePath);
  }

  Future<void> startMCUDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    setState(() {
      isInstalling = true;
    });
    try {
      addDfuLog('Preparing DFU (MCU Manager)...');
      await Provider.of<DeviceProvider>(context, listen: false).prepareDFU();
      await Future.delayed(const Duration(seconds: 2));

      String firmwareFile = zipFilePath ?? '${(await getApplicationDocumentsDirectory()).path}/firmware.zip';
      final bytes = await File(firmwareFile).readAsBytes();
      addDfuLog('Firmware file: ${bytes.length} bytes');
      const configuration = mcumgr.FirmwareUpgradeConfiguration(
        estimatedSwapTime: Duration(seconds: 0),
        eraseAppSettings: true,
        pipelineDepth: 1,
      );
      final updateManager = await managerFactory!.getUpdateManager(btDevice.id);
      addDfuLog('Processing ZIP...');
      final images = await processZipFile(bytes);
      addDfuLog('Images: ${images.length}');

      final updateStream = updateManager.setup();

      updateStream.listen((state) {
        addDfuLog('MCU state: $state');
        if (state == mcumgr.FirmwareUpgradeState.success) {
          setState(() {
            isInstalling = false;
            isInstalled = true;
          });
        }
      });

      updateManager.progressStream.listen((progress) {
        setState(() {
          installProgress = (progress.bytesSent / progress.imageSize * 100).round();
        });
      });

      updateManager.logger.logMessageStream
          .where((log) => log.level.rawValue > 1)
          .listen((log) {
        addDfuLog('MCU log: ${log.message}');
      });

      addDfuLog('Starting MCU update...');
      await updateManager.update(
        images,
        configuration: configuration,
      );
    } catch (e) {
      addDfuLog('MCU DFU ERROR: $e');
      setState(() {
        isInstalling = false;
      });
    }
  }

  Future<void> startLegacyDfu(BtDevice btDevice, {bool fileInAssets = false}) async {
    setState(() {
      isInstalling = true;
    });
    try {
      addDfuLog('Preparing DFU (Legacy Nordic)...');
      await Provider.of<DeviceProvider>(context, listen: false).prepareDFU();
      addDfuLog('BLE disconnected, waiting 2s...');
      await Future.delayed(const Duration(seconds: 2));
      String firmwareFile = '${(await getApplicationDocumentsDirectory()).path}/firmware.zip';
      final fileSize = await File(firmwareFile).length();
      addDfuLog('Firmware file: $fileSize bytes');
      addDfuLog('Starting Nordic DFU to ${btDevice.id}...');
      NordicDfu dfu = NordicDfu();
      await dfu.startDfu(
        btDevice.id,
        firmwareFile,
        fileInAsset: fileInAssets,
        numberOfPackets: 8,
        enableUnsafeExperimentalButtonlessServiceInSecureDfu: true,
        iosSpecialParameter: const IosSpecialParameter(
          packetReceiptNotificationParameter: 8,
          forceScanningForNewAddressInLegacyDfu: true,
          connectionTimeout: 60,
        ),
        androidSpecialParameter: const AndroidSpecialParameter(
          packetReceiptNotificationsEnabled: true,
          rebootTime: 1000,
        ),
        onProgressChanged: (deviceAddress, percent, speed, avgSpeed, currentPart, partsTotal) {
          setState(() {
            installProgress = percent.toInt();
          });
          if (percent.toInt() % 10 == 0) {
            addDfuLog('Progress: ${percent.toInt()}% (part $currentPart/$partsTotal, ${speed.toStringAsFixed(1)} KB/s)');
          }
        },
        onError: (deviceAddress, error, errorType, message) {
          addDfuLog('ERROR: $error, type: $errorType, msg: $message');
        },
        onDeviceConnecting: (deviceAddress) => addDfuLog('Connecting to $deviceAddress...'),
        onDeviceConnected: (deviceAddress) => addDfuLog('Connected to $deviceAddress'),
        onDfuProcessStarting: (deviceAddress) => addDfuLog('DFU process starting...'),
        onDfuProcessStarted: (deviceAddress) => addDfuLog('DFU process started'),
        onEnablingDfuMode: (deviceAddress) => addDfuLog('Enabling DFU mode...'),
        onFirmwareValidating: (deviceAddress) => addDfuLog('Validating firmware...'),
        onDfuCompleted: (deviceAddress) {
          addDfuLog('DFU completed successfully!');
          setState(() {
            isInstalling = false;
            isInstalled = true;
          });
        },
      );
    } catch (e) {
      addDfuLog('DFU EXCEPTION: $e');
      setState(() {
        isInstalling = false;
      });
    }
  }

  Future getLatestVersion(
      {required String deviceModelNumber,
      required String firmwareRevision,
      required String hardwareRevision,
      required String manufacturerName}) async {
    addDfuLog('Device: $deviceModelNumber, FW: $firmwareRevision, HW: $hardwareRevision');
    latestFirmwareDetails = await getLatestFirmwareVersion(
      deviceModelNumber: deviceModelNumber,
      firmwareRevision: firmwareRevision,
      hardwareRevision: hardwareRevision,
      manufacturerName: manufacturerName,
    );
    if (latestFirmwareDetails.isEmpty) {
      addDfuLog('Server returned no firmware info');
    } else {
      addDfuLog('Server: version=${latestFirmwareDetails['version']}, legacy_dfu=${latestFirmwareDetails['is_legacy_secure_dfu']}');
    }
    if (latestFirmwareDetails['ota_update_steps'] != null) {
      otaUpdateSteps = List<String>.from(latestFirmwareDetails['ota_update_steps']);
    }
    if (latestFirmwareDetails['is_legacy_secure_dfu'] != null) {
      isLegacySecureDFU = latestFirmwareDetails['is_legacy_secure_dfu'];
    }
  }

  Future<(String, bool, String)> shouldUpdateFirmware({required String currentFirmware}) async {
    return DeviceUtils.shouldUpdateFirmware(
        currentFirmware: currentFirmware, latestFirmwareDetails: latestFirmwareDetails);
  }

  Future downloadFirmware() async {
    final zipUrl = latestFirmwareDetails['zip_url'];
    if (zipUrl == null) {
      addDfuLog('ERROR: zip_url is null');
      return;
    }

    addDfuLog('Downloading from: $zipUrl');
    setState(() {
      isDownloading = true;
      isDownloaded = false;
    });

    try {
      var httpClient = http.Client();
      var request = http.Request('GET', Uri.parse(zipUrl));
      var r = await httpClient.send(request);
      addDfuLog('HTTP ${r.statusCode}, content-length: ${r.contentLength}');
      String dir = (await getApplicationDocumentsDirectory()).path;

      final totalBytes = r.contentLength ?? 0;
      List<List<int>> chunks = [];
      int downloaded = 0;

      await for (final chunk in r.stream) {
        chunks.add(chunk);
        downloaded += chunk.length;
        if (totalBytes > 0) {
          setState(() {
            downloadProgress = (downloaded / totalBytes * 100).toInt();
          });
        }
      }

      File file = File('$dir/firmware.zip');
      final Uint8List bytes = Uint8List(downloaded);
      int offset = 0;
      for (List<int> chunk in chunks) {
        bytes.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      await file.writeAsBytes(bytes);
      addDfuLog('Download complete: $downloaded bytes saved');

      setState(() {
        isDownloading = false;
        isDownloaded = true;
      });
    } catch (e) {
      addDfuLog('DOWNLOAD ERROR: $e');
      setState(() {
        isDownloading = false;
        isDownloaded = false;
      });
    }
  }
}
