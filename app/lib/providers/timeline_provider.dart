import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/timeline.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';

/// 拉一天章节的实现签名。生产是 [getTimelineDayChapters]；测试注入假实现。
typedef TimelineDayFetcher = Future<TimelineDay?> Function({required String date, bool refresh});
typedef TimelineChapterUpdater = Future<TimelineChapter?> Function({
  required TimelineChapter chapter,
  String? title,
  String? overview,
});

/// 首页时间轴的章节数据源（后端 `GET /v1/timeline/{date}/chapters`）。
///
/// 分工上它**不管「有哪些天」**——那仍然是 `ConversationProvider` 的事（分页、
/// 无限滚动、正在处理中的会话都在那边）。本 Provider 只回答「这一天由哪些章节
/// 组成」，按天缓存。页面把它关心的日期集合喂进 [syncDays]，剩下的它自己判。
///
/// ⚠️ **不做本地章节化**。章节是后端的可重算投影；端上再算一遍就会出现两套边界，
/// 而两套边界一定会在某个阈值改动后开始互相矛盾。拉不到就退回缓存，缓存也没有就
/// 让页面显示空态。
class TimelineProvider extends ChangeNotifier {
  /// 拉一天章节的实现。生产就是 [getTimelineDayChapters]，测试注入假实现。
  ///
  /// 存在的理由是本 Provider 几条最容易出错的规则都**只在多次调用之间**才显形
  /// （stale 只重试一次、拉失败保留缓存、refresh 重置退避），拿真网络测不出来。
  final TimelineDayFetcher _fetch;
  final TimelineChapterUpdater _updateChapter;
  final Map<String, int> _editRevisions = {};
  int _accountGeneration = 0;

  /// `YYYY-MM-DD` → 这一天的章节文档。
  final Map<String, TimelineDay> _days = {};

  /// 正在飞的请求，按天去重。同一天的并发请求（首帧 + 下拉刷新撞在一起）只发一次。
  final Set<String> _inFlight = {};
  final Map<String, Completer<void>> _fetchDone = {};
  final Set<String> _needsRefresh = {};
  final Map<String, Timer> _pendingRetries = {};

  /// 因「服务端那份缺了本地已知的会话」而触发过刷新的天。
  ///
  /// 每天每会话生命周期只允许触发一次。缺一条会话并不总是 dirty 未落地——它也可能
  /// 是后端**故意**不收（零 segment、被判 discarded、整段静音），那种情况下无条件
  /// 重试会变成每次 syncDays 都打一发 refresh 的死循环。
  final Set<String> _stalenessRetried = {};

  /// 至少完成过一次服务端拉取。语义与 `MomentsProvider.isInitialized` 一致：
  /// **不是**「缓存已加载」，所以页面首帧仍会触发 [syncDays]。
  bool isInitialized = false;

  /// 是否有请求在飞（页面用它决定要不要显示 loading）。
  bool get isLoading => _inFlight.isNotEmpty;

  /// 缓存里最多留几天。首页往回滚一般不会超过两周，而整份缓存是一个
  /// shared_preferences key，不设上限的话它会随使用时间单调增长。
  static const int _maxCachedDays = 14;

  /// 下拉刷新时强制重算的天数（从最新一天算起）。
  ///
  /// 曾经是「可见的每一天」，而 [syncDays] 要等最慢的那个返回才收起转圈。单天
  /// `refresh=true` 的 p90 是 3.7s、7.6% 超 5s（生产 api_logs_daily 2026-08-08..12），
  /// 首页常态可见 6 天 → 一次下拉至少踩中一个长尾的概率约 38%，体感就是「下拉经常
  /// 没响应」。
  ///
  /// 只强制最新一天不是妥协：其余天该不该重算，服务端有指纹、本地有 stale 判据
  /// （缺了本地已知的会话才补），两道判据都说没变就一个请求都不该发。真正每次下拉
  /// 都可能变的只有今天——刚录完的音会把当天标 dirty。
  static const int _forcedRefreshDays = 1;

  static const String _cacheKey = 'timeline_days_v1';

  TimelineProvider({TimelineDayFetcher? fetch, TimelineChapterUpdater? updateChapter})
      : _fetch = fetch ?? getTimelineDayChapters,
        _updateChapter = updateChapter ?? updateTimelineChapter {
    _loadFromCache();
  }

  void _loadFromCache() {
    try {
      final cached = SharedPreferencesUtil().getCachedJson(_cacheKey);
      if (cached is Map) {
        cached.forEach((key, value) {
          if (key is String && value is Map) {
            _days[key] = TimelineDay.fromJson(Map<String, dynamic>.from(value), fallbackDate: key);
          }
        });
      }
    } catch (e) {
      debugPrint('TimelineProvider: failed to load cache: $e');
    }
  }

