import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/notifications/notification_deep_link.dart';

void main() {
  group('NotificationDeepLink.fromPayload', () {
    test('daily-summary push with moment_id → diaryDetail', () {
      final link = NotificationDeepLink.fromPayload({
        'navigate_to': '/moments',
        'moment_id': 'abc-123',
        'type': 'day_summary',
      });
      expect(link.target, NotificationDeepLinkTarget.diaryDetail);
      expect(link.momentId, 'abc-123');
    });

    test('old daily-summary payload (no moment_id) → homeShell fallback', () {
      final link = NotificationDeepLink.fromPayload({'navigate_to': '/moments'});
      expect(link.target, NotificationDeepLinkTarget.homeShell);
      expect(link.momentId, isNull);
    });

    test('/moments with empty moment_id → homeShell fallback', () {
      final link = NotificationDeepLink.fromPayload({
        'navigate_to': '/moments',
        'moment_id': '',
      });
      expect(link.target, NotificationDeepLinkTarget.homeShell);
    });

    test('/chat → chat', () {
      final link = NotificationDeepLink.fromPayload({'navigate_to': '/chat'});
      expect(link.target, NotificationDeepLinkTarget.chat);
    });

    test('/insights with insight_id → insightDetail', () {
      final link = NotificationDeepLink.fromPayload({
        'navigate_to': '/insights',
        'notification_type': 'insight_card',
        'insight_id': 'card-9',
      });
      expect(link.target, NotificationDeepLinkTarget.insightDetail);
      expect(link.insightId, 'card-9');
    });

    test('/insights without an ID → insight list for older pushes', () {
      for (final payload in [
        {'navigate_to': '/insights'},
        {'navigate_to': '/insights', 'insight_id': ''},
      ]) {
        expect(NotificationDeepLink.fromPayload(payload).target, NotificationDeepLinkTarget.insights);
      }
    });

    test('/mood → homeShell (legacy mood tab removed in 1.0)', () {
      final link = NotificationDeepLink.fromPayload({'navigate_to': '/mood'});
      expect(link.target, NotificationDeepLinkTarget.homeShell);
    });

    test('missing navigate_to → none', () {
      final link = NotificationDeepLink.fromPayload({'type': 'day_summary'});
      expect(link.target, NotificationDeepLinkTarget.none);
    });

    test('unknown navigate_to → homeShell (safe default, never legacy dark page)', () {
      final link = NotificationDeepLink.fromPayload({'navigate_to': '/settings/data-privacy'});
      expect(link.target, NotificationDeepLinkTarget.homeShell);
    });
  });

  group('notificationPayloadFromRemoteData', () {
    test('carries insight_id through for foreground notification taps', () {
      final payload = notificationPayloadFromRemoteData({
        'navigate_to': '/insights',
        'insight_id': 'card-9',
      });
      expect(NotificationDeepLink.fromPayload(payload).insightId, 'card-9');
    });
    // 曾经只白名单 navigate_to，moment_id 被丢掉 → 每日一刻推送点开只到首页。
    test('carries moment_id through so /moments can deep-link to the diary', () {
      final payload = notificationPayloadFromRemoteData({
        'navigate_to': '/moments',
        'moment_id': 'abc-123',
        'notification_type': 'daily_summary',
      });
      expect(payload['moment_id'], 'abc-123');
      expect(NotificationDeepLink.fromPayload(payload).target, NotificationDeepLinkTarget.diaryDetail);
    });

    test('drops non-string values (from_integration is rewritten to a bool in place)', () {
      final payload = notificationPayloadFromRemoteData({
        'navigate_to': '/chat',
        'from_integration': true,
      });
      expect(payload.containsKey('from_integration'), isFalse);
      expect(payload['navigate_to'], '/chat');
    });

    test('missing navigate_to becomes empty string (preserves legacy behavior)', () {
      final payload = notificationPayloadFromRemoteData({'type': 'day_summary'});
      expect(payload['navigate_to'], '');
    });
  });
}
