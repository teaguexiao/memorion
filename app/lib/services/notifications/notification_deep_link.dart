/// Pure routing decision for a tapped notification's payload.
///
/// Kept free of Flutter/Navigator/Provider imports so it can be unit-tested in
/// isolation. The imperative navigation lives in `NotificationUtil`.
enum NotificationDeepLinkTarget {
  /// Open the day's diary detail page (requires [NotificationDeepLink.momentId]).
  diaryDetail,

  /// Land on the light 1.0 home shell timeline.
  homeShell,

  /// Open the chat page.
  chat,

  /// Open the「你答应过的事」promises / to-do list page.
  promises,

  /// Open the「它看到的你」insight card list (PortraitDetailPage).
  insights,

  /// Open the card specified by [NotificationDeepLink.insightId].
  insightDetail,

  /// Payload carried no `navigate_to`; do nothing.
  none,
}

/// FCM `data` → `awesome_notifications` 的本地通知 payload（前台展示那条）。
///
/// 整份透传所有字符串字段，因为路由决定不止看 `navigate_to`：`/moments` 还要
/// `moment_id` 才能直达当天日记。只挑 `navigate_to` 的旧写法会让每日一刻推送静默
/// 退化成「回首页」。非字符串值（如被就地改写成 bool 的 `from_integration`）丢掉，
/// payload 只接受 `String`。
Map<String, String> notificationPayloadFromRemoteData(Map<String, dynamic> data) {
  final payload = <String, String>{};
  data.forEach((key, value) {
    if (value is String) payload[key] = value;
  });
  payload['navigate_to'] = data['navigate_to'] is String ? data['navigate_to'] as String : '';
  return payload;
}

class NotificationDeepLink {
  final NotificationDeepLinkTarget target;
  final String? momentId;
  final String? insightId;

  const NotificationDeepLink(this.target, {this.momentId, this.insightId});

  /// Maps a notification `data` payload to a routing decision.
  ///
  /// Backward-compatibility contract with the backend daily-summary push:
  /// - `navigate_to` stays `'/moments'` for both old and new payloads.
  /// - A `'/moments'` push WITH a non-empty `moment_id` deep-links to that day's
  ///   diary detail. WITHOUT one (older payloads, or non-diary /moments) it falls
  ///   back to the home shell timeline — never the legacy dark Moments list.
  static NotificationDeepLink fromPayload(Map<String, dynamic> payload) {
    final navigateTo = payload['navigate_to'] as String?;
    switch (navigateTo) {
      case '/moments':
        final id = payload['moment_id'] as String?;
        if (id != null && id.isNotEmpty) {
          return NotificationDeepLink(NotificationDeepLinkTarget.diaryDetail, momentId: id);
        }
        return const NotificationDeepLink(NotificationDeepLinkTarget.homeShell);
      case '/chat':
        return const NotificationDeepLink(NotificationDeepLinkTarget.chat);
      case '/promises':
        return const NotificationDeepLink(NotificationDeepLinkTarget.promises);
      case '/insights':
        final id = payload['insight_id'] as String?;
        if (id != null && id.isNotEmpty) {
          return NotificationDeepLink(NotificationDeepLinkTarget.insightDetail, insightId: id);
        }
        // 兼容旧推送：没有卡片 ID 时打开列表。
        return const NotificationDeepLink(NotificationDeepLinkTarget.insights);
      case '/mood':
        // Every-day-a-line push: legacy dark 4-tab (incl. the standalone "mood"
        // tab) is gone in 1.0; just return to the home shell.
        return const NotificationDeepLink(NotificationDeepLinkTarget.homeShell);
      case null:
        return const NotificationDeepLink(NotificationDeepLinkTarget.none);
      default:
        return const NotificationDeepLink(NotificationDeepLinkTarget.homeShell);
    }
  }
}
