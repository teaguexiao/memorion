import 'dart:io';
import 'package:version/version.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:memorion/utils/localization_helper.dart';

class DeviceUtils {
  static Future<(String, bool, String)> shouldUpdateFirmware({
    required String currentFirmware,
    required Map latestFirmwareDetails,
  }) async {
    Version currentVersion = Version.parse(currentFirmware);
    if (latestFirmwareDetails.isEmpty) {
      return (appT((s) => s.fwLatestNotAvailable, 'Latest Version Not Available'), false, '');
    }
    if (latestFirmwareDetails.isEmpty || latestFirmwareDetails['version'] == null) {
      return (appT((s) => s.fwLatestNotAvailable, 'Latest Version Not Available'), false, '');
    }
    if (latestFirmwareDetails['version'] == null || latestFirmwareDetails['draft']) {
      return (appT((s) => s.fwLatestNotAvailable, 'Latest Version Not Available'), false, '');
    }

    String latestVersionStr = latestFirmwareDetails['version'];
    Version latestVersion = Version.parse(latestVersionStr);
    Version minVersion = Version.parse(latestFirmwareDetails['min_version']);

    if (currentVersion < minVersion) {
      return ('0', false, latestVersionStr);
    } else {
      if (latestVersion > currentVersion) {
        PackageInfo packageInfo = await PackageInfo.fromPlatform();
        if (Version.parse(packageInfo.version) <= Version.parse(latestFirmwareDetails['min_app_version']) &&
            int.parse(packageInfo.buildNumber) < int.parse(latestFirmwareDetails['min_app_version_code'])) {
          final store = Platform.isAndroid
              ? appT((s) => s.fwStorePlay, 'Play Store')
              : appT((s) => s.fwStoreApp, 'App Store');
          return (
            appT(
              (s) => s.fwIncompatibleApp(packageInfo.version, packageInfo.buildNumber, store),
              'The latest version of firmware is not compatible with this version of App (${packageInfo.version}+${packageInfo.buildNumber}). Please update the app from $store',
            ),
            false,
            latestVersionStr
          );
        } else {
          return (
            appT((s) => s.fwNewVersionAvailable, 'A new version is available! Update your Memorion now.'),
            true,
            latestVersionStr
          );
        }
      } else {
        return (
          appT((s) => s.fwAlreadyLatest, 'You are already on the latest version'),
          false,
          latestVersionStr
        );
      }
    }
  }
}
