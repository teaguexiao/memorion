import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:crypto/crypto.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/services/notifications/fcm_token_registration.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:memorion/backend/http/api/notifications.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/services/notifications/notification_deep_link.dart';
import 'package:memorion/services/notifications/notification_interface.dart';
import 'package:memorion/utils/localization_helper.dart';
import 'package:memorion/backend/preferences.dart';

/// Firebase Cloud Messaging enabled notification service
/// Supports iOS, Android, macOS, web, and Linux with full FCM functionality
class _FCMNotificationService implements NotificationInterface {
  _FCMNotificationService._();

  MethodChannel platform = const MethodChannel('me.memorion.api/notifyOnKill');
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  late final FcmTokenRegistration _tokenRegistration = FcmTokenRegistration(
    currentAccount: () {
      final user = FirebaseAuth.instance.currentUser;
      return user != null && !user.isAnonymous && getExternalUserId() == user.uid && getAuthHeader().isNotEmpty
          ? user.uid
          : null;
    },
    isReady: () async => !Platform.isIOS || await _firebaseMessaging.getAPNSToken() != null,
    getToken: _firebaseMessaging.getToken,
    uploadToken: (token, account) => saveFcmToken(token, expectedAccount: account),
    tokenRefresh: _firebaseMessaging.onTokenRefresh,
    log: debugPrint,
  );

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
    _tokenRegistration.start();
    listenForMessages();
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
      register();
    }
    return isAllowed;
  }

  @override
  Future<void> register() async {
    try {
      await platform.invokeMethod(
        'setNotificationOnKillService',
        {
          'title': appT((s) => s.deviceNotificationDisconnectedTitle, 'Your Memorion Device Disconnected'),
          'description': appT(
            (s) => s.deviceNotificationDisconnectedBody,
            'Please reconnect to continue using your Memorion.',
          ),
        },
      );
    } catch (e) {
      debugPrint('NotifOnKill error: $e');
    }
  }

  @override
  Future<String> getTimeZone() async {
    final String currentTimeZone = await FlutterTimezone.getLocalTimezone();
    return currentTimeZone;
  }

  @override
  Future<void> saveFcmToken(String? token, {String? expectedAccount}) async {
    if (token == null || token.isEmpty) return;
    String timeZone;
    if (SharedPreferencesUtil().hasSetTimezone && SharedPreferencesUtil().userTimezone.isNotEmpty) {
      timeZone = SharedPreferencesUtil().userTimezone;
      debugPrint('[FCM] Using manually set timezone: $timeZone');
    } else {
      timeZone = await getTimeZone();
      debugPrint('[FCM] Using device timezone: $timeZone');
    }
    final account = expectedAccount ?? FirebaseAuth.instance.currentUser?.uid;
    if (account == null || FirebaseAuth.instance.currentUser?.uid != account || getExternalUserId() != account) return;
    await saveFcmTokenServer(token: token, timeZone: timeZone);
    // A fingerprint lets device/server diagnostics match registrations without logging tokens.
    debugPrint('[FCM] uploaded token fingerprint=${sha256.convert(utf8.encode(token)).toString().substring(0, 12)}');
  }

  @override
  Future<void> saveNotificationToken() async {
    await _tokenRegistration.register();
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

  // FIXME: Causes the different behavior on android and iOS
  bool _shouldShowForegroundNotificationOnFCMMessageReceived() {
    return Platform.isAndroid;
  }

  @override
  Future<void> listenForMessages() async {
    // 后台点击：App 在后台时推送由系统托盘展示，点击后 Flutter 侧只能从这里知道。
    // 没有这个监听，点推送等于普通冷/热启动 → 永远停在首页。
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _emitNotificationTap(message);
    });

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final data = message.data;
      final noti = message.notification;

      // Plugin
      if (data.isNotEmpty) {
        // 整份透传（含 moment_id），不是只挑 navigate_to——理由见该函数注释。
        final payload = notificationPayloadFromRemoteData(data);

        // plugin, daily summary
        final notificationType = data['notification_type'];
        if (notificationType == 'plugin' || notificationType == 'daily_summary') {
          data['from_integration'] = data['from_integration'] == 'true';
          _serverMessageStreamController.add(ServerMessage.fromJson(data));
        }
        if (noti != null && _shouldShowForegroundNotificationOnFCMMessageReceived()) {
          _showForegroundNotification(noti: noti, payload: payload);
        }
        return;
      }

      // Announcement likes
      if (noti != null && _shouldShowForegroundNotificationOnFCMMessageReceived()) {
        _showForegroundNotification(noti: noti, layout: NotificationLayout.BigText);
        return;
      }
    });
  }

  final _serverMessageStreamController = StreamController<ServerMessage>.broadcast();

  @override
  Stream<ServerMessage> get listenForServerMessages => _serverMessageStreamController.stream;

  /// `onListen` 里才去查 `getInitialMessage()`：冷启动那一次点击发生在 `runApp` 之前，
  /// 若在 `initialize()` 里就取，事件会 add 进一个还没有订阅者的 broadcast stream 里被
  /// 丢掉（症状与完全没接线一模一样——点推送进首页）。
  late final StreamController<Map<String, dynamic>> _notificationTapController =
      StreamController<Map<String, dynamic>>.broadcast(onListen: _emitInitialNotificationTap);

  @override
  Stream<Map<String, dynamic>> get notificationTapStream => _notificationTapController.stream;

  Future<void> _emitInitialNotificationTap() async {
    try {
      final initial = await _firebaseMessaging.getInitialMessage();
      if (initial != null) _emitNotificationTap(initial);
    } catch (e) {
      debugPrint('getInitialMessage error: $e');
    }
  }

  void _emitNotificationTap(RemoteMessage message) {
    if (message.data.isEmpty || _notificationTapController.isClosed) return;
    debugPrint('Notification tapped (remote): ${message.data}');
    _notificationTapController.add(Map<String, dynamic>.from(message.data));
  }

  Future<void> _showForegroundNotification(
      {required RemoteNotification noti,
      NotificationLayout layout = NotificationLayout.Default,
      Map<String, String?>? payload}) async {
    final id = Random().nextInt(10000);
    showNotification(id: id, title: noti.title!, body: noti.body!, layout: layout, payload: payload);
  }
}

/// Factory function to create the FCM notification service
NotificationInterface createNotificationService() => _FCMNotificationService._();
