import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/preferences.dart';

/// Only successful server reads renew freshness; local edits do not.
/// Empty snapshots are valid, failures must remain retryable.
class AboutMeCache {
  AboutMeCache(this.key);

  final String key;
  static const freshFor = Duration(minutes: 5);
  String get stampKey => '${key}_fetched_at';

  bool get isFresh {
    final stamp = SharedPreferencesUtil().getCachedJson(stampKey);
    if (stamp is! Map || stamp['owner'] != ApiConfig().externalUserId) return false;
    final fetchedAt = stamp['at'];
    if (fetchedAt is! int) return false;
    final age = DateTime.now().millisecondsSinceEpoch - fetchedAt;
    return age >= 0 && age < freshFor.inMilliseconds;
  }

  Future<void> markFetched({required String owner}) => SharedPreferencesUtil().cacheJson(stampKey, {
        'owner': owner,
        'at': DateTime.now().millisecondsSinceEpoch,
      });

  Future<void> invalidate() => SharedPreferencesUtil().clearCache(stampKey);
}
