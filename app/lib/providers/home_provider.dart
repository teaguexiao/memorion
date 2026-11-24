import 'package:flutter/material.dart';
import 'package:memorion/backend/http/api/speech_profile.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/main.dart';
import 'package:memorion/pages/settings/language_selection_dialog.dart';
import 'package:memorion/utils/analytics/analytics_manager.dart';

class HomeProvider extends ChangeNotifier {
  int selectedIndex = 0;
  Function(int idx)? onSelectedIndexChanged;
  final FocusNode chatFieldFocusNode = FocusNode();
  final FocusNode appsSearchFieldFocusNode = FocusNode();
  final FocusNode convoSearchFieldFocusNode = FocusNode();
  final FocusNode memoriesSearchFieldFocusNode = FocusNode();
  bool isAppsSearchFieldFocused = false;
  bool isChatFieldFocused = false;
  bool isConvoSearchFieldFocused = false;
  bool isMemoriesSearchFieldFocused = false;
  bool hasSpeakerProfile = true;
  bool isLoading = false;
  String userPrimaryLanguage = SharedPreferencesUtil().userPrimaryLanguage;
  bool hasSetPrimaryLanguage = SharedPreferencesUtil().hasSetPrimaryLanguage;
  String userTimezone = SharedPreferencesUtil().userTimezone;
  bool hasSetTimezone = SharedPreferencesUtil().hasSetTimezone;

  // Available timezones grouped by region (display name -> IANA timezone)
  static const Map<String, String> availableTimezones = {
    // Americas
    'US Eastern (New York)': 'America/New_York',
    'US Central (Chicago)': 'America/Chicago',
    'US Mountain (Denver)': 'America/Denver',
    'US Pacific (Los Angeles)': 'America/Los_Angeles',
    'US Alaska (Anchorage)': 'America/Anchorage',
    'US Hawaii (Honolulu)': 'Pacific/Honolulu',
    'Canada (Toronto)': 'America/Toronto',
    'Canada (Vancouver)': 'America/Vancouver',
    'Mexico (Mexico City)': 'America/Mexico_City',
    'Brazil (Sao Paulo)': 'America/Sao_Paulo',
    'Argentina (Buenos Aires)': 'America/Argentina/Buenos_Aires',
    // Europe
    'UK (London)': 'Europe/London',
    'France (Paris)': 'Europe/Paris',
    'Germany (Berlin)': 'Europe/Berlin',
    'Spain (Madrid)': 'Europe/Madrid',
    'Italy (Rome)': 'Europe/Rome',
    'Netherlands (Amsterdam)': 'Europe/Amsterdam',
    'Switzerland (Zurich)': 'Europe/Zurich',
    'Russia (Moscow)': 'Europe/Moscow',
    'Turkey (Istanbul)': 'Europe/Istanbul',
    // Asia
    'China (Shanghai)': 'Asia/Shanghai',
    'Japan (Tokyo)': 'Asia/Tokyo',
    'South Korea (Seoul)': 'Asia/Seoul',
    'Singapore': 'Asia/Singapore',
    'Hong Kong': 'Asia/Hong_Kong',
    'Taiwan (Taipei)': 'Asia/Taipei',
    'India (Kolkata)': 'Asia/Kolkata',
    'UAE (Dubai)': 'Asia/Dubai',
    'Thailand (Bangkok)': 'Asia/Bangkok',
    'Vietnam (Ho Chi Minh)': 'Asia/Ho_Chi_Minh',
    'Indonesia (Jakarta)': 'Asia/Jakarta',
    'Malaysia (Kuala Lumpur)': 'Asia/Kuala_Lumpur',
    'Philippines (Manila)': 'Asia/Manila',
    'Israel (Jerusalem)': 'Asia/Jerusalem',
    // Oceania
    'Australia (Sydney)': 'Australia/Sydney',
    'Australia (Melbourne)': 'Australia/Melbourne',
    'Australia (Perth)': 'Australia/Perth',
    'New Zealand (Auckland)': 'Pacific/Auckland',
    // Africa
    'South Africa (Johannesburg)': 'Africa/Johannesburg',
    'Egypt (Cairo)': 'Africa/Cairo',
    'Nigeria (Lagos)': 'Africa/Lagos',
  };

  final Map<String, String> availableLanguages = {
    'English': 'en',
    '中文': 'zh',
  };

  HomeProvider() {
    chatFieldFocusNode.addListener(_onFocusChange);
    appsSearchFieldFocusNode.addListener(_onFocusChange);
    convoSearchFieldFocusNode.addListener(_onFocusChange);
    memoriesSearchFieldFocusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    isChatFieldFocused = chatFieldFocusNode.hasFocus;
    isAppsSearchFieldFocused = appsSearchFieldFocusNode.hasFocus;
    isConvoSearchFieldFocused = convoSearchFieldFocusNode.hasFocus;
    isMemoriesSearchFieldFocused = memoriesSearchFieldFocusNode.hasFocus;
    notifyListeners();
  }

