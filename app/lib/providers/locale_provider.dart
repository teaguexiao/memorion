import 'package:flutter/material.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/services/notifications/notification_service.dart';
import 'package:memorion/services/watch_recording_service.dart';

class LocaleProvider extends ChangeNotifier {
  Locale? _locale;

  Locale? get locale => _locale;

  LocaleProvider() {
    final saved = SharedPreferencesUtil().uiLocale;
    if (saved.isNotEmpty) {
      _locale = Locale(saved);
    } else {
      // Migration: inherit STT language only if it's a supported UI locale
      const supportedUiCodes = {'en', 'zh'};
      final sttLang = SharedPreferencesUtil().userPrimaryLanguage;
      if (sttLang.isNotEmpty && supportedUiCodes.contains(sttLang)) {
        _locale = Locale(sttLang);
        SharedPreferencesUtil().uiLocale = sttLang;
      }
    }
    // 启动时也要下发一次：`updateApplicationContext` 只在**值变化**时才投递，而手表可能
    // 从来没收到过（先装的手表 App、或者换过表）。
    _syncWatchLocale();
  }

  /// 把 App 里的手动语言选择下发给 Apple Watch。
  ///
  /// ⚠️ 手表读不到这个 Provider —— 它是另一台设备上的独立进程，而**系统语言看不出用户在
  /// App 里手动切过中/英**（手机系统英文 + App 内选中文是常见组合）。所以手表侧的取词
  /// 优先用这个值，见 `ios/MemorionWatch/WatchText.swift`。
  ///
  /// 空串（跟随系统）也要照发：它是一个有意义的值，手表侧据此回落到自己的系统语言。
  void _syncWatchLocale() {
    WatchRecordingService.instance.syncLocale(_locale?.languageCode ?? '');
  }

  void setLocale(Locale? locale) {
    _locale = locale;
    SharedPreferencesUtil().uiLocale = locale?.languageCode ?? '';
    notifyListeners();
    _syncWatchLocale();

    // 语言切换后，重新下发依赖当前 locale 的本地化通知文案：
    // - register(): 更新原生侧缓存的「App 被杀」通知（否则切语言不生效）。
    // 延后到下一帧执行，确保 MaterialApp 已用新 locale 重建，appT 能取到新翻译。
    //
    // 每日一刻不在此列 —— 它是服务端推送，文案由后端按用户语言生成。任务提醒的正文是
    // 待办描述（用户自己的话），标题会在下次重排时刷新，不值得为切语言单独重排一遍。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.instance.register();
    });
  }

  String get currentLocaleCode => _locale?.languageCode ?? '';

  /// Concrete STT language code derived from current setting.
  /// If explicit (en/zh), returns that. If system default, derives from device locale.
  String get resolvedSttLanguageCode {
    if (_locale != null) return _locale!.languageCode;
    return resolveDeviceLanguageCode();
  }

  static String resolveDeviceLanguageCode() {
    final deviceLocale = WidgetsBinding.instance.platformDispatcher.locale;
    return deviceLocale.languageCode == 'zh' ? 'zh' : 'en';
  }
}
