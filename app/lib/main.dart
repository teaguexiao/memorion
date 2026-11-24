import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/providers/locale_provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/auth.dart' as backend_auth;
import 'package:memorion/backend/http/api/app_auth.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/env/dev_env.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/env/prod_env.dart';
import 'package:memorion/flavors.dart';
import 'package:memorion/pages/conversation_detail/conversation_detail_provider.dart';
import 'package:memorion/core/app_shell.dart';
import 'package:memorion/pages/today_chapters/today_chapters_page.dart';
import 'package:memorion/pages/today_chapters/live_capture_page.dart';
import 'package:memorion/providers/auth_provider.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/providers/chat_session_provider.dart';
import 'package:memorion/providers/connectivity_provider.dart';
import 'package:memorion/providers/discover_provider.dart';
import 'package:memorion/providers/home_updates_provider.dart';
import 'package:memorion/providers/mood_quote_provider.dart';
import 'package:memorion/providers/mood_pixel_provider.dart';
import 'package:memorion/providers/audio_input_device_provider.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/providers/insights_provider.dart';
import 'package:memorion/providers/memories_provider.dart';
import 'package:memorion/providers/moments_provider.dart';
import 'package:memorion/providers/people_provider.dart';
import 'package:memorion/providers/vocabulary_provider.dart';
import 'package:memorion/providers/home_provider.dart';
import 'package:memorion/providers/main_nav_provider.dart';
import 'package:memorion/providers/conversation_audio_provider.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/message_provider.dart';
import 'package:memorion/providers/pdp_provider.dart';
import 'package:memorion/providers/purchase_provider.dart';
import 'package:memorion/providers/onboarding_provider.dart';
import 'package:memorion/providers/recording_source_provider.dart';
import 'package:memorion/providers/speech_profile_provider.dart';
import 'package:memorion/providers/timeline_provider.dart';
import 'package:memorion/providers/usage_provider.dart';
import 'package:memorion/providers/user_provider.dart';
import 'package:memorion/services/press_to_talk_service.dart';
import 'package:memorion/widgets/ptt_overlay.dart';
import 'package:memorion/services/calendar_sync_service.dart';
import 'package:memorion/services/notifications.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/services/phone_recording_shortcut_service.dart';
import 'package:memorion/pages/today_chapters/widgets/open_conversation.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/services/watch_moment_service.dart';
import 'package:memorion/services/watch_recording_service.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/analytics/growthbook.dart';
import 'package:memorion/utils/logger.dart';
import 'package:memorion/utils/notification_prefs.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:memorion/utils/platform/platform_manager.dart'; // Provides PlatformManager used below.

Future<bool> _init() async {
  // Service manager
  ServiceManager.init();

  // Firebase initialization
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('Firebase initialization error: $e');
  }

  await PlatformManager.initializeServices();
  await NotificationService.instance.initialize();
  await SharedPreferencesUtil.init();

  // 撤销旧版本留在系统里的废弃通知和排期。
  unawaited(NotificationPrefs.clearRetiredLocalNotifications());

  // Initialize API config from Env if SharedPreferences is empty
  ApiConfig().initializeFromEnv();

  // If Firebase user already logged in, sync UID to ApiConfig
  try {
    final firebaseUser = FirebaseAuth.instance.currentUser;
    if (firebaseUser != null) {
      ApiConfig().setExternalUserIdFromFirebase(firebaseUser.uid);
    }
  } catch (e) {
    debugPrint('Firebase user sync error: $e');
  }

  // Offline A1 imports can start with the app-owned services, including cached
  // recordings. Their native decoder must be ready before the first sync tick.
  initOpus(await opus_flutter.load());

  // TODO: thinh, move to app start
  await ServiceManager.instance().start();

  // Check auth using Firebase Auth (not just ApiConfig)
  // User must be signed in via Firebase AND have API key configured
  final firebaseUser = FirebaseAuth.instance.currentUser;
  bool isAuth = firebaseUser != null && !firebaseUser.isAnonymous && ApiConfig().apiKey.isNotEmpty;
  if (isAuth) {
    // Ensure Firebase UID is synced to ApiConfig
    ApiConfig().setExternalUserIdFromFirebase(firebaseUser.uid);
    PlatformManager.instance.mixpanel.identify();

    // Warm up the Firebase ID token in the background. After the app has
    // been suspended for a long time, the first getIdTokenResult call has
    // to do TLS handshake + DNS + token endpoint round-trip and can stall
    // for several seconds. Warming it during splash helps later authenticated
    // calls use the cached token without blocking app launch.
    //
    // 预热完顺带补一次 bound key 换发：存量用户是「已登录」状态进来的，不会再走
    // 登录路径，只有这里能把他们从全体共用的内嵌 key 迁到本人专属 key。
    // 同样 fire-and-forget——换发没完成时 apiKey 退回内嵌 key，录音等功能照常。
    unawaited(backend_auth.getIdToken().then((_) => ensureBoundApiKey()).catchError((e) {
      debugPrint('[startup] token warm-up / key exchange failed: $e');
      return null;
    }));

    // 回读服务端通知偏好，覆盖用户确实设置过的字段。修的是「重装 App / 换机后本地回到
    // 默认值、云端还是上次设的值」—— 设置页显示开着、服务端其实不推。
    // fire-and-forget：失败就沿用本地值，不能挡住启动。
    unawaited(NotificationPrefs.hydrateFromServer());
  }
  await GrowthbookUtil.init();
  ble.FlutterBluePlus.setLogLevel(ble.LogLevel.info, color: true);
  return isAuth;
}

