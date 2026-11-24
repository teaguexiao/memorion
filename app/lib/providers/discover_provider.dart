import 'package:flutter/foundation.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/utils/about_me_cache.dart';
import 'package:memorion/backend/http/api/discover.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/avatar_emotion.dart';

class DiscoverActionItem {
  String description;
  bool completed;
  final String conversationId;
  final String conversationTitle;

  /// 后端定位下标：待办存在会话的 `structured.action_items[]` 里，按**下标**定位。
  ///
  /// ⚠️ 不是 final：后端删一条是 `action_items.pop(idx)`，同一会话里比它大的下标
  /// 全部左移一位，本地缓存必须跟着减 1（见 [removeActionItemAt]），否则接下来的
  /// 勾选 / 删除会打到隔壁那条待办上。
  int itemIdx;
  final String? createdAt;
  bool deleted;

  /// 截止时间：只在后端能确定到具体某天时才有值。
  final DateTime? dueDate;

  /// 人说的原话（「本周内」「尽快」），后端定不到具体日期时的兜底展示。
  final String dueHint;

  DiscoverActionItem({
    required this.description,
    required this.completed,
    required this.conversationId,
    required this.conversationTitle,
    required this.itemIdx,
    this.createdAt,
    this.deleted = false,
    this.dueDate,
    this.dueHint = '',
  });

  factory DiscoverActionItem.fromJson(Map<String, dynamic> json) {
    final rawDue = json['due_date'];
    return DiscoverActionItem(
      description: json['description'] ?? '',
      completed: json['completed'] ?? false,
      conversationId: json['conversation_id'] ?? '',
      conversationTitle: json['conversation_title'] ?? '',
      itemIdx: json['item_idx'] ?? 0,
      createdAt: json['created_at'],
      dueDate: rawDue == null ? null : DateTime.tryParse(rawDue.toString())?.toLocal(),
      dueHint: (json['due_hint'] ?? '').toString(),
    );
  }
}

typedef ActionItemsFetcher = Future<Map<String, dynamic>> Function({String status, int limit, int offset});

class DiscoverProvider extends ChangeNotifier {
  DiscoverProvider({ActionItemsFetcher? fetchActions}) : _fetchActions = fetchActions ?? getActionItems;

  final ActionItemsFetcher _fetchActions;
  final _actionsCache = AboutMeCache('discover_actions');
  Future<void>? _refreshingActions;

  Future<void> ensureActionItemsLoaded() async {
    if (_actionItemsLoadedOnce && _actionsCache.isFresh) return;
    await (_refreshingActions ?? loadActionItems());
  }

  List<dynamic> emotionTrends = [];
  List<dynamic> categoryStats = [];
  List<dynamic> peopleStats = [];
  List<DiscoverActionItem> actionItems = [];
  Map<String, dynamic>? weeklyReport;

  // Latest EIR-detected emotion driving the Avatar card. Defaults to calm
  // until the first EIR result is loaded.
  AvatarEmotion latestEmotion = AvatarEmotion.calm;

  // Playful one-line persona greeting generated from the weekly tag cloud,
  // shown atop the Today welcome card. Empty until the first load resolves.
  String personaTagline = '';

  bool isLoadingEmotions = false;
  bool isLoadingPersona = false;
  bool isLoadingCategories = false;
  bool isLoadingPeople = false;
  bool isLoadingActions = false;
  bool isLoadingMoreActions = false;
  bool isLoadingReport = false;
  bool isLoadingStats = false;
  bool isLoadingLatestEmotion = false;

  static const int _actionItemsPageSize = 50;
  int _actionItemsTotalCount = 0;
  int _actionItemsCompletedCount = 0;
  bool _actionItemsHasMore = true;

  /// 待办是否已经有过一份数据（来自本地缓存或服务端）。
  ///
  /// 用来区分「还没拿到过任何数据」和「拿到了，确实是空的」——UI 只在前者转圈，
  /// 后者直接出空态。缓存命中时立刻为 true，所以「关于我」页不用等网络往返。
  bool _actionItemsLoadedOnce = false;
  bool get actionItemsLoadedOnce => _actionItemsLoadedOnce;

  int get actionItemsTotalCount => _actionItemsTotalCount;
  int get actionItemsCompletedCount => _actionItemsCompletedCount;
  bool get actionItemsHasMore => _actionItemsHasMore;

  /// 未完成的待办（「你答应过的事」用）。后端 status='all' 只返回已确认的条目，
  /// 所以在本地滤掉 completed 就等价于 status='pending'，不用再打一次接口。
  List<DiscoverActionItem> get pendingActionItems => actionItems.where((i) => !i.completed).toList();

