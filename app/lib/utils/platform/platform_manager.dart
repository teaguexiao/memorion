import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:memorion/utils/debugging/instabug_manager.dart';
import 'package:memorion/utils/platform/platform_service.dart';

/// Centralized platform manager for all platform-specific services
/// This provides a single point of access for all platform services
class PlatformManager {
  static final PlatformManager _instance = PlatformManager._internal();

  factory PlatformManager() => _instance;
  PlatformManager._internal();

  static PlatformManager get instance => _instance;

  // Service instances
  MixpanelManager get mixpanel => MixpanelManager();
  InstabugManager get instabug => InstabugManager.instance;

  /// Initialize all platform services
  static Future<void> initializeServices() async {
    await MixpanelManager.init();
    // Note: Instabug initialization is handled separately in main.dart
    // due to its specific initialization requirements
  }

  /// Check if analytics services are supported on current platform
  bool get isAnalyticsSupported => PlatformService.isAnalyticsSupported;

  /// Check if debugging services are supported on current platform
  bool get isDebuggingSupported => PlatformService.isInstabugSupported;
}
