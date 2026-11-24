import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 钉住「远程推送点击 → deep-link」这条链路的三个接线点。
///
/// 为什么是源码断言而不是行为测试：`FirebaseMessaging.onMessageOpenedApp` /
/// `getInitialMessage()` 是静态入口，纯单测里没法喂事件。而这个 bug 的形态恰恰是
/// **路由逻辑完全正确、但没有任何人调用它**——`NotificationDeepLink` 的单测全绿，
/// 用户点每日一刻推送却一直只进首页（2026-08-11 修复）。之前只有
/// `awesome_notifications` 的 `onActionReceivedMethod`，它只认 App 自己建的本地通知，
/// 后端 FCM 推来的那条走系统托盘，点击后 Flutter 侧根本收不到。
void main() {
  String src(String path) => File(path).readAsStringSync();

  test('FCM service listens for background notification taps', () {
    final s = src('lib/services/notifications/notification_service_fcm.dart');
    expect(s.contains('FirebaseMessaging.onMessageOpenedApp.listen'), isTrue,
        reason: '后台点击推送只能从 onMessageOpenedApp 得知；缺了它点推送等于普通启动');
  });

  test('FCM service recovers the cold-start tap via getInitialMessage', () {
    final s = src('lib/services/notifications/notification_service_fcm.dart');
    expect(s.contains('getInitialMessage()'), isTrue,
        reason: 'App 被杀死时点推送，那次点击不会走 onMessageOpenedApp');
    // onListen 里取，否则事件 add 进无订阅者的 broadcast stream 会被丢掉。
    expect(s.contains('onListen: _emitInitialNotificationTap'), isTrue,
        reason: 'initial message 必须等到 tap stream 被订阅后才取，否则事件静默丢失');
  });

  test('app subscribes the tap stream at startup', () {
    expect(src('lib/main.dart').contains('NotificationUtil.initializeRemoteNotificationTapListener()'), isTrue,
        reason: 'tap stream 没人订阅 = deep-link 不执行，且 getInitialMessage 也不会被触发');
    expect(src('lib/services/notifications.dart').contains('notificationTapStream.listen'), isTrue,
        reason: '订阅必须真正接到 NotificationDeepLink 路由上');
  });
}
