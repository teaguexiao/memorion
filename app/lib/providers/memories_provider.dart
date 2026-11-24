import 'package:memorion/backend/api_config.dart';
import 'package:memorion/widgets/extensions/string.dart';
import 'package:memorion/backend/http/api/memories.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/memory.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:memorion/utils/fact_confirm_rotation.dart';
import 'package:memorion/utils/about_me_cache.dart';
import 'package:tuple/tuple.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

typedef MemoryReviewer = Future<bool> Function(String id, bool confirmed);

typedef MemoriesFetcher = Future<List<Memory>?> Function({int limit, int offset, String status});

class MemoriesProvider extends ChangeNotifier {
  MemoriesProvider({MemoriesFetcher? fetch, MemoryReviewer? review})
      : _fetch = fetch ?? getMemories,
        _review = review ?? reviewMemoryServer {
    _loadFromCache();
  }

  final MemoriesFetcher _fetch;
  final MemoryReviewer _review;
  int _reviewEpoch = 0;
  int _reviewsInFlight = 0;
  final _cache = AboutMeCache('memories_list');
  Future<void>? _refreshing;
  bool _hasSnapshot = false;

  Future<void> ensureLoaded() async {
    if (_hasSnapshot && _cache.isFresh) return;
    await (_refreshing ?? loadMemories());
  }

  List<Memory> _memories = [];
  List<Memory> _unreviewed = [];

  /// 待确认事实：LLM 提取、用户还没在气泡卡里裁决过的（后端 status=pending）。
  /// 不进 `_memories`（正式列表），只喂「关于我」页的待确认气泡卡。
  List<Memory> _pendingFacts = [];

  /// 本次已选定的那条待确认事实。一旦出现就固定住，不能每次 rebuild 重挑——
  /// 否则用户正要点「没错」时卡片内容可能已经换了（待办气泡卡踩过的坑）。
  Memory? _pickedFact;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _searchQuery = '';
  MemoryCategory? _categoryFilter;
  bool _excludeInteresting = false;
  List<Tuple2<MemoryCategory, int>> categories = [];
  MemoryCategory? selectedCategory;

  static const int _pageSize = 100;

  List<Memory> get memories => _memories;
  List<Memory> get unreviewed => _unreviewed;
  List<Memory> get pendingFacts => _pendingFacts;

  /// 「关于我」页当前该问的那一条待确认事实（一次只问一条）。
  ///
  /// 挑选规则（对齐待办气泡卡 [FactConfirmRotation]，但事实不设时效窗口）：
  /// 1. **没问过的优先**，且其中挑最新的（刚记住的最有印象）；
  /// 2. 都问过了，就挑最久没问过的那条——用户忽略掉的下次换别的，不反复唠叨。
  ///
  /// 「问过」只记本地，不占后端字段。选定后固定住直到用户拍板或该条消失。
  Memory? get pendingFactToConfirm {
    if (_pendingFacts.isEmpty) {
      _pickedFact = null;
      return null;
    }

    // 已选定的还在候选里就继续用它。
    if (_pickedFact case final picked?) {
      final still = _pendingFacts.where((m) => m.id == picked.id).firstOrNull;
      if (still != null) return still;
    }

    var best = _pendingFacts.first;
    for (final m in _pendingFacts.skip(1)) {
      if (_winsFactSlot(m, best)) best = m;
    }
    _pickedFact = best;
    // 露面即记一笔，下次进首页会轮到别的那条。
    FactConfirmRotation.markAsked(best.id);
    return best;
  }

  /// a 是否比 b 更该被问：没问过的赢过问过的；同类里没问过比"新"、问过比"久"。
  bool _winsFactSlot(Memory a, Memory b) {
    final aAsked = FactConfirmRotation.lastAskedAt(a.id);
    final bAsked = FactConfirmRotation.lastAskedAt(b.id);
    if ((aAsked == null) != (bAsked == null)) return aAsked == null;
    if (aAsked == null) return a.createdAt.isAfter(b.createdAt);
    return aAsked.isBefore(bAsked!);
  }

  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String get searchQuery => _searchQuery;
  MemoryCategory? get categoryFilter => _categoryFilter;
  bool get excludeInteresting => _excludeInteresting;