  void _saveCache() {
    try {
      final keys = _days.keys.toList()..sort((a, b) => b.compareTo(a));
      final payload = <String, dynamic>{};
      for (final key in keys.take(_maxCachedDays)) {
        payload[key] = _days[key]!.toJson();
      }
      SharedPreferencesUtil().cacheJson(_cacheKey, payload);
    } catch (e) {
      debugPrint('TimelineProvider: failed to save cache: $e');
    }
  }

  /// 这一天的章节；没拉到过就是空列表。
  List<TimelineChapter> chaptersFor(String dateKey) => _days[dateKey]?.chapters ?? const [];

  /// 这一天的完整文档（页面判断「拉到过但确实是空的」用得到）。
  TimelineDay? dayFor(String dateKey) => _days[dateKey];

  /// 拉到过这一天（即使结果是 0 章）。区分空态与「还没拉」。
  bool hasDay(String dateKey) => _days.containsKey(dateKey);

  /// Recover an expired speaker revision even when cached source IDs are unchanged.
  /// Read the server projection without forcing a new summary, and keep the same
  /// span AND source set so a split/merged chapter cannot silently change targets.
  Future<TimelineChapter?> reloadChapter(TimelineChapter chapter) async {
    final date = chapter.date ?? timelineDayKey(chapter.start);
    final generation = _accountGeneration;
    while (_inFlight.contains(date) && generation == _accountGeneration) {
      await _fetchDone[date]!.future;
    }
    if (generation != _accountGeneration) return null;
    final before = _days[date];
    _inFlight.add(date);
    _fetchDone[date] = Completer<void>();
    notifyListeners();
    await _fetchBatch({date: false});
    if (generation != _accountGeneration || identical(before, _days[date])) return null;
    return chaptersFor(date)
        .where((item) =>
            item.start == chapter.start &&
            item.end == chapter.end &&
            setEquals(item.sourceConversationIds.toSet(), chapter.sourceConversationIds.toSet()))
        .firstOrNull;
  }

  /// 保存成功后同步首页与磁盘缓存。请求失败时保留原文。
  Future<TimelineChapter?> saveChapter(TimelineChapter chapter, {String? title, String? overview}) async {
    return saveChapterMutation(chapter, () => _updateChapter(chapter: chapter, title: title, overview: overview));
  }

  Future<TimelineChapter?> saveChapterMutation(
      TimelineChapter chapter, Future<TimelineChapter?> Function() mutation) async {
    final generation = _accountGeneration;
    final updated = await mutation();
    if (updated == null || generation != _accountGeneration) return null;
    final date = updated.date ?? chapter.date ?? timelineDayKey(chapter.start);
    _editRevisions[date] = (_editRevisions[date] ?? 0) + 1;
    final day = _days[date];
    if (day != null) {
      _days[date] = TimelineDay(
        date: day.date,
        timezone: day.timezone,
        chapters: [
          for (final item in day.chapters)
            if (item.start == chapter.start &&
                item.end == chapter.end &&
                setEquals(item.sourceConversationIds.toSet(), chapter.sourceConversationIds.toSet()))
              updated
            else
              item
        ],
        sourceConversationIds: day.sourceConversationIds,
        cache: day.cache,
        computedAt: day.computedAt,
      );
      _saveCache();
      notifyListeners();
    }
    return updated;
  }

  /// 已知章节里包含这条 conversation 的那一章；找不到返回 null。
  ///
  /// 深链（通知点进来只有一个 conversation id）用它把单条会话还原成所在章节。
  TimelineChapter? chapterContaining(String conversationId) {
    for (final day in _days.values) {
      for (final chapter in day.chapters) {
        if (chapter.sourceConversationIds.contains(conversationId)) return chapter;
      }
    }
    return null;
  }

  /// A saved recording identity changes content even when source IDs stay the same.
  /// Use cached server dates (including its timezone), then the recording date for
  /// days that have not been loaded. Reject older responses before waiting for them.
  Future<void> refreshConversations(Set<String> conversationIds, {required String fallbackDate}) async {
    if (conversationIds.isEmpty) return;
    final dates = _days.entries
        .where((entry) => entry.value.sourceConversationIds.any(conversationIds.contains))
        .map((entry) => entry.key)
        .toSet();
    if (dates.isEmpty) dates.add(fallbackDate);
    final generation = _accountGeneration;
    for (final date in dates) {
      _editRevisions[date] = (_editRevisions[date] ?? 0) + 1;
      _needsRefresh.add(date);
    }
    await Future.wait(dates.map((date) async {
      while (_inFlight.contains(date) && generation == _accountGeneration) {
        await _fetchDone[date]!.future;
      }
      if (generation != _accountGeneration) return;
      _inFlight.add(date);
      _fetchDone[date] = Completer<void>();
      notifyListeners();
      await _fetchBatch({date: true});
    }));
  }