  void setIndex(int index) {
    selectedIndex = index;
    notifyListeners();
  }

  void setIsLoading(bool loading) {
    isLoading = loading;
    notifyListeners();
  }

  void setSpeakerProfile(bool? value) {
    hasSpeakerProfile = value ?? SharedPreferencesUtil().hasSpeakerProfile;
    notifyListeners();
  }

  Future setupHasSpeakerProfile() async {
    setIsLoading(true);
    var res = await userHasSpeakerProfile();
    setSpeakerProfile(res);
    SharedPreferencesUtil().hasSpeakerProfile = res;
    debugPrint('_setupHasSpeakerProfile: ${SharedPreferencesUtil().hasSpeakerProfile}');
    AnalyticsManager().setUserAttribute('Speaker Profile', SharedPreferencesUtil().hasSpeakerProfile);

    setIsLoading(false);
    notifyListeners();
  }

  Future<void> setupUserPrimaryLanguage() async {
    final localHasSet = SharedPreferencesUtil().hasSetPrimaryLanguage;
    final localLanguage = SharedPreferencesUtil().userPrimaryLanguage;

    debugPrint('[Language] Setup started - localHasSet: $localHasSet, localLanguage: "$localLanguage"');

    // Case 1: Local cache is valid - use it immediately (no network delay)
    if (localHasSet && localLanguage.isNotEmpty) {
      userPrimaryLanguage = localLanguage;
      hasSetPrimaryLanguage = true;
      debugPrint('[Language] Using valid local cache: $localLanguage');

      // Background sync: verify with backend without blocking
      _syncLanguageWithBackendInBackground();
      return;
    }

    // Case 2: Inconsistent state - hasSetPrimaryLanguage=true but language is empty
    // This is the bug scenario - try to recover from backend
    if (localHasSet && localLanguage.isEmpty) {
      debugPrint('[Language] WARNING: Inconsistent state detected! hasSet=true but language is empty. Recovering from backend...');
      await _recoverLanguageFromBackend();
      return;
    }

    // Case 3: Never set - fetch from backend
    debugPrint('[Language] No local cache, fetching from backend...');
    await _fetchAndSetLanguageFromBackend();
  }

  /// 1.0 浅色壳专用：设置主语言但**绝不弹旧深色语言 Dialog**。
  /// onboarding 个性化步已负责收集语言；缺失时仅静默回退设备语言，不打断新壳。
  Future<void> setupUserPrimaryLanguageSilently() async {
    final localHasSet = SharedPreferencesUtil().hasSetPrimaryLanguage;
    final localLanguage = SharedPreferencesUtil().userPrimaryLanguage;

    if (localHasSet && localLanguage.isNotEmpty) {
      userPrimaryLanguage = localLanguage;
      hasSetPrimaryLanguage = true;
      _syncLanguageWithBackendInBackground();
      return;
    }
    // 无本地缓存：尝试后端，取不到就静默留空（不弹 Dialog）。
    try {
      final language = await getUserPrimaryLanguage();
      if (language != null && language.isNotEmpty) {
        userPrimaryLanguage = language;
        hasSetPrimaryLanguage = true;
        SharedPreferencesUtil().userPrimaryLanguage = language;
        SharedPreferencesUtil().hasSetPrimaryLanguage = true;
        AnalyticsManager().setUserAttribute('Primary Language', language);
      }
    } catch (_) {
      // 静默失败，下次再取。
    }
    notifyListeners();
  }

  /// Background sync to verify local cache matches backend
  /// Does not block the main flow
  void _syncLanguageWithBackendInBackground() {
    Future.microtask(() async {
      try {
        final backendLanguage = await getUserPrimaryLanguage();
        final localLanguage = SharedPreferencesUtil().userPrimaryLanguage;

        if (backendLanguage != null && backendLanguage.isNotEmpty && backendLanguage != localLanguage) {
          debugPrint('[Language] Background sync: backend($backendLanguage) differs from local($localLanguage), updating local...');
          SharedPreferencesUtil().userPrimaryLanguage = backendLanguage;
          SharedPreferencesUtil().hasSetPrimaryLanguage = true;
          userPrimaryLanguage = backendLanguage;
          hasSetPrimaryLanguage = true;
          AnalyticsManager().setUserAttribute('Primary Language', backendLanguage);
          notifyListeners();
        } else {
          debugPrint('[Language] Background sync: local cache is up to date');
        }
      } catch (e) {
        debugPrint('[Language] Background sync failed (non-critical): $e');
        // Don't clear local cache on background sync failure
      }
    });
  }