/// TEMP(P-01 验收): 让 App 冷启动直达新版「今日·章节时间线」(P-01)。
/// 用于设计还原度验收，验收通过并接入正式导航后应删除此开关。
/// 仅在 debug 构建生效（`kDebugMode`），release 构建永远走正常 AppShell，
/// 避免误入跳过认证/路由的演示页。
const bool kDebugShowTodayChapters = kDebugMode && false;

void main() async {
  // 2026-07：Instabug/PostHog SDK 已移除。全局崩溃仍在 runZonedGuarded 内捕获，
  // 未捕获错误交给 Flutter 默认处理器（debug 下打到控制台便于定位）。
  //
  // ⚠️ 绑定初始化（ensureInitialized）与 runApp 必须在同一个 zone 里，否则会触发
  // 「Zone mismatch」（The Flutter bindings were initialized in a different zone
  // than is now being used）。因此把 ensureInitialized 及全部初始化都放进
  // runZonedGuarded 回调内，与 runApp 共用同一 zone。
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // DEBUG-only：把所有 Flutter 框架错误以可 grep 的标签打到控制台，
      // 方便 UI 测试时用 `flutter run` 日志定位（否则错误会被 CrashReporting/Instabug 吞掉，
      // 只在屏幕上显示 ErrorWidget「出错了」而看不到 stack）。release 构建不受影响。
      if (kDebugMode) {
        final defaultOnError = FlutterError.onError;
        FlutterError.onError = (FlutterErrorDetails details) {
          // ignore: avoid_print
          print('[FLUTTER-ERROR] ${details.exceptionAsString()}\n${details.stack}');
          defaultOnError?.call(details);
        };
      }

      if (F.env == Environment.prod) {
        Env.init(ProdEnv());
      } else {
        Env.init(DevEnv());
      }

      FlutterForegroundTask.initCommunicationPort();
      // _setupAudioSession();

      bool isAuth = await _init();

      if (isAuth) {
        PlatformManager.instance.instabug.identifyUser(
          SharedPreferencesUtil().email,
          SharedPreferencesUtil().fullName,
          ApiConfig().externalUserId,
        );
        // 把系统日历镜像到服务端，供 chat agent 了解用户行程。
        // 未授权时内部直接返回，不会弹框、不阻塞启动，所以不 await。
        CalendarSyncService().syncNow();
      }
      runApp(const MyApp());
    },
    (Object error, StackTrace stack) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[UNCAUGHT-ERROR] $error\n$stack');
      }
    },
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  static _MyAppState of(BuildContext context) => context.findAncestorStateOfType<_MyAppState>()!;

  // The navigator key is necessary to navigate using static methods
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  UndoDeleteNavigatorObserver? _undoDeleteObserver;
  PhoneRecordingShortcutService? _phoneRecordingShortcuts;
  PhoneRecordingShortcutController? _phoneRecordingController;
  Completer<void>? _phoneRecordingResumed;

  @override
  void initState() {
    NotificationUtil.initializeNotificationsEventListeners();
    NotificationUtil.initializeIsolateReceivePort();
    // 远程推送（每日一刻/新发现…）的点击 deep-link。放在 initState 而不是 _init()：
    // 冷启动那次点击要靠 getInitialMessage()，而它只在这条流被订阅时才去取。
    NotificationUtil.initializeRemoteNotificationTapListener();
    WidgetsBinding.instance.addObserver(this);
    _initWatchSync();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _phoneRecordingShortcuts = PhoneRecordingShortcutService()..attach(_startPhoneRecordingFromShortcut);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
          unawaited(_phoneRecordingShortcuts!.markReady());
        }
      });
    }
    super.initState();
  }

  Future<void> _startPhoneRecordingFromShortcut() async {
    final navigator = MyApp.navigatorKey.currentState;
    final context = MyApp.navigatorKey.currentContext;
    if (!mounted || navigator == null || context == null) throw PlatformException(code: 'start_failed');
    _phoneRecordingController ??= PhoneRecordingShortcutController(
      capture: context.read<CaptureProvider>(),
      isAuthenticated: () {
        final current = MyApp.navigatorKey.currentContext;
        return mounted && current != null && current.read<AuthenticationProvider>().isSignedIn() &&
            SharedPreferencesUtil().memorionOnboardingCompleted;
      },
      isForeground: () => mounted && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      requestMicrophonePermission: () async => (await Permission.microphone.request()).isGranted,
      waitForForeground: _waitForPhoneRecordingForeground,
    );
    final started = await _phoneRecordingController!.start();
    if (started && mounted && navigator.mounted) {
      unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) => const LiveCapturePage())));
    }
  }

  Future<void> _waitForPhoneRecordingForeground() async {
    if (!mounted) throw PlatformException(code: 'foreground_required');
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    final resumed = _phoneRecordingResumed ??= Completer<void>();
    await resumed.future.timeout(const Duration(seconds: 10),
        onTimeout: () => throw PlatformException(code: 'foreground_required'));
    if (!mounted || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      throw PlatformException(code: 'foreground_required');
    }
  }

  @override
  void dispose() {
    _phoneRecordingResumed?.complete();
    _phoneRecordingResumed = null;
    _phoneRecordingShortcuts?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Apple Watch 录音的补传。
  ///
  /// ⚠️ **每次启动和每次回前台都要主动拉一次，不能只靠原生的 `onRecordingReceived` 回调。**
  /// `transferFile` 的投递时机由系统决定：手机 App 可能根本没在运行，那一刻 MethodChannel
  /// 那头没人听、事件直接消失。真相源是磁盘上的队列目录（见
  /// `ios/Runner/WatchSessionService.swift` 的长注释），回调只是让前台立刻看到而已。
  ///
  /// 收到文件那一刻的同步现在由 `WatchRecordingService.init()` 自己接（它是那个类的职责，
  /// 不该由每个调用方记得接一遍），所以这里只负责冷启动这一次。
  void _initWatchSync() {
    WatchRecordingService.instance.init();
    WatchRecordingService.instance.onOpenWatchMoment = _openPendingWatchMoment;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingWatchMoment());
    // ⚠️ **这里以前是 `Future.delayed(8s)`，那是在猜鉴权几秒后就绪。** 猜早了这一次就白跑
    // （`syncPending` 判定未登录直接返回），而下一次机会要等用户把 App 切走再切回来 ——
    // 手表上的录音就那么一直挂着。现在立刻试，未就绪时由服务自己按退避排下一轮。
    WatchRecordingService.instance.syncNow(reason: 'cold start'); // i18n-ignore: 日志用的触发原因，不进 UI
  }

  bool _openingWatchMoment = false;
  Future<void> _openPendingWatchMoment() async {
    if (_openingWatchMoment || !mounted) return;
    _openingWatchMoment = true;
    try {
      final request = await WatchMomentService.channel.invokeMapMethod<String, dynamic>('getOpenMomentRequest');
      final context = MyApp.navigatorKey.currentContext;
      if (request == null || context == null || !context.mounted || request['accountId'] != getExternalUserId()) return;
      final offset = (request['offsetSeconds'] as num?)?.toDouble() ?? 0;
      if (!offset.isFinite || offset < 0) return;
      final opened = await openWatchConversationMoment(context, request['conversationId'] as String, offset);
      if (opened) await WatchMomentService.channel.invokeMethod('ackOpenMomentRequest', {'id': request['openWatchMoment']});
    } catch (e) { debugPrint('[Watch] pending moment retained: $e'); }
    finally { _openingWatchMoment = false; }
  }

  void _deinit() {
    debugPrint("App > _deinit");
    ServiceManager.instance().deinit();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint("App lifecycle state changed: $state");
    if (state != AppLifecycleState.resumed) unawaited(_phoneRecordingShortcuts?.markNotReady());

    switch (state) {
      case AppLifecycleState.resumed:
        // App returned to foreground - verify and restore device connection
        _onAppResumed();
        break;
      case AppLifecycleState.paused:
        // App going to background
        debugPrint("App paused - device connection may be suspended by iOS");
        break;
      case AppLifecycleState.detached:
        _deinit();
        break;
      default:
        break;
    }
  }

  void _onAppResumed() {
    _phoneRecordingResumed?.complete();
    _phoneRecordingResumed = null;
    if (MyApp.navigatorKey.currentState != null) unawaited(_phoneRecordingShortcuts?.markReady());
    debugPrint("App resumed - checking device connection status");
    // 手表在口袋里录的那几段，多半是这一刻才有机会上传（App 之前没在跑）。
    // `syncNow` 会把退避计数归零：回到前台意味着网络/鉴权条件很可能变了，不该继续沿用
    // 上一轮已经退避到 10 分钟的间隔。
    WatchRecordingService.instance.syncNow(reason: 'app resumed');
    unawaited(NotificationService.instance.saveNotificationToken());
    _openPendingWatchMoment();
    // Give the system a moment to restore BLE state
    Future.delayed(const Duration(milliseconds: 500), () {
      try {
        // Notify DeviceProvider to verify connection when app returns to foreground
        final context = MyApp.navigatorKey.currentContext;
        if (context != null) {
          final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
          deviceProvider.verifyConnectionAfterResume();
        }
      } catch (e) {
        debugPrint("Error verifying connection on resume: $e");
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => UndoDeleteController(account: () => ApiConfig().externalUserId)),
          ListenableProvider(create: (context) => ConnectivityProvider()),
          ChangeNotifierProvider(create: (context) => AuthenticationProvider()),
          ChangeNotifierProvider(create: (context) => ConversationProvider()),
          ChangeNotifierProvider(create: (context) => PeopleProvider()),
          ChangeNotifierProvider(create: (context) => VocabularyProvider()),
          ChangeNotifierProvider(create: (context) => UsageProvider()),
          ChangeNotifierProxyProvider<UsageProvider, PurchaseProvider>(
            lazy: false,
            create: (context) => PurchaseProvider()..initialize(),
            update: (context, usage, purchases) =>
                (purchases ?? (PurchaseProvider()..initialize()))..setUsageProvider(usage),
          ),
          ChangeNotifierProvider(create: (context) => MessageProvider()),
          // PressToTalkService — BLE 长按和 Chat UI 共用的语音转写服务
          ChangeNotifierProvider(create: (context) => PressToTalkService()),
          // ChatSessionProvider 上移到 CaptureProvider 之前，让 ProxyProvider5 能注入它
          ChangeNotifierProvider(create: (context) => ChatSessionProvider()),
          ChangeNotifierProxyProvider5<ConversationProvider, MessageProvider, PeopleProvider, UsageProvider,
              ChatSessionProvider, CaptureProvider>(
            create: (context) => CaptureProvider(),
            update:
                (BuildContext context, conversation, message, people, usage, chatSession, CaptureProvider? previous) {
              final pttService = Provider.of<PressToTalkService>(context, listen: false);
              return (previous
                    ?..updateProviderInstances(conversation, message, people, usage,
                        pttService: pttService, chatSession: chatSession)) ??
                  CaptureProvider();
            },
          ),
          ChangeNotifierProxyProvider<CaptureProvider, DeviceProvider>(
            create: (context) => DeviceProvider(),
            update: (BuildContext context, captureProvider, DeviceProvider? previous) =>
                (previous?..setProviders(captureProvider)) ?? DeviceProvider(),
          ),
          ChangeNotifierProxyProvider<DeviceProvider, OnboardingProvider>(
            create: (context) => OnboardingProvider(),
            update: (BuildContext context, value, OnboardingProvider? previous) =>
                (previous?..setDeviceProvider(value)) ?? OnboardingProvider(),
          ),
          ListenableProvider(create: (context) => HomeProvider()),
          ChangeNotifierProvider(create: (context) => MainNavProvider()),
          ChangeNotifierProxyProvider<DeviceProvider, SpeechProfileProvider>(
            create: (context) => SpeechProfileProvider(),
            update: (BuildContext context, device, SpeechProfileProvider? previous) =>
                (previous?..setProviders(device)) ?? SpeechProfileProvider(),
          ),
          ChangeNotifierProxyProvider<ConversationProvider, ConversationDetailProvider>(
            create: (context) => ConversationDetailProvider(),
            update: (BuildContext context, conversation, ConversationDetailProvider? previous) =>
                (previous?..setProviders(conversation)) ?? ConversationDetailProvider(),
          ),
          ChangeNotifierProvider(create: (context) => MemoriesProvider()),
          ChangeNotifierProvider(create: (context) => MomentsProvider()),
          ChangeNotifierProvider(create: (context) => TimelineProvider()),
          ChangeNotifierProvider(create: (context) => InsightsProvider()),
          ChangeNotifierProvider(create: (context) => UserProvider()),
          // 注意：ChatSessionProvider 已上移到 CaptureProvider 之前注册（见上方），
          // 以便 PTT 转写能注入同一实例；此处不再重复注册，避免两个实例不一致。
          ChangeNotifierProvider(create: (context) => ConversationAudioProvider()),
          ChangeNotifierProvider(create: (context) => AudioInputDeviceProvider()),
          ChangeNotifierProvider(create: (context) => DiscoverProvider()),
          ChangeNotifierProvider(create: (context) => HomeUpdatesProvider()),
          ChangeNotifierProvider(create: (context) => MoodPixelProvider()),
          ChangeNotifierProvider(create: (context) => MoodQuoteProvider()),
          ChangeNotifierProvider(create: (context) => PdpProvider()),
          ChangeNotifierProvider(create: (context) => LocaleProvider()),
          ChangeNotifierProvider(create: (context) => RecordingSourceProvider()),
        ],
        builder: (context, child) {
          return WithForegroundTask(
            child: Consumer<LocaleProvider>(
              builder: (context, localeProvider, child) => MaterialApp(
                // 2026-07：Instabug/PostHog 导航观察器已随 SDK 一并移除。
                navigatorObservers: [
                  _undoDeleteObserver ??= UndoDeleteNavigatorObserver(context.read<UndoDeleteController>()),
                ],
                debugShowCheckedModeBanner: F.env == Environment.dev,
                title: F.title,
                navigatorKey: MyApp.navigatorKey,
                localizationsDelegates: S.localizationsDelegates,
                supportedLocales: S.supportedLocales,
                locale: localeProvider.locale,
                // 全局主题 = 1.0 浅色。**这是兜底，不是「某个壳的主题」**：页面级
                // `Theme(data: ThemeData.light(...).copyWith(...))` 只覆盖它显式写的字段，
                // 其余（选区、光标、SnackBar、默认文字色、无自带 Theme 的弹框）全落回这里。
                //
                // 2026-08-20 之前这里是深色（`ColorScheme.dark` + 白字 textTheme +
                // `themeMode: dark`），那是已经不存在的旧深色壳留下的。后果不是「深色壳的
                // 事」而是全局的：浅底页面继承到不透明紫选区、白光标（在白底上隐形）、
                // 深色 SnackBar；`getDialog` / `ConfirmationDialog` / 充电指南这些通用弹框
                // 也跟着是深色，弹在浅色页面上。
                theme: ThemeData(
                    useMaterial3: false,
                    scaffoldBackgroundColor: JXB.bgApp,
                    colorScheme: const ColorScheme.light(
                      primary: JXB.brandPrimary,
                      secondary: JXB.brandSecondary,
                      surface: JXB.surface,
                      error: JXB.error,
                    ),
                    snackBarTheme: const SnackBarThemeData(
                      backgroundColor: JXB.textPrimary,
                      contentTextStyle: TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 15, color: Colors.white, fontWeight: FontWeight.w500),
                      behavior: SnackBarBehavior.floating,
                    ),
                    textTheme: const TextTheme(
                      titleLarge: TextStyle(fontFamily: JXB.fontSans, fontSize: 18, color: JXB.textPrimary),
                      titleMedium: TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPrimary),
                      bodyMedium: TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPrimary),
                      labelMedium: TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textSecondary),
                    ),
                    // 选区/光标只在这一处定义，整个 App 的所有页面都从这里继承。
                    //
                    // ⚠️ 页面级 `Theme` 若不声明 `textSelectionTheme`，`Theme` 注入
                    // `DefaultSelectionStyle` 时取的是
                    // `data.textSelectionTheme.selectionColor ?? 外层值`（Flutter
                    // `material/theme.dart`），于是页面**静默继承**这里的值——而
                    // `SelectableText`（`flutter_markdown` 的 `selectable: true` 内部就是它）
                    // 读的正是 `DefaultSelectionStyle`，不是 `TextSelectionTheme`。
                    // 这里曾是不透明 `Colors.deepPurple` + 白光标，代价是浅底页面选中后
                    // 文字被紫块糊住、光标看不见（chat 页实测）。不变式由
                    // `test/text_selection_color_test.dart` 钉住。
                    textSelectionTheme: const TextSelectionThemeData(
                      cursorColor: JXB.brandPrimary,
                      selectionColor: JXB.textSelection,
                      selectionHandleColor: JXB.brandPrimary,
                    ),
                    // iOS 的选择手柄/放大镜跟这个色走（原先是白色，配深色壳）。
                    cupertinoOverrideTheme: const CupertinoThemeData(
                      brightness: Brightness.light,
                      primaryColor: JXB.brandPrimary,
                    )),
                themeMode: ThemeMode.light,
                builder: (context, child) {
                  FlutterError.onError = (FlutterErrorDetails details) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      Logger.instance.talker.handle(details.exception, details.stack);
                    });
                  };
                  ErrorWidget.builder = (errorDetails) {
                    return CustomErrorWidget(errorMessage: errorDetails.exceptionAsString());
                  };
                  return UndoDeleteHost(child: Stack(
                    children: [
                      child!,
                      const PttOverlay(),
                    ],
                  ));
                },
                home: TalkerWrapper(
                  talker: Logger.instance.talker,
                  // 关闭 talker 的 error/exception 弹窗：它通过 ScaffoldMessenger.showSnackBar
                  // 在收到日志时弹红条，页面快速 push/pop（如录音页进退）时会在已 deactivated 的
                  // Scaffold 上触发「Looking up a deactivated widget's ancestor is unsafe」崩溃；
                  // 且这类内部错误本不该弹给用户。日志仍进 talker store，开发时可正常查看。
                  options: const TalkerWrapperOptions(
                    enableErrorAlerts: false,
                    enableExceptionAlerts: false,
                  ),
                  // TEMP(P-01 验收): 设为 true 可直达新版今日·章节时间线页面，
                  // 验收完成后删除此临时分支。见 pages/today_chapters/。
                  child: kDebugShowTodayChapters ? const TodayChaptersPage() : const AppShell(),
                ),
              ),
            ),
          );
        });
  }
}

class CustomErrorWidget extends StatelessWidget {
  final String errorMessage;

  const CustomErrorWidget({super.key, required this.errorMessage});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.red,
                size: 50.0,
              ),
              const SizedBox(height: 10.0),
              Text(
                S.of(context).errorScreenTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10.0),
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.all(16),
                height: 200,
                decoration: BoxDecoration(
                  color: const Color.fromARGB(255, 63, 63, 63),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  errorMessage,
                  textAlign: TextAlign.start,
                  style: const TextStyle(fontSize: 16.0),
                ),
              ),
              const SizedBox(height: 10.0),
              SizedBox(
                width: 210,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: errorMessage));
                    UndoDeleteHost.showMessage(context, S.of(context).errorCopyToClipboard);
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(S.of(context).errorCopyAction),
                      const SizedBox(width: 10),
                      const Icon(Icons.copy_rounded),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