  /// 未完成待办总数。`actionItems` 只是第一页（50 条），所以用服务端返回的
  /// total/completed 相减，翻页外的也算得准。
  int get pendingActionItemsCount {
    final derived = _actionItemsTotalCount - _actionItemsCompletedCount;
    return derived < 0 ? pendingActionItems.length : derived;
  }

  /// 仅供测试：把待办计数与「已加载过」标记直接置位，免得为了造状态去打网络。
  @visibleForTesting
  void debugMarkActionItemsLoaded({required int total, required int completed}) {
    _actionItemsTotalCount = total;
    _actionItemsCompletedCount = completed;
    _actionItemsLoadedOnce = true;
  }

  int memoriesCount = 0;
  int actionItemsCount = 0;

  bool get isLoading =>
      isLoadingEmotions || isLoadingCategories || isLoadingPeople || isLoadingActions || isLoadingReport;

  void loadFromCache() {
    final prefs = SharedPreferencesUtil();
    final cachedEmotions = prefs.getCachedJson('discover_emotions');
    if (cachedEmotions != null) emotionTrends = List<dynamic>.from(cachedEmotions);
    final cachedCategories = prefs.getCachedJson('discover_categories');
    if (cachedCategories != null) categoryStats = List<dynamic>.from(cachedCategories);
    final cachedPeople = prefs.getCachedJson('discover_people');
    if (cachedPeople != null) peopleStats = List<dynamic>.from(cachedPeople);
    final cachedActions = prefs.getCachedJson('discover_actions');
    if (cachedActions != null) {
      final rawItems = (cachedActions['items'] as List<dynamic>?) ?? [];
      actionItems = rawItems.map((e) => DiscoverActionItem.fromJson(Map<String, dynamic>.from(e))).toList();
      _actionItemsTotalCount = (cachedActions['total_count'] as num?)?.toInt() ?? actionItems.length;
      _actionItemsCompletedCount = (cachedActions['completed_count'] as num?)?.toInt() ?? 0;
      _actionItemsHasMore = (cachedActions['has_more'] as bool?) ?? false;
      _actionItemsLoadedOnce = true;
    }
    final cachedStats = prefs.getCachedJson('discover_stats');
    if (cachedStats != null) {
      memoriesCount = (cachedStats['memories_count'] as num?)?.toInt() ?? 0;
      actionItemsCount = (cachedStats['action_items_count'] as num?)?.toInt() ?? 0;
    }
    final cachedLatest = prefs.getCachedJson('discover_latest_emotion');
    if (cachedLatest is Map<String, dynamic>) {
      latestEmotion = AvatarEmotion.fromString(cachedLatest['emotion'] as String?);
    }
    final cachedPersona = prefs.getCachedJson('discover_persona_tagline');
    if (cachedPersona is Map<String, dynamic>) {
      personaTagline = (cachedPersona['tagline'] as String?)?.trim() ?? '';
    }
    notifyListeners();
  }

  Future<void> loadAll() async {
    loadFromCache();
    await Future.wait([
      loadEmotionTrends(),
      loadCategoryStats(),
      loadPeopleStats(),
      ensureActionItemsLoaded(),
      loadDiscoverStats(),
      loadLatestEmotion(),
      loadPersonaTagline(),
    ]);
  }

  Future<void> loadPersonaTagline({int days = 7}) async {
    isLoadingPersona = true;
    notifyListeners();
    try {
      final tagline = await getPersonaTagline(days: days);
      if (tagline != null && tagline.isNotEmpty) {
        personaTagline = tagline;
        SharedPreferencesUtil().cacheJson('discover_persona_tagline', {'tagline': tagline});
      }
    } catch (e) {
      debugPrint('Error loading persona tagline: $e');
    }
    isLoadingPersona = false;
    notifyListeners();
  }

  Future<void> loadLatestEmotion() async {
    isLoadingLatestEmotion = true;
    notifyListeners();
    try {
      final response = await getLatestEmotion();
      if (response != null) {
        latestEmotion = AvatarEmotion.fromString(response['emotion'] as String?);
        SharedPreferencesUtil().cacheJson('discover_latest_emotion', response);
      }
    } catch (e) {
      debugPrint('Error loading latest emotion: $e');
    }
    isLoadingLatestEmotion = false;
    notifyListeners();
  }

