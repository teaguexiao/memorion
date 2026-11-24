import 'package:memorion/backend/api_config.dart';
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/services/photo_sync_service.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/services/wals.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:memorion/services/notifications/notification_service.dart';
import 'package:memorion/utils/notification_prefs.dart';
import 'package:memorion/utils/task_confirm_rotation.dart';
import 'package:memorion/utils/task_reminder_state.dart';

typedef ConversationListFetcher = Future<List<ServerConversation>> Function({
  int limit,
  int offset,
  List<ConversationStatus> statuses,
  bool includeDiscarded,
});
typedef ConversationSearcher = Future<(List<ServerConversation>, int, int)> Function(
  String query, {
  int? page,
  int? limit,
  bool includeDiscarded,
});

Future<List<ServerConversation>> _fetchProcessingSnapshot({
  int limit = 50,
  int offset = 0,
  List<ConversationStatus> statuses = const [],
  bool includeDiscarded = false,
}) =>
    getConversations(
        limit: limit, offset: offset, statuses: statuses, includeDiscarded: includeDiscarded, throwOnError: true);

bool _isProcessing(ServerConversation conversation) =>
    conversation.status == ConversationStatus.processing || conversation.status == ConversationStatus.in_progress;

// An unfinished capture can wait indefinitely for more segments or an explicit
// finish call. It is not cloud processing until it has ended or entered processing.
bool _isCloudProcessing(ServerConversation conversation) =>
    conversation.status == ConversationStatus.processing ||
    (conversation.status == ConversationStatus.in_progress && conversation.finishedAt != null);

class ConversationProvider extends ChangeNotifier implements IWalServiceListener, IWalSyncProgressListener {
  final ConversationListFetcher _fetch;
  final ConversationSearcher _search;
  final ConversationListFetcher _processingFetch;
  final Future<ServerConversation?> Function(String) _processingGet;
  final AudioJobsApi _audioJobs;
  List<AudioProcessingJob> _cloudJobs = [];
  Set<String> _pendingPublicationIds = {};
  // Cloud status/detail reads can insert old rows beyond the loaded list pages.
  final Set<String> _unpagedCloudIds = {};
  Future<void>? _cloudRefresh;
  String? _processingOwner;
  bool _disposed = false;
  DateTime? _lastCloudRefresh;
  final IWalService? _walService;
  List<ServerConversation> conversations = [];
  List<ServerConversation> searchedConversations = [];
  Map<DateTime, List<ServerConversation>> groupedConversations = {};

  bool isLoadingConversations = false;

  /// 首次拉取是否已经跑完（不管成功与否）。
  ///
  /// `isLoadingConversations` 初值是 false，而首帧拉取要等 addPostFrameCallback
  /// 才发起 —— 光看它会让首页第一帧命中「空态」，明明有会话却闪一下「还没听到
  /// 什么」。用这个标志把「还没开始拉」也算进加载中，交给骨架屏覆盖。
  bool hasLoadedConversationsOnce = false;
  // Legacy discarded-only filter. The default list includes processed recordings,
  // including discarded ones: content filtering must not hide retained audio.
  bool showDiscardedConversations = false;
  DateTime? selectedDate;

  /// 服务端还有更早的会话没拉。只在**返回空**时才置 false —— 详见
  /// [getMoreConversationsFromServer] 里为什么不能用「返回条数 < limit」。
  bool hasMoreConversations = true;

  /// 每页条数。必须和 `getConversations` 的默认 limit 一致，否则翻页会跳段。
  static const int conversationsPageSize = 50;

  String previousQuery = '';
  int totalSearchPages = 1;
  int currentSearchPage = 1;

  Timer? _processingConversationWatchTimer;

  // Add debounce mechanism for refresh
  Timer? _refreshDebounceTimer;
  DateTime? _lastRefreshTime;
  static const Duration _refreshCooldown = Duration(seconds: 60); // Minimum time between refreshes

  List<ServerConversation> processingConversations = [];

  bool get hasCloudProcessing =>
      _cloudJobs.isNotEmpty ||
      _pendingPublicationIds.isNotEmpty ||
      processingConversations.any(_isCloudProcessing) ||
      conversations.any(_isCloudProcessing);

  IWalService get _wal => _walService ?? ServiceManager.instance().wal;

  List<Wal> _missingWals = [];

  List<Wal> get missingWals => _missingWals;

  int get missingWalsInSeconds => _missingWals.isEmpty ? 0 : _missingWals.map((val) => val.seconds).reduce((a, b) => a + b);

  double _walsSyncedProgress = 0.0;

  double get walsSyncedProgress => _walsSyncedProgress;

  bool isSyncing = false;
  bool syncCompleted = false;
  int _lastSyncedTotalSeconds = 0;
  int get lastSyncedTotalSeconds => _lastSyncedTotalSeconds;
  List<bool> multipleSyncs = [];
  bool isFetchingConversations = false;
  List<SyncedConversationPointer> syncedConversationsPointers = [];

  ConversationProvider(
      {ConversationListFetcher? fetch,
      ConversationSearcher? search,
      IWalService? wal,
      ConversationListFetcher? processingFetch,
      Future<ServerConversation?> Function(String)? processingGet,
      AudioJobsApi? audioJobs})
      : _fetch = fetch ?? getConversations,
        _search = search ?? searchConversationsServer,
        _walService = wal,
        _processingFetch = processingFetch ?? fetch ?? _fetchProcessingSnapshot,
        _processingGet = processingGet ?? ((id) => getConversationById(id, throwOnError: true)),
        _audioJobs = audioJobs ?? AudioJobsApi() {
    _wal.subscribe(this, this);
    _preload();
  }

  _preload() async {
    _missingWals = await _wal.getSyncs().getMissingWals();
    notifyListeners();
  }

  void resetGroupedConvos() {
    groupConversationsByDate();
  }

  Future updateSearchedConvoDetails(String id, DateTime date, int idx) async {
    var convo = await getConversationById(id);
    if (convo != null) {
      updateSpecificGroupedConvo(convo, date, idx);
    }
    notifyListeners();
  }

  void updateSpecificGroupedConvo(ServerConversation convo, DateTime date, int idx) {
    final list = groupedConversations[date];
    if (list == null || idx < 0 || idx >= list.length) return;
    list[idx] = convo;
    notifyListeners();
  }

