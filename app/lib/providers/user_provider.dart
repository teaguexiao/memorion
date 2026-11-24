import 'package:flutter/material.dart';
import 'package:memorion/backend/http/api/privacy.dart';
import 'package:memorion/utils/localization_helper.dart';
import 'package:memorion/utils/logger.dart';

class UserProvider with ChangeNotifier {
  String _dataProtectionLevel = 'standard';
  bool _isLoading = false;

  bool _isMigrating = false;
  bool _migrationFailed = false;
  List<MigrationRequest> _migrationQueue = [];
  int _processedCount = 0;
  String _migrationMessage = '';

  // New properties for enhanced UX
  String _sourceLevel = '';
  String _targetLevel = '';
  DateTime? _startTime;

  String get dataProtectionLevel => _dataProtectionLevel;
  bool get isLoading => _isLoading;
  bool get isMigrating => _isMigrating;
  bool get migrationFailed => _migrationFailed;
  int get migrationTotalCount => _migrationQueue.length;
  int get migrationProcessedCount => _processedCount;
  String get migrationMessage => _migrationMessage;
  String get sourceLevel => _sourceLevel;
  String get targetLevel => _targetLevel;

  String get migrationETA {
    if (_processedCount == 0 || _startTime == null || migrationTotalCount == 0) {
      return appT((s) => s.migrationCalculating, 'Calculating...');
    }
    final elapsed = DateTime.now().difference(_startTime!);
    if (elapsed.inSeconds < 2) {
      return appT((s) => s.migrationCalculating, 'Calculating...');
    }
    final timePerObject = elapsed.inMilliseconds / _processedCount;
    final remainingObjects = migrationTotalCount - _processedCount;
    final remainingMilliseconds = (timePerObject * remainingObjects).round();
    final remainingDuration = Duration(milliseconds: remainingMilliseconds);

    if (remainingDuration.inMinutes > 1) {
      return appT(
        (s) => s.migrationMinutesRemaining(remainingDuration.inMinutes),
        'About ${remainingDuration.inMinutes} minutes remaining',
      );
    } else if (remainingDuration.inSeconds > 10) {
      return appT((s) => s.migrationOneMinuteRemaining, 'About a minute remaining');
    } else if (remainingObjects > 0) {
      return appT((s) => s.migrationAlmostDone, 'Almost done...');
    }
    return '';
  }

  String _getMigrationItemName(String type) {
    switch (type) {
      case 'conversation':
        return appT((s) => s.migrationItemConversations, 'conversations');
      case 'memory':
        return appT((s) => s.migrationItemMemories, 'memories');
      case 'chat':
        return appT((s) => s.migrationItemChats, 'chats');
      default:
        return appT((s) => s.migrationItemData, 'data');
    }
  }

  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();
    try {
      final userProfile = await PrivacyApi.getUserProfile();
      _dataProtectionLevel = userProfile['data_protection_level'] ?? 'standard';

      final migrationStatus = userProfile['migration_status'];
      if (migrationStatus != null && migrationStatus['status'] == 'in_progress') {
        final targetLevel = migrationStatus['target_level'];
        if (targetLevel != null) {
          Future.microtask(() => updateDataProtectionLevel(targetLevel));
        }
      }
    } catch (e, stackTrace) {
      Logger.error('Failed to initialize UserProvider: $e\n$stackTrace');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<int> getMigrationCountFor(String targetLevel) async {
    if (dataProtectionLevel == targetLevel) return 0;
    try {
      final objects = await PrivacyApi.checkMigration(targetLevel);
      return objects.length;
    } catch (e) {
      return 0;
    }
  }

  Future<void> updateDataProtectionLevel(String targetLevel) async {
    if (_isMigrating) return;

    _isMigrating = true;
    _migrationFailed = false;
    _sourceLevel = _dataProtectionLevel;
    _targetLevel = targetLevel;
    _startTime = DateTime.now();
    _migrationMessage = appT((s) => s.migrationAnalyzing, 'Analyzing your data...');
    notifyListeners();

    try {
      await PrivacyApi.startMigration(targetLevel);

      _migrationQueue = await PrivacyApi.checkMigration(targetLevel);
      _processedCount = 0;

      if (_migrationQueue.isEmpty) {
        _migrationMessage = appT((s) => s.migrationNoDataToMigrate, 'No data to migrate. Finalizing...');
        notifyListeners();
        await _finalize(targetLevel);
        return;
      }

      const batchSize = 100;
      for (var i = 0; i < _migrationQueue.length; i += batchSize) {
        final end = (i + batchSize > _migrationQueue.length) ? _migrationQueue.length : i + batchSize;
        final batch = _migrationQueue.sublist(i, end);
        final itemType = _getMigrationItemName(batch.first.type);

        await PrivacyApi.migrateObjectsBatch(batch);

        _processedCount += batch.length;
        final percentage = ((_processedCount / migrationTotalCount) * 100).toInt();
        _migrationMessage = appT(
          (s) => s.migrationProgress(itemType, percentage),
          'Migrating $itemType... $percentage%',
        );

        notifyListeners();
      }

      _migrationMessage = appT((s) => s.migrationFinalizing, 'All objects migrated. Finalizing...');
      notifyListeners();
      await _finalize(targetLevel);
    } catch (e, stackTrace) {
      Logger.error('Failed to update data protection level: $e\n$stackTrace');
      _isMigrating = false;
      _migrationFailed = true;
      _migrationMessage = appT((s) => s.migrationError, 'An error occurred during migration. Please try again.');

      notifyListeners();
      rethrow;
    }
  }

  Future<void> _finalize(String targetLevel) async {
    await PrivacyApi.finalizeMigration(targetLevel);
    _dataProtectionLevel = targetLevel;
    _isMigrating = false;
    _migrationFailed = false;
    _migrationMessage = appT((s) => s.migrationCompleteMessage, 'Migration complete!');
    _startTime = null;
    _processedCount = 0;
    _migrationQueue = [];

    notifyListeners();
  }
}
