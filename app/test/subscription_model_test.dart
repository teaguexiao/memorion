import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/models/subscription.dart';
import 'package:memorion/utils/subscription_test_mode.dart';

Map<String, dynamic> _oldBackendPayload({required String plan}) => {
      'subscription': {
        'plan': plan,
        'status': 'active',
        'features': <String>[],
        'cancel_at_period_end': false,
      },
      'transcription_seconds_used': 0,
      'transcription_seconds_limit': 0,
      'words_transcribed_used': 0,
      'words_transcribed_limit': 0,
      'insights_gained_used': 0,
      'insights_gained_limit': 0,
      'memories_created_used': 0,
      'memories_created_limit': 0,
      'available_plans': <dynamic>[],
      'show_subscription_ui': false,
    };

void main() {
  test('old backend unlimited response preserves legacy unlimited access', () {
    final response = UserSubscriptionResponse.fromJson(
      _oldBackendPayload(plan: 'unlimited'),
    );

    expect(response.accessLevel, AccessLevel.legacyUnlimited);
    expect(response.isLegacy, isTrue);
    expect(response.canPurchase, isFalse);
    expect(response.showSubscriptionUi, isTrue);
  });

  test('debug Starter override is explicit and can transition to Pro', () {
    final legacy = UserSubscriptionResponse.fromJson(
      _oldBackendPayload(plan: 'unlimited'),
    );

    expect(
      SubscriptionTestMode.apply(legacy, enabled: false),
      same(legacy),
    );

    final starter = SubscriptionTestMode.apply(
      legacy,
      enabled: true,
      purchaseCompleted: false,
    );
    expect(starter.accessLevel, AccessLevel.starter);
    expect(starter.canPurchase, isTrue);

    final pro = SubscriptionTestMode.apply(
      legacy,
      enabled: true,
      purchaseCompleted: true,
    );
    expect(pro.accessLevel, AccessLevel.pro);
    expect(pro.canPurchase, isFalse);
  });
}