  List<Memory> get filteredMemories {
    return _memories.where((memory) {
      // Apply search filter
      final matchesSearch =
          _searchQuery.isEmpty || memory.content.decodeString.toLowerCase().contains(_searchQuery.toLowerCase());

      // Apply category filter or exclusion logic
      bool categoryMatch;
      if (_excludeInteresting) {
        // Show all categories except interesting
        categoryMatch = memory.category != MemoryCategory.interesting;
      } else if (_categoryFilter != null) {
        // Show only selected category
        categoryMatch = memory.category == _categoryFilter;
      } else {
        // Show all categories if no filter is applied
        categoryMatch = true;
      }

      return matchesSearch && categoryMatch;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  void setExcludeInteresting(bool exclude) {
    _excludeInteresting = exclude;
    notifyListeners();
  }

  void setCategory(MemoryCategory? category) {
    selectedCategory = category;
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query.toLowerCase();
    notifyListeners();
  }

  void setCategoryFilter(MemoryCategory? category) {
    _categoryFilter = category;
    _excludeInteresting = false; // Reset exclude filter when setting a category filter
    notifyListeners();
  }

  /// 把当前列表写回缓存。增删改后都要调：`_loadFromCache()` 会在冷启动时先铺缓存，
  /// 不落盘的话用户刚改过的事实下次进来会闪一下旧内容（等 loadMemories 回来才纠正）。
  void _persist() {
    SharedPreferencesUtil().cacheJson('memories_list', _memories.map((m) => m.toJson()).toList());
    SharedPreferencesUtil().cacheJson('memories_pending', _pendingFacts.map((m) => m.toJson()).toList());
  }

  void _setCategories() {
    categories = MemoryCategory.values.map((category) {
      final count = memories.where((memory) => memory.category == category).length;
      return Tuple2(category, count);
    }).toList();
    notifyListeners();
  }

  void _loadFromCache() {
    try {
      final prefs = SharedPreferencesUtil();
      final cached = prefs.getCachedJson('memories_list');
      if (cached is List) {
        _memories = cached.map((e) => Memory.fromJson(Map<String, dynamic>.from(e))).toList();
        _hasMore = _memories.length >= _pageSize;
        _loading = false;
        _unreviewed = _memories
            .where((m) => !m.reviewed && m.createdAt.isAfter(DateTime.now().subtract(const Duration(days: 1))))
            .toList();
        _setCategories();
      }
      final pending = prefs.getCachedJson('memories_pending');
      if (pending is List) {
        _hasSnapshot = cached is List;
        _pendingFacts = pending.map((e) => Memory.fromJson(Map<String, dynamic>.from(e))).toList();
      }
    } catch (e) {
      debugPrint('MemoriesProvider: cache load error: $e');
    }
  }

  Future<void> init() => ensureLoaded();

  /// A real refresh is shared by all callers, including when cached data is visible.
  Future<void> loadMemories() {
    final previous = _refreshing;
    late final Future<void> request;
    request = (() async {
      if (previous != null) await previous;
      await _fetchMemories();
    })()
        .whenComplete(() {
      if (identical(_refreshing, request)) _refreshing = null;
    });
    _refreshing = request;
    return request;
  }

  Future<void> _fetchMemories() async {
    final owner = ApiConfig().externalUserId;
    final reviewEpoch = _reviewEpoch;
    _loadMoreEpoch++;
    _loading = _memories.isEmpty;
    notifyListeners();
    try {
      // Independent lists: do not make the pending card wait for confirmed facts.
      final results = await Future.wait([
        _fetch(limit: _pageSize, offset: 0, status: 'confirmed'),
        _fetch(limit: _pageSize, offset: 0, status: 'pending'),
      ]);
      if (owner != ApiConfig().externalUserId || reviewEpoch != _reviewEpoch || _reviewsInFlight > 0) return;
      final fetched = results[0];
      final pending = results[1];
      if (fetched != null) {
        _memories = fetched;
        _hasMore = fetched.length >= _pageSize;
        _unreviewed = _memories
            .where((m) => !m.reviewed && m.createdAt.isAfter(DateTime.now().subtract(const Duration(days: 1))))
            .toList();
        _persist();
      }
      if (pending != null) {
        _pendingFacts = pending;
        SharedPreferencesUtil().cacheJson('memories_pending', pending.map((m) => m.toJson()).toList());
      }
      if (fetched != null && pending != null) {
        _hasSnapshot = true;
        await _cache.markFetched(owner: owner);
      }
    } catch (e) {
      debugPrint('MemoriesProvider: load error: $e');
    } finally {
      _loading = false;
      _setCategories();
    }
  }

  int _loadMoreEpoch = 0;

  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore || _searchQuery.isNotEmpty) return;
    _loadingMore = true;
    final epoch = _loadMoreEpoch;
    notifyListeners();

    try {
      final expectedOffset = _memories.length;
      final moreMemories = await getMemories(limit: _pageSize, offset: expectedOffset);
      if (epoch != _loadMoreEpoch) {
        _loadingMore = false;
        notifyListeners();
        return;
      }
      // 这一页没拉到，别当成"到底了"——保持 _hasMore，下次滑动还能再试。
      // （finally 会复位 _loadingMore 并 notifyListeners。）
      if (moreMemories == null) return;
      if (moreMemories.isEmpty) {
        _hasMore = false;
      } else {
        _memories.addAll(moreMemories);
        _hasMore = moreMemories.length >= _pageSize;
      }
    } catch (e) {
      debugPrint('Error loading more memories: $e');
    } finally {
      _loadingMore = false;
      _setCategories();
    }
  }

  /// Refresh memories from server (pull-to-refresh)
  Future<void> refresh() => loadMemories();

  /// 气泡卡「没错」：把这条待确认事实写进正式事实库。
  ///
  /// 乐观更新：先把它从待确认挪进 `_memories` 并刷 UI，再打服务端；失败回滚。
  /// `markAsked` 记一笔，即便这次没拍成，轮换也会先去问别的那条。
  Future<void> confirmFact(Memory memory) async {
    _reviewEpoch++;
    _reviewsInFlight++;
    _cache.invalidate();
    try {
      FactConfirmRotation.markAsked(memory.id);
      MixpanelManager().memoryReviewed(memory, true, 'fact_bubble_card');

      _pendingFacts.removeWhere((m) => m.id == memory.id);
      if (_pickedFact?.id == memory.id) _pickedFact = null;
      memory.reviewed = true;
      memory.userReview = true;
      if (_memories.every((m) => m.id != memory.id)) {
        _memories.add(memory);
      }
      _persist();
      _setCategories();

      final ok = await _review(memory.id, true);
      if (!ok) {
        // 服务端没写成，回滚：从正式列表撤回、放回待确认。
        _memories.removeWhere((m) => m.id == memory.id);
        memory.reviewed = false;
        memory.userReview = null;
        if (_pendingFacts.every((m) => m.id != memory.id)) {
          _pendingFacts.add(memory);
        }
        _persist();
        _setCategories();
      }
    } finally {
      _reviewsInFlight--;
      _reviewEpoch++;
      await _cache.invalidate();
    }
  }

  /// 气泡卡「不对」：否决这条待确认事实。
  ///
  /// 记住否决、不再问（tombstone）：`user_review=false`，不进正式列表、也不物理删——
  /// 留着它的文本进去重上下文，同一句话下次提取会被挡掉，不会反复来问。
  Future<void> rejectFact(Memory memory) async {
    _reviewEpoch++;
    _reviewsInFlight++;
    _cache.invalidate();
    try {
      FactConfirmRotation.markAsked(memory.id);
      MixpanelManager().memoryReviewed(memory, false, 'fact_bubble_card');

      _pendingFacts.removeWhere((m) => m.id == memory.id);
      if (_pickedFact?.id == memory.id) _pickedFact = null;
      notifyListeners();

      _persist();
      final ok = await _review(memory.id, false);
      if (!ok) {
        // 没写成放回去，下次再问。
        if (_pendingFacts.every((m) => m.id != memory.id)) {
          _pendingFacts.add(memory);
        }
        _persist();
        notifyListeners();
      }
    } finally {
      _reviewsInFlight--;
      _reviewEpoch++;
      await _cache.invalidate();
    }
  }

  Future<bool> deleteMemory(Memory memory) async {
    final owner = ApiConfig().externalUserId;
    final ok = await deleteMemoryServer(memory.id);
    if (!ok || owner != ApiConfig().externalUserId) return false;
    _memories.removeWhere((m) => m.id == memory.id);
    _unreviewed.removeWhere((m) => m.id == memory.id);
    _persist();
    _setCategories();
    return true;
  }

  void deleteAllMemories() async {
    final int countBeforeDeletion = _memories.length;
    await deleteAllMemoriesServer();
    _memories.clear();
    _unreviewed.clear();
    if (countBeforeDeletion > 0) {
      MixpanelManager().memoriesAllDeleted(countBeforeDeletion);
    }
    _setCategories();
  }

  Future<void> createMemory(String content,
      [MemoryVisibility visibility = MemoryVisibility.public,
      MemoryCategory category = MemoryCategory.interesting]) async {
    // 优先用服务端返回的那一条：id 由后端生成，本地自造 uuid 的话这条新事实在
    // 下次 loadMemories 之前无法编辑/删除（按 id 请求会 404）。
    final created = await createMemoryServer(content, visibility.name);
    _memories.add(created ??
        Memory(
          id: const Uuid().v4(),
          uid: SharedPreferencesUtil().uid,
          content: content,
          category: category,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          conversationId: null,
          reviewed: false,
          manuallyAdded: true,
          visibility: visibility,
        ));
    _persist();
    _setCategories();
  }

  Future<void> updateMemoryVisibility(Memory memory, MemoryVisibility visibility) async {
    await updateMemoryVisibilityServer(memory.id, visibility.name);

    final idx = _memories.indexWhere((m) => m.id == memory.id);
    if (idx != -1) {
      Memory memoryToUpdate = _memories[idx];
      memoryToUpdate.visibility = visibility;
      _memories[idx] = memoryToUpdate;
      _unreviewed.removeWhere((m) => m.id == memory.id);

      MixpanelManager().memoryVisibilityChanged(memoryToUpdate, visibility);
      _setCategories();
    }
  }

  void editMemory(Memory memory, String value, [MemoryCategory? category]) async {
    // 服务端没写成就别改本地：否则界面显示新内容，下次拉取又变回旧的，
    // 用户以为编辑丢了（其实是本地先信了一个没落库的值）。
    final ok = await editMemoryServer(memory.id, value);
    if (!ok) return;

    final idx = _memories.indexWhere((m) => m.id == memory.id);
    if (idx != -1) {
      memory.content = value;
      if (category != null) {
        memory.category = category;
      }
      memory.updatedAt = DateTime.now();
      memory.edited = true;
      _memories[idx] = memory;

      // Remove from unreviewed if it was there
      final unreviewedIdx = _unreviewed.indexWhere((m) => m.id == memory.id);
      if (unreviewedIdx != -1) {
        _unreviewed.removeAt(unreviewedIdx);
      }

      _persist();
      _setCategories();
    }
  }

  void reviewMemory(Memory memory, bool approved, String source) async {
    MixpanelManager().memoryReviewed(memory, approved, source);

    await reviewMemoryServer(memory.id, approved);

    final idx = _memories.indexWhere((m) => m.id == memory.id);
    if (idx != -1) {
      memory.reviewed = true;
      memory.userReview = approved;

      if (!approved) {
        memory.deleted = true;
        _memories.removeAt(idx);
        _unreviewed.remove(memory);
        // Don't call deleteMemory again because it would be a duplicate deletion
      } else {
        _memories[idx] = memory;

        // Remove from unreviewed list
        final unreviewedIdx = _unreviewed.indexWhere((m) => m.id == memory.id);
        if (unreviewedIdx != -1) {
          _unreviewed.removeAt(unreviewedIdx);
        }
      }

      _setCategories();
    }
  }

  Future<void> updateAllMemoriesVisibility(bool makePrivate) async {
    final visibility = makePrivate ? MemoryVisibility.private : MemoryVisibility.public;
    int updatedCount = 0;
    List<Memory> memoriesSuccessfullyUpdated = [];

    for (var memory in List.from(_memories)) {
      if (memory.visibility != visibility) {
        try {
          await updateMemoryVisibilityServer(memory.id, visibility.name);
          final idx = _memories.indexWhere((m) => m.id == memory.id);
          if (idx != -1) {
            _memories[idx].visibility = visibility;
            memoriesSuccessfullyUpdated.add(_memories[idx]);
            updatedCount++;
          }
        } catch (e) {
          print('Failed to update visibility for memory ${memory.id}: $e');
        }
      }
    }

    if (updatedCount > 0) {
      MixpanelManager().memoriesAllVisibilityChanged(visibility, updatedCount);
    }

    _setCategories();
  }
}