  /// 让这些天的章节与服务端同步。
  ///
  /// [conversationIdsByDay] 是页面已知的、**已完成**的会话 id 按天分组。
  /// 键必须按会话的 `startedAt` 归日（后端就是这么归的），否则跨夜会话会一直被判
  /// 成「服务端漏了」。⚠️ 别把 processing / in_progress 的会话放进来——它们还没进
  /// 章节是正常的，放进来等于每次都判 stale。
  ///
  /// [refresh] 是下拉刷新：**只对最新一天**带 `refresh=true` 强制重算（见
  /// [_forcedRefreshDays]），其余天照常走缓存 / stale 判据。服务端的指纹校验对两者
  /// 都生效，所以没变过的天即使带了 refresh 也不会真的重算 LLM。
  Future<void> syncDays(Map<String, Set<String>> conversationIdsByDay, {bool refresh = false}) async {
    if (refresh) {
      // 手动刷新先清掉「已重试过」的记账，再按判据决定发不发：用户明确要求重新算，
      // 就别拿上一轮的退避挡着。⚠️ 必须清在构造 pending **之前**——非最新的那些天
      // 现在要走 stale 判据了，清晚一步这一轮就等于没清。
      _stalenessRetried.removeWhere(conversationIdsByDay.containsKey);
    }

    // 键是 `YYYY-MM-DD`，字符串降序即时间倒序。
    final hotDays = refresh
        ? (conversationIdsByDay.keys.toList()..sort((a, b) => b.compareTo(a))).take(_forcedRefreshDays).toSet()
        : const <String>{};

    final pending = <String, bool>{}; // dateKey → 是否要带 refresh
    conversationIdsByDay.forEach((dateKey, ids) {
      if (_inFlight.contains(dateKey)) return;
      if (hotDays.contains(dateKey) || _needsRefresh.contains(dateKey)) {
        pending[dateKey] = true;
        return;
      }
      final day = _days[dateKey];
      if (day == null) {
        pending[dateKey] = false;
        return;
      }
      final known = day.sourceConversationIds.toSet();
      final missing = ids.where((id) => !known.contains(id));
      if (missing.isNotEmpty && !_stalenessRetried.contains(dateKey)) {
        _stalenessRetried.add(dateKey);
        pending[dateKey] = true;
      }
    });

    if (pending.isEmpty) {
      if (!isInitialized) {
        // 全部命中缓存也算初始化完成，否则页面会永远停在 loading。
        isInitialized = true;
        notifyListeners();
      }
      return;
    }

    _inFlight.addAll(pending.keys);
    for (final date in pending.keys) {
      _fetchDone[date] = Completer<void>();
    }
    notifyListeners();

    // 前台只等用户此刻在等的东西——下拉刷新那天，以及还没拉过的天（它们在界面上是
    // 空洞，丢后台会先闪一下空态）。已有缓存的补算天放后台：等它们就等于把下拉刷新
    // 的时长重新变回「最慢那天」，那正是要治的病。
    //
    // 只有下拉刷新才分前后台。首帧那次 `refresh=false` 拉的都是界面上还没有的天，
    // 等它们是对的。
    final foreground = <String, bool>{};
    final background = <String, bool>{};
    pending.forEach((dateKey, withRefresh) {
      final canDefer = refresh && !hotDays.contains(dateKey) && _days.containsKey(dateKey);
      (canDefer ? background : foreground)[dateKey] = withRefresh;
    });

    // 故意不 await：后台那批自己落库、自己 notify，失败也不拖累前台这次刷新。
    if (background.isNotEmpty) _fetchBatch(background);
    await _fetchBatch(foreground);
  }

