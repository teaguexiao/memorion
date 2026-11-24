// Platform-aware notification service with conditional implementation
// FCM Implementation: Full Firebase Cloud Messaging support for push notifications
// Basic Implementation: Local notifications only (platforms without FCM support)

import 'dart:io';

import 'package:memorion/services/notifications/notification_interface.dart';
import 'package:memorion/services/notifications/notification_service_basic.dart' as basic;
import 'package:memorion/services/notifications/notification_service_fcm.dart' as fcm;

/// Factory function to create the appropriate notification service based on platform capabilities
NotificationInterface _createPlatformNotificationService() {
  if (Platform.isIOS || Platform.isAndroid) {
    return fcm.createNotificationService();
  }
  return basic.createNotificationService();
}

/// Singleton notification service instance
/// Automatically selects the correct platform-specific implementation
class NotificationService {
  static NotificationInterface? _instance;

  /// Get the singleton notification service instance
  static NotificationInterface get instance {
    _instance ??= _createPlatformNotificationService();
    return _instance!;
  }

  /// Clear the instance (useful for testing)
  static void reset() {
    _instance = null;
  }
}
