import 'dart:async';

/// Registers the current device after APNs and authentication are ready. A token
/// refresh listener is installed before the first attempt, even if it fails.
class FcmTokenRegistration {
  FcmTokenRegistration({
    required this.currentAccount,
    required this.isReady,
    required this.getToken,
    required this.uploadToken,
    required this.tokenRefresh,
    required this.log,
    this.retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
      Duration(seconds: 60),
      Duration(seconds: 60),
    ],
  });

  final String? Function() currentAccount;
  final Future<bool> Function() isReady;
  final Future<String?> Function() getToken;
  final Future<void> Function(String token, String account) uploadToken;
  final Stream<String> tokenRefresh;
  final void Function(String message) log;
  final List<Duration> retryDelays;

  StreamSubscription<String>? _subscription;
  Timer? _retry;
  Future<void>? _inFlight;
  int _failures = 0;
  int _refreshVersion = 0;
  bool _disposed = false;

  void start() {
    if (_disposed || _subscription != null) return;
    _subscription = tokenRefresh.listen((_) {
      _refreshVersion++;
      unawaited(register());
    }, onError: (Object error) {
      log('[FCM] token refresh failed (${error.runtimeType})');
      unawaited(register());
    });
  }

  /// Startup, login and foreground entry each get a new bounded retry budget.
  Future<void> register() {
    if (_disposed) return Future.value();
    start();
    _failures = 0;
    _retry?.cancel();
    return _attempt();
  }

  Future<void> _attempt() {
    if (_disposed) return Future.value();
    if (_inFlight != null) return _inFlight!;
    final account = currentAccount();
    if (account == null) return Future.value();
    final refreshVersion = _refreshVersion;
    // Assign the future before any injected callback can complete or reenter.
    _inFlight = Future<void>.value().then((_) async {
      try {
        if (!await isReady().timeout(const Duration(seconds: 10))) {
          log('[FCM] registration pending: APNs not ready');
          _scheduleRetry();
          return;
        }
        log('[FCM] push transport ready');
        final token = await getToken().timeout(const Duration(seconds: 10));
        if (token == null || token.isEmpty) throw StateError('FCM token unavailable');
        // Never upload a token obtained for a previous login to a new account.
        if (_disposed || currentAccount() != account) return;
        await uploadToken(token, account).timeout(const Duration(seconds: 15));
        log('[FCM] registration synchronized');
        _failures = 0;
      } catch (error) {
        log('[FCM] registration failed (${error.runtimeType})');
        _scheduleRetry();
      } finally {
        _inFlight = null;
        if (!_disposed && (refreshVersion != _refreshVersion || currentAccount() != account)) {
          unawaited(register());
        }
      }
    });
    return _inFlight!;
  }

  void _scheduleRetry() {
    if (_disposed || currentAccount() == null || _failures >= retryDelays.length) return;
    _retry?.cancel();
    _retry = Timer(retryDelays[_failures++], () => unawaited(_attempt()));
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    unawaited(_subscription?.cancel());
  }
}
