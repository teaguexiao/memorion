import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/mood_quote.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/models/mood_quote.dart';

/// 情绪页「每日一语」状态管理。
///
/// 选型：独立的轻量 provider（而非扩展 DiscoverProvider），因为本功能完全自包含——
/// 独立 API、独立缓存键、独立 loading/error 状态，且仅 MoodPage 使用；
/// 拆开可避免 DiscoverProvider 进一步膨胀，并与 fortune 一样按功能聚合。
/// 缓存模式沿用 DiscoverProvider：SharedPreferencesUtil.cacheJson / getCachedJson。
class MoodQuoteProvider extends ChangeNotifier {
  static const String _cacheKey = 'mood_daily_quote';

  DailyMoodQuote? quote;
  bool isLoading = false;
  bool hasError = false;

  /// 从本地缓存恢复当日寄语（同 DiscoverProvider.loadFromCache 模式）。
  void loadFromCache() {
    final cached = SharedPreferencesUtil().getCachedJson(_cacheKey, maxAge: const Duration(days: 1));
    if (cached is Map) {
      try {
        quote = DailyMoodQuote.fromJson(Map<String, dynamic>.from(cached));
        notifyListeners();
      } catch (e) {
        debugPrint('MoodQuoteProvider cache parse error: $e');
      }
    }
  }

  /// 加载当日寄语。先用缓存占位（若 [useCache]），再请求后端覆盖。
  Future<void> loadDailyQuote({bool useCache = true, String? language}) async {
    if (useCache && quote == null) {
      loadFromCache();
    }
    isLoading = true;
    hasError = false;
    notifyListeners();
    try {
      final lang = language ?? SharedPreferencesUtil().userPrimaryLanguage;
      final result = await getDailyMoodQuote(language: lang.isNotEmpty ? lang : null);
      if (result != null) {
        quote = result;
        SharedPreferencesUtil().cacheJson(_cacheKey, result.toJson());
      } else {
        hasError = quote == null;
      }
    } catch (e) {
      debugPrint('MoodQuoteProvider load error: $e');
      hasError = quote == null;
    }
    isLoading = false;
    notifyListeners();
  }
}
