import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/moments.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/message.dart';

/// 拉 moments 的实现签名。生产是 [getMomentsFromServer]；测试注入假实现。
typedef MomentsFetcher = Future<List<ServerMessage>> Function({int limit, int offset});

/// 「日记」tab 的数据源（后端 `GET /v1/moments`）。
///
/// **缓存策略是 stale-while-revalidate**：本地快照先渲染，需要时才后台刷新。
/// 日记是每晚生成一次的静态内容——同一天的日记写完就不再变，所以「进来先看缓存」
/// 几乎永远是对的，用户不该为看昨天的日记等一次网络往返。
///
/// ⚠️ **这里最容易写错的是「什么时候不该请求」，而不是「怎么请求」。** 历史形态是
/// 页面每次切到日记 tab 都判 `isInitialized`，而它只在**服务端拉取成功**后才置
/// true（构造期的 `_loadFromCache` 刻意不置）。于是：
/// - 冷启动进日记 → 必然一次全量请求，而 `/v1/moments` 在后端是**全表 stream 后在
///   Python 里排序切片**（`routers/moments.py`），条数越多越慢；
/// - `isLoading` 又只在 `moments.isEmpty` 时才置 true，所以缓存命中时用户看不到
///   loading——**卡片是旧的、请求在飞**，看起来就是「打开就卡一下然后跳一下」。
///
/// 现在的规则：缓存新鲜（[_freshFor] 内）就**一次网络都不发**；过期了才后台
/// revalidate，且期间继续显示旧内容。下拉刷新（[refresh]）无条件绕过新鲜度判定——
/// 用户明确要求更新时不该被记账挡住。
class MomentsProvider extends ChangeNotifier {
  final MomentsFetcher _fetch;

  List<ServerMessage> moments = [];
  bool isLoading = false;
  bool hasMore = true;
  bool isInitialized = false;

  static const int _pageSize = 20;
  int _currentOffset = 0;

  static const String _cacheKey = 'moments_list';
  static const String _cacheStampKey = 'moments_list_fetched_at';

  /// 缓存新鲜期。日记每晚生成一次，所以这个窗口可以开得比一般列表大。
  ///
  /// 取 6 小时而不是 24：新日记在夜里落库，若窗口跨过整天，晚上生成的那篇要等到
  /// 第二天同一时刻才会出现。6 小时保证「睡前生成、早上打开」这条最常见的路径能
  /// 看到新内容，同一天里的反复进出则全部命中缓存。
  static const Duration _freshFor = Duration(hours: 6);

  /// 本地快照的写入时刻（毫秒）。null = 没有缓存或已被清理。
  int? _cachedAtMs;

  MomentsProvider({MomentsFetcher? fetch}) : _fetch = fetch ?? getMomentsFromServer {
    // Load cache synchronously at construction so the first build of the diary
    // tab renders cached moments instantly — matches DiscoverProvider's behavior
    // for action items / people / etc.
    _loadFromCache();
  }

  void _loadFromCache() {
    if (moments.isNotEmpty) return;
    try {
      final cached = SharedPreferencesUtil().getCachedJson(_cacheKey);
      if (cached is List && cached.isNotEmpty) {
        moments = cached.map((e) => ServerMessage.fromJson(Map<String, dynamic>.from(e))).toList();
        _currentOffset = moments.length;
        _cachedAtMs = SharedPreferencesUtil().getInt(_cacheStampKey);
        // 缓存有多少条就认它还有没有下一页：整页说明后面可能还有，不整页说明到底了。
        // 少了这句，缓存命中时 hasMore 恒为 true，滚到底会白发一次分页请求。
        hasMore = moments.length >= _pageSize;
      }
    } catch (e) {
      debugPrint('MomentsProvider: failed to load cache: $e');
    }
  }

