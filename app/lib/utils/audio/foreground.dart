import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:memorion/utils/localization_helper.dart';
import 'package:memorion/utils/platform/platform_service.dart';

@pragma('vm:entry-point')
void _startForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_ForegroundFirstTaskHandler());
}

class _ForegroundFirstTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter taskStarter) async {
    debugPrint("Starting foreground task");
  }

  @override
  void onReceiveData(Object data) async {
    debugPrint('onReceiveData: $data');
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    debugPrint("Foreground repeat event triggered");
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // The plugin is already in its own teardown path here. Calling stopService()
    // again can recurse back through a channel that's being destroyed.
    debugPrint("Destroying foreground task");
  }
}

class ForegroundUtil {
  static bool _isInitialized = false;
  static bool _isStarting = false;

  static Future<void> requestPermissions() async {
    // Android 13+, you need to allow notification permission to display foreground service notification.
    //
    // iOS: If you need notification, ask for permission.
    final NotificationPermission notificationPermissionStatus =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermissionStatus != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (Platform.isAndroid) {
      // if (!await FlutterForegroundTask.canDrawOverlays) {
      //   await FlutterForegroundTask.openSystemAlertWindowSettings();
      // }
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }

  Future<bool> get isIgnoringBatteryOptimizations async => await FlutterForegroundTask.isIgnoringBatteryOptimizations;

  static Future<void> initializeForegroundService() async {
    if (PlatformService.isIosSimulator) {
      // iOS simulator's foreground task plugin restarts itself, producing
      // repeated "Destroying foreground task" logs. No-op on simulator.
      _isInitialized = true;
      return;
    }
    if (_isInitialized) {
      debugPrint('ForegroundService already initialized, skipping');
      return;
    }

    if (await FlutterForegroundTask.isRunningService) {
      _isInitialized = true;
      return;
    }

    debugPrint('initializeForegroundService');

    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'foreground_service',
          channelName: appT((s) => s.fgServiceChannelName, 'Foreground Service Notification'),
          channelDescription: appT(
            (s) => s.fgServiceChannelDesc,
            'Transcription service is running in the background.',
          ),
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.HIGH,
          // iconData: const NotificationIconData(
          //   resType: ResourceType.mipmap,
          //   resPrefix: ResourcePrefix.ic,
          //   name: 'launcher',
          // ),
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      _isInitialized = true;
      debugPrint('ForegroundService initialized successfully');
    } catch (e) {
      debugPrint('ForegroundService initialization failed: $e');
      _isInitialized = false;
    }
  }

  static Future<ServiceRequestResult> startForegroundTask() async {
    if (PlatformService.isIosSimulator) {
      return const ServiceRequestSuccess();
    }
    if (_isStarting) {
      debugPrint('ForegroundTask already starting, skipping');
      return const ServiceRequestSuccess();
    }

    _isStarting = true;
    debugPrint('startForegroundTask');

    try {
      ServiceRequestResult result;
      if (await FlutterForegroundTask.isRunningService) {
        result = await FlutterForegroundTask.restartService();
      } else {
        result = await FlutterForegroundTask.startService(
          notificationTitle: appT((s) => s.fgServiceConnectedTitle, 'Your Memorion Device is connected.'),
          notificationText: appT(
            (s) => s.fgServiceConnectedBody,
            'Transcription service is running in the background.',
          ),
          callback: _startForegroundCallback,
        );
      }
      debugPrint('ForegroundTask started successfully');
      return result;
    } catch (e) {
      debugPrint('ForegroundTask start failed: $e');
      return ServiceRequestFailure(error: e.toString());
    } finally {
      _isStarting = false;
    }
  }

  static Future<void> stopForegroundTask() async {
    debugPrint('stopForegroundTask');

    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        _isInitialized = false;
      }
    } catch (e) {
      debugPrint('ForegroundTask stop failed: $e');
    }
  }
}
