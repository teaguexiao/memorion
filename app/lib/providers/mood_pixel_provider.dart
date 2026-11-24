import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/mood_pixel.dart';
import 'package:memorion/models/mood_pixel_state.dart';

class MoodPixelProvider extends ChangeNotifier {
  MoodPixelState? state;
  bool isLoading = false;
  bool isSaving = false;
  Timer? _saveDebounceTimer;
  bool _hasPendingSave = false;

  Future<void> loadState() async {
    if (isLoading) return;
    isLoading = true;
    notifyListeners();
    try {
      state = await getMoodPixelState();
    } catch (e) {
      debugPrint('MoodPixelProvider load error: $e');
    }
    isLoading = false;
    notifyListeners();
  }

  /// Update state locally without persisting to backend
  void updateLocalState(MoodPixelState nextState) {
    debugPrint('[MoodPixelProvider] updateLocalState: selectedMood=${nextState.selectedMood}');
    state = nextState;
    notifyListeners();
    debugPrint('[MoodPixelProvider] updateLocalState completed, notified listeners');
  }

  /// Save state with debounce - batches multiple rapid changes into a single API call
  /// User can click multiple times rapidly, and all changes will be saved in one batch
  /// after 1.5 seconds of inactivity
  Future<void> saveState(MoodPixelState nextState) async {
    debugPrint('[MoodPixelProvider] saveState called, selectedMood=${nextState.selectedMood}');

    // Always update local state immediately for responsive UI
    state = nextState;
    notifyListeners();

    // Cancel previous pending save
    _saveDebounceTimer?.cancel();

    // Schedule a new save after 1.5 seconds of no changes (longer debounce for better batching)
    _saveDebounceTimer = Timer(const Duration(milliseconds: 1500), () async {
      debugPrint('[MoodPixelProvider] Debounce timer fired (1.5s elapsed), saving to backend...');
      await _performSave();
    });

    debugPrint('[MoodPixelProvider] saveState: debounce timer scheduled (1.5s)');
  }

  Future<void> _performSave() async {
    if (state == null) {
      debugPrint('[MoodPixelProvider] _performSave: skipped (state is null)');
      return;
    }

    // If already saving, mark as pending and return (no recursive timer!)
    if (isSaving) {
      debugPrint('[MoodPixelProvider] _performSave: already saving, marking as pending');
      _hasPendingSave = true;
      return;
    }

    isSaving = true;
    _hasPendingSave = false;
    notifyListeners();

    final stateBeforeSave = state!;

    try {
      debugPrint('[MoodPixelProvider] _performSave: calling API...');
      final saved = await updateMoodPixelState(stateBeforeSave);
      debugPrint('[MoodPixelProvider] _performSave: API returned successfully');

      // Only apply server response if state hasn't changed during save
      if (saved != null && state == stateBeforeSave) {
        state = saved;
        debugPrint('[MoodPixelProvider] _performSave: applied server response');
      } else if (state != stateBeforeSave) {
        debugPrint('[MoodPixelProvider] _performSave: state changed during save, marking as pending');
        _hasPendingSave = true;
      }
    } catch (e) {
      debugPrint('[MoodPixelProvider] _performSave error: $e');
    }

    isSaving = false;
    notifyListeners();
    debugPrint('[MoodPixelProvider] _performSave: completed, hasPendingSave=$_hasPendingSave');

    // If state changed during save, save again (with max retry limit to prevent infinite loop)
    int retryCount = 0;
    const maxRetries = 3;
    while (_hasPendingSave && retryCount < maxRetries) {
      retryCount++;
      debugPrint('[MoodPixelProvider] _performSave: pending save detected, retry #$retryCount');
      _hasPendingSave = false;

      isSaving = true;
      notifyListeners();

      final stateToSave = state!;
      try {
        debugPrint('[MoodPixelProvider] _performSave retry: calling API...');
        final saved = await updateMoodPixelState(stateToSave);
        if (saved != null && state == stateToSave) {
          state = saved;
        } else if (state != stateToSave) {
          _hasPendingSave = true;
        }
      } catch (e) {
        debugPrint('[MoodPixelProvider] _performSave retry error: $e');
      }

      isSaving = false;
      notifyListeners();
    }

    if (_hasPendingSave) {
      debugPrint('[MoodPixelProvider] _performSave: max retries reached, remaining changes will be saved on next user action');
      _hasPendingSave = false;
    }
  }

  @override
  void dispose() {
    _saveDebounceTimer?.cancel();
    super.dispose();
  }
}
