import 'dart:async';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:memorion/backend/schema/message.dart';

/// Common interface for notification services across all platforms
abstract class NotificationInterface {
  Future<void> initialize();

  void showNotification({
    required int id,
    required String title,
    required String body,
    Map<String, String?>? payload,
    bool wakeUpScreen = false,
    NotificationSchedule? schedule,
    NotificationLayout layout = NotificationLayout.Default,
  });

  Future<bool> requestNotificationPermissions();
  Future<void> register();
  Future<String> getTimeZone();
  Future<void> saveFcmToken(String? token);
  Future<void> saveNotificationToken();
  Future<bool> hasNotificationPermissions();

  Future<void> createNotification({
    String title = '',
    String body = '',
    int notificationId = 1,
    Map<String, String?>? payload,
  });

  void clearNotification(int id);
  Future<void> listenForMessages();

  Stream<ServerMessage> get listenForServerMessages;

  /// 用户点击**远程**推送（系统托盘那条）时发出的 `data` payload。
  ///
  /// 后台/冷启动状态下的推送由系统直接展示，`awesome_notifications` 的
  /// `onActionReceivedMethod` 收不到——它只认 App 自己 `showNotification()` 建的本地
  /// 通知。少了这条流，点推送就只是把 App 拉起来，deep-link 永远不执行。
  Stream<Map<String, dynamic>> get notificationTapStream;
}
