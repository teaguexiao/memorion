import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/models/subscription.dart';
import 'package:memorion/pages/today_chapters/subscription_page.dart';
import 'package:memorion/providers/purchase_provider.dart';
import 'package:memorion/providers/usage_provider.dart';
import 'package:provider/provider.dart';

class _NoopPurchaseClient implements PurchaseClient {
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

class _PageUsageProvider extends UsageProvider {
  _PageUsageProvider(this.value);

  final UserSubscriptionResponse value;

  @override
  UserSubscriptionResponse get subscription => value;

  @override
  bool get isLoading => false;

  @override
  Future<void> fetchSubscription() async {}
}

class _PagePurchaseProvider extends PurchaseProvider {
  _PagePurchaseProvider({
    this.available = true,
    this.message,
    this.items = const [],
  }) : super(store: _NoopPurchaseClient(), isIOS: true);

  final bool available;
  final String? message;
  final List<ProductDetails> items;
  int loadCount = 0;

  @override
  bool get storeAvailable => available;

  @override
  bool get loading => false;

  @override
  bool get purchasePending => false;

  @override
  String? get error => message;

  @override
  List<ProductDetails> get products => items;

  @override
  ProductDetails? product(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<void> loadProducts() async {
    loadCount += 1;
  }
}

UserSubscriptionResponse _subscription(
  AccessLevel accessLevel, {
  bool canPurchase = false,
  bool isLegacy = false,
  int? trialDaysRemaining,
}) =>
    UserSubscriptionResponse(
      subscription: Subscription(
        plan: accessLevel == AccessLevel.pro || accessLevel == AccessLevel.legacyUnlimited
            ? PlanType.unlimited
            : PlanType.basic,
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
      accessLevel: accessLevel,
      canPurchase: canPurchase,
      isLegacy: isLegacy,
      trialDaysRemaining: trialDaysRemaining,
    );

final _products = [
  ProductDetails(
    id: PurchaseProvider.monthlyProductId,
    title: 'Monthly',
    description: 'Monthly subscription',
    price: r'$14.99',
    rawPrice: 14.99,
    currencyCode: 'USD',
  ),
  ProductDetails(
    id: PurchaseProvider.annualProductId,
    title: 'Annual',
    description: 'Annual subscription',
    price: r'$149.99',
    rawPrice: 149.99,
    currencyCode: 'USD',
  ),
];

Future<_PagePurchaseProvider> _pumpPage(
  WidgetTester tester,
  UserSubscriptionResponse subscription, {
  bool storeAvailable = true,
  String? error,
  List<ProductDetails> products = const [],
}) async {
  final purchases = _PagePurchaseProvider(
    available: storeAvailable,
    message: error,
    items: products,
  );
  await tester.pumpWidget(
    MultiProvider(
      key: UniqueKey(),
      providers: [
        ChangeNotifierProvider<UsageProvider>(
          create: (_) => _PageUsageProvider(subscription),
        ),
        ChangeNotifierProvider<PurchaseProvider>.value(value: purchases),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: SubscriptionPage(),
      ),
    ),
  );
  await tester.pump();
  return purchases;
}

void main() {
  testWidgets('Starter shows localized products, restore, and legal links', (tester) async {
    await _pumpPage(
      tester,
      _subscription(AccessLevel.starter, canPurchase: true),
      products: _products,
    );

    expect(find.text('Starter 免费版'), findsWidgets);
    expect(find.text('不限量本机离线转录'), findsOneWidget);
    expect(find.text('每月 5 小时云端转录'), findsOneWidget);
    expect(find.text('为额度内录音生成 AI 洞察与记忆'), findsOneWidget);
    expect(find.text('当前权益'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('无限云端转录'), 250);
    expect(find.text('无限云端转录'), findsOneWidget);
    // The expanded comparison cards push purchase options outside ListView's
    // initial build window, so advance the viewport before locating prices.
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text(r'$149.99'), findsOneWidget);
    expect(find.text(r'$14.99'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('服务条款'), 300);
    expect(find.text('恢复购买'), findsOneWidget);
    expect(find.text('服务条款'), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
  });

  testWidgets('unavailable App Store hides hard-coded prices and offers retry', (tester) async {
    final purchases = await _pumpPage(
      tester,
      _subscription(AccessLevel.starter, canPurchase: true),
      storeAvailable: false,
      error: 'store unavailable',
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.text('价格暂不可用'), findsNWidgets(2));
    expect(find.text(r'$149.99'), findsNothing);
    expect(find.text(r'$14.99'), findsNothing);
    expect(find.text('暂时无法获取 App Store 价格。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    final restore = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '恢复购买'),
    );
    expect(restore.onPressed, isNull);

    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(purchases.loadCount, 2);
  });

  testWidgets('legacy unlimited never exposes purchase or restore controls', (tester) async {
    await _pumpPage(
      tester,
      _subscription(
        AccessLevel.legacyUnlimited,
        isLegacy: true,
      ),
    );

    expect(find.text('老用户无限权益'), findsOneWidget);
    expect(find.text('选择 Pro'), findsNothing);
    expect(find.text('恢复购买'), findsNothing);
  });

  testWidgets('Founding trial explains the purchase timing correctly', (tester) async {
    await _pumpPage(
      tester,
      _subscription(
        AccessLevel.foundingTrial,
        trialDaysRemaining: 45,
      ),
    );

    expect(find.text('Founding Pro 体验'), findsOneWidget);
    expect(find.text('还剩 45 天'), findsOneWidget);
    expect(find.text('订阅选项会在体验期最后 14 天出现。'), findsOneWidget);
    expect(find.text('选择 Pro'), findsNothing);

    await _pumpPage(
      tester,
      _subscription(
        AccessLevel.foundingTrial,
        canPurchase: true,
        trialDaysRemaining: 10,
      ),
      products: _products,
    );

    expect(find.text('现在购买会立即开始由 Apple 计费。'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('选择 Pro'), 300);
    expect(find.text('选择 Pro'), findsOneWidget);
  });

  testWidgets('active Pro shows Apple management and restore controls', (tester) async {
    await _pumpPage(
      tester,
      _subscription(AccessLevel.pro),
      products: _products,
    );

    expect(find.text('Memorion Pro'), findsWidgets);
    await tester.scrollUntilVisible(find.text('无限 AI 洞察与记忆'), 250);
    await tester.scrollUntilVisible(find.text('在 Apple 中管理订阅'), 300);
    expect(find.text('包含 Starter 全部权益'), findsOneWidget);
    expect(find.text('无限 AI 洞察与记忆'), findsOneWidget);
    expect(find.text('当前权益'), findsOneWidget);
    expect(find.text('在 Apple 中管理订阅'), findsOneWidget);
    expect(find.text('恢复购买'), findsOneWidget);
    expect(find.text('选择 Pro'), findsNothing);
  });
}
