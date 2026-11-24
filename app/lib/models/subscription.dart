import 'package:json_annotation/json_annotation.dart';

part 'subscription.g.dart';

enum PlanType {
  basic,
  unlimited,
}

enum SubscriptionStatus {
  active,
  inactive,
}

enum AccessLevel {
  legacyUnlimited,
  trialAvailable,
  foundingTrial,
  pro,
  starter,
}

@JsonSerializable(fieldRename: FieldRename.snake)
class Subscription {
  final PlanType plan;
  final SubscriptionStatus status;
  final int? currentPeriodEnd;
  @JsonKey(defaultValue: [])
  final List<String> features;
  @JsonKey(defaultValue: false)
  final bool cancelAtPeriodEnd;

  Subscription({
    required this.plan,
    required this.status,
    this.currentPeriodEnd,
    this.features = const [],
    this.cancelAtPeriodEnd = false,
  });

  factory Subscription.fromJson(Map<String, dynamic> json) => _$SubscriptionFromJson(json);
  Map<String, dynamic> toJson() => _$SubscriptionToJson(this);
}

@JsonSerializable(fieldRename: FieldRename.snake)
class PricingOption {
  final String id;
  final String title;
  final String? description;
  final String priceString;

  PricingOption({
    required this.id,
    required this.title,
    this.description,
    required this.priceString,
  });

  factory PricingOption.fromJson(Map<String, dynamic> json) => _$PricingOptionFromJson(json);
  Map<String, dynamic> toJson() => _$PricingOptionToJson(this);
}

@JsonSerializable(fieldRename: FieldRename.snake)
class SubscriptionPlan {
  final String id;
  final String title;
  @JsonKey(defaultValue: [])
  final List<String> features;
  @JsonKey(defaultValue: [])
  final List<PricingOption> prices;

  SubscriptionPlan({
    required this.id,
    required this.title,
    this.features = const [],
    this.prices = const [],
  });

  factory SubscriptionPlan.fromJson(Map<String, dynamic> json) => _$SubscriptionPlanFromJson(json);
  Map<String, dynamic> toJson() => _$SubscriptionPlanToJson(this);
}

@JsonSerializable(fieldRename: FieldRename.snake)
class UserSubscriptionResponse {
  final Subscription subscription;
  final int transcriptionSecondsUsed;
  final int transcriptionSecondsLimit;
  final int wordsTranscribedUsed;
  final int wordsTranscribedLimit;
  final int insightsGainedUsed;
  final int insightsGainedLimit;
  final int memoriesCreatedUsed;
  final int memoriesCreatedLimit;
  @JsonKey(defaultValue: 18000)
  final int starterTranscriptionSecondsLimit;
  @JsonKey(defaultValue: [])
  final List<SubscriptionPlan> availablePlans;
  @JsonKey(defaultValue: false)
  final bool showSubscriptionUi;
  @JsonKey(defaultValue: AccessLevel.starter)
  final AccessLevel accessLevel;
  final int? trialEndsAt;
  final int? trialDaysRemaining;
  @JsonKey(defaultValue: false)
  final bool isLegacy;
  @JsonKey(defaultValue: false)
  final bool canPurchase;

  UserSubscriptionResponse({
    required this.subscription,
    required this.transcriptionSecondsUsed,
    required this.transcriptionSecondsLimit,
    required this.wordsTranscribedUsed,
    required this.wordsTranscribedLimit,
    required this.insightsGainedUsed,
    required this.insightsGainedLimit,
    required this.memoriesCreatedUsed,
    required this.memoriesCreatedLimit,
    this.starterTranscriptionSecondsLimit = 18000,
    this.availablePlans = const [],
    this.showSubscriptionUi = true,
    this.accessLevel = AccessLevel.starter,
    this.trialEndsAt,
    this.trialDaysRemaining,
    this.isLegacy = false,
    this.canPurchase = false,
  });

  factory UserSubscriptionResponse.fromJson(Map<String, dynamic> json) {
    final normalized = Map<String, dynamic>.from(json);
    if (!normalized.containsKey('access_level')) {
      final subscription = normalized['subscription'];
      final plan = subscription is Map<String, dynamic> ? subscription['plan'] : null;
      if (plan == 'unlimited') {
        normalized['access_level'] = 'legacy_unlimited';
        normalized['is_legacy'] = true;
        normalized['can_purchase'] = false;
        normalized['show_subscription_ui'] = true;
      }
    }
    return _$UserSubscriptionResponseFromJson(normalized);
  }
  Map<String, dynamic> toJson() => _$UserSubscriptionResponseToJson(this);
}
