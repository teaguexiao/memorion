import 'package:memorion/backend/preferences.dart';
import 'package:memorion/env/env.dart';

/// Unified API configuration manager
/// Provides a single source of truth for API credentials
/// Priority: bound key > explicitly configured key
///
/// After Firebase Auth login, Firebase UID is automatically set as externalUserId
class ApiConfig {
  static final ApiConfig _instance = ApiConfig._internal();
  factory ApiConfig() => _instance;
  ApiConfig._internal();

  /// Prefer the key exchanged for the currently signed-in Firebase user.
  /// A self-hosted client may explicitly configure an API key via [save].
  String get apiKey {
    if (usingBoundKey) return SharedPreferencesUtil().boundApiKey;
    return SharedPreferencesUtil().memorionApiKey;
  }

  bool get usingBoundKey {
    final bound = SharedPreferencesUtil().boundApiKey;
    return bound.isNotEmpty && SharedPreferencesUtil().boundApiKeyUid == externalUserId;
  }

  /// 保存登录换来的 bound key。uid 一并记下，用于校验归属。
  void saveBoundKey(String key, String uid) {
    if (key.isEmpty || uid.isEmpty) return;
    SharedPreferencesUtil().boundApiKey = key;
    SharedPreferencesUtil().boundApiKeyUid = uid;
  }

  /// 清掉当前用户的 bound key。登出和删号时调用。
  void clearBoundKey() {
    SharedPreferencesUtil().boundApiKey = '';
    SharedPreferencesUtil().boundApiKeyUid = '';
  }

  /// Get External User ID (SharedPreferences > Env)
  /// After Firebase login, this is automatically set to Firebase UID
  String get externalUserId {
    final stored = SharedPreferencesUtil().externalUserId;
    if (stored.isNotEmpty) return stored;
    return Env.externalUserId ?? '';
  }

  /// Check if API credentials are configured
  bool get isConfigured => apiKey.isNotEmpty && externalUserId.isNotEmpty;

  /// Save API configuration to SharedPreferences
  void save(String apiKey, String userId) {
    SharedPreferencesUtil().memorionApiKey = apiKey;
    SharedPreferencesUtil().externalUserId = userId;
  }

  /// Set external_user_id from Firebase UID after login
  /// This bridges Firebase Auth with Memorion Developer API
  void setExternalUserIdFromFirebase(String uid) {
    if (uid.isNotEmpty) {
      SharedPreferencesUtil().externalUserId = uid;
    }
  }

  /// Clear API configuration from SharedPreferences
  void clear() {
    SharedPreferencesUtil().memorionApiKey = '';
    SharedPreferencesUtil().externalUserId = '';
    clearBoundKey();
  }

  /// Initialize from Env if SharedPreferences is empty
  void initializeFromEnv() {
    if (SharedPreferencesUtil().externalUserId.isEmpty &&
        (Env.externalUserId?.isNotEmpty ?? false)) {
      SharedPreferencesUtil().externalUserId = Env.externalUserId!;
    }
  }
}
