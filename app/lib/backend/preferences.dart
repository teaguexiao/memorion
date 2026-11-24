import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/backend/schema/chat_session.dart';
import 'package:memorion/services/wals.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SharedPreferencesUtil {
  static final SharedPreferencesUtil _instance = SharedPreferencesUtil._internal();
  static SharedPreferences? _preferences;

  factory SharedPreferencesUtil() {
    return _instance;
  }

  SharedPreferencesUtil._internal();

  static Future<void> init() async {
    final preferences = await SharedPreferences.getInstance();
    // Previous builds populated this key with the shared build-time credential.
    if (preferences.containsKey('memorionApiKey')) {
      await preferences.remove('memorionApiKey');
    }
    _preferences = preferences;
  }

  set uid(String value) => saveString('uid', value);

  String get uid => getString('uid') ?? '';

  //-------------------------------- Device ----------------------------------//

  bool? get hasMemorionDevice {
    // Migration: check old key and migrate to new key
    final newValue = _preferences?.getBool('hasMemorionDevice');
    if (newValue != null) return newValue;
    final oldValue = _preferences?.getBool('hasOmiDevice');
    if (oldValue != null) {
      _preferences?.setBool('hasMemorionDevice', oldValue);
      _preferences?.remove('hasOmiDevice');
      return oldValue;
    }
    return null;
  }

  set hasMemorionDevice(bool? value) {
    if (value != null) {
      _preferences?.setBool('hasMemorionDevice', value);
    } else {
      _preferences?.remove('hasMemorionDevice');
    }
    // Clean up legacy key if it exists
    _preferences?.remove('hasOmiDevice');
  }

  set btDevice(BtDevice value) {
    saveString('btDevice', jsonEncode(value.toJson()));
  }

  Future<void> btDeviceSet(BtDevice value) async {
    await saveString('btDevice', jsonEncode(value.toJson()));
  }

  BtDevice get btDevice {
    final String device = getString('btDevice') ?? '';
    if (device.isEmpty) return BtDevice(id: '', name: '', type: DeviceType.memorion, rssi: 0);
    return BtDevice.fromJson(jsonDecode(device));
  }

  set deviceName(String value) => saveString('deviceName', value);

  String get deviceName => getString('deviceName') ?? '';

  bool get deviceIsV2 => getBool('deviceIsV2') ?? false;

  set deviceIsV2(bool value) => saveBool('deviceIsV2', value);

  // 自动同步设备缓存录音（1.0 设备页开关，默认开）。
  bool get autoSyncRecordings => getBool('autoSyncRecordings') ?? true;

  set autoSyncRecordings(bool value) => saveBool('autoSyncRecordings', value);

  //----------------------------- Permissions ---------------------------------//

  set notificationsEnabled(bool value) => saveBool('notificationsEnabled', value);

  bool get notificationsEnabled => getBool('notificationsEnabled') ?? false;

  //-------------------- Notification Preferences (P-30N) ----------------------//
  // 各提醒类型开关（本地持久化，默认开）。已与服务端双向同步：改动即
  // POST /v1/users/notification-preferences，启动时 GET 回读一次
  // （NotificationPrefs.syncToServer / hydrateFromServer）。服务端推送
  // （每日一刻、新发现）发之前会 honor 这些开关与静默时段。

  bool get notifDailyMoment => getBool('notifDailyMoment') ?? true;
  set notifDailyMoment(bool v) => saveBool('notifDailyMoment', v);

  bool get notifTaskReminder => getBool('notifTaskReminder') ?? true;
  set notifTaskReminder(bool v) => saveBool('notifTaskReminder', v);

  bool get notifPauseReminder => getBool('notifPauseReminder') ?? true;
  set notifPauseReminder(bool v) => saveBool('notifPauseReminder', v);

  bool get notifMilestone => getBool('notifMilestone') ?? true;
  set notifMilestone(bool v) => saveBool('notifMilestone', v);

  // 静默时段（本地持久化）。startMinutes/endMinutes 为「自午夜起的分钟数」。
  bool get quietHoursEnabled => getBool('quietHoursEnabled') ?? false;
  set quietHoursEnabled(bool v) => saveBool('quietHoursEnabled', v);

  // ⚠️ 起点别设成 22:00：服务端每日一刻恰好在本地 22:00 整点推，而后端
  // _in_quiet_hours 跨午夜分支是 now >= start → 一开静默时段就永久收不到它。
  // 这三个默认值必须与后端 NOTIFICATION_PREFERENCES_DEFAULTS 一致
  // (backend/database/developer_data.py)。
  int get quietHoursStartMinutes => getInt('quietHoursStartMinutes') ?? 23 * 60; // 默认 23:00
  set quietHoursStartMinutes(int v) => saveInt('quietHoursStartMinutes', v);

  int get quietHoursEndMinutes => getInt('quietHoursEndMinutes') ?? 8 * 60; // 默认 08:00
  set quietHoursEndMinutes(int v) => saveInt('quietHoursEndMinutes', v);

  // 当前已排定的「任务提醒」本地通知 id 列表（用于下次重排前逐个取消，避免残留）。
  List<String> get scheduledTaskReminderIds => getStringList('scheduledTaskReminderIds') ?? [];
  set scheduledTaskReminderIds(List<String> v) => saveStringList('scheduledTaskReminderIds', v);

  //---------------------- API Credentials ---------------------------------//

  String get memorionApiKey => getString('configuredMemorionApiKey') ?? '';

  set memorionApiKey(String value) => saveString('configuredMemorionApiKey', value);

  /// 每用户专属的 bound API key（POST /v1/auth/app-token 换来的）。
  ///
  /// 与它配对的 uid 记在 [boundApiKeyUid]。切换账号后需要重新换发。
  String get boundApiKey => getString('boundApiKey') ?? '';

  set boundApiKey(String value) => saveString('boundApiKey', value);

  String get boundApiKeyUid => getString('boundApiKeyUid') ?? '';

  set boundApiKeyUid(String value) => saveString('boundApiKeyUid', value);

  String get externalUserId => getString('externalUserId') ?? '';

  set externalUserId(String value) => saveString('externalUserId', value);

  //---------------------- Feature Settings ---------------------------------//

  set transcriptionDiagnosticEnabled(bool value) => saveBool('transcriptionDiagnosticEnabled', value);

  bool get transcriptionDiagnosticEnabled => getBool('transcriptionDiagnosticEnabled') ?? false;

  set autoCreateSpeakersEnabled(bool value) => saveBool('autoCreateSpeakersEnabled', value);

  bool get autoCreateSpeakersEnabled => getBool('autoCreateSpeakersEnabled') ?? true;

  set localSyncEnabled(bool value) => saveBool('localSyncEnabled', value);

  bool get localSyncEnabled => getBool('localSyncEnabled') ?? true;

  //-------------------------------- Audio Upload Mode ----------------------------------//

  /// Whether to save uploaded audio to cloud storage
  bool get saveUploadedAudio => getBool('saveUploadedAudio') ?? false;

  set saveUploadedAudio(bool value) => saveBool('saveUploadedAudio', value);

  /// Auto-upload timeout in seconds (silence duration before auto-upload)
  int get autoUploadTimeoutSeconds => getInt('autoUploadTimeoutSeconds') ?? 30;

  set autoUploadTimeoutSeconds(int value) => saveInt('autoUploadTimeoutSeconds', value);

  /// Default recording mode: 'realtime' or 'fileUpload'
  String get defaultRecordingMode => getString('defaultRecordingMode') ?? 'realtime';

  set defaultRecordingMode(String value) => saveString('defaultRecordingMode', value);

  //-------------------------------- Local Audio Storage ----------------------------------//

  /// Map of conversation IDs to local audio file paths
  Map<String, String> get conversationAudioPaths {
    final String data = getString('conversationAudioPaths') ?? '{}';
    try {
      final Map<String, dynamic> decoded = jsonDecode(data);
      return decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (e) {
      return {};
    }
  }

  set conversationAudioPaths(Map<String, String> value) {
    saveString('conversationAudioPaths', jsonEncode(value));
  }

  //-------------------------------- Local Image Storage ----------------------------------//

  /// Map of image IDs to local image file paths
  Map<String, String> get conversationImagePaths {
    final String data = getString('conversationImagePaths') ?? '{}';
    try {
      final Map<String, dynamic> decoded = jsonDecode(data);
      return decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (e) {
      return {};
    }
  }

  set conversationImagePaths(Map<String, String> value) {
    saveString('conversationImagePaths', jsonEncode(value));
  }

  /// Map of image IDs to conversation IDs (for association)
  Map<String, String> get imageConversationAssociations {
    final String data = getString('imageConversationAssociations') ?? '{}';
    try {
      final Map<String, dynamic> decoded = jsonDecode(data);
      return decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (e) {
      return {};
    }
  }

  set imageConversationAssociations(Map<String, String> value) {
    saveString('imageConversationAssociations', jsonEncode(value));
  }

  bool get hasShownLedDisclaimer => getBool('hasShownLedDisclaimer') ?? false;

  set hasShownLedDisclaimer(bool value) => saveBool('hasShownLedDisclaimer', value);

  bool get showSummarizeConfirmation => getBool('showSummarizeConfirmation') ?? true;

  set showSummarizeConfirmation(bool value) => saveBool('showSummarizeConfirmation', value);

  //-------------------------------- Sidebar ----------------------------------//

  bool get sidebarCollapsed => getBool('sidebarCollapsed') ?? false;

  set sidebarCollapsed(bool value) => saveBool('sidebarCollapsed', value);

  bool get aiDataConsentAccepted => getBool('aiDataConsentAccepted') ?? false;

  set aiDataConsentAccepted(bool value) => saveBool('aiDataConsentAccepted', value);

  bool get showFirmwareUpdateDialog => getBool('v2/showFirmwareUpdateDialog') ?? true;

  set showFirmwareUpdateDialog(bool value) => saveBool('v2/showFirmwareUpdateDialog', value);

  String get transcriptionModel => getString('transcriptionModel3') ?? 'soniox';

  set transcriptionModel(String value) => saveString('transcriptionModel3', value);

  bool get useOnDeviceStt => getBool('useOnDeviceStt') ?? false;

  set useOnDeviceStt(bool value) => saveBool('useOnDeviceStt', value);

  // 🚫 `recordingSource`（用户选的录音设备，手机 / Apple Watch / BLE 硬件）已于
  // 2026-08-19 移除 —— 那个三选一把三个性质不同的东西并列在一起，取消的理由见
  // `providers/recording_source_provider.dart` 的类注释。
  //
  // ⚠️ **prefs 里的存量键刻意不清理、也不迁移。** 清理需要一次性的启动期写操作，而它
  // 换来的只是几十字节；迁移则没有目标 —— 新模型里没有任何字段能承接「我一直想用手机
  // 录」这个意思，那恰恰是被判定为不该持久化的东西。留着不读即可，装回旧版本还能用。

  bool get onboardingCompleted => getBool('onboardingCompleted') ?? false;

  set onboardingCompleted(bool value) => saveBool('onboardingCompleted', value);

  /// Memorion-specific onboarding flag (separate from legacy flag)
  /// Forces re-onboarding when migrating to Memorion app
  bool get memorionOnboardingCompleted => getBool('memorionOnboardingCompleted') ?? false;

  set memorionOnboardingCompleted(bool value) => saveBool('memorionOnboardingCompleted', value);

  List<String> get memorionCategories => getStringList('memorionCategories') ?? ['all'];

  set memorionCategories(List<String> value) => saveStringList('memorionCategories', value);

  String gptCompletionCache(String key) => getString('gptCompletionCache:$key') ?? '';

  setGptCompletionCache(String key, String value) => saveString('gptCompletionCache:$key', value);

  bool get optInAnalytics => getBool('optInAnalytics') ?? true;

  set optInAnalytics(bool value) => saveBool('optInAnalytics', value);

  bool get optInEmotionalFeedback => getBool('optInEmotionalFeedback') ?? false;

  set optInEmotionalFeedback(bool value) => saveBool('optInEmotionalFeedback', value);

  bool get permissionStoreRecordingsEnabled => getBool('permissionStoreRecordingsEnabled') ?? false;

  set permissionStoreRecordingsEnabled(bool value) => saveBool('permissionStoreRecordingsEnabled', value);

  bool get hasSpeakerProfile => getBool('hasSpeakerProfile') ?? false;

  set hasSpeakerProfile(bool value) => saveBool('hasSpeakerProfile', value);

  bool get showDiscardedMemories => getBool('showDiscardedMemories') ?? true;

  set showDiscardedMemories(bool value) => saveBool('showDiscardedMemories', value);

  // User primary language preferences
  String get userPrimaryLanguage => getString('userPrimaryLanguage') ?? '';

  set userPrimaryLanguage(String value) => saveString('userPrimaryLanguage', value);

  bool get hasSetPrimaryLanguage => getBool('hasSetPrimaryLanguage') ?? false;

  set hasSetPrimaryLanguage(bool value) => saveBool('hasSetPrimaryLanguage', value);

  // UI locale preference
  String get uiLocale => getString('uiLocale') ?? '';

  set uiLocale(String value) => saveString('uiLocale', value);

  // User timezone preferences
  String get userTimezone => getString('userTimezone') ?? '';

  set userTimezone(String value) => saveString('userTimezone', value);

  bool get hasSetTimezone => getBool('hasSetTimezone') ?? false;

  set hasSetTimezone(bool value) => saveBool('hasSetTimezone', value);

  int get currentStorageBytes => getInt('currentStorageBytes') ?? 0;

  set currentStorageBytes(int value) => saveInt('currentStorageBytes', value);

  int get previousStorageBytes => getInt('previousStorageBytes') ?? 0;

  set previousStorageBytes(int value) => saveInt('previousStorageBytes', value);

  bool get showConversationDeleteConfirmation => getBool('showConversationDeleteConfirmation') ?? true;

  set showConversationDeleteConfirmation(bool value) => saveBool("showConversationDeleteConfirmation", value);

  bool get showActionItemDeleteConfirmation => getBool('showActionItemDeleteConfirmation') ?? true;

  set showActionItemDeleteConfirmation(bool value) => saveBool('showActionItemDeleteConfirmation', value);

  List<ServerConversation> get cachedConversations {
    if (getBool('migratedMemories') ?? false) {
      if (getStringList('cachedMemories') != null || getStringList('cachedMemories')!.isNotEmpty) {
        final List<ServerConversation> cachedMemories =
            getStringList('cachedMemories')!.map((e) => ServerConversation.fromJson(jsonDecode(e))).toList();
        cachedConversations = cachedMemories;
        saveBool('migratedMemories', true);
      }
    }
    final List<String> conversations = getStringList('cachedConversations') ?? [];
    return conversations.map((e) => ServerConversation.fromJson(jsonDecode(e))).toList();
  }

  set cachedConversations(List<ServerConversation> value) {
    final List<String> conversations = value.map((e) => jsonEncode(e.toJson())).toList();
    saveStringList('cachedConversations', conversations);
  }

  List<ServerMessage> get cachedMessages {
    final List<String> messages = getStringList('cachedMessages') ?? [];
    return messages.map((e) => ServerMessage.fromJson(jsonDecode(e))).toList();
  }

  set cachedMessages(List<ServerMessage> value) {
    final List<String> messages = value.map((e) => jsonEncode(e.toJson())).toList();
    saveStringList('cachedMessages', messages);
  }

  List<ServerMessage> getCachedMessagesForSession(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return cachedMessages;
    final key = 'cachedMessages_$sessionId';
    final List<String> messages = getStringList(key) ?? [];
    return messages.map((e) => ServerMessage.fromJson(jsonDecode(e))).toList();
  }

  void setCachedMessagesForSession(String? sessionId, List<ServerMessage> value) {
    if (sessionId == null || sessionId.isEmpty) {
      cachedMessages = value;
      return;
    }
    final key = 'cachedMessages_$sessionId';
    final List<String> messages = value.map((e) => jsonEncode(e.toJson())).toList();
    saveStringList(key, messages);
  }

  List<ChatSession> get cachedSessions {
    final List<String> sessions = getStringList('cachedSessions') ?? [];
    return sessions.map((e) => ChatSession.fromJson(jsonDecode(e))).toList();
  }

  set cachedSessions(List<ChatSession> value) {
    final List<String> sessions = value.map((e) => jsonEncode(e.toJson())).toList();
    saveStringList('cachedSessions', sessions);
  }

  // Cache sessions by app ID for better performance
  List<ChatSession> getCachedSessionsForApp(String? appId) {
    final key = 'cachedSessions_${appId ?? 'default'}';
    final List<String> sessions = getStringList(key) ?? [];
    return sessions.map((e) => ChatSession.fromJson(jsonDecode(e))).toList();
  }

  void setCachedSessionsForApp(String? appId, List<ChatSession> sessions) {
    final key = 'cachedSessions_${appId ?? 'default'}';
    final List<String> sessionStrings = sessions.map((e) => jsonEncode(e.toJson())).toList();
    saveStringList(key, sessionStrings);
  }

  void clearCachedSessionsForApp(String? appId) {
    final key = 'cachedSessions_${appId ?? 'default'}';
    _preferences?.remove(key);
  }

  Future<void> clearAllCachedSessions() async {
    // Get all keys to find session cache keys
    final allKeys = _preferences?.getKeys() ?? <String>{};
    for (final key in allKeys) {
      if (key.startsWith('cachedSessions_')) {
        await _preferences?.remove(key);
      }
    }
  }

  List<Person> get cachedPeople {
    final List<String> people = getStringList('cachedPeople') ?? [];
    return people.map((e) => Person.fromJson(jsonDecode(e))).toList();
  }

  Person? getPersonById(String id) {
    return cachedPeople.firstWhereOrNull((element) => element.id == id);
  }

  set cachedPeople(List<Person> value) {
    final List<String> people = value.map((e) => jsonEncode(e.toJson())).toList();
    saveStringList('cachedPeople', people);
  }

  addCachedPerson(Person person) {
    final List<Person> people = cachedPeople;
    people.add(person);
    cachedPeople = people;
  }

  removeCachedPerson(String personId) {
    final List<Person> people = cachedPeople;
    Person? person = people.firstWhereOrNull((p) => p.id == personId);
    if (person != null) {
      people.remove(person);
      cachedPeople = people;
    }
  }

  replaceCachedPerson(Person person) {
    final List<Person> people = cachedPeople;
    Person? oldPerson = people.firstWhereOrNull((p) => p.id == person.id);
    if (oldPerson != null) {
      people.remove(oldPerson);
      people.add(person);
      cachedPeople = people;
    }
  }

  ServerConversation? get modifiedConversationDetails {
    final String conversation = getString('modifiedConversationDetails') ?? '';
    if (conversation.isEmpty) return null;
    return ServerConversation.fromJson(jsonDecode(conversation));
  }

  set modifiedConversationDetails(ServerConversation? value) {
    saveString('modifiedConversationDetails', value == null ? '' : jsonEncode(value.toJson()));
  }

  set calendarPermissionAlreadyRequested(bool value) => saveBool('calendarPermissionAlreadyRequested', value);

  bool get calendarPermissionAlreadyRequested => getBool('calendarPermissionAlreadyRequested') ?? false;

  set calendarEnabled(bool value) => saveBool('calendarEnabled', value);

  bool get calendarEnabled => getBool('calendarEnabled') ?? false;

  set calendarId(String value) => saveString('calendarId', value);

  String get calendarId => getString('calendarId') ?? '';

  set calendarType(String value) => saveString('calendarType2', value); // auto, manual (only for now)

  String get calendarType => getString('calendarType2') ?? 'manual';

  /// 上次成功把系统日历同步到服务端的时刻（ISO-8601），用于节流。
  set calendarLastSyncedAt(DateTime? value) => saveString('calendarLastSyncedAt', value?.toIso8601String() ?? '');

  DateTime? get calendarLastSyncedAt {
    final raw = getString('calendarLastSyncedAt') ?? '';
    return raw.isEmpty ? null : DateTime.tryParse(raw);
  }

  /// 上次上传内容的指纹。日历大多数时候没变化，靠它跳过无谓的整窗重写。
  set calendarLastSyncFingerprint(String value) => saveString('calendarLastSyncFingerprint', value);

  String get calendarLastSyncFingerprint => getString('calendarLastSyncFingerprint') ?? '';

  /// 用户是否同意把日程同步到服务器并交给 AI 供应商处理。
  ///
  /// 这与系统日历权限是**两件不同的事**：iOS 弹窗只代表同意 App 读取本机日历，
  /// 不代表同意把内容上传、更不代表同意转交第三方 AI。App Review 5.1.2(i)
  /// （2025-11 新增）明确要求披露第三方 AI 并事前取得许可，故单独记一个开关。
  /// 未取得它之前 CalendarSyncService 不上传任何东西。
  ///
  /// ⚠️ 这只是**服务端那份的本地缓存**，不是真相源。真相在
  /// `/v1/calendar/sync-state` 的 `consent_granted`（见 `CalendarAiConsent`）——
  /// 本地这份会随沙盒一起被重装清掉，而系统日历权限不会，只信本地就会让开关
  /// 在重装后显示"关"、看起来像 iOS 权限出了问题。
  set calendarAiConsentGranted(bool value) => saveBool('calendarAiConsentGranted', value);

  bool get calendarAiConsentGranted => getBool('calendarAiConsentGranted') ?? false;

  /// 本机是否做过决定：null = 没有（含刚重装、刚换号）。
  ///
  /// 必须与明确的 `false` 分开：null 要去服务端问一次（可能是重装丢了同意），
  /// 明确的 false 是用户按过"暂不同意"，不该每次启动再去问。
  bool? get calendarAiConsentDecision => getBool('calendarAiConsentGranted');

  //--------------------------------- Auth ------------------------------------//

  String get authToken => getString('authToken') ?? '';

  set authToken(String value) => saveString('authToken', value);

  int get tokenExpirationTime => getInt('tokenExpirationTime') ?? 0;

  set tokenExpirationTime(int value) => saveInt('tokenExpirationTime', value);

  String get email => getString('email') ?? '';

  set email(String value) => saveString('email', value);

  String get givenName => getString('givenName') ?? '';

  set givenName(String value) => saveString('givenName', value);

  String get familyName => getString('familyName') ?? '';

  set familyName(String value) => saveString('familyName', value);

  String get fullName => '$givenName $familyName'.trim();

  String get fortuneBirthDate => getString('fortuneBirthDate') ?? '';

  set fortuneBirthDate(String value) => saveString('fortuneBirthDate', value);

  //--------------------------- Audio Input Device ----------------------------//

  String get preferredAudioInputId => getString('preferredAudioInputId') ?? '';

  set preferredAudioInputId(String value) => saveString('preferredAudioInputId', value);

  //--------------------------------- Wals ------------------------------------//

  set wals(List<Wal> wals) {
    final List<String> value = wals.map((e) => jsonEncode(e.toJson())).toList();
    saveStringList('wals', value);
  }

  List<Wal> get wals {
    final List<String> value = getStringList('wals') ?? [];
    return Wal.fromJsonList(value.map((e) => jsonDecode(e)).toList());
  }

  //--------------------------- JSON Cache with TTL ---------------------------//

  Future<void> cacheJson(String key, dynamic data) async {
    final envelope = jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch, 'data': data});
    await saveString('cache:$key', envelope);
  }

  dynamic getCachedJson(String key, {Duration maxAge = const Duration(days: 7)}) {
    final raw = getString('cache:$key');
    if (raw == null || raw.isEmpty) return null;
    try {
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      final ts = envelope['ts'] as int;
      if (DateTime.now().millisecondsSinceEpoch - ts > maxAge.inMilliseconds) return null;
      return envelope['data'];
    } catch (_) {
      return null;
    }
  }

  Future<void> clearCache(String key) async {
    await remove('cache:$key');
  }

  //--------------------------- Setters & Getters -----------------------------//

  Future<bool> saveString(String key, String value) async {
    return await _preferences?.setString(key, value) ?? false;
  }

  String? getString(String key) {
    return _preferences?.getString(key);
  }

  Future<bool> saveInt(String key, int value) async {
    return await _preferences?.setInt(key, value) ?? false;
  }

  int? getInt(String key) {
    return _preferences?.getInt(key);
  }

  Future<bool> saveBool(String key, bool value) async {
    return await _preferences?.setBool(key, value) ?? false;
  }

  bool? getBool(String key) {
    return _preferences?.getBool(key);
  }

  Future<bool> saveDouble(String key, double value) async {
    return await _preferences?.setDouble(key, value) ?? false;
  }

  double? getDouble(String key) {
    return _preferences?.getDouble(key);
  }

  Future<bool> saveStringList(String key, List<String> value) async {
    return await _preferences?.setStringList(key, value) ?? false;
  }

  List<String>? getStringList(String key) {
    return _preferences?.getStringList(key);
  }

  Future<bool> remove(String key) async {
    return await _preferences?.remove(key) ?? false;
  }

  Future<bool> clear() async {
    return await _preferences?.clear() ?? false;
  }

  /// Clears all user-related preferences when signing out
  Future<void> clearUserPreferences() async {
    // Remove authentication related data
    await remove('authToken');
    await remove('tokenExpirationTime');
    await remove('email');
    await remove('givenName');
    await remove('familyName');
    await remove('fortuneBirthDate');

    // Remove device related data
    await remove('hasMemorionDevice');
    await remove('hasOmiDevice'); // Clean up legacy key
    // Remove cached data
    await remove('cachedConversations');
    await remove('cachedMessages');
    await remove('cachedPeople');
    await remove('cachedSessions');
    await remove('modifiedConversationDetails');

    // Clear app-specific cached sessions
    await clearAllCachedSessions();

    // Remove all data caches
    await clearCache('discover_emotions');
    await clearCache('discover_categories');
    await clearCache('discover_people');
    await clearCache('discover_actions');
    await clearCache('discover_stats');
    await clearCache('usage_subscription');
    await clearCache('usage_all_time');
    await clearCache('usage_monthly');
    await clearCache('memories_list');
    await clearCache('memories_pending');
    await clearCache('insights_list');
    for (final key in ['memories_list', 'insights_list', 'discover_actions']) {
      await clearCache('${key}_fetched_at');
    }
    await clearCache('moments_list');
    // 日记列表的「上次拉取时刻」。⚠️ 必须跟着 moments_list 一起清：它是新鲜度
    // 判定的唯一依据，留着的话下一个账号进日记 tab 会被判成「缓存还新鲜」而
    // 一次请求都不发，界面停在空态直到时间戳过期。
    await remove('moments_list_fetched_at');
    // 章节缓存里有摘要正文（后端二次归纳的结果），不能留给下一个登录的用户。
    // key 与 TimelineProvider._cacheKey 一致。
    await clearCache('timeline_days_v1');

    // Remove Twitter connection data
    await remove('twitterProfile');
    await remove('twitterTimeline');

    // Remove calendar data
    await remove('calendarEnabled');
    await remove('calendarId');
    await remove('calendarType2');
    await remove('calendarLastSyncedAt');
    await remove('calendarLastSyncFingerprint');
    await remove('calendarAiConsentGranted');

    // User Primary language
    await remove('userPrimaryLanguage');
    await remove('hasSetPrimaryLanguage');

    // User Timezone
    await remove('userTimezone');
    await remove('hasSetTimezone');

    // Keep settings like language, analytics opt-in, etc.
    // as these are user preferences that should persist across logins
  }
}