  /// Recover language setting from backend when local state is inconsistent
  Future<void> _recoverLanguageFromBackend() async {
    try {
      final language = await getUserPrimaryLanguage();
      if (language != null && language.isNotEmpty) {
        debugPrint('[Language] Recovery successful: $language');
        userPrimaryLanguage = language;
        hasSetPrimaryLanguage = true;
        SharedPreferencesUtil().userPrimaryLanguage = language;
        SharedPreferencesUtil().hasSetPrimaryLanguage = true;
        AnalyticsManager().setUserAttribute('Primary Language', language);
      } else {
        debugPrint('[Language] Recovery: backend has no language set, showing dialog');
        // Backend also has no language - reset local state and show dialog
        userPrimaryLanguage = '';
        hasSetPrimaryLanguage = false;
        SharedPreferencesUtil().userPrimaryLanguage = '';
        SharedPreferencesUtil().hasSetPrimaryLanguage = false;
        _showLanguageDialogDelayed();
      }
    } catch (e) {
      debugPrint('[Language] Recovery failed: $e - keeping hasSet=true to retry later');
      // On error, don't clear hasSetPrimaryLanguage to avoid repeated failures
      // The user can manually set it in settings if needed
      userPrimaryLanguage = '';
      hasSetPrimaryLanguage = true; // Keep true so we don't spam the dialog
    }
    notifyListeners();
  }

  /// Fetch language from backend for first-time setup
  Future<void> _fetchAndSetLanguageFromBackend() async {
    try {
      final language = await getUserPrimaryLanguage();
      if (language == null || language.isEmpty) {
        debugPrint('[Language] Backend has no language set, showing dialog');
        userPrimaryLanguage = '';
        hasSetPrimaryLanguage = false;
        _showLanguageDialogDelayed();
      } else {
        debugPrint('[Language] Fetched from backend: $language');
        userPrimaryLanguage = language;
        hasSetPrimaryLanguage = true;
        SharedPreferencesUtil().userPrimaryLanguage = language;
        SharedPreferencesUtil().hasSetPrimaryLanguage = true;
        AnalyticsManager().setUserAttribute('Primary Language', language);
      }
    } catch (e) {
      debugPrint('[Language] Fetch failed: $e');
      // On error during first setup, don't set hasSetPrimaryLanguage
      // This allows retry on next app launch
      userPrimaryLanguage = '';
      hasSetPrimaryLanguage = false;
    }
    notifyListeners();
  }

  void _showLanguageDialogDelayed() {
    Future.delayed(const Duration(milliseconds: 500), () {
      if (MyApp.navigatorKey.currentContext != null) {
        showLanguageDialogIfNeeded(MyApp.navigatorKey.currentContext!);
      }
    });
  }

  void showLanguageDialogIfNeeded(BuildContext context) {
    if (!hasSetPrimaryLanguage) {
      LanguageSelectionDialog.show(context, isRequired: true);
    }
  }