  Future<void> loadEmotionTrends({int days = 7}) async {
    isLoadingEmotions = true;
    notifyListeners();
    try {
      emotionTrends = await getEmotionTrends(days: days);
      SharedPreferencesUtil().cacheJson('discover_emotions', emotionTrends);
    } catch (e) {
      debugPrint('Error loading emotion trends: $e');
    }
    isLoadingEmotions = false;
    notifyListeners();
  }

  Future<void> loadCategoryStats({int days = 30}) async {
    isLoadingCategories = true;
    notifyListeners();
    try {
      categoryStats = await getCategoryStats(days: days);
      SharedPreferencesUtil().cacheJson('discover_categories', categoryStats);
    } catch (e) {
      debugPrint('Error loading category stats: $e');
    }
    isLoadingCategories = false;
    notifyListeners();
  }

  Future<void> loadPeopleStats({int days = 30}) async {
    isLoadingPeople = true;
    notifyListeners();
    try {
      peopleStats = await getPeopleStats(days: days);
      SharedPreferencesUtil().cacheJson('discover_people', peopleStats);
    } catch (e) {
      debugPrint('Error loading people stats: $e');
    }
    isLoadingPeople = false;
    notifyListeners();
  }

  /// Explicit reloads (including after mutations) must start after older reads.
  /// Tab entry deduplicates separately in ensureActionItemsLoaded.
  Future<void> loadActionItems({String status = 'all'}) {
    final previous = _refreshingActions;
    late final Future<void> request;
    request = (() async {
      if (previous != null) await previous;
      await _loadActionItems(status: status);
    })()
        .whenComplete(() {
      if (identical(_refreshingActions, request)) _refreshingActions = null;
    });
    _refreshingActions = request;
    return request;
  }

