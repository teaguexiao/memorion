import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/home_updates.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/models/home_module_update.dart';

class HomeUpdatesProvider extends ChangeNotifier {
  static const String _cacheKey = 'home_module_updates';

  List<HomeModuleUpdate> items = const [];
  bool isLoading = false;

  void loadFromCache() {
    final cached = SharedPreferencesUtil().getCachedJson(_cacheKey, maxAge: const Duration(hours: 2));
    if (cached is List) {
      try {
        items =
            cached.map((e) => HomeModuleUpdate.fromJson(Map<String, dynamic>.from(e as Map))).toList(growable: false);
        notifyListeners();
      } catch (e) {
        debugPrint('HomeUpdatesProvider cache parse error: $e');
      }
    }
  }

  Future<void> loadUpdates({bool useCache = true}) async {
    if (useCache && items.isEmpty) {
      loadFromCache();
    }
    isLoading = true;
    notifyListeners();
    try {
      final result = await getHomeModuleUpdates();
      items = result;
      SharedPreferencesUtil().cacheJson(
        _cacheKey,
        result.map((item) => item.toJson()).toList(growable: false),
      );
    } catch (e) {
      debugPrint('HomeUpdatesProvider load error: $e');
    }
    isLoading = false;
    notifyListeners();
  }
}
