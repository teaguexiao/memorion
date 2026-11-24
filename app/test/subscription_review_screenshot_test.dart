import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:memorion/models/subscription.dart';
import 'package:memorion/pages/today_chapters/subscription_page.dart';
import 'package:memorion/providers/purchase_provider.dart';
import 'package:memorion/providers/usage_provider.dart';
import 'package:provider/provider.dart';

class _ReviewPurchaseClient implements PurchaseClient {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => const Stream.empty();

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) async =>
      ProductDetailsResponse(productDetails: const [], notFoundIDs: const []);

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async => true;

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {}

  @override
  Future<void> restorePurchases() async {}
}

class _ReviewUsageProvider extends UsageProvider {
  final UserSubscriptionResponse _reviewSubscription = UserSubscriptionResponse(
    subscription: Subscription(
      plan: PlanType.basic,
      status: SubscriptionStatus.active,
    ),
    transcriptionSecondsUsed: 0,
    transcriptionSecondsLimit: 18000,
    wordsTranscribedUsed: 0,
    wordsTranscribedLimit: 0,
    insightsGainedUsed: 0,
    insightsGainedLimit: 0,
    memoriesCreatedUsed: 0,
    memoriesCreatedLimit: 0,
    accessLevel: AccessLevel.starter,
    canPurchase: true,
  );

  @override
  UserSubscriptionResponse get subscription => _reviewSubscription;

  @override
  bool get isLoading => false;

  @override
  Future<void> fetchSubscription() async {}
}

class _ReviewPurchaseProvider extends PurchaseProvider {
  _ReviewPurchaseProvider() : super(store: _ReviewPurchaseClient());

  @override
  bool get purchasePending => false;

  @override
  String? get error => null;

  @override
  Future<void> loadProducts() async {}
}

void main() {
  testWidgets('render App Store review screenshot', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1179, 2556);
    addTearDown(tester.view.reset);

    const boundaryKey = ValueKey('subscription-review-boundary');
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<UsageProvider>(create: (_) => _ReviewUsageProvider()),
          ChangeNotifierProvider<PurchaseProvider>(create: (_) => _ReviewPurchaseProvider()),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          home: RepaintBoundary(
            key: boundaryKey,
            child: SubscriptionPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    final output = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/subscription_review.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      return file;
    });

    expect(output!.lengthSync(), greaterThan(10000));
  });
}
