import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS Live Activity is fully removed', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    final project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final captureProvider = File('lib/providers/capture_provider.dart').readAsStringSync();
    final deviceProvider = File('lib/providers/device_provider.dart').readAsStringSync();
    final extensionDirectory = Directory('ios/MemorionLiveActivity');

    expect(extensionDirectory.existsSync() ? extensionDirectory.listSync(recursive: true) : const [], isEmpty);
    expect(File('ios/Runner/LiveActivityService.swift').existsSync(), isFalse);
    expect(File('lib/services/live_activity_service.dart').existsSync(), isFalse);

    expect(infoPlist, isNot(contains('NSSupportsLiveActivities')));
    expect(infoPlist, isNot(contains('<string>memorion</string>')));
    expect(project, isNot(contains('MemorionLiveActivity')));
    expect(project, isNot(contains('LiveActivityService.swift')));
    expect(appDelegate, isNot(contains('com.memorion.ios/live_activity')));
    expect(captureProvider, isNot(contains('syncLiveActivity')));
    expect(deviceProvider, isNot(contains('LiveActivityService')));
  });
}
