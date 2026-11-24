import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/models/subscription.dart';
import 'package:memorion/providers/usage_provider.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/services/watch_recording_service.dart';
import 'package:memorion/utils/subscription_test_mode.dart';

typedef PurchaseVerifier = Future<bool> Function({
  required String transactionId,
  required String productId,
  required String signedTransaction,
});
typedef SoundcoreUploadResumer = Future<bool> Function();

Future<bool> _resumeSoundcoreUploadsWithServices() async {
  final resumed = await ServiceManager.instance().soundcoreSync.resumeAfterSubscriptionUpgrade();
  unawaited(ServiceManager.instance().ringSync.resumeAfterSubscriptionUpgrade().catchError((Object error) {
    debugPrint('Ring subscription resume failed: $error');
  }));
  return resumed;
}

Future<bool> _verifyPurchaseWithBackend({
  required String transactionId,
  required String productId,
  required String signedTransaction,
}) async {
  final response = await verifyAppleSubscription(
    transactionId: transactionId,
    productId: productId,
    signedTransaction: signedTransaction,
  );
  return response != null;
}

abstract class PurchaseClient {
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<bool> isAvailable();
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers);
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam});
  Future<void> restorePurchases();
  Future<void> completePurchase(PurchaseDetails purchase);
}

class AppStorePurchaseClient implements PurchaseClient {
  final InAppPurchase _store = InAppPurchase.instance;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _store.purchaseStream;

  @override
  Future<bool> isAvailable() => _store.isAvailable();

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) =>
      _store.queryProductDetails(identifiers);

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) =>
      _store.buyNonConsumable(purchaseParam: purchaseParam);

  @override
  Future<void> restorePurchases() => _store.restorePurchases();

  @override
  Future<void> completePurchase(PurchaseDetails purchase) => _store.completePurchase(purchase);
}