  Future<void> searchConversations(String query, {bool showShimmer = false}) async {
    if (query.isEmpty) {
      previousQuery = "";
      currentSearchPage = 0;
      totalSearchPages = 0;
      searchedConversations = [];
      groupConversationsByDate();
      return;
    }

    if (showShimmer) {
      setLoadingConversations(true);
    } else {
      setIsFetchingConversations(true);
    }

    previousQuery = query;
    var (convos, current, total) = await _search(query, includeDiscarded: true);
    convos.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    searchedConversations = convos;
    currentSearchPage = current;
    totalSearchPages = total;
    groupSearchConvosByDate();

    if (showShimmer) {
      setLoadingConversations(false);
    } else {
      setIsFetchingConversations(false);
    }

    notifyListeners();
  }

  Future<void> searchMoreConversations() async {
    if (totalSearchPages < currentSearchPage + 1) {
      return;
    }
    setLoadingConversations(true);
    var (newConvos, current, total) = await _search(
      previousQuery,
      page: currentSearchPage + 1,
      includeDiscarded: true,
    );
    searchedConversations.addAll(newConvos);
    searchedConversations.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    totalSearchPages = total;
    currentSearchPage = current;
    groupSearchConvosByDate();
    setLoadingConversations(false);
    notifyListeners();
  }

  int groupedSearchConvoIndex(ServerConversation convo) {
    var date = DateTime(convo.createdAt.year, convo.createdAt.month, convo.createdAt.day);
    if (groupedConversations.containsKey(date)) {
      return groupedConversations[date]!.indexWhere((element) => element.id == convo.id);
    }
    return -1;
  }

  void addProcessingConversation(ServerConversation conversation) {
    processingConversations.removeWhere((c) => c.id == conversation.id);
    processingConversations.add(conversation);
    notifyListeners();
  }

  void removeProcessingConversation(String conversationId) {
    processingConversations.removeWhere((m) => m.id == conversationId);
    notifyListeners();
  }

  void onConversationTap(int idx) {
    if (idx < 0 || idx > conversations.length - 1) {
      return;
    }
    var changed = false;
    if (conversations[idx].isNew) {
      conversations[idx].isNew = false;
      changed = true;
    }
    if (changed) {
      groupConversationsByDate();
    }
  }

  void toggleDiscardConversations() {
    showDiscardedConversations = !showDiscardedConversations;

    // Clear grouped conversations to show shimmer effect while loading
    groupedConversations = {};
    notifyListeners();

    if (previousQuery.isNotEmpty) {
      searchConversations(previousQuery, showShimmer: true);
    } else {
      fetchConversations();
    }

    MixpanelManager().showDiscardedMemoriesToggled(showDiscardedConversations);
  }

  void setLoadingConversations(bool value) {
    isLoadingConversations = value;
    notifyListeners();
  }