  /// 拉一批天并落库。前台批和后台批共用，所以 in-flight 清理、缓存落盘、通知都收在
  /// 这里的 `finally`——两批各自清自己那几天，互不干扰。
  Future<void> _fetchBatch(Map<String, bool> batch) async {
    if (batch.isEmpty) return;
    for (final date in batch.keys) {
      _pendingRetries.remove(date)?.cancel();
    }
    final generation = _accountGeneration;
    final revisions = {for (final date in batch.keys) date: _editRevisions[date] ?? 0};
    final completed = {for (final date in batch.keys) date: _fetchDone[date] ?? Completer<void>()};
    _fetchDone.addAll(completed);
    var changed = false;
    try {
      final results = await Future.wait(batch.entries.map(
        (entry) async {
          var day = await _fetch(date: entry.key, refresh: entry.value);
          // A concurrent server recompute can return its older cached document.
          // Retry briefly; keep the pending marker if it remains locked or fails.
          for (var attempt = 0;
              {'locked', 'pending'}.contains(day?.cache) &&
                  _needsRefresh.contains(entry.key) &&
                  generation == _accountGeneration &&
                  attempt < 5;
              attempt++) {
            await Future<void>.delayed(Duration(seconds: attempt < 2 ? 1 : 4));
            if (generation != _accountGeneration) break;
            day = await _fetch(date: entry.key, refresh: true);
          }
          return MapEntry(entry.key, day);
        },
      ));
      for (final result in results) {
        if (generation != _accountGeneration || revisions[result.key] != (_editRevisions[result.key] ?? 0)) {
          continue;
        }
        final day = result.value;
        // 拉失败（null）保留缓存里的那份：空响应通常是网络/鉴权抖动，不是
        // 「这天真的没有章节」。照 MomentsProvider 的处理。
        if (day == null) continue;
        if ({'locked', 'pending'}.contains(day.cache) && _needsRefresh.contains(result.key)) {
          _retryPendingDay(result.key, generation);
          continue;
        }
        _needsRefresh.remove(result.key);
        _days[result.key] = day;
        changed = true;
      }
    } catch (e) {
      debugPrint('TimelineProvider: syncDays failed: $e');
    } finally {
      for (final entry in completed.entries) {
        if (identical(_fetchDone[entry.key], entry.value)) _fetchDone.remove(entry.key);
        entry.value.complete();
      }
      if (generation == _accountGeneration) {
        _inFlight.removeAll(batch.keys);
        isInitialized = true;
        if (changed) _saveCache();
        notifyListeners();
      }
    }
  }

  void _retryPendingDay(String date, int generation) {
    _pendingRetries.remove(date)?.cancel();
    // Long server rollups can outlive the foreground retries. The homepage
    // deduplicates unchanged source IDs, so it cannot trigger this retry itself.
    _pendingRetries[date] = Timer(const Duration(seconds: 30), () {
      _pendingRetries.remove(date);
      if (generation != _accountGeneration || !_needsRefresh.contains(date) || _inFlight.contains(date)) return;
      _inFlight.add(date);
      _fetchDone[date] = Completer<void>();
      notifyListeners();
      unawaited(_fetchBatch({date: true}));
    });
  }

  /// 删掉若干源 conversation 后的乐观更新。
  ///
  /// 源会话删了，指向它的章节必须立刻消失——否则界面上留着一张点进去 404 的卡。
  /// 一章的所有源都被删则整章消失。真正的重算由后端负责（`DELETE
  /// /v1/conversations/{id}` 已把那天标 dirty），下一次 [syncDays] 会覆盖这里的
  /// 近似结果。
  void forgetConversations(Set<String> conversationIds) {
    if (conversationIds.isEmpty) return;
    var changed = false;
    for (final key in _days.keys.toList()) {
      final before = _days[key]!;
      final after = before.withoutConversations(conversationIds);
      if (after.chapters.length != before.chapters.length ||
          after.sourceConversationIds.length != before.sourceConversationIds.length) {
        _days[key] = after;
        changed = true;
      }
    }
    if (changed) {
      // 被删的天下次要重新拉：本地这份已经是近似值了。
      _stalenessRetried.clear();
      _saveCache();
      notifyListeners();
    }
  }

  /// 退出登录 / 切账号时清空。章节里有摘要正文，不能留给下一个用户。
  void clear() {
    _accountGeneration++;
    for (final timer in _pendingRetries.values) {
      timer.cancel();
    }
    _pendingRetries.clear();
    _editRevisions.clear();
    _days.clear();
    _inFlight.clear();
    _fetchDone.clear();
    _needsRefresh.clear();
    _stalenessRetried.clear();
    isInitialized = false;
    SharedPreferencesUtil().cacheJson(_cacheKey, <String, dynamic>{});
    notifyListeners();
  }

  @override
  void dispose() {
    _accountGeneration++;
    for (final timer in _pendingRetries.values) {
      timer.cancel();
    }
    _pendingRetries.clear();
    super.dispose();
  }

  @visibleForTesting
  void seedDay(TimelineDay day) {
    _days[day.date] = day;
  }
}
