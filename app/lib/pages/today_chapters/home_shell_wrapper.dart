import 'package:flutter/material.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/pages/today_chapters/today_chapters_page.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/providers/discover_provider.dart';
import 'package:memorion/providers/home_provider.dart';
import 'package:memorion/providers/home_updates_provider.dart';
import 'package:memorion/providers/mood_pixel_provider.dart';
import 'package:memorion/providers/mood_quote_provider.dart';
import 'package:memorion/services/notifications.dart';
import 'package:memorion/utils/analytics/analytics_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

/// 1.0 浅色正式壳容器：承接旧 `MainHomePageWrapper` 的全部启动初始化
/// （设备连接 / 语言时区 / 会话·discover·mood 等），但 UI 用新版 [TodayChaptersPage]。
///
/// 说明：设备/录音/数据初始化原本都放在旧深色壳的 `initState`，切壳时必须一并搬来，
/// 否则新壳缺少这些副作用（详见 iOS 1.0 切壳记忆）。语言设置走
/// `setupUserPrimaryLanguageSilently()`，**不再弹旧深色语言 Dialog**——onboarding
/// 个性化步已负责收集语言。
class HomeShellWrapper extends StatefulWidget {
  const HomeShellWrapper({super.key});

  @override
  State<HomeShellWrapper> createState() => _HomeShellWrapperState();
}

class _HomeShellWrapperState extends State<HomeShellWrapper> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (SharedPreferencesUtil().notificationsEnabled != await Permission.notification.isGranted) {
        SharedPreferencesUtil().notificationsEnabled = await Permission.notification.isGranted;
        AnalyticsManager().setUserAttribute(
          'Notifications Enabled', // i18n-ignore analytics attribute key
          SharedPreferencesUtil().notificationsEnabled,
        );
      }
      if (SharedPreferencesUtil().notificationsEnabled) {
        NotificationService.instance.register();
        NotificationService.instance.saveNotificationToken();
      }
      if (mounted) {
        context.read<DeviceProvider>().periodicConnect('coming from HomeShellWrapper'); // i18n-ignore debug tag
      }
      if (mounted) {
        final homeProvider = context.read<HomeProvider>();
        await homeProvider.setupUserPrimaryLanguageSilently();
        await homeProvider.setupUserTimezone();
      }
      if (mounted) {
        await Future.wait([
          context.read<ConversationProvider>().getInitialConversations(),
          context.read<DiscoverProvider>().loadAll(),
          context.read<HomeUpdatesProvider>().loadUpdates(),
          context.read<MoodPixelProvider>().loadState(),
          context.read<MoodQuoteProvider>().loadDailyQuote(),
          context.read<CaptureProvider>().initPersistedPhotos(),
        ]);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return const TodayChaptersPage();
  }
}