  Future<void> _loadActionItems({required String status}) async {
    final owner = ApiConfig().externalUserId;
    isLoadingActions = !_actionItemsLoadedOnce;
    notifyListeners();
    try {
      final response = await _fetchActions(status: status, limit: _actionItemsPageSize, offset: 0);
      if (owner != ApiConfig().externalUserId) return;
      // ⚠️ 拉取失败时保留现有列表，**别把空响应写进缓存**：那会让一次超时变成持久化的
      // 假空态（`cacheJson` 活到下次启动）。也别置 `_actionItemsLoadedOnce`，否则
      // 「加载过了、就是空的」这个结论会盖住重试。
      if (response['ok'] == false) {
        isLoadingActions = false;
        notifyListeners();
        return;
      }
      final rawItems = (response['items'] as List<dynamic>?) ?? [];
      actionItems = rawItems.map((e) => DiscoverActionItem.fromJson(e as Map<String, dynamic>)).toList();
      _actionItemsTotalCount = (response['total_count'] as num?)?.toInt() ?? actionItems.length;
      _actionItemsCompletedCount = (response['completed_count'] as num?)?.toInt() ?? 0;
      _actionItemsHasMore = (response['has_more'] as bool?) ?? false;
      _actionItemsLoadedOnce = true;
      await SharedPreferencesUtil().cacheJson('discover_actions', response);
      if (status == 'all') {
        await _actionsCache.markFetched(owner: owner);
      } else {
        await _actionsCache.invalidate();
      }
    } catch (e) {
      debugPrint('Error loading action items: $e');
    } finally {
      isLoadingActions = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreActionItems({String status = 'all'}) async {
    if (isLoadingMoreActions || !_actionItemsHasMore) return;
    isLoadingMoreActions = true;
    notifyListeners();
    try {
      final response = await getActionItems(
        status: status,
        limit: _actionItemsPageSize,
        offset: actionItems.length,
      );
      // ⚠️ 同 `loadActionItems`：失败也返回空 items，而这里空 items 会被读成「翻到底
      // 了」并把 `_actionItemsHasMore` 永久置 false —— 一次超时就让列表静默截断，本次
      // 会话再也拉不动。这一对函数必须一起尊重 `ok`，只改一个等于只修一半。
      if (response['ok'] == false) {
        isLoadingMoreActions = false;
        notifyListeners();
        return;
      }
      final rawItems = (response['items'] as List<dynamic>?) ?? [];
      final moreItems = rawItems.map((e) => DiscoverActionItem.fromJson(e as Map<String, dynamic>)).toList();
      if (moreItems.isEmpty) {
        _actionItemsHasMore = false;
      } else {
        actionItems.addAll(moreItems);
        _actionItemsTotalCount = (response['total_count'] as num?)?.toInt() ?? actionItems.length;
        _actionItemsCompletedCount = (response['completed_count'] as num?)?.toInt() ?? 0;
        _actionItemsHasMore = (response['has_more'] as bool?) ?? false;
      }
    } catch (e) {
      debugPrint('Error loading more action items: $e');
    }
    isLoadingMoreActions = false;
    notifyListeners();
  }

  Future<void> loadDiscoverStats() async {
    isLoadingStats = true;
    notifyListeners();
    try {
      final stats = await getDiscoverStats();
      if (stats.isNotEmpty) {
        memoriesCount = (stats['memories_count'] as num?)?.toInt() ?? 0;
        actionItemsCount = (stats['action_items_count'] as num?)?.toInt() ?? 0;
        SharedPreferencesUtil().cacheJson('discover_stats', stats);
      }
    } catch (e) {
      debugPrint('Error loading discover stats: $e');
    }
    isLoadingStats = false;
    notifyListeners();
  }

  int _findIndex(DiscoverActionItem item) {
    return actionItems.indexWhere(
      (i) => i.conversationId == item.conversationId && i.itemIdx == item.itemIdx,
    );
  }

  void toggleActionItemCompleted(DiscoverActionItem item, bool completed) {
    setActionItemCompleted(
      conversationId: item.conversationId,
      itemIdx: item.itemIdx,
      completed: completed,
    );
  }

  /// 按后端定位键（会话 + 下标）改一条待办的完成态。
  ///
  /// P-03 页自己 fetch 待办、不经本 Provider，勾完得回来同步这份缓存，否则
  /// 「关于我」摘要卡里那条还挂着。计数也要跟着动——`pendingActionItemsCount`
  /// 是 total-completed 算出来的，只改列表不改计数会让「还有 N 条」对不上。
  void setActionItemCompleted({
    required String conversationId,
    required int itemIdx,
    required bool completed,
  }) {
    final idx = actionItems.indexWhere(
      (i) => i.conversationId == conversationId && i.itemIdx == itemIdx,
    );
    if (idx == -1) return;
    if (actionItems[idx].completed == completed) return;
    actionItems[idx].completed = completed;
    _actionItemsCompletedCount = (_actionItemsCompletedCount + (completed ? 1 : -1)).clamp(0, _actionItemsTotalCount);
    notifyListeners();
  }

  void removeActionItem(DiscoverActionItem item) {
    removeActionItemAt(conversationId: item.conversationId, itemIdx: item.itemIdx);
  }

  /// 删掉一条待办后同步这份缓存：摘掉该条 + **把同会话内更大的下标全部左移一位**
  /// + 修计数。
  ///
  /// ⚠️ 左移是必须的，不是优化：后端 `delete_action_item` 做的是
  /// `action_items.pop(item_idx)`（`database/developer_data.py`），删完第 1 条，
  /// 原来的第 2 条就变成了第 1 条。缓存里还留着旧下标的话，下一次勾选或删除会**静默
  /// 打到隔壁那条待办**——两次操作各自看着都成功，错位只在刷新后才显形。
  ///
  /// 三段逻辑都不能因为「缓存里没这条」提前返回：`actionItems` 只是第一页（50 条），
  /// 分页外的条目照样要左移、计数照样要减。
  void removeActionItemAt({required String conversationId, required int itemIdx}) {
    final idx = actionItems.indexWhere(
      (i) => i.conversationId == conversationId && i.itemIdx == itemIdx,
    );
    final removedCompleted = idx == -1 ? null : actionItems[idx].completed;
    if (idx != -1) actionItems.removeAt(idx);

    for (final i in actionItems) {
      if (i.conversationId == conversationId && i.itemIdx > itemIdx) i.itemIdx -= 1;
    }

    _actionItemsTotalCount = (_actionItemsTotalCount - 1).clamp(0, 1 << 30);
    if (removedCompleted == true) {
      _actionItemsCompletedCount = (_actionItemsCompletedCount - 1).clamp(0, _actionItemsTotalCount);
    } else {
      // total 减了，completed 可能因此越界（clamp 的上界跟着变小了）。
      _actionItemsCompletedCount = _actionItemsCompletedCount.clamp(0, _actionItemsTotalCount);
    }
    notifyListeners();
  }

  void updateActionItemDescription(DiscoverActionItem item, String newDescription) {
    final idx = _findIndex(item);
    if (idx != -1) {
      actionItems[idx].description = newDescription;
      notifyListeners();
    }
  }

  Future<void> loadWeeklyReport() async {
    isLoadingReport = true;
    notifyListeners();
    try {
      weeklyReport = await generateDiscoverReport(type: 'weekly');
    } catch (e) {
      debugPrint('Error loading weekly report: $e');
    }
    isLoadingReport = false;
    notifyListeners();
  }
}
