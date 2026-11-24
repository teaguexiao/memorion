import 'package:memorion/env/dev_env.dart';

abstract class Env {
  static late final EnvFields _instance;

  static void init([EnvFields? instance]) {
    _instance = instance ?? DevEnv() as EnvFields;
  }

  static String? get openAIAPIKey => _instance.openAIAPIKey;

  static String? get instabugApiKey => _instance.instabugApiKey;

  static String? get mixpanelProjectToken => _instance.mixpanelProjectToken;

  static String? get apiBaseUrl => _normalizeApiBaseUrl(_instance.apiBaseUrl);

  static String? get growthbookApiKey => _instance.growthbookApiKey;

  static String? get googleMapsApiKey => _instance.googleMapsApiKey;

  static String? get posthogApiKey => _instance.posthogApiKey;

  static String? get googleClientId => _instance.googleClientId;

  static String? get googleClientSecret => _instance.googleClientSecret;


  static String? get externalUserId => _instance.externalUserId;

  static String? _normalizeApiBaseUrl(String? value) {
    if (value == null) return null;
    final normalized = value
        .replaceFirst('https://api2.memorion.me/', 'https://api.memorion.me/')
        .replaceFirst('https://api2.memorion.me', 'https://api.memorion.me');

    if (normalized == 'https://api.memorion.me') {
      return 'https://api.memorion.me/';
    }
    return normalized;
  }
}

abstract class EnvFields {
  String? get openAIAPIKey;

  String? get instabugApiKey;

  String? get mixpanelProjectToken;

  String? get apiBaseUrl;

  String? get growthbookApiKey;

  String? get googleMapsApiKey;

  String? get posthogApiKey;

  String? get googleClientId;

  String? get googleClientSecret;


  String? get externalUserId;
}