  /// 本地快照是否还在新鲜期内（有内容 + 有时间戳 + 未过期）。
  bool get isCacheFresh {
    if (moments.isEmpty) return false;
    final stamp = _cachedAtMs;
    if (stamp == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - stamp;
    // age < 0 = 时间戳在未来（用户改过系统时间）。当成不新鲜处理：宁可多拉一次，
    // 也不要因为一个坏时间戳把缓存钉死在「永远新鲜」。
    if (age < 0) return false;
    return age < _freshFor.inMilliseconds;
  }

  /// 页面进入日记 tab 时调用：缓存新鲜就直接返回，不发请求。
  ///
  /// 与 [loadMoments] 的区别只在这道新鲜度闸门。页面不该自己判断——把判据留在
  /// Provider 里，才不会出现「页面 A 判了、页面 B 忘判」的偏差。
  Future<void> ensureLoaded() async {
    if (isCacheFresh) {
      // 缓存直接可用。标记初始化完成，否则 isEmpty 永远返回 false（它要求
      // isInitialized），空账号会一直停在骨架屏而不是空态文案。
      isInitialized = true;
      debugPrint('MomentsProvider: cache fresh (${moments.length} moments), skipping fetch');
      return;
    }
    await loadMoments();
  }

  /// Load initial moments from server
  Future<void> loadMoments() async {
    if (isLoading) return;

    isLoading = moments.isEmpty;
    _currentOffset = 0;
    notifyListeners();

    try {
      final fetchedMoments = await _fetch(limit: _pageSize, offset: 0);

      // Preserve cached moments if server returns empty while we have cache —
      // empty response is usually a transient auth/network issue, not a real
      // "no moments" state. Real refresh of an actually-empty account still
      // works because moments starts empty on first install.
      if (fetchedMoments.isNotEmpty || moments.isEmpty) {
        moments = fetchedMoments;
        hasMore = fetchedMoments.length >= _pageSize;
        _currentOffset = fetchedMoments.length;

        if (fetchedMoments.isNotEmpty) {
          _saveCache();
        }
        debugPrint('MomentsProvider: Loaded ${moments.length} moments');
      } else {
        debugPrint('MomentsProvider: Server returned empty, keeping ${moments.length} cached moments');
      }
      isInitialized = true;
    } catch (e) {
      debugPrint('MomentsProvider: Error loading moments: $e');
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// 把当前列表连同写入时刻存进本地。
  ///
  /// ⚠️ 时间戳单独存一个 key，**不复用 `getCachedJson` 内部那个 `ts`**：它是私有
  /// 信封字段，没有读取接口，而新鲜度判定必须能读到它。
  void _saveCache() {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      SharedPreferencesUtil().cacheJson(_cacheKey, moments.map((m) => m.toJson()).toList());
      SharedPreferencesUtil().saveInt(_cacheStampKey, now);
      _cachedAtMs = now;
    } catch (e) {
      debugPrint('MomentsProvider: failed to save cache: $e');
    }
  }

  /// Load more moments for infinite scroll pagination
  Future<void> loadMoreMoments() async {
    if (isLoading || !hasMore) return;

    isLoading = true;
    notifyListeners();

    try {
      final fetchedMoments = await _fetch(limit: _pageSize, offset: _currentOffset);

      if (fetchedMoments.isEmpty) {
        hasMore = false;
      } else {
        moments.addAll(fetchedMoments);
        hasMore = fetchedMoments.length >= _pageSize;
        _currentOffset += fetchedMoments.length;
        // 翻出来的页也存起来：否则用户翻了五页、退出再进来又只剩第一页，
        // 滚动位置一还原就得重新翻一遍。
        _saveCache();
      }

      debugPrint('MomentsProvider: Loaded ${fetchedMoments.length} more moments, total: ${moments.length}');
    } catch (e) {
      debugPrint('MomentsProvider: Error loading more moments: $e');
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Refresh moments from server (pull-to-refresh)
  ///
  /// 无条件打服务端——用户下拉就是明确要求更新，不看新鲜度。
  Future<void> refresh() async {
    _currentOffset = 0;
    hasMore = true;
    await loadMoments();
  }

  /// Check if there are no moments to display
  bool get isEmpty => moments.isEmpty && !isLoading && isInitialized;

  /// Resolve a single moment by id for notification deep-linking.
  ///
  /// Checks the in-memory list (populated from cache and server) first; on a
  /// miss it fetches the latest page and retries — the just-pushed diary is the
  /// newest moment, so it lands on the first page. Returns null if it still
  /// can't be found (e.g. deleted), letting the caller fall back gracefully.
  ///
  /// ⚠️ 未命中时走的是 [loadMoments] 而**不是** [ensureLoaded]：推送点进来的那篇
  /// 日记刚在服务端落库，本地缓存必然没有它。这里如果尊重新鲜度，深链就会因为
  /// 「缓存还新鲜」而永远拉不到那篇，点通知打不开。
  Future<ServerMessage?> getMomentById(String id) async {
    final cached = _findMomentById(id);
    if (cached != null) return cached;

    await loadMoments();
    return _findMomentById(id);
  }

  ServerMessage? _findMomentById(String id) {
    for (final m in moments) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 丢弃本地快照（登出 / 切账号）。
  ///
  /// 不清的话下一个账号进日记 tab 会先看到上一个账号的日记——缓存新鲜度判定
  /// 恰恰会让它**不去请求**，那份错内容能挂到过期为止。
  Future<void> clearCache() async {
    moments = [];
    _currentOffset = 0;
    hasMore = true;
    isInitialized = false;
    _cachedAtMs = null;
    await SharedPreferencesUtil().clearCache(_cacheKey);
    await SharedPreferencesUtil().remove(_cacheStampKey);
    notifyListeners();
  }
}
