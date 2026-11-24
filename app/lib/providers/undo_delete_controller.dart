import 'dart:async';
import 'package:flutter/foundation.dart';

enum DeleteKind { chapter, fact, contact, promise, recording }

/// A UI deletion reservation. The destructive operation only runs after Undo
/// expires; the original model remains authoritative until the server succeeds.
class UndoDeletion {
  final String key;
  final DeleteKind kind;
  final String title;
  final Set<String> hiddenKeys;
  final Future<bool> Function() commit;
  final VoidCallback? cancel;
  final VoidCallback? settled;
  // Index-addressed action items must be popped from highest to lowest.
  final int order;
  UndoDeletion(
      {required this.key,
      required this.kind,
      required this.title,
      required this.commit,
      Set<String>? hiddenKeys,
      this.cancel,
      this.settled,
      this.order = 0})
      : hiddenKeys = hiddenKeys ?? {key};
}

class UndoDeleteController extends ChangeNotifier {
  static const window = Duration(seconds: 6);
  final String Function() account;
  UndoDeleteController({String Function()? account}) : account = account ?? (() => '');
  final List<UndoDeletion> _pending = [];
  final List<UndoDeletion> _committing = [];
  final Set<Object> _pauses = {};
  Timer? _timer;
  Duration _remaining = window;
  String? _owner;
  bool _disposed = false;
  final Set<UndoDeletion> _active = {};
  bool failed = false;
  bool modalVisible = false;
  bool rootPageVisible = false;
  final _modalPause = Object();
  Timer? _errorTimer;
  List<UndoDeletion> get pending => List.unmodifiable(_pending);
  final ValueNotifier<double> countdown = ValueNotifier(1);
  double get progress => countdown.value;
  bool hides(String key) => [..._pending, ..._committing].any((d) => d.hiddenKeys.contains(key));
  bool hasKind(DeleteKind kind) => [..._pending, ..._committing].any((d) => d.kind == kind);
  bool committingKind(DeleteKind kind) => _committing.any((d) => d.kind == kind);
  final Map<DeleteKind, int> _settledRevisions = {};
  int settledRevision(DeleteKind kind) => _settledRevisions[kind] ?? 0;

  bool add(UndoDeletion deletion) {
    if (_disposed || hides(deletion.key) || (deletion.kind == DeleteKind.promise && committingKind(DeleteKind.promise)))
      return false;
    _checkAccount();
    _owner = account();
    _pending.add(deletion);
    failed = false;
    _errorTimer?.cancel();
    _remaining = window;
    countdown.value = 1;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _checkAccount();
      if (_pending.isEmpty || _pauses.isNotEmpty) return;
      _remaining -= const Duration(milliseconds: 100);
      if (_remaining <= Duration.zero) {
        _timer?.cancel();
        unawaited(_commit());
      } else {
        countdown.value = (_remaining.inMilliseconds / window.inMilliseconds).clamp(0, 1);
      }
    });
    notifyListeners();
    return true;
  }

  void pause(Object reason, bool paused) {
    if (paused) {
      _pauses.add(reason);
    } else {
      _pauses.remove(reason);
    }
  }

  void setModalVisible(bool visible) {
    if (_disposed || modalVisible == visible) return;
    modalVisible = visible;
    pause(_modalPause, visible);
    notifyListeners();
  }

  void setRootPageVisible(bool visible) {
    if (_disposed || rootPageVisible == visible) return;
    rootPageVisible = visible;
    notifyListeners();
  }

  /// Route replacements can invalidate page actions without changing depth.
  void syncNavigation({required bool modal, required bool rootPage}) {
    if (_disposed) return;
    modalVisible = modal;
    rootPageVisible = rootPage;
    pause(_modalPause, modal);
    notifyListeners();
  }

  void finish() {
    _timer?.cancel();
    if (_pending.isNotEmpty) unawaited(_commit());
  }

  void undo() {
    _timer?.cancel();
    final entries = _pending.toList();
    _pending.clear();
    for (final d in entries) {
      d.cancel?.call();
    }
    notifyListeners();
    for (final d in entries) {
      d.settled?.call();
    }
  }

  void _checkAccount() {
    if (_owner != null && _owner != account()) {
      undo();
      failed = false;
      _errorTimer?.cancel();
    }
  }

  Future<void> _commit() async {
    final batch = _pending.toList()..sort((a, b) => b.order.compareTo(a.order));
    final owner = _owner;
    _pending.clear();
    _committing.addAll(batch);
    notifyListeners();
    for (final d in batch) {
      var ok = false;
      if (!_disposed && owner == account()) {
        try {
          _active.add(d);
          ok = await d.commit();
        } catch (_) {
          ok = false;
        }
      } else {
        d.cancel?.call();
      }
      _active.remove(d);
      if (_disposed) return;
      if (!ok && owner == account()) {
        failed = true;
        d.cancel?.call();
        _errorTimer?.cancel();
        _errorTimer = Timer(const Duration(seconds: 5), () {
          failed = false;
          if (!_disposed) notifyListeners();
        });
      }
      notifyListeners();
    }
    _committing.removeWhere(batch.contains);
    // Every mounted list instance must refresh after an index-addressed batch.
    for (final kind in batch.map((d) => d.kind).toSet()) {
      _settledRevisions[kind] = settledRevision(kind) + 1;
    }
    if (!_disposed) notifyListeners();
    // Refresh index-based lists once the whole descending batch has finished.
    for (final d in batch) {
      if (!_disposed && owner == account()) d.settled?.call();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _errorTimer?.cancel();
    for (final d in [..._pending, ..._committing]) {
      // An in-flight operation owns its reservation until it completes.
      if (!_active.contains(d)) d.cancel?.call();
    }
    _committing.clear();
    _pending.clear();
    countdown.dispose();
    super.dispose();
  }
}