  Future<bool> updateUserPrimaryLanguage(String languageCode) async {
    try {
      final success = await setUserPrimaryLanguage(languageCode);
      if (success) {
        userPrimaryLanguage = languageCode;
        hasSetPrimaryLanguage = true;
        SharedPreferencesUtil().userPrimaryLanguage = languageCode;
        SharedPreferencesUtil().hasSetPrimaryLanguage = true;
        AnalyticsManager().setUserAttribute('Primary Language', languageCode);
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error setting user primary language: $e');
      return false;
    }
  }

  String getLanguageName(String code) {
    try {
      return availableLanguages.entries.firstWhere((element) => element.value == code).key;
    } catch (_) {
      return code;
    }
  }

  // Timezone management methods
  Future<void> setupUserTimezone() async {
    final localHasSet = SharedPreferencesUtil().hasSetTimezone;
    final localTimezone = SharedPreferencesUtil().userTimezone;

    debugPrint('[Timezone] Setup started - localHasSet: $localHasSet, localTimezone: "$localTimezone"');

    // Case 1: Local cache is valid - use it immediately (no network delay)
    if (localHasSet && localTimezone.isNotEmpty) {
      userTimezone = localTimezone;
      hasSetTimezone = true;
      debugPrint('[Timezone] Using valid local cache: $localTimezone');

      // Background sync: verify with backend without blocking
      _syncTimezoneWithBackendInBackground();
      return;
    }

    // Case 2: Inconsistent state - hasSetTimezone=true but timezone is empty
    if (localHasSet && localTimezone.isEmpty) {
      debugPrint('[Timezone] WARNING: Inconsistent state detected! hasSet=true but timezone is empty. Recovering from backend...');
      await _recoverTimezoneFromBackend();
      return;
    }

    // Case 3: Never set - fetch from backend
    debugPrint('[Timezone] No local cache, fetching from backend...');
    await _fetchAndSetTimezoneFromBackend();
  }

  void _syncTimezoneWithBackendInBackground() {
    Future.microtask(() async {
      try {
        final backendTimezone = await getUserTimezone();
        final localTimezone = SharedPreferencesUtil().userTimezone;

        if (backendTimezone != null && backendTimezone.isNotEmpty && backendTimezone != localTimezone) {
          debugPrint('[Timezone] Background sync: backend($backendTimezone) differs from local($localTimezone), updating local...');
          SharedPreferencesUtil().userTimezone = backendTimezone;
          SharedPreferencesUtil().hasSetTimezone = true;
          userTimezone = backendTimezone;
          hasSetTimezone = true;
          AnalyticsManager().setUserAttribute('Timezone', backendTimezone);
          notifyListeners();
        } else {
          debugPrint('[Timezone] Background sync: local cache is up to date');
        }
      } catch (e) {
        debugPrint('[Timezone] Background sync failed (non-critical): $e');
      }
    });
  }

  Future<void> _recoverTimezoneFromBackend() async {
    try {
      final timezone = await getUserTimezone();
      if (timezone != null && timezone.isNotEmpty) {
        debugPrint('[Timezone] Recovery successful: $timezone');
        userTimezone = timezone;
        hasSetTimezone = true;
        SharedPreferencesUtil().userTimezone = timezone;
        SharedPreferencesUtil().hasSetTimezone = true;
        AnalyticsManager().setUserAttribute('Timezone', timezone);
      } else {
        debugPrint('[Timezone] Recovery: backend has no timezone set');
        userTimezone = '';
        hasSetTimezone = false;
        SharedPreferencesUtil().userTimezone = '';
        SharedPreferencesUtil().hasSetTimezone = false;
      }
    } catch (e) {
      debugPrint('[Timezone] Recovery failed: $e - keeping hasSet=true to retry later');
      userTimezone = '';
      hasSetTimezone = true; // Keep true so we don't spam
    }
    notifyListeners();
  }

  Future<void> _fetchAndSetTimezoneFromBackend() async {
    try {
      final timezone = await getUserTimezone();
      if (timezone == null || timezone.isEmpty) {
        debugPrint('[Timezone] Backend has no timezone set');
        userTimezone = '';
        hasSetTimezone = false;
      } else {
        debugPrint('[Timezone] Fetched from backend: $timezone');
        userTimezone = timezone;
        hasSetTimezone = true;
        SharedPreferencesUtil().userTimezone = timezone;
        SharedPreferencesUtil().hasSetTimezone = true;
        AnalyticsManager().setUserAttribute('Timezone', timezone);
      }
    } catch (e) {
      debugPrint('[Timezone] Fetch failed: $e');
      userTimezone = '';
      hasSetTimezone = false;
    }
    notifyListeners();
  }

  Future<bool> updateUserTimezone(String timezoneCode) async {
    try {
      final success = await setUserTimezone(timezoneCode);
      if (success) {
        userTimezone = timezoneCode;
        hasSetTimezone = true;
        SharedPreferencesUtil().userTimezone = timezoneCode;
        SharedPreferencesUtil().hasSetTimezone = true;
        AnalyticsManager().setUserAttribute('Timezone', timezoneCode);
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error setting user timezone: $e');
      return false;
    }
  }

  String getTimezoneDisplayName(String code) {
    final entry = availableTimezones.entries.firstWhere(
      (element) => element.value == code,
      orElse: () => MapEntry(code, code),
    );
    return entry.key;
  }

  // 删掉了 setUserPeople()：全仓库无人调用，而它是「人物缓存被冲空」那个 bug 的第二份
  // 拷贝——拉取失败时把结果原样写进 cachedPeople。修法在 PeopleProvider 里（失败保持
  // 现状），留着这份等于给同一个 bug 留了条后路。要拉人物列表用 PeopleProvider。

  @override
  void dispose() {
    chatFieldFocusNode.removeListener(_onFocusChange);
    appsSearchFieldFocusNode.removeListener(_onFocusChange);
    convoSearchFieldFocusNode.removeListener(_onFocusChange);
    memoriesSearchFieldFocusNode.removeListener(_onFocusChange);
    memoriesSearchFieldFocusNode.dispose();
    chatFieldFocusNode.dispose();
    appsSearchFieldFocusNode.dispose();
    convoSearchFieldFocusNode.dispose();
    onSelectedIndexChanged = null;
    super.dispose();
  }
}
