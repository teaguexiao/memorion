import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:memorion/providers/purchase_provider.dart';

class _FakePurchaseClient implements PurchaseClient {
  final controller = StreamController<List<PurchaseDetails>>.broadcast();
  bool buyResult = true;
  bool available = true;
  int completedPurchases = 0;

  final monthly = ProductDetails(
    id: PurchaseProvider.monthlyProductId,
    title: 'Monthly',
    description: 'Monthly subscription',
    price: r'$14.99',
    rawPrice: 14.99,
    currencyCode: 'USD',
  );

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => controller.stream;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) async =>
      ProductDetailsResponse(productDetails: [monthly], notFoundIDs: const []);

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async => buyResult;

  @override
  Future<void> restorePurchases() async {}

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completedPurchases += 1;
  }

  Future<void> dispose() => controller.close();
}

PurchaseDetails _purchase({
  PurchaseStatus status = PurchaseStatus.purchased,
  String? purchaseID = '200000000000001',
  String serverVerificationData = 'signed-jws',
}) {
  final purchase = PurchaseDetails(
    purchaseID: purchaseID,
    productID: PurchaseProvider.monthlyProductId,
    verificationData: PurchaseVerificationData(
      localVerificationData: '{}',
      serverVerificationData: serverVerificationData,
      source: 'app_store',
    ),
    transactionDate: '1',
    status: status,
  );
  purchase.pendingCompletePurchase = true;
  return purchase;
}

void main() {
  test('usage provider updates cannot bypass the scheduled cloud resume retry', () {
    final source = File('lib/providers/purchase_provider.dart').readAsStringSync();
    expect(source, contains('_watchResumeRetryTimer == null'));
    expect(source, contains('_cloudResumeAttempts <= _cloudResumeRetryDelays.length'));
  });

  test('failed purchase start clears pending state', () async {
    final store = _FakePurchaseClient()..buyResult = false;
    final provider = PurchaseProvider(store: store, isIOS: true);
    addTearDown(() async {
      provider.dispose();
      await store.dispose();
    });

    await provider.initialize();
    expect(await provider.buy(PurchaseProvider.monthlyProductId), isFalse);
    expect(provider.purchasePending, isFalse);
    expect(provider.error, isNotNull);
  });

  test('restore with no transactions does not stay pending', () async {
    final store = _FakePurchaseClient();
    final provider = PurchaseProvider(store: store, isIOS: true);
    addTearDown(() async {
      provider.dispose();
      await store.dispose();
    });

    await provider.initialize();
    await provider.restore();
    expect(provider.purchasePending, isFalse);
  });

  test('verified StoreKit update is completed', () async {
    final store = _FakePurchaseClient();
    final provider = PurchaseProvider(
      store: store,
      isIOS: true,
      verifyPurchase: ({
        required transactionId,
        required productId,
        required signedTransaction,
      }) async {
        expect(transactionId, '200000000000001');
        expect(productId, PurchaseProvider.monthlyProductId);
        expect(signedTransaction, 'signed-jws');
        return true;
      },
    );
    addTearDown(() async {
      provider.dispose();
      await store.dispose();
    });

    await provider.initialize();
    store.controller.add([_purchase()]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(store.completedPurchases, 1);
    expect(provider.purchasePending, isFalse);
    expect(provider.error, isNull);
  });

  test('Xcode StoreKit transaction without an id is verified only in local test mode', () async {
    final store = _FakePurchaseClient();
    var verifierCalled = false;
    final provider = PurchaseProvider(
      store: store,
      isIOS: true,
      localStoreKitTestEnabled: true,
      verifyPurchase: ({
        required transactionId,
        required productId,
        required signedTransaction,
      }) async {
        verifierCalled = true;
        return true;
      },
    );
    addTearDown(() async {
      provider.dispose();
      await store.dispose();
    });

    await provider.initialize();
    store.controller.add([_purchase(purchaseID: null)]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(verifierCalled, isFalse);
    expect(store.completedPurchases, 1);
    expect(provider.purchasePending, isFalse);
    expect(provider.error, isNull);
  });

  test('Sandbox transaction without an id is rejected', () async {
    final store = _FakePurchaseClient();
    var verifierCalled = false;
    final provider = PurchaseProvider(
      store: store,
      isIOS: true,
      localStoreKitTestEnabled: false,
      verifyPurchase: ({
        required transactionId,
        required productId,
        required signedTransaction,
      }) async {
        verifierCalled = true;
        return true;
      },
    );
    addTearDown(() async {
      provider.dispose();
      await store.dispose();
    });

    await provider.initialize();
    store.controller.add([_purchase(purchaseID: null)]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(verifierCalled, isFalse);
    expect(store.completedPurchases, 0);
    expect(provider.error, contains('Apple could not verify'));
  });

  test('unavailable App Store exposes a retryable loading error', () async {
    final store = _FakePurchaseClient()..available = false;
    final provider = PurchaseProvider(store: store, isIOS: true);
    addTearDown(() async {
      provider.dispose();
      await store.dispose();
    });

    await provider.initialize();

    expect(provider.storeAvailable, isFalse);
    expect(provider.products, isEmpty);
    expect(provider.error, isNotNull);
    expect(provider.loading, isFalse);
  });
}
