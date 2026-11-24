import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:memorion/models/subscription.dart';

/// Debug-only launch arguments used for simulator StoreKit testing.
///
/// These switches are ignored in profile and release builds:
/// - `--subscription-test-starter` exposes the purchasable Starter state.
/// - `--storekit-local-test` accepts Xcode's locally signed StoreKit transaction.
class SubscriptionTestMode {
  static const starterArgument = '--subscription-test-starter';
  static const localStoreKitArgument = '--storekit-local-test';
  static const starterEnvironment = 'MEMORION_SUBSCRIPTION_TEST_STARTER';
  static const localStoreKitEnvironment = 'MEMORION_STOREKIT_LOCAL_TEST';
  static const _starterDefine = bool.fromEnvironment(
    starterEnvironment,
  );
  static const _localStoreKitDefine = bool.fromEnvironment(
    localStoreKitEnvironment,
  );

  static bool _localPurchaseCompleted = false;

  static bool get starterEnabled =>
      kDebugMode &&
      (_starterDefine ||
          _isEnabled(
            argument: starterArgument,
            environment: starterEnvironment,
          ));

  static bool get localStoreKitEnabled =>
      kDebugMode &&
      (_localStoreKitDefine ||
          _isEnabled(
            argument: localStoreKitArgument,
            environment: localStoreKitEnvironment,
          ));

  static bool _isEnabled({
    required String argument,
    required String environment,
  }) =>
      Platform.executableArguments.contains(argument) || Platform.environment[environment] == '1';

  static void markLocalPurchaseCompleted() {
    if (localStoreKitEnabled) {
      _localPurchaseCompleted = true;
    }
  }

  static UserSubscriptionResponse apply(
    UserSubscriptionResponse response, {
    bool? enabled,
    bool? purchaseCompleted,
  }) {
    final isPro = purchaseCompleted ?? _localPurchaseCompleted;
    final shouldOverride = enabled ?? (starterEnabled || isPro);
    if (!shouldOverride) return response;

    return UserSubscriptionResponse(
      subscription: Subscription(
        plan: isPro ? PlanType.unlimited : PlanType.basic,
        status: SubscriptionStatus.active,
      ),
      transcriptionSecondsUsed: 0,
      transcriptionSecondsLimit: isPro ? 0 : 18000,
      wordsTranscribedUsed: 0,
      wordsTranscribedLimit: 0,
      insightsGainedUsed: 0,
      insightsGainedLimit: 0,
      memoriesCreatedUsed: 0,
      memoriesCreatedLimit: 0,
      availablePlans: response.availablePlans,
      showSubscriptionUi: true,
      accessLevel: isPro ? AccessLevel.pro : AccessLevel.starter,
      isLegacy: false,
      canPurchase: !isPro,
    );
  }
}