class PurchaseProvider with ChangeNotifier {
  static const monthlyProductId = 'me.memorion.pro.monthly';
  static const annualProductId = 'me.memorion.pro.annual';
  static const productIds = {monthlyProductId, annualProductId};
  static const _cloudResumeRetryDelays = [
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 2),
  ];

  final PurchaseClient _store;
  final PurchaseVerifier _verifyPurchase;
  final bool _isIOS;
  final bool _localStoreKitTestEnabled;
  final SoundcoreUploadResumer _resumeSoundcoreUploads;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  UsageProvider? _usageProvider;
  bool _watchResumePending = false;
  bool _cloudResumeInFlight = false;
  int _cloudResumeAttempts = 0;
  int _authResumeAttempts = 0;
  Timer? _watchResumeRetryTimer;
  String? _proReconciledUser;

  bool _initialized = false;
  bool _storeAvailable = false;
  bool _loading = false;
  bool _purchasePending = false;
  String? _error;
  List<ProductDetails> _products = const [];

  PurchaseProvider({
    PurchaseClient? store,
    PurchaseVerifier? verifyPurchase,
    bool? isIOS,
    bool? localStoreKitTestEnabled,
    SoundcoreUploadResumer? resumeSoundcoreUploads,
  })  : _store = store ?? AppStorePurchaseClient(),
        _verifyPurchase = verifyPurchase ?? _verifyPurchaseWithBackend,
        _isIOS = isIOS ?? Platform.isIOS,
        _resumeSoundcoreUploads = resumeSoundcoreUploads ?? _resumeSoundcoreUploadsWithServices,
        _localStoreKitTestEnabled =
            kDebugMode && (localStoreKitTestEnabled ?? SubscriptionTestMode.localStoreKitEnabled);

  bool get storeAvailable => _storeAvailable;
  bool get loading => _loading;
  bool get purchasePending => _purchasePending;
  String? get error => _error;
  List<ProductDetails> get products => List.unmodifiable(_products);

  void setUsageProvider(UsageProvider provider) {
    _usageProvider = provider;
    // The purchase stream can replay a restored transaction before Firebase/API
    // authentication has populated the external user id. Keep the wake-up
    // pending and retry when the UsageProvider proxy updates after sign-in.
    final subscription = provider.subscription;
    if (subscription?.accessLevel == AccessLevel.pro && _hasAuthenticatedUser()) {
      final user = getExternalUserId();
      if (_proReconciledUser != user && !_watchResumePending && !_cloudResumeInFlight) {
        _watchResumePending = true;
        _cloudResumeAttempts = 0;
        _authResumeAttempts = 0;
      }
    }
    if (_watchResumePending &&
        _hasAuthenticatedUser() &&
        !_cloudResumeInFlight &&
        _watchResumeRetryTimer == null &&
        _cloudResumeAttempts <= _cloudResumeRetryDelays.length) {
      unawaited(_resumeWatchUploadsAfterPurchase());
    }
  }

  ProductDetails? product(String id) {
    for (final item in _products) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!_isIOS) return;

    _purchaseSubscription = _store.purchaseStream.listen(
      _handlePurchaseUpdates,
      onError: (Object error) {
        _error = error.toString();
        _purchasePending = false;
        notifyListeners();
      },
    );
    await loadProducts();
  }

  Future<void> loadProducts() async {
    if (!_isIOS || _loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _storeAvailable = await _store.isAvailable();
      if (!_storeAvailable) {
        _products = const [];
        _error = 'The App Store is unavailable right now.';
        return;
      }
      final response = await _store.queryProductDetails(productIds);
      _products = response.productDetails..sort((a, b) => a.rawPrice.compareTo(b.rawPrice));
      if (response.error != null) {
        _error = response.error!.message;
      } else if (response.notFoundIDs.isNotEmpty) {
        _error = 'Subscription products are not available yet.';
      }
    } catch (error) {
      _error = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> buy(String productId) async {
    final details = product(productId);
    if (details == null || _purchasePending) return false;
    _purchasePending = true;
    _error = null;
    notifyListeners();
    try {
      final started = await _store.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: details),
      );
      if (!started) {
        _purchasePending = false;
        _error = 'The App Store could not start this purchase.';
        notifyListeners();
      }
      return started;
    } catch (error) {
      _purchasePending = false;
      _error = error.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> restore() async {
    if (!_storeAvailable || _purchasePending) return;
    _purchasePending = true;
    _error = null;
    notifyListeners();
    try {
      await _store.restorePurchases();
      if (_purchasePending) {
        _purchasePending = false;
        notifyListeners();
      }
    } catch (error) {
      _purchasePending = false;
      _error = error.toString();
      notifyListeners();
    }
  }

  Future<void> _handlePurchaseUpdates(List<PurchaseDetails> purchases) async {
    if (purchases.isEmpty) {
      _purchasePending = false;
      notifyListeners();
      return;
    }

    for (final purchase in purchases) {
      final signedTransaction = purchase.verificationData.serverVerificationData;
      final isLocalXcodeTransaction = _localStoreKitTestEnabled;
      switch (purchase.status) {
        case PurchaseStatus.pending:
          _purchasePending = true;
          notifyListeners();
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          _purchasePending = true;
          notifyListeners();
          var verified = false;
          if (isLocalXcodeTransaction) {
            verified = productIds.contains(purchase.productID) && signedTransaction.isNotEmpty;
            if (verified) {
              debugPrint(
                'StoreKit local test transaction received: '
                '${purchase.productID}, ${signedTransaction.length} signed bytes',
              );
            }
          } else {
            final transactionId = purchase.purchaseID;
            if (transactionId != null && transactionId.isNotEmpty) {
              verified = await _verifyPurchase(
                transactionId: transactionId,
                productId: purchase.productID,
                signedTransaction: signedTransaction,
              );
            }
          }
          if (verified) {
            SubscriptionTestMode.markLocalPurchaseCompleted();
            if (purchase.pendingCompletePurchase) {
              await _store.completePurchase(purchase);
            }
            await _usageProvider?.fetchSubscription();
            _watchResumePending = true;
            _cloudResumeAttempts = 0;
            _authResumeAttempts = 0;
            unawaited(_resumeWatchUploadsAfterPurchase());
            _error = null;
          } else {
            _error = 'Apple could not verify this purchase. Please try Restore Purchases.';
          }
          _purchasePending = false;
          notifyListeners();
          break;
        case PurchaseStatus.error:
          _error = purchase.error?.message ?? 'Purchase failed.';
          _purchasePending = false;
          notifyListeners();
          break;
        case PurchaseStatus.canceled:
          _purchasePending = false;
          notifyListeners();
          break;
      }
    }
  }

  Future<void> _resumeWatchUploadsAfterPurchase() async {
    if (!_watchResumePending || _cloudResumeInFlight || _cloudResumeAttempts > _cloudResumeRetryDelays.length) {
      return;
    }
    _cloudResumeInFlight = true;
    if (!_hasAuthenticatedUser()) {
      _authResumeAttempts++;
      _cloudResumeInFlight = false;
      _scheduleWatchResumeRetry(waitingForAuth: true);
      return;
    }
    _authResumeAttempts = 0;
    _cloudResumeAttempts++;
    _watchResumePending = false;
    try {
      await WatchRecordingService.instance.clearQuotaPause();
      final result = await WatchRecordingService.instance.syncNow(
        reason: 'subscription-upgrade', // i18n-ignore
        ignoreQuotaPause: true,
        ignoreOversizedPause: true,
      );
      final soundcoreResumed = await _resumeSoundcoreUploads();
      if (!soundcoreResumed ||
          result.outcome == WatchSyncOutcome.quotaBlocked ||
          result.outcome == WatchSyncOutcome.uploadTooLarge ||
          result.outcome == WatchSyncOutcome.retryable ||
          result.outcome == WatchSyncOutcome.notAuthenticated ||
          result.outcome == WatchSyncOutcome.busy) {
        _watchResumePending = true;
        _scheduleWatchResumeRetry();
      } else {
        _watchResumeRetryTimer?.cancel();
        _cloudResumeAttempts = 0;
        _proReconciledUser = getExternalUserId();
      }
    } catch (error) {
      _watchResumePending = true;
      _scheduleWatchResumeRetry();
      // Purchase completion must never be held hostage by this optional queue
      // wake-up. The next app launch can still retry normally.
      debugPrint('Could not resume Watch uploads after purchase: $error');
    } finally {
      _cloudResumeInFlight = false;
    }
  }

  void _scheduleWatchResumeRetry({bool waitingForAuth = false}) {
    final attempts = waitingForAuth ? _authResumeAttempts : _cloudResumeAttempts;
    if (attempts > _cloudResumeRetryDelays.length) {
      debugPrint('Cloud upload resume retry budget exhausted; next app launch will reconcile Pro access.');
      return;
    }
    _watchResumeRetryTimer?.cancel();
    _watchResumeRetryTimer = Timer(_cloudResumeRetryDelays[attempts - 1], () {
      _watchResumeRetryTimer = null;
      unawaited(_resumeWatchUploadsAfterPurchase());
    });
  }

  bool _hasAuthenticatedUser() {
    try {
      return getExternalUserId().isNotEmpty && getAuthHeader().isNotEmpty;
    } catch (_) {
      // Env/API configuration can still be uninitialized when StoreKit replays
      // restored transactions during very early startup.
      return false;
    }
  }

  @override
  void dispose() {
    _purchaseSubscription?.cancel();
    _watchResumeRetryTimer?.cancel();
    super.dispose();
  }
}
