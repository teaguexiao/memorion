import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/pdp.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/models/pdp_snapshot.dart';

class PdpProvider extends ChangeNotifier {
  static const String _latestCacheKey = 'pdp_latest_snapshot';
  static const String _historyCacheKey = 'pdp_history_snapshot';

  PdpSnapshot? latest;
  List<PdpSnapshot> history = const [];
  bool isLoadingLatest = false;
  bool isLoadingHistory = false;

  void loadFromCache() {
    final latestCached = SharedPreferencesUtil().getCachedJson(_latestCacheKey, maxAge: const Duration(days: 1));
    if (latestCached is Map) {
      try {
        latest = PdpSnapshot.fromJson(Map<String, dynamic>.from(latestCached));
      } catch (e) {
        debugPrint('PdpProvider latest cache parse error: $e');
      }
    }

    final historyCached = SharedPreferencesUtil().getCachedJson(_historyCacheKey, maxAge: const Duration(days: 1));
    if (historyCached is List) {
      try {
        history =
            historyCached.map((e) => PdpSnapshot.fromJson(Map<String, dynamic>.from(e as Map))).toList(growable: false);
      } catch (e) {
        debugPrint('PdpProvider history cache parse error: $e');
      }
    }
    notifyListeners();
  }

  Future<void> loadLatest({bool useCache = true, String? language}) async {
    if (useCache && latest == null) {
      loadFromCache();
    }
    isLoadingLatest = true;
    notifyListeners();
    try {
      final lang = language ?? SharedPreferencesUtil().userPrimaryLanguage;
      final result = await getLatestPdpSnapshot(language: lang.isNotEmpty ? lang : null);
      if (result != null) {
        latest = result;
        SharedPreferencesUtil().cacheJson(_latestCacheKey, _snapshotToJson(result));
      }
    } catch (e) {
      debugPrint('PdpProvider loadLatest error: $e');
    }
    isLoadingLatest = false;
    notifyListeners();
  }

  Future<void> loadHistory({bool useCache = true, int limit = 10, String? language}) async {
    if (useCache && history.isEmpty) {
      loadFromCache();
    }
    isLoadingHistory = true;
    notifyListeners();
    try {
      final lang = language ?? SharedPreferencesUtil().userPrimaryLanguage;
      final page = await getPdpHistory(limit: limit, language: lang.isNotEmpty ? lang : null);
      history = page.items;
      SharedPreferencesUtil().cacheJson(
        _historyCacheKey,
        history.map(_snapshotToJson).toList(growable: false),
      );
    } catch (e) {
      debugPrint('PdpProvider loadHistory error: $e');
    }
    isLoadingHistory = false;
    notifyListeners();
  }

  Map<String, dynamic> _snapshotToJson(PdpSnapshot snapshot) => {
        'date': snapshot.date,
        'language': snapshot.language,
        'primary_animal_key': snapshot.primaryAnimalKey,
        'secondary_animal_key': snapshot.secondaryAnimalKey,
        'primary_trait_key': snapshot.primaryTraitKey,
        'secondary_trait_key': snapshot.secondaryTraitKey,
        'hero_animal_key': snapshot.heroAnimalKey,
        'hero_summary': snapshot.heroSummary,
        'insight_lines': snapshot.insightLines,
        'metrics': snapshot.metrics
            .map(
              (metric) => {
                'key': metric.key,
                'score': metric.score,
                'delta': metric.delta,
              },
            )
            .toList(growable: false),
        'trajectory': snapshot.trajectory
            .map(
              (item) => {
                'date': item.date,
                'animal_key': item.animalKey,
              },
            )
            .toList(growable: false),
        'updated_at': snapshot.updatedAt?.toIso8601String(),
      };
}