  Future refreshConversations() async {
    // Debounce mechanism: only refresh if enough time has passed since last refresh
    final now = DateTime.now();
    if (_lastRefreshTime != null && now.difference(_lastRefreshTime!) < _refreshCooldown) {
      debugPrint('Skipping conversations refresh - too soon since last refresh (${now.difference(_lastRefreshTime!).inSeconds}s ago)');
      return;
    }

    // Cancel any pending refresh
    _refreshDebounceTimer?.cancel();

    // Set debounce timer
    _refreshDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _lastRefreshTime = DateTime.now();
      _fetchNewConversations();
    });
  }

  // Force refresh bypassing debounce (for manual refresh, connection restored, etc.)
  Future forceRefreshConversations() async {
    _refreshDebounceTimer?.cancel();
    _lastRefreshTime = DateTime.now();
    await _fetchNewConversations();
  }

  Future _fetchNewConversations() async {
    setLoadingConversations(true);
    try {
      final recent = await _getConversationsFromServer();
      _unpagedCloudIds.removeAll(recent.map((c) => c.id));
      _mergeConversations(recent);
      _regroupAfterProcessing();
    } finally {
      setLoadingConversations(false);
    }
  }

  void _mergeConversations(List<ServerConversation> incoming) {
    final byId = {for (final c in conversations) c.id: c};
    final pending = {for (final c in processingConversations) c.id: c};
    for (final c in incoming) {
      byId[c.id] = c;
      if (_isProcessing(c)) {
        pending[c.id] = c;
      } else {
        pending.remove(c.id);
      }
    }
    conversations = byId.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    processingConversations = pending.values.toList();
  }

  void _regroupAfterProcessing() {
    if (previousQuery.isNotEmpty) {
      final latest = {for (final c in conversations) c.id: c};
      searchedConversations = searchedConversations.map((c) => latest[c.id] ?? c).toList();
      _groupSearchConvosByDateWithoutNotify();
    } else {
      _groupConversationsByDateWithoutNotify();
    }
  }

  void startCloudProcessingWatch() {
    _processingConversationWatchTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (hasCloudProcessing ||
          _lastCloudRefresh == null ||
          DateTime.now().difference(_lastCloudRefresh!) >= const Duration(seconds: 15)) {
        unawaited(refreshCloudProcessing());
      }
    });
    unawaited(refreshCloudProcessing());
  }

  void stopCloudProcessingWatch() {
    _processingConversationWatchTimer?.cancel();
    _processingConversationWatchTimer = null;
  }

  Future<void> refreshCloudProcessing() => _cloudRefresh ??= _refreshCloudProcessing().whenComplete(() {
        _cloudRefresh = null;
      });

  Future<List<ServerConversation>> _allProcessingConversations() async {
    final pending = <ServerConversation>[];
    while (true) {
      final page = await _processingFetch(
          limit: 500,
          offset: pending.length,
          statuses: const [ConversationStatus.processing, ConversationStatus.in_progress],
          includeDiscarded: true);
      pending.addAll(page);
      if (page.length < 500) return pending;
    }
  }

  Future<void> _refreshCloudProcessing() async {
    final owner = _audioJobs.ownerId;
    if ((_processingOwner != null && _processingOwner != owner) || owner.isEmpty) {
      _cloudJobs = [];
      _pendingPublicationIds = {};
      processingConversations = [];
      conversations.removeWhere(_isProcessing);
      _regroupAfterProcessing();
      if (!_disposed) notifyListeners();
    }
    _processingOwner = owner;
    if (owner.isEmpty || _disposed) return;
    bool current() => !_disposed && owner == _audioJobs.ownerId;
    final previous = {
      for (final c in [...conversations, ...processingConversations])
        if (_isProcessing(c)) c.id: c
    };
    final previousIds = {
      ...previous.values.where(_isCloudProcessing).map((c) => c.id),
      ..._cloudJobs.map((j) => j.conversationId),
      ..._pendingPublicationIds,
    };
    try {
      final results = await Future.wait<dynamic>([
        _allProcessingConversations(),
        _audioJobs.active(),
        _processingFetch(includeDiscarded: true),
      ]);
      if (!current()) return;
      final pending = {for (final c in results[0] as List<ServerConversation>) c.id: c};
      final jobs = (results[1] as List<AudioProcessingJob>).where((j) => j.active).toList();
      final incoming = {for (final c in results[2] as List<ServerConversation>) c.id: c};
      final recentIds = incoming.keys.toSet();
      for (final c in incoming.values) {
        if (_isProcessing(c)) {
          pending[c.id] = c;
        } else {
          pending.remove(c.id);
        }
      }
      final activeIds = jobs.map((j) => j.conversationId).toSet();
      final removed = <String>{};
      final unresolved = <String>{};
      // A completed old recording may be outside the newest conversation page.
      for (final id in previousIds.difference({...pending.keys, ...activeIds})) {
        if (incoming[id]?.status == ConversationStatus.completed) continue;
        try {
          final c = await _processingGet(id);
          if (c == null) {
            removed.add(id); // Confirmed 404, not a network error.
          } else {
            incoming[id] = c;
            if (_isProcessing(c)) pending[id] = c;
          }
        } catch (_) {
          unresolved.add(id);
          if (previous[id] case final c?) pending[id] = c;
        }
      }
      if (!current()) return;
      conversations.removeWhere((c) => removed.contains(c.id));
      _unpagedCloudIds.removeAll({...removed, ...recentIds});
      _unpagedCloudIds.addAll({...pending.keys, ...incoming.keys}
          .difference({...conversations.map((c) => c.id), ...recentIds}));
      _mergeConversations([...pending.values, ...incoming.values]);
      processingConversations = pending.values.toList();
      _cloudJobs = jobs;
      _pendingPublicationIds = unresolved;
      _regroupAfterProcessing();
      SharedPreferencesUtil().cachedConversations =
          conversations.where((c) => c.status == ConversationStatus.completed).toList();
      notifyListeners();
    } catch (e) {
      // Preserve the last confirmed state during outages; an error is not an empty queue.
      debugPrint('Could not refresh cloud processing: $e');
    } finally {
      _lastCloudRefresh = DateTime.now();
    }
  }

  Future fetchConversations() async {
    previousQuery = "";
    currentSearchPage = 0;
    totalSearchPages = 0;
    searchedConversations = [];
    // 重新拉第一页就重置翻页状态：否则翻到底之后下拉刷新，列表回到 50 条却仍然
    // 记着「没有更多了」，再也翻不动。
    hasMoreConversations = true;

    // Load cache immediately so UI is not blank
    if (conversations.isEmpty) {
      final cached = SharedPreferencesUtil().cachedConversations;
      if (cached.isNotEmpty) {
        conversations = cached;
        searchedConversations = conversations;
        _groupConversationsByDateWithoutNotify();
        notifyListeners();
      }
    }

    setLoadingConversations(true);
    try {
      conversations = await _getConversationsFromServer();
      _unpagedCloudIds.clear();
    } finally {
      // 拉取抛异常（断网 / 401）时也要收工，否则骨架屏会一直挂着不落地。
      hasLoadedConversationsOnce = true;
      setLoadingConversations(false);
    }

    // processing convos
    processingConversations = conversations.where(_isProcessing).toList();

    // Keep pending rows in the list so pagination offsets still match the server.
    if (conversations.isEmpty) {
      conversations = SharedPreferencesUtil().cachedConversations;
    } else {
      SharedPreferencesUtil().cachedConversations =
          conversations.where((c) => c.status == ConversationStatus.completed).toList();
    }
    if (searchedConversations.isEmpty) {
      searchedConversations = conversations;
    }
    _groupConversationsByDateWithoutNotify();

    notifyListeners();

    // 拉到最新会话后，按当前待办的到期时间重排任务提醒本地推送（尊重开关/权限/静默时段）。
    NotificationPrefs.applyTaskReminderSchedule(conversations);

    // Cache photos from conversations to local storage for persistence after app restart
    _cacheConversationPhotos(conversations);
  }

  /// Cache photos from conversations to local storage asynchronously.
  /// This allows photos to persist after app restart.
  void _cacheConversationPhotos(List<ServerConversation> conversations) {
    PhotoSyncService().cachePhotosForConversations(
      conversations,
      onPhotoCached: (photoId) {
        // Notify listeners when a photo is cached so UI can update
        notifyListeners();
      },
    );
  }

  Future getInitialConversations() async {
    await fetchConversations();
  }

  List<ServerConversation> _filterOutConvos(List<ServerConversation> convos) {
    return convos.where((convo) {
      if (convo.deleted) return false;
      if (showDiscardedConversations && !convo.discarded) return false;
      if (convo.discarded && convo.status != ConversationStatus.completed) return false;

      // Apply date filter if selected
      if (selectedDate != null) {
        final start = convo.startedAt ?? convo.createdAt;
        var convoDate = DateTime(start.year, start.month, start.day);
        var filterDate = DateTime(selectedDate!.year, selectedDate!.month, selectedDate!.day);
        if (convoDate != filterDate) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Filter conversations by a specific date
  Future<void> filterConversationsByDate(DateTime date) async {
    selectedDate = date;

    // Clear search when applying date filter
    previousQuery = "";
    currentSearchPage = 0;
    totalSearchPages = 0;
    searchedConversations = [];

    // Re-apply grouping with date filter
    groupConversationsByDate();
    notifyListeners();
  }

  /// Clear the date filter
  Future<void> clearDateFilter() async {
    selectedDate = null;

    // Clear search when clearing date filter
    previousQuery = "";
    currentSearchPage = 0;
    totalSearchPages = 0;
    searchedConversations = [];

    // Re-apply grouping without date filter
    groupConversationsByDate();
    notifyListeners();
  }

  void _groupSearchConvosByDateWithoutNotify() {
    groupedConversations = {};
    for (var conversation in _filterOutConvos(searchedConversations)) {
      var date = DateTime(conversation.createdAt.year, conversation.createdAt.month, conversation.createdAt.day);
      if (!groupedConversations.containsKey(date)) {
        groupedConversations[date] = [];
      }
      groupedConversations[date]?.add(conversation);
    }

    // Sort
    for (final date in groupedConversations.keys) {
      groupedConversations[date]?.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
  }

  void _groupConversationsByDateWithoutNotify() {
    groupedConversations = {};
    for (var conversation in _filterOutConvos(conversations)) {
      var date = DateTime(conversation.createdAt.year, conversation.createdAt.month, conversation.createdAt.day);
      if (!groupedConversations.containsKey(date)) {
        groupedConversations[date] = [];
      }
      groupedConversations[date]?.add(conversation);
    }

    // Sort
    for (final date in groupedConversations.keys) {
      groupedConversations[date]?.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
  }

  void groupConversationsByDate() {
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
  }

  /// 月历活跃度：按录制日期统计已完成记录，包括已过滤但保留的录音。
  ///
  /// 基于完整的 [conversations]，**刻意不走 [groupedConversations]**——后者会被
  /// `selectedDate` 日期筛选削成只剩选中那一天，拿它打月历的点会导致「选了某天后
  /// 整月只剩一个点」。这里始终用未筛选的全量列表。
  ///
  /// key 为按天归零的 [DateTime](y, m, d)，value 为当天会话数。数据仅覆盖**已加载**
  /// 的会话（默认最近若干页），翻到更久以前的月份可能无标记——与列表本身的加载范围
  /// 一致，是可接受的近似。
  Map<DateTime, int> get conversationCountByDay {
    final map = <DateTime, int>{};
    for (final c in conversations) {
      if (c.deleted || c.status != ConversationStatus.completed) continue;
      final start = c.startedAt ?? c.createdAt;
      final d = DateTime(start.year, start.month, start.day);
      map[d] = (map[d] ?? 0) + 1;
    }
    return map;
  }

  void groupSearchConvosByDate() {
    _groupSearchConvosByDateWithoutNotify();
    notifyListeners();
  }

  Future _getConversationsFromServer() async {
    return await _fetch(includeDiscarded: true);
  }

  void updateActionItemState(String convoId, bool state, int i, DateTime date) {
    conversations.firstWhere((element) => element.id == convoId).structured.actionItems[i].completed = state;
    groupedConversations[date]!.firstWhere((element) => element.id == convoId).structured.actionItems[i].completed = state;
    notifyListeners();
  }

  /// 往前翻一页。
  ///
  /// 🚨 判据刻意是「**返回空**才算到底」，不是「返回条数 < limit」。后者曾经以
  /// `conversations.length % 50 != 0` 的形式存在，把首页锁死在第一页整整一个月：
  /// 服务端那时把 `limit` 打在丢弃过滤**之前**，请求 50 条只回 21 条（那天丢弃率
  /// 57%），于是 `21 % 50 != 0` 永远成立，一次都没往下翻过。表现是「昨天之前的内容
  /// 一条都看不到」，而两边单独看都说得通 —— 服务端"少给几条"，客户端"看着像到底了"。
  ///
  /// 服务端已经把过滤下推进查询（`get_conversations`），所以现在满页就是满页。但这个
  /// 判据仍然按「返回空」写：客户端和服务端不同步发布，App 先上线时旧服务端仍会少给，
  /// 用 `< limit` 会立刻退回上面那个死锁。代价只是到底时多一次空请求。
  ///
  /// 去重同理是防御：旧服务端的 `offset` 打在未过滤序列上，同一条会重复回来（实测第
  /// 2 页 18 条里重复 10 条）。而「返回非空但一条新的都没有」意味着 offset 推不动了,
  /// 此时必须停 —— 否则 `offset = conversations.length` 不变，会无限请求同一页。
  Future getMoreConversationsFromServer() async {
    if (!hasMoreConversations) return;
    if (isLoadingConversations) return;
    setLoadingConversations(true);
    try {
      final fetched = await _fetch(
        offset: conversations.where((c) => !_unpagedCloudIds.contains(c.id)).length,
        includeDiscarded: true,
      );
      if (fetched.isEmpty) {
        hasMoreConversations = false;
      } else {
        final known = conversations.map((c) => c.id).toSet();
        final fresh = fetched.where((c) => !known.contains(c.id) || _unpagedCloudIds.contains(c.id)).toList();
        if (fresh.isEmpty) {
          hasMoreConversations = false;
        } else {
          _unpagedCloudIds.removeAll(fetched.map((c) => c.id));
          _mergeConversations(fetched);
          _groupConversationsByDateWithoutNotify();
        }
      }
    } finally {
      // 抛异常也要收工，否则 isLoadingConversations 挂住 ⇒ 再也翻不动页。
      setLoadingConversations(false);
    }
    notifyListeners();
  }

  void addConversation(ServerConversation conversation) {
    _mergeConversations([conversation]);
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
  }

  void upsertConversation(ServerConversation conversation) {
    int idx = conversations.indexWhere((m) => m.id == conversation.id);
    if (idx < 0) {
      addConversation(conversation);
    } else {
      updateConversation(conversation, idx);
    }
  }

  void updateConversationInSortedList(ServerConversation conversation) {
    var date = DateTime(conversation.createdAt.year, conversation.createdAt.month, conversation.createdAt.day);
    if (groupedConversations.containsKey(date)) {
      int idx = groupedConversations[date]!.indexWhere((element) => element.id == conversation.id);
      if (idx != -1) {
        groupedConversations[date]![idx] = conversation;
      }
    }
    notifyListeners();
  }

  (int, DateTime) addConversationWithDateGrouped(ServerConversation conversation) {
    conversations.insert(0, conversation);
    conversations.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    int idx;
    var memDate = DateTime(conversation.createdAt.year, conversation.createdAt.month, conversation.createdAt.day);
    if (groupedConversations.containsKey(memDate)) {
      idx = groupedConversations[memDate]!.indexWhere((element) => element.createdAt.isBefore(conversation.createdAt));
      if (idx == -1) {
        groupedConversations[memDate]!.insert(0, conversation);
        idx = 0;
      } else {
        groupedConversations[memDate]!.insert(idx, conversation);
      }
    } else {
      groupedConversations[memDate] = [conversation];
      groupedConversations = Map.fromEntries(groupedConversations.entries.toList()..sort((a, b) => b.key.compareTo(a.key)));
      idx = 0;
    }
    return (idx, memDate);
  }

  void updateConversation(ServerConversation conversation, [int? index]) {
    _mergeConversations([conversation]);
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
  }

  // _handleCalendarCreation(ServerMemory memory) {
  //   if (!SharedPreferencesUtil().calendarEnabled) return;
  //   if (SharedPreferencesUtil().calendarType != 'auto') return;
  //
  //   List<Event> events = memory.structured.events;
  //   if (events.isEmpty) return;
  //
  //   List<int> indexes = events.mapIndexed((index, e) => index).toList();
  //   setMemoryEventsState(memory.id, indexes, indexes.map((_) => true).toList());
  //   for (var i = 0; i < events.length; i++) {
  //     if (events[i].created) continue;
  //     events[i].created = true;
  //     CalendarUtil().createEvent(
  //       events[i].title,
  //       events[i].startsAt,
  //       events[i].duration,
  //       description: events[i].description,
  //     );
  //   }
  // }

  /////////////////////////////////////////////////////////////////
  ////////// Delete Memory With Undo Functionality ///////////////

  Map<String, ServerConversation> memoriesToDelete = {};
  String? lastDeletedConversationId;
  Map<String, DateTime> deleteTimestamps = {};

  void deleteConversationLocally(ServerConversation conversation, int index, DateTime date) {
    if (lastDeletedConversationId != null && memoriesToDelete.containsKey(lastDeletedConversationId) && DateTime.now().difference(deleteTimestamps[lastDeletedConversationId]!) < const Duration(seconds: 3)) {
      deleteConversationOnServer(lastDeletedConversationId!);
    }

    memoriesToDelete[conversation.id] = conversation;
    lastDeletedConversationId = conversation.id;
    deleteTimestamps[conversation.id] = DateTime.now();
    conversations.removeWhere((element) => element.id == conversation.id);
    groupedConversations[date]!.removeAt(index);
    if (groupedConversations[date]!.isEmpty) {
      groupedConversations.remove(date);
    }
    notifyListeners();
    Future.delayed(const Duration(seconds: 3), () {
      if (memoriesToDelete.containsKey(conversation.id) && lastDeletedConversationId == conversation.id) {
        deleteConversationOnServer(conversation.id);
      }
    });
  }

  void deleteConversationOnServer(String conversationId) {
    deleteConversationServer(conversationId);
    memoriesToDelete.remove(conversationId);
    deleteTimestamps.remove(conversationId);
    if (lastDeletedConversationId == conversationId) {
      lastDeletedConversationId = null;
    }
  }

  void undoDeletedConversation(ServerConversation conversation) {
    if (!conversations.any((e) => e.id == conversation.id)) {
      conversations.add(conversation);
      conversations.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _groupConversationsByDateWithoutNotify();
    }
    memoriesToDelete.remove(conversation.id);
    deleteTimestamps.remove(conversation.id);
    if (lastDeletedConversationId == conversation.id) {
      lastDeletedConversationId = null;
    }
    notifyListeners();
  }

  /////////////////////////////////////////////////////////////////

  Future<bool> commitConversationDeletion(String id) async {
    final owner = ApiConfig().externalUserId;
    final ok = await deleteConversationServer(id);
    if (!ok || owner != ApiConfig().externalUserId) return false;
    conversations.removeWhere((c) => c.id == id);
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
    return true;
  }

  void deleteConversation(ServerConversation conversation, int index) {
    conversations.removeWhere((element) => element.id == conversation.id);
    deleteConversationServer(conversation.id);
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
  }

  /// 设置会话的⭐高亮标记（`structured.is_highlighted`）。
  ///
  /// 这是首页 P-01 章节卡⭐高亮标签的**唯一**触发路径——与章节详情
  /// 「值得回顾的时刻」(`structured.highlights`) 已解耦。
  ///
  /// 预留给硬件按钮：未来固件上报「按钮按下」后，由接收方（BLE 回调 / 后端推送）
  /// 定位对应会话并调用本方法。当前尚无调用方，故线上高亮恒为空。
  ///
  /// TODO(hardware-button): 硬件链路接入时，补上后端持久化调用
  /// （形如 `PATCH /v1/conversations/{id}/highlight`，参照
  /// [togglePinConversationServer]），并在失败时回滚本地状态。
  void setConversationHighlighted(String conversationId, bool highlighted) {
    final target = conversations.firstWhereOrNull((c) => c.id == conversationId);
    if (target == null) return;
    if (target.structured.isHighlighted == highlighted) return;
    target.structured.isHighlighted = highlighted;
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
  }

  Future<void> togglePinConversation(ServerConversation conversation) async {
    // Optimistic update
    conversation.pinned = !conversation.pinned;
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
    // Call API
    final success = await togglePinConversationServer(conversation.id);
    if (!success) {
      // Revert on failure
      conversation.pinned = !conversation.pinned;
      _groupConversationsByDateWithoutNotify();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _processingConversationWatchTimer?.cancel();
    _refreshDebounceTimer?.cancel();
    _reminderAckTimer?.cancel();
    _wal.unsubscribe(this);
    super.dispose();
  }

  @override
  void onMissingWalUpdated() async {
    _missingWals = await _wal.getSyncs().getMissingWals();
    notifyListeners();
  }

  @override
  void onWalSynced(Wal wal, {ServerConversation? conversation}) async {
    _missingWals = await _wal.getSyncs().getMissingWals();
    notifyListeners();
  }

  @override
  void onStatusChanged(WalServiceStatus status) {}

  @override
  void onWalSyncedProgress(double percentage) {
    _walsSyncedProgress = percentage;
    notifyListeners();
  }

  Future syncWals() async {
    debugPrint("provider > syncWals");
    _lastSyncedTotalSeconds = missingWalsInSeconds;
    setSyncCompleted(false);
    _walsSyncedProgress = 0.0;
    setIsSyncing(true);
    var res = await _wal.getSyncs().syncAll(progress: this);
    if (res != null) {
      if (res.newConversationIds.isNotEmpty || res.updatedConversationIds.isNotEmpty) {
        await getSyncedConversationsData(res);
      }
    }
    // Refresh missing WALs list so the sync icon disappears
    _missingWals = await _wal.getSyncs().getMissingWals();
    setSyncCompleted(true);
    setIsSyncing(false);
    notifyListeners();
    return;
  }

  Future<void> deletePendingWal(Wal wal) async {
    if (isSyncing || multipleSyncs.isNotEmpty || _missingWals.any((w) => w.isSyncing)) {
      throw StateError('Cannot delete recordings while syncing');
    }
    // The confirmation may have been open while this recording finished syncing.
    if (!_missingWals.contains(wal) || wal.status != WalStatus.miss) return;
    await _wal.getSyncs().deleteWal(wal);
    _missingWals = await _wal.getSyncs().getMissingWals();
    notifyListeners();
  }

  Future syncWal(Wal wal) async {
    debugPrint("provider > syncWal ${wal.id}");
    appendMultipleSyncs(true);
    _walsSyncedProgress = 0.0;
    var res = await _wal.getSyncs().syncWal(wal: wal, progress: this);
    if (res != null) {
      if (res.newConversationIds.isNotEmpty || res.updatedConversationIds.isNotEmpty) {
        print('Synced memories: ${res.newConversationIds} ${res.updatedConversationIds}');
        await getSyncedConversationsData(res);
      }
    }
    // Refresh missing WALs list so the sync icon disappears
    _missingWals = await _wal.getSyncs().getMissingWals();
    removeMultipleSyncs();
    notifyListeners();
    return;
  }

  void setSyncCompleted(bool value) {
    syncCompleted = value;
    notifyListeners();
  }

  Future getSyncedConversationsData(SyncLocalFilesResponse syncResult) async {
    List<dynamic> newConversations = syncResult.newConversationIds;
    List<dynamic> updatedConversations = syncResult.updatedConversationIds;
    setIsFetchingConversations(true);
    List<Future<ServerConversation?>> newConversationsFutures = newConversations.map((item) => getConversationDetails(item)).toList();

    List<Future<ServerConversation?>> updatedConversationsFutures = updatedConversations.map((item) => getConversationDetails(item)).toList();
    var syncedConversations = {'new_memories': [], 'updated_memories': []};
    try {
      final newConversationsResponses = await Future.wait(newConversationsFutures);
      syncedConversations['new_memories'] = newConversationsResponses;

      final updatedConversationsResponses = await Future.wait(updatedConversationsFutures);
      syncedConversations['updated_memories'] = updatedConversationsResponses;
      addSyncedConversationsToGroupedConversations(syncedConversations);
      setIsFetchingConversations(false);
    } catch (e) {
      print('Error during API calls: $e');
      setIsFetchingConversations(false);
    }
  }

  void addSyncedConversationsToGroupedConversations(Map syncedConversations) {
    if (syncedConversations['new_memories'] != []) {
      for (var conversation in syncedConversations['new_memories']!) {
        if (conversation != null && conversation.status == ConversationStatus.completed) {
          addConversation(conversation);
        }
      }
    }
    if (syncedConversations['updated_memories'] != []) {
      for (var conversation in syncedConversations['updated_memories']!) {
        if (conversation != null && conversation.status == ConversationStatus.completed) {
          upsertConversation(conversation);
        }
      }
    }
    for (var conversation in syncedConversations['new_memories']!) {
      if (conversation != null && conversation.status == ConversationStatus.completed) {
        var res = getConversationDateAndIndex(conversation);
        syncedConversationsPointers.add(SyncedConversationPointer(type: SyncedConversationType.newConversation, index: res.$2, key: res.$1, conversation: conversation));
      }
    }
    if (syncedConversations['updated_memories'] != []) {
      for (var conversation in syncedConversations['updated_memories']!) {
        if (conversation != null && conversation.status == ConversationStatus.completed) {
          var res = getConversationDateAndIndex(conversation);
          syncedConversationsPointers.add(SyncedConversationPointer(type: SyncedConversationType.newConversation, index: res.$2, key: res.$1, conversation: conversation));
        }
      }
    }
  }

  void updateSyncedConversationPointerIndex(SyncedConversationPointer mem, int index) {
    var oldIdx = syncedConversationsPointers.indexOf(mem);
    syncedConversationsPointers[oldIdx] = mem.copyWith(index: index);
    notifyListeners();
  }

  void updateSyncedConversation(ServerConversation conversation) {
    var id = syncedConversationsPointers.indexWhere((e) => e.conversation.id == conversation.id);
    if (id != -1) {
      syncedConversationsPointers[id] = syncedConversationsPointers[id].copyWith(conversation: conversation);
    }
    updateConversationInSortedList(conversation);
    notifyListeners();
  }

  (DateTime, int) getConversationDateAndIndex(ServerConversation conversation) {
    var date = DateTime(conversation.createdAt.year, conversation.createdAt.month, conversation.createdAt.day);
    if (!groupedConversations.containsKey(date) || groupedConversations[date] == null) {
      groupedConversations[date] = [conversation];
      return (date, 0);
    }
    var idx = groupedConversations[date]!.indexWhere((element) => element.id == conversation.id);
    if (idx == -1) {
      groupedConversations[date]!.add(conversation);
      idx = groupedConversations[date]!.length - 1;
    }
    return (date, idx);
  }

  Future<ServerConversation?> getConversationDetails(String conversationId) async {
    var conversation = await getConversationById(conversationId);
    return conversation;
  }

  void clearSyncResult() {
    syncCompleted = false;
    syncedConversationsPointers = [];
    notifyListeners();
  }

  void setIsSyncing(bool value) {
    isSyncing = value;
    notifyListeners();
  }

  void appendMultipleSyncs(bool value) {
    setIsSyncing(true);
    multipleSyncs.add(value);
    notifyListeners();
  }

  void removeMultipleSyncs() {
    if (multipleSyncs.isNotEmpty) {
      multipleSyncs.removeLast();
    } else {
      setIsSyncing(false);
      setSyncCompleted(true);
    }
    notifyListeners();
  }

  void clearMultipleSyncs() {
    multipleSyncs.clear();
    notifyListeners();
  }

  void setIsFetchingConversations(bool value) {
    isFetchingConversations = value;
    notifyListeners();
  }

  // New Getter for Action Items Page
  Map<ServerConversation, List<ActionItem>> get conversationsWithActiveActionItems {
    final Map<ServerConversation, List<ActionItem>> result = {};
    final List<ServerConversation> sourceList = conversations;

    for (final convo in sourceList) {
      if (convo.discarded && !showDiscardedConversations) continue;

      final activeItems = convo.structured.actionItems.where((item) => !item.deleted && item.confirmed).toList();
      if (activeItems.isNotEmpty) {
        result[convo] = activeItems;
      }
    }
    return result;
  }

  Future<void> updateGlobalActionItemState(ServerConversation conversation, String actionItemDescription, bool newState) async {
    final convoId = conversation.id;
    bool conversationFoundAndUpdated = false;

    final originalConvoIndex = conversations.indexWhere((c) => c.id == convoId);
    if (originalConvoIndex != -1) {
      final itemIndex = conversations[originalConvoIndex].structured.actionItems.indexWhere((item) => item.description == actionItemDescription);
      if (itemIndex != -1) {
        conversations[originalConvoIndex].structured.actionItems[itemIndex].completed = newState;
        conversationFoundAndUpdated = true;
      }
    }

    var dateKey = DateTime(conversation.createdAt.year, conversation.createdAt.month, conversation.createdAt.day);
    if (groupedConversations.containsKey(dateKey)) {
      final groupIndex = groupedConversations[dateKey]!.indexWhere((c) => c.id == convoId);
      if (groupIndex != -1) {
        final itemIndex = groupedConversations[dateKey]![groupIndex].structured.actionItems.indexWhere((item) => item.description == actionItemDescription);
        if (itemIndex != -1) {
          groupedConversations[dateKey]![groupIndex].structured.actionItems[itemIndex].completed = newState;
        }
      }
    }

    if (conversationFoundAndUpdated) {
      // Find the item index for the server call
      final itemIndex = conversation.structured.actionItems.indexWhere((item) => item.description == actionItemDescription);
      if (itemIndex != -1) {
        await setConversationActionItemState(convoId, [itemIndex], [newState]);
      }
      notifyListeners();
    } else {
      debugPrint("Error: Conversation or action item not found for updateGlobalActionItemState.");
    }
  }

  /// 待确认待办的时效窗口：超过这个岁数的就不再问了。**超窗即静默放弃**
  ///（既不进 to-do，也不再出现），不做「过期提醒」。
  ///
  /// 7 天是产品意图：一周前没在意的事，再问只是噪音。
  ///（曾因 prompt v5 时代 action_items 产出归零临时放宽到 30 天，
  /// v6/v7 修复产出后于 2026-08-07 收回。）
  static const Duration kTaskConfirmWindow = Duration(days: 7);

  /// 本次会话已选定的那张卡。卡片一旦出现就固定住，不能每次 rebuild 重挑
  /// ——否则用户正要点「加入待办」时卡片内容可能已经换了。
  ({String conversationId, String description})? _pickedTask;

  /// P-01 气泡卡当前该问的那一条待确认待办。
  ///
  /// 挑选规则（一次只问一件事）：
  /// 1. 只看 [kTaskConfirmWindow] 内的会话——太旧的用户已经不关心了；
  /// 2. **没问过的优先**，且其中挑最新的（刚发生的事最有印象）；
  /// 3. 都问过了，就挑最久没问过的那条——用户忽略掉的下次换别的，不反复唠叨。
  ///
  /// 「问过」只记本地（[TaskConfirmRotation]），不占后端字段。
  ({ServerConversation conversation, int idx, ActionItem item})? get pendingTaskToConfirm {
    final candidates = _unconfirmedTaskCandidates();
    if (candidates.isEmpty) {
      _pickedTask = null;
      return null;
    }

    // 已选定的还在候选里就继续用它（下标可能因删除移位，所以按描述重新定位）。
    if (_pickedTask case final picked?) {
      for (final c in candidates) {
        if (c.conversation.id == picked.conversationId && c.item.description == picked.description) {
          return (conversation: c.conversation, idx: c.idx, item: c.item);
        }
      }
    }

    var best = candidates.first;
    for (final c in candidates.skip(1)) {
      if (_winsTaskSlot(c, best)) best = c;
    }
    _pickedTask = (conversationId: best.conversation.id, description: best.item.description);
    // 露面即记一笔，这样下次进首页会轮到别的那条。
    TaskConfirmRotation.markAsked(best.conversation.id, best.item.description);
    return (conversation: best.conversation, idx: best.idx, item: best.item);
  }

  List<({ServerConversation conversation, int idx, ActionItem item, DateTime? askedAt})>
      _unconfirmedTaskCandidates() {
    final cutoff = DateTime.now().subtract(kTaskConfirmWindow);
    final result = <({ServerConversation conversation, int idx, ActionItem item, DateTime? askedAt})>[];
    for (final convo in conversations) {
      if (convo.discarded) continue;
      if (convo.createdAt.isBefore(cutoff)) continue;
      final items = convo.structured.actionItems;
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.deleted || item.confirmed) continue;
        result.add((
          conversation: convo,
          idx: i,
          item: item,
          askedAt: TaskConfirmRotation.lastAskedAt(convo.id, item.description),
        ));
      }
    }
    return result;
  }

  /// a 是否比 b 更该被问：没问过的赢过问过的；同类里没问过比"新"、问过比"久"。
  bool _winsTaskSlot(
    ({ServerConversation conversation, int idx, ActionItem item, DateTime? askedAt}) a,
    ({ServerConversation conversation, int idx, ActionItem item, DateTime? askedAt}) b,
  ) {
    if ((a.askedAt == null) != (b.askedAt == null)) return a.askedAt == null;
    if (a.askedAt == null) return a.conversation.createdAt.isAfter(b.conversation.createdAt);
    return a.askedAt!.isBefore(b.askedAt!);
  }

  /// 「加入待办」：确认为真待办，从气泡卡消失、进 to-do list。
  ///
  /// 返回结局供 UI 决定要不要提示。⚠️ **`gone` 不能走回滚那一支**：那会把幽灵卡片
  /// 原样放回首页，而它永远按不掉（见 [ActionItemMutation]）。
  Future<ActionItemMutation> confirmActionItem(String conversationId, int idx) async {
    _pickedTask = null; // 让下一条轮上来
    _setActionItemConfirmedLocal(conversationId, idx, true);
    notifyListeners();
    final result = await confirmConversationActionItem(conversationId, idx);
    switch (result) {
      case ActionItemMutation.ok:
        break;
      case ActionItemMutation.gone:
        // 服务端早就没有这条了（待办门禁在下发之后撤销过它）。乐观更新已经让卡片
        // 消失，这里要做的是把本地也对齐 —— 否则它既进不了 to-do list、又会作为
        // 幽灵留在候选里反复弹出来。
        await _resyncConversationAfterGone(conversationId, idx);
      case ActionItemMutation.failed:
        _setActionItemConfirmedLocal(conversationId, idx, false);
        notifyListeners();
    }
    return result;
  }

  /// 「不是待办」：直接弃掉（后端删除该条），不再问第二次。
  ///
  /// `gone` 与 `ok` 在这里**同样处置**：用户要的就是让它走掉，而它本来就已经不在了。
  Future<ActionItemMutation> rejectActionItem(String conversationId, int idx) async {
    _pickedTask = null;
    final result = await rejectConversationActionItem(conversationId, idx);
    switch (result) {
      case ActionItemMutation.ok:
        _removeActionItemLocal(conversationId, idx);
      case ActionItemMutation.gone:
        await _resyncConversationAfterGone(conversationId, idx);
      case ActionItemMutation.failed:
        break; // 本地不动，用户可以重试
    }
    notifyListeners();
    return result;
  }

  /// 404 之后让本地这条会话与服务端对齐。
  ///
  /// 为什么要整条重拉、而不是只 `removeAt(idx)`：撤销是**整条清空**
  /// （`clear_action_items`），所以同一条会话里的其他待办通常也一并没了。只删被点
  /// 到的那一条，剩下的会一条接一条继续以幽灵卡的形式弹出来，用户得逐条点掉。
  ///
  /// 重拉失败（离线等）时退回到只删这一条：那至少能让当前这张卡片走掉，不至于卡住。
  Future<void> _resyncConversationAfterGone(String conversationId, int idx) async {
    final fresh = await getConversationById(conversationId);
    if (fresh == null) {
      _removeActionItemLocal(conversationId, idx);
      notifyListeners();
      return;
    }
    // `upsertConversation` → `updateConversation` 里已经 `_groupConversationsByDateWithoutNotify()`
    // 并 notify 了，grouped 那一份跟着重建 —— 不需要再单独同步一次。
    upsertConversation(fresh);
  }

  // ---- 到期待办「提醒卡」（与上面的待确认卡不同：这里提醒的是已确认、到点、还没做完的事）----

  /// 本次会话已选定的那张提醒卡，出现后固定住（同 [_pickedTask] 的理由）。
  ({String conversationId, String description})? _pickedReminder;

  /// 用户刚点了「稍后提醒我」的那条——用来短暂显示回执态「收到，半小时后再提醒你」。
  /// 三秒后让出唯一提示位；切走 tab / 重开 app 也会消失，不需要持久化。
  ({String conversationId, String description})? _reminderAckShowing;
  Timer? _reminderAckTimer;

  ({String conversationId, String description})? get reminderAckShowing => _reminderAckShowing;

  /// 首页顶部该提醒的那条到期待办（一次只提醒一件事）。
  ///
  /// 候选：已确认（confirmed）、未完成、未删除、有确切 dueDate 且已到点的待办；
  /// 排除用户已「知晓」或处于「稍后」静默期的。挑最逾期（dueDate 最早）的那条。
  ({ServerConversation conversation, int idx, ActionItem item})? get pendingTaskReminder {
    final candidates = _dueReminderCandidates();
    if (candidates.isEmpty) {
      _pickedReminder = null;
      return null;
    }

    // 已选定的还在候选里就继续用它（下标可能因删除移位，按描述重新定位）。
    if (_pickedReminder case final picked?) {
      for (final c in candidates) {
        if (c.conversation.id == picked.conversationId && c.item.description == picked.description) {
          return (conversation: c.conversation, idx: c.idx, item: c.item);
        }
      }
    }

    var best = candidates.first;
    for (final c in candidates.skip(1)) {
      if (c.item.dueDate!.isBefore(best.item.dueDate!)) best = c;
    }
    _pickedReminder = (conversationId: best.conversation.id, description: best.item.description);
    return (conversation: best.conversation, idx: best.idx, item: best.item);
  }

  List<({ServerConversation conversation, int idx, ActionItem item})> _dueReminderCandidates() {
    final now = DateTime.now();
    final result = <({ServerConversation conversation, int idx, ActionItem item})>[];
    for (final convo in conversations) {
      if (convo.discarded) continue;
      final items = convo.structured.actionItems;
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.deleted || item.completed || !item.confirmed) continue;
        final due = item.dueDate;
        if (due == null || due.isAfter(now)) continue; // 只提醒到点的；模糊时效（无 dueDate）不提醒
        if (TaskReminderState.isAcknowledged(convo.id, item.description)) continue;
        if (TaskReminderState.isSnoozed(convo.id, item.description, now)) continue;
        result.add((conversation: convo, idx: i, item: item));
      }
    }
    return result;
  }

  /// 「OK / 已经知晓」：这条以后不再提醒，但待办仍保留在列表里、不标完成。
  /// 同时撤下可能已排定的系统推送。
  void acknowledgeReminder(String conversationId, String description) {
    TaskReminderState.acknowledge(conversationId, description);
    NotificationService.instance
        .clearNotification(NotificationPrefs.taskReminderIdFor(conversationId, description));
    _pickedReminder = null;
    _reminderAckTimer?.cancel();
    _reminderAckTimer = null;
    _reminderAckShowing = null;
    notifyListeners();
  }

  /// 「稍后提醒我」：半小时内不再弹这条 app 内卡片，同时排一条半小时后的系统推送，
  /// 并短暂显示回执态。
  void snoozeReminder(String conversationId, String description) {
    TaskReminderState.snooze(conversationId, description);
    NotificationPrefs.scheduleSnoozedReminder(conversationId, description,
        delay: TaskReminderState.snoozeDuration);
    _pickedReminder = null;
    _reminderAckShowing = (conversationId: conversationId, description: description);
    _reminderAckTimer?.cancel();
    _reminderAckTimer = Timer(const Duration(seconds: 3), dismissReminderAck);
    notifyListeners();
  }

  /// 关掉回执态，让下一条提醒或待确认待办接着显示。
  void dismissReminderAck() {
    _reminderAckTimer?.cancel();
    _reminderAckTimer = null;
    if (_reminderAckShowing == null) return;
    _reminderAckShowing = null;
    notifyListeners();
  }

  void _setActionItemConfirmedLocal(String conversationId, int idx, bool value) {
    for (final list in _actionItemListsFor(conversationId)) {
      if (idx >= 0 && idx < list.length) list[idx].confirmed = value;
    }
  }

  void _removeActionItemLocal(String conversationId, int idx) {
    for (final list in _actionItemListsFor(conversationId)) {
      if (idx >= 0 && idx < list.length) list.removeAt(idx);
    }
  }

  /// 同一条会话在 conversations 与 groupedConversations 里是两份对象，
  /// 改本地状态要一起改，否则 P-01 列表与 to-do 会不一致。
  List<List<ActionItem>> _actionItemListsFor(String conversationId) {
    final result = <List<ActionItem>>[];
    final i = conversations.indexWhere((c) => c.id == conversationId);
    if (i != -1) result.add(conversations[i].structured.actionItems);
    for (final group in groupedConversations.values) {
      final j = group.indexWhere((c) => c.id == conversationId);
      if (j != -1 && !result.contains(group[j].structured.actionItems)) {
        result.add(group[j].structured.actionItems);
      }
    }
    return result;
  }

  void updateActionItemDescriptionInConversation(String conversationId, int itemIndex, String newDescription) {
    final convoIndex = conversations.indexWhere((c) => c.id == conversationId);
    if (convoIndex != -1) {
      if (conversations[convoIndex].structured.actionItems.length > itemIndex) {
        conversations[convoIndex].structured.actionItems[itemIndex].description = newDescription;
      }
    }

    groupedConversations.forEach((date, convoList) {
      final groupIndex = convoList.indexWhere((c) => c.id == conversationId);
      if (groupIndex != -1) {
        if (convoList[groupIndex].structured.actionItems.length > itemIndex) {
          convoList[groupIndex].structured.actionItems[itemIndex].description = newDescription;
        }
      }
    });

    notifyListeners();
  }

  Future<void> deleteActionItemAndUpdateLocally(String conversationId, int itemIndex, ActionItem actionItem) async {
    deleteConversationActionItem(conversationId, actionItem);

    final convoIndex = conversations.indexWhere((c) => c.id == conversationId);
    if (convoIndex != -1) {
      if (conversations[convoIndex].structured.actionItems.length > itemIndex) {
        conversations[convoIndex].structured.actionItems.removeAt(itemIndex);
      }
    }

    groupedConversations.forEach((date, convoList) {
      final groupConvoIndex = convoList.indexWhere((c) => c.id == conversationId);
      if (groupConvoIndex != -1) {
        if (convoList[groupConvoIndex].structured.actionItems.length > itemIndex) {
          convoList[groupConvoIndex].structured.actionItems.removeAt(itemIndex);
        }
      }
    });

    notifyListeners();
  }
}
