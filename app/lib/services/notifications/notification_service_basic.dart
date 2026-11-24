import 'dart:async';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/services/notifications/notification_interface.dart';

/// Basic notification service for platforms without Firebase Messaging support
/// Currently used for Windows - provides local notifications only
class _BasicNotificationService implements NotificationInterface {
  _BasicNotificationService._();

  // Notification cooldown configuration (in milliseconds)
  static const int _defaultCooldownMs = 5 * 60 * 1000; // 5 minutes

  // Track last notification time for each notification ID
  final Map<int, DateTime> _lastNotificationTime = {};

  // Cooldown configuration per notification ID
  static const Map<int, int> _cooldownConfig = {
    1: 5 * 60 * 1000, // Device Disconnected: 5 minutes
    2: 5 * 60 * 1000, // Connection Issue: 5 minutes
    3: 5 * 60 * 1000, // Internet Connection Lost: 5 minutes
  };

  final channel = NotificationChannel(
    channelGroupKey: 'channel_group_key',
    channelKey: 'channel',
    channelName: 'Memorion Notifications',
    channelDescription: 'Notification channel for Memorion',
    defaultColor: const Color(0xFF9D50DD),
    ledColor: Colors.white,
  );

  final AwesomeNotifications _awesomeNotifications = AwesomeNotifications();

  @override
  Future<void> initialize() async {
    await _initializeAwesomeNotifications();
    debugPrint('Basic notification service initialized (Firebase Messaging not available on this platform)');
  }

  Future<void> _initializeAwesomeNotifications() async {
    bool initialized = await _awesomeNotifications.initialize(
        // set the icon to null if you want to use the default app icon
        'resource://drawable/icon',
        [
          NotificationChannel(
            channelGroupKey: 'channel_group_key',
            channelKey: channel.channelKey,
            channelName: channel.channelName,
            channelDescription: channel.channelDescription,
            defaultColor: const Color(0xFF9D50DD),
            ledColor: Colors.white,
          )
        ],
        // Channel groups are only visual and are not required
        channelGroups: [
          NotificationChannelGroup(
            channelGroupKey: channel.channelKey!,
            channelGroupName: channel.channelName!,
          )
        ],
        debug: false);

    debugPrint('initializeNotifications: $initialized');
  }

  @override
  void showNotification({
    required int id,
    required String title,
    required String body,
    Map<String, String?>? payload,
    bool wakeUpScreen = false,
    NotificationSchedule? schedule,
    NotificationLayout layout = NotificationLayout.Default,
  }) {
    _awesomeNotifications.createNotification(
      content: NotificationContent(
        id: id,
        channelKey: channel.channelKey!,
        actionType: ActionType.Default,
        title: title,
        body: body,
        payload: payload,
        notificationLayout: layout,
      ),
      schedule: schedule,
    );
  }

  @override
  Future<bool> requestNotificationPermissions() async {
    bool isAllowed = await _awesomeNotifications.isNotificationAllowed();
    if (!isAllowed) {
      isAllowed = await _awesomeNotifications.requestPermissionToSendNotifications();
    }
    return isAllowed;
  }

  @override
  Future<void> register() async {
    // Platform-specific notification registration not available on this platform
    debugPrint('Notification registration not available on this platform');
  }

  @override
  Future<String> getTimeZone() async {
    final String currentTimeZone = await FlutterTimezone.getLocalTimezone();
    return currentTimeZone;
  }

  @override
  Future<void> saveFcmToken(String? token) async {
    // Firebase Cloud Messaging not supported on this platform
    debugPrint('FCM token save skipped - Firebase Messaging not supported on this platform');
  }

  @override
  Future<void> saveNotificationToken() async {
    // Firebase Cloud Messaging not supported on this platform
    debugPrint('Notification token save skipped - Firebase Messaging not supported on this platform');
  }

  @override
  Future<bool> hasNotificationPermissions() async {
    return await _awesomeNotifications.isNotificationAllowed();
  }

  @override
  Future<void> createNotification({
    String title = '',
    String body = '',
    int notificationId = 1,
    Map<String, String?>? payload,
  }) async {
    var allowed = await _awesomeNotifications.isNotificationAllowed();
    debugPrint('createNotification: $allowed');
    if (!allowed) return;

    // Check cooldown period
    if (_isInCooldown(notificationId)) {
      debugPrint('createNotification ~ Skipped (in cooldown): $title');
      return;
    }

    debugPrint('createNotification ~ Creating notification: $title');
    _lastNotificationTime[notificationId] = DateTime.now();
    showNotification(id: notificationId, title: title, body: body, wakeUpScreen: true, payload: payload);
  }

  bool _isInCooldown(int notificationId) {
    final lastTime = _lastNotificationTime[notificationId];
    if (lastTime == null) return false;

    final cooldownMs = _cooldownConfig[notificationId] ?? _defaultCooldownMs;
    if (cooldownMs == 0) return false; // No cooldown

    final elapsed = DateTime.now().difference(lastTime).inMilliseconds;
    return elapsed < cooldownMs;
  }

  @override
  void clearNotification(int id) => _awesomeNotifications.cancel(id);

  @override
  Future<void> listenForMessages() async {
    // Firebase Cloud Messaging not supported on this platform
    // Local notifications still work, but no remote messaging
    debugPrint('Firebase message listening not available on this platform');
  }

  final _serverMessageStreamController = StreamController<ServerMessage>.broadcast();

  @override
  Stream<ServerMessage> get listenForServerMessages => _serverMessageStreamController.stream;

  @override
  Stream<Map<String, dynamic>> get notificationTapStream => const Stream<Map<String, dynamic>>.empty();
}

/// Factory function to create the basic notification service
NotificationInterface createNotificationService() => _BasicNotificationService._();
