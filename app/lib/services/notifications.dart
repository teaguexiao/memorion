// Re-export the main notification service for backward compatibility
// All notification functionality is now handled by the platform-aware service

import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/material.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/backend/schema/insight.dart';
import 'package:memorion/main.dart';
import 'package:memorion/pages/today_chapters/ask_page.dart';
import 'package:memorion/pages/today_chapters/diary_detail_page.dart';
import 'package:memorion/pages/today_chapters/first_impression_page.dart';
import 'package:memorion/pages/today_chapters/portrait_detail_page.dart';
import 'package:memorion/pages/today_chapters/promises_page.dart';
import 'package:memorion/providers/moments_provider.dart';
import 'package:memorion/providers/insights_provider.dart';
import 'package:memorion/services/notifications/notification_deep_link.dart';
import 'package:memorion/services/notifications/notification_service.dart';
import 'package:provider/provider.dart';

export 'package:memorion/services/notifications/notification_service.dart';

class NotificationUtil {
  static ReceivePort? receivePort;
  static StreamSubscription<Map<String, dynamic>>? _remoteTapSubscription;

  /// 订阅**远程**推送（每日一刻、新发现等）的点击事件。
  ///
  /// 必须和 [initializeNotificationsEventListeners] 一起调用：那个只覆盖
  /// `awesome_notifications` 建的**本地**通知，后端 FCM 推来的那条走系统托盘，
  /// 点击后只有 `FirebaseMessaging.onMessageOpenedApp` /
  /// `getInitialMessage()` 知道（见 notification_service_fcm.dart）。
  static void initializeRemoteNotificationTapListener() {
    _remoteTapSubscription?.cancel();
    _remoteTapSubscription = NotificationService.instance.notificationTapStream.listen(
      handleRemoteNotificationTap,
      onError: (e) => debugPrint('Notification tap stream error: $e'),
    );
  }

  /// 远程推送被点击：payload 就是 FCM 的 `data`，与本地通知同一套路由规则。
  static Future<void> handleRemoteNotificationTap(Map<String, dynamic> payload) =>
      _handleAppLinkOrDeepLink(payload);

  static Future<void> initializeNotificationsEventListeners() async {
    // Only after at least the action method is set, the notification events are delivered
    AwesomeNotifications().setListeners(onActionReceivedMethod: NotificationUtil.onActionReceivedMethod);
  }

  static Future<void> initializeIsolateReceivePort() async {
    receivePort = ReceivePort('Notification action port in main isolate');
    receivePort!.listen((serializedData) {
      final receivedAction = ReceivedAction().fromMap(serializedData);
      onActionReceivedMethodImpl(receivedAction);
    });

    // This initialization only happens on main isolate
    IsolateNameServer.registerPortWithName(receivePort!.sendPort, 'notification_action_port');
  }

  /// Use this method to detect when the user taps on a notification or action button
  @pragma("vm:entry-point")
  static Future<void> onActionReceivedMethod(ReceivedAction receivedAction) async {
    if (receivePort != null) {
      await onActionReceivedMethodImpl(receivedAction);
    } else {
      print(
          'onActionReceivedMethod was called inside a parallel dart isolate, where receivePort was never initialized.');
      SendPort? sendPort = IsolateNameServer.lookupPortByName('notification_action_port');

      if (sendPort != null) {
        print('Redirecting the execution to main isolate process in listening...');
        dynamic serializedData = receivedAction.toMap();
        sendPort.send(serializedData);
      }
    }
  }

  static Future<void> onActionReceivedMethodImpl(ReceivedAction receivedAction) async {
    if (receivedAction.payload == null || receivedAction.payload!.isEmpty) {
      return;
    }
    _handleAppLinkOrDeepLink(receivedAction.payload!);
  }

