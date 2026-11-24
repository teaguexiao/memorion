import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('subscription flow uses Apple IAP and keeps usage details off the page', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final provider = File('lib/providers/purchase_provider.dart').readAsStringSync();
    final page = File('lib/pages/today_chapters/subscription_page.dart').readAsStringSync();
    final settings = File('lib/pages/today_chapters/settings_page.dart').readAsStringSync();

    expect(pubspec, contains('in_app_purchase:'));
    expect(provider, contains('me.memorion.pro.monthly'));
    expect(provider, contains('me.memorion.pro.annual'));
    expect(provider, contains('verificationData.serverVerificationData'));
    expect(provider, contains('completePurchase'));
    expect(provider, contains('restorePurchases'));
    expect(settings, contains('SubscriptionPage'));

    expect(page, contains('90 days of Pro included'));
    expect(page, contains('No payment method and no automatic charge.'));
    expect(page, contains('Legacy Unlimited'));
    expect(page, isNot(contains('transcriptionSecondsUsed')));
    expect(page, isNot(contains('minutes used')));
    expect(page, isNot(contains('Stripe')));
  });
}