  static Future<void> _handleAppLinkOrDeepLink(Map<String, dynamic> payload) async {
    WidgetsFlutterBinding.ensureInitialized();

    final link = NotificationDeepLink.fromPayload(payload);
    if (link.target == NotificationDeepLinkTarget.none) {
      debugPrint('Notification deep-link: no navigate_to, ignoring');
      return;
    }

    // Cold start: the notification can be delivered before the Navigator/Provider
    // tree is mounted (app was killed and launched by the tap). Wait for the
    // navigator to become available instead of silently dropping the deep-link.
    final navigator = await _waitForNavigator();
    if (navigator == null) {
      debugPrint('Notification deep-link: navigator never became ready, giving up');
      return;
    }

    switch (link.target) {
      case NotificationDeepLinkTarget.diaryDetail:
        await _openDiaryDetail(navigator, link.momentId!);
        break;
      case NotificationDeepLinkTarget.insightDetail:
        await _openInsightDetail(navigator, link.insightId!);
        break;
      case NotificationDeepLinkTarget.chat:
        // 回到 1.0 浅色主壳根，再打开「回响」页（AskPage）。旧深色 ChatPage 已废弃。
        navigator.popUntil((route) => route.isFirst);
        navigator.push(MaterialPageRoute(builder: (context) => const AskPage()));
        break;
      case NotificationDeepLinkTarget.promises:
        // 任务提醒点击：回到主壳根，打开「你答应过的事」列表。
        navigator.popUntil((route) => route.isFirst);
        navigator.push(MaterialPageRoute(builder: (context) => const PromisesPage()));
        break;
      case NotificationDeepLinkTarget.insights:
        // 「新发现」推送点击：回到主壳根，打开「它看到的你」洞察卡列表。
        navigator.popUntil((route) => route.isFirst);
        navigator.push(MaterialPageRoute(builder: (context) => const PortraitDetailPage()));
        break;
      case NotificationDeepLinkTarget.homeShell:
        // Return to the light 1.0 home shell (the app's root). No-op if already there.
        navigator.popUntil((route) => route.isFirst);
        break;
      case NotificationDeepLinkTarget.none:
        break;
    }
  }

  /// Deep-link to a specific day's diary detail page.
  ///
  /// Anchors at the light home shell (root) first so the detail page always sits
  /// on top of the 1.0 light shell, never a leftover legacy dark page. Then
  /// resolves the [ServerMessage] by id via [MomentsProvider] and pushes
  /// [DiaryDetailPage]. If the moment can't be resolved (missing/deleted), we
  /// stay on the home shell — a safe fallback, never a crash.
  static Future<void> _openDiaryDetail(NavigatorState navigator, String momentId) async {
    navigator.popUntil((route) => route.isFirst);

    final context = MyApp.navigatorKey.currentContext;
    if (context == null) return;

    ServerMessage? moment;
    try {
      moment = await context.read<MomentsProvider>().getMomentById(momentId);
    } catch (e) {
      debugPrint('Notification deep-link: failed to resolve moment $momentId: $e');
    }
    if (!navigator.mounted) return;
    if (moment == null) {
      debugPrint('Notification deep-link: moment $momentId not found, staying on home shell');
      return;
    }

    // gradientIndex only drives the detail card's gradient palette (cosmetic); a
    // deep-linked single moment has no list index, so a stable 0 is fine.
    navigator.push(MaterialPageRoute(builder: (_) => DiaryDetailPage(moment: moment!, gradientIndex: 0)));
  }

  static Future<void> _openInsightDetail(NavigatorState navigator, String insightId) async {
    navigator.popUntil((route) => route.isFirst);
    final context = MyApp.navigatorKey.currentContext;
    if (context == null) return;

    InsightCard? card;
    try {
      card = await context.read<InsightsProvider>().getInsightById(insightId);
    } catch (e) {
      debugPrint('Notification deep-link: failed to resolve insight $insightId: $e');
    }
    if (!navigator.mounted) return;
    // 已删除、未发布或读取失败时仍可进入洞察列表。
    navigator.push(MaterialPageRoute(
      builder: (_) => card == null ? const PortraitDetailPage() : FirstImpressionPage(card: card!),
    ));
  }

  /// Polls [MyApp.navigatorKey] until its state is mounted, up to ~5s.
  ///
  /// Covers the cold-start race where a tapped notification is processed on the
  /// main isolate before `MaterialApp` has attached the navigator.
  static Future<NavigatorState?> _waitForNavigator() async {
    const maxAttempts = 50;
    const interval = Duration(milliseconds: 100);
    for (var i = 0; i < maxAttempts; i++) {
      final navigator = MyApp.navigatorKey.currentState;
      if (navigator != null) return navigator;
      await Future.delayed(interval);
    }
    return MyApp.navigatorKey.currentState;
  }
}
