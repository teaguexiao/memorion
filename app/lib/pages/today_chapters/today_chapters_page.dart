import 'package:memorion/backend/api_config.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/http/api/conversations.dart' show ActionItemMutation;
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/ask_page.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:memorion/pages/today_chapters/day_timeline_planner.dart';
import 'package:memorion/pages/today_chapters/device_detail_page.dart';
import 'package:memorion/pages/today_chapters/device_pairing_page.dart';
import 'package:memorion/pages/today_chapters/diary_detail_page.dart';
import 'package:memorion/pages/today_chapters/live_capture_page.dart';
import 'package:memorion/pages/today_chapters/settings_page.dart';
import 'package:memorion/pages/today_chapters/today_chapters_mock.dart';
import 'package:memorion/pages/today_chapters/widgets/about_me_body.dart';
import 'package:memorion/pages/today_chapters/widgets/chapter_card.dart';
import 'package:memorion/pages/today_chapters/widgets/diary_card.dart';
import 'package:memorion/pages/today_chapters/widgets/coverage_gap_bar.dart';
import 'package:memorion/pages/today_chapters/widgets/global_top_bar.dart';
import 'package:memorion/pages/today_chapters/widgets/jxb_bottom_nav.dart';
import 'package:memorion/pages/today_chapters/widgets/jxb_gradient_background.dart';
import 'package:memorion/pages/today_chapters/widgets/month_calendar_sheet.dart';
import 'package:memorion/pages/today_chapters/widgets/processing_card.dart';
import 'package:memorion/pages/today_chapters/widgets/task_bubble_card.dart';
import 'package:memorion/pages/today_chapters/widgets/task_reminder_card.dart';
import 'package:memorion/pages/today_chapters/widgets/timeline_rail.dart';
import 'package:memorion/pages/today_chapters/widgets/today_segmented.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/providers/discover_provider.dart';
import 'package:memorion/providers/insights_provider.dart';
import 'package:memorion/providers/memories_provider.dart';
import 'package:memorion/providers/moments_provider.dart';
import 'package:memorion/providers/timeline_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/ui/atoms/memorion_skeleton.dart';
import 'package:memorion/utils/category_localizer.dart';
import 'package:memorion/utils/moment_parser.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:memorion/utils/wear_tracking.dart';
import 'package:provider/provider.dart';

/// P-01 今日·章节时间线（记小宝 1.0 浅色改版）。
///
/// 数据策略（全真数据，视图模型见 today_chapters_mock.dart）：
/// - `ConversationProvider.groupedConversations` 按天分组的真实会话
///   → 每条会话映射为一个章节卡（时段 / 标题 / 处理中态）。无会话即出空态。
/// - 第一人称观察（后端 `structured.first_person_observation`，老数据回退语料）。
/// - ⭐高亮标签（后端 `structured.is_highlighted`，未来由硬件按钮触发；
///   当前无写入方故恒为 false）。**不再**由「值得回顾的时刻」(highlights) 推导。
/// - 任务气泡卡：`ActionItem.confirmed == false` 的待确认待办，确认进 to-do、否决即删。
/// - 空档条：`WearTracking` 本地佩戴追踪推导的未覆盖时长。
///
/// 本页独立局部套用浅色主题与 Noto 字体，不改动现有深色全局壳。
class TodayChaptersPage extends StatefulWidget {
  const TodayChaptersPage({super.key});

  @override
  State<TodayChaptersPage> createState() => _TodayChaptersPageState();
}

class _TodayChaptersPageState extends State<TodayChaptersPage> with WidgetsBindingObserver {
  int _segmentIndex = 0; // 0=章节 1=日记 2=关于我
  int _bottomTabIndex = 0; // 0=今日 1=Ask

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchDebounce;
  String _searchHintText = '';
  ConversationProvider? _conversationProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    // 首帧后拉取真实会话（若 Provider 尚未加载）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final provider = context.read<ConversationProvider>();
      _conversationProvider = provider;
      if (provider.conversations.isEmpty && !provider.isLoadingConversations) {
        try {
          await provider.getInitialConversations();
        } catch (_) {
          // The cloud watcher retries without hiding cached content.
        }
      }
      if (mounted &&
          (WidgetsBinding.instance.lifecycleState == null ||
              WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed)) {
        provider.startCloudProcessingWatch();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _conversationProvider?.startCloudProcessingWatch();
    } else {
      _conversationProvider?.stopCloudProcessingWatch();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _conversationProvider?.stopCloudProcessingWatch();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 快到底就往前翻一页。
  ///
  /// 🚨 **这个入口一度整个不存在**，那是「昨天之前的内容一条都看不到」的直接原因：
  /// 07-22 首页切到本页、07-25 删旧壳死代码时带走了
  /// `getMoreConversationsFromServer` 的唯一调用者，于是首页只有第一页 —— 而第一页
  /// 有多少天，取决于服务端那 50 条里有多少被丢弃吃掉。丢弃率低的时候能铺 4~5 天，
  /// 看起来正常，所以这个缺口藏了一个月。
  ///
  /// 提前 400px 触发，让加载盖在滚动手势里而不是等用户撞到底。重复调用是安全的：
  /// Provider 侧用 `isLoadingConversations` / `hasMoreConversations` 双重守卫。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 400) return;
    final provider = context.read<ConversationProvider>();
    if (!provider.hasMoreConversations || provider.isLoadingConversations) return;
    provider.getMoreConversationsFromServer();
  }

  /// 搜索：300ms 防抖，复用 ConversationProvider.searchConversations（走后端）。
  void _onSearchChanged(String q) {
    setState(() {}); // 立即刷新搜索/清除图标状态
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      context.read<ConversationProvider>().searchConversations(q.trim());
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _searchFocus.unfocus();
    context.read<ConversationProvider>().searchConversations('');
    setState(() {});
  }

  /// 日期筛选：自定义月历弹窗（Figma 1000:4664 / 1006:5194）→
  /// 复用 Provider.filterConversationsByDate / clearDateFilter。
  Future<void> _pickDate() async {
    final provider = context.read<ConversationProvider>();
    final picked = await showMonthCalendarSheet(
      context,
      countByDay: provider.conversationCountByDay,
      selectedDate: provider.selectedDate,
    );
    if (picked != null) {
      await provider.filterConversationsByDate(picked);
      setState(() {});
    }
  }

  /// 打开 Ask 聊天页（云朵吉祥物 / 底部「Ask」共用入口）。
  void _openAsk() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AskPage()));
  }

  /// 顶栏声波按钮点击：直接进入实时录音页。
  ///
  /// 采集启动交由 `LiveCapturePage.initState` 兜底负责（按 BLE 状态启动
  /// streamDeviceRecording/streamRecording，单一入口）。此处只做导航，
  /// 不在 push 前 await 启动流程——否则权限请求/建连的耗时会阻塞导航、
  /// 首次点击「无反应」，诱发用户重复点击而压入两层页面（见双击 bug）。
  void _openLiveCapture(BuildContext context) {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LiveCapturePage()),
    );
  }

  /// 顶栏设备芯片点击：已配对 → 设备详情；否则 → 配对页。
  void _openDevice() {
    final paired = context.read<DeviceProvider>().pairedDevice != null;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => paired ? const DeviceDetailPage() : const DevicePairingPage(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = S.of(context);
    _searchHintText = l.todaySearchHint;
    // 局部浅色主题 + Noto 字体，隔离于全局深色壳。
    return Theme(
      data: _lightTheme(context),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // 顶部蓝白渐变背景（还原 Figma v2.4）。
          body: JxbGradientBackground(
            child: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                Column(
                  children: [
                    Consumer2<DeviceProvider, CaptureProvider>(
                      builder: (context, dp, cp, _) {
                        final connected = dp.isConnected && dp.connectedDevice != null;
                        return GlobalTopBar(
                          batteryPercent: dp.batteryLevel < 0 ? 0 : dp.batteryLevel,
                          connected: connected,
                          charging: dp.isCharging,
                          recording: cp.isRecording,
                          onDeviceTap: _openDevice,
                          // DEBUG：长按芯片循环切换模拟设备状态（未连接/充电/普通/低电量）。
                          onDeviceLongPress: kDebugMode ? () => dp.debugCycleMockDevice() : null,
                          onRecordTap: () => _openLiveCapture(context),
                          onSettingsTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const SettingsPage()),
                          ),
                        );
                      },
                    ),
                    Expanded(
                      child: Consumer2<ConversationProvider, TimelineProvider>(
                        builder: (context, provider, timeline, _) {
                          return _buildBody(context, provider, timeline, l);
                        },
                      ),
                    ),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.of(context).padding.bottom + 12,
                  child: Center(
                    child: JxbBottomNav(
                      selectedIndex: _bottomTabIndex,
                      todayLabel: l.todayTabToday,
                      recallLabel: l.todayTabAsk,
                      onChanged: (i) {
                        if (i == 1) {
                          _openAsk();
                        } else {
                          setState(() => _bottomTabIndex = i);
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ConversationProvider provider, TimelineProvider timeline, S l) {
    // 骨架屏只覆盖「一条都还没有」的窗口：
    //  - 有内容（含 fetchConversations 的本地缓存预填）就直接显示，别让骨架屏
    //    盖住缓存，那会把冷启动的可见时间反而推后；
    //  - hasLoadedConversationsOnce 补的是首帧空档：拉取要等 postFrame 才发起，
    //    这之前 isLoadingConversations 仍是 false，光看它会闪一下空态。
    //
    // ⚠️ **不等章节拉完**。章节只改「怎么分组」，会话在手就能先显示（降级路径一条
    // 一张卡）；等章节等于给每次冷启动加一次网络往返的白屏。
    final loading = provider.conversations.isEmpty &&
        (!provider.hasLoadedConversationsOnce || provider.isLoadingConversations);
    final dayGroups = _buildDayGroups(provider, timeline);

    return RefreshIndicator(
      color: JXB.brandPrimary,
      onRefresh: () => _refreshAll(provider),
      child: CustomScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Segmented(章节/日记/关于我) + 右侧云朵吉祥物
                  Row(
                    children: [
                      Expanded(
                        child: TodaySegmented(
                          selectedIndex: _segmentIndex,
                          labels: [l.todaySegChapters, l.todaySegJournal, l.todaySegAboutMe],
                          onChanged: (i) {
                            setState(() => _segmentIndex = i);
                            // 切走时清掉「稍后提醒」回执态，回到章节时露出下一条提醒。
                            if (i != 0) context.read<ConversationProvider>().dismissReminderAck();
                            // 切到「日记」→ 交给 Provider 判断要不要真发请求。
                            //
                            // ⚠️ 这里**不能**写 `if (!mp.isInitialized)`：那个标记只在
                            // 服务端拉取成功后才置 true，构造期的缓存预填刻意不置，
                            // 于是每次冷启动进日记都必然打一发全量请求（后端
                            // `/v1/moments` 是全表 stream 后在 Python 里排序切片，
                            // 条数一多就是秒级）。新鲜度判定收在
                            // `ensureLoaded()` 里，页面只管调。
                            if (i == 1) {
                              context.read<MomentsProvider>().ensureLoaded();
                            }
                            // Cached snapshots remain visible; providers revalidate after five minutes.
                            if (i == 2) {
                              context.read<MemoriesProvider>().ensureLoaded();
                              context.read<InsightsProvider>().ensureLoaded();
                              context.read<DiscoverProvider>().ensureActionItemsLoaded();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      _MascotAvatar(onTap: _openAsk),
                    ],
                  ),
                  // 「章节」tab 专属：一个提示位（提醒优先）+ 日期筛选。
                  if (_segmentIndex == 0) ...[
                    // 回执 → 到期提醒 → 待确认待办，互斥显示；只有真正展示待办时
                    // 才读取 pendingTaskToConfirm，避免隐藏时也被记为「问过」。
                    if (provider.reminderAckShowing case final ack?) ...[
                      const SizedBox(height: 16),
                      TaskReminderAckCard(
                        speaker: l.todayReminderAckSpeaker,
                        body: l.todayReminderSnoozed,
                        key: ValueKey('reminder-ack-${ack.conversationId}|${ack.description}'), // i18n-ignore: widget key，非用户文案
                      ),
                    ] else if (provider.pendingTaskReminder case final reminder?) ...[
                      const SizedBox(height: 16),
                      TaskReminderCard(
                        speaker: l.todayReminderSpeaker,
                        body: reminder.item.description,
                        confirmLabel: l.todayReminderConfirm,
                        snoozeLabel: l.todayReminderSnooze,
                        onConfirm: () =>
                            provider.acknowledgeReminder(reminder.conversation.id, reminder.item.description),
                        onSnooze: () =>
                            provider.snoozeReminder(reminder.conversation.id, reminder.item.description),
                      ),
                    ] else if (provider.pendingTaskToConfirm case final task?) ...[
                      const SizedBox(height: 16),
                      TaskBubbleCard(
                        speaker: l.todayTaskHeard,
                        body: task.item.description,
                        confirmLabel: l.todayTaskConfirm,
                        dismissLabel: l.todayTaskDismiss,
                        onConfirm: () => _handleTaskMutation(
                          provider.confirmActionItem(task.conversation.id, task.idx).then((result) {
                            if (result == ActionItemMutation.ok && context.mounted) {
                              context.read<DiscoverProvider>().loadActionItems();
                            }
                            return result;
                          }),
                          // 「加入待办」必须说一句：用户接下来会去「你答应过的事」里找它，
                          // 而 gone 意味着它根本进不去。静默处理就是那次"点了确定、
                          // 卡片消失、列表里却没有"的观感。
                          notifyWhenGone: true,
                        ),
                        onDismiss: () => _handleTaskMutation(
                          // 「不是待办」求的就是让它走掉，已经没了正合心意 —— 不打扰。
                          provider.rejectActionItem(task.conversation.id, task.idx),
                          notifyWhenGone: false,
                        ),
                      ),
                    ],
                    if (provider.selectedDate != null) ...[
                      const SizedBox(height: 12),
                      _ActiveDateFilterChip(
                        date: provider.selectedDate!,
                        onClear: () async {
                          await provider.clearDateFilter();
                          setState(() {});
                        },
                      ),
                    ],
                  ],
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
          // One account-wide indicator, independent of recording source or day.
          if (provider.hasCloudProcessing)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: ProcessingCard(
                  key: const ValueKey('cloud-processing-status'), // i18n-ignore: Widget key.
                  text: revampText(context, en: "I'm still organizing that conversation…", zh: '我还在整理刚才那段对话…'),
                ),
              ),
            ),
          // Body 按 tab 分支
          if (_segmentIndex == 1)
            _buildDiarySliver(context)
          else if (_segmentIndex == 2)
            _buildAboutMePlaceholder(l)
          else if (loading)
            _buildLoadingSliver()
          else if (dayGroups.isEmpty)
            _buildEmptySliver(l)
          else
            _buildTimelineSliver(dayGroups),
          // 往前翻页时的转圈。只在「章节」tab 且列表已有内容时出现——首屏的空白由
          // _buildLoadingSliver 的骨架屏负责，两个同时转会看起来像卡住了。
          if (_segmentIndex == 0 && dayGroups.isNotEmpty && provider.isLoadingConversations)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: JXB.brandPrimary),
                  ),
                ),
              ),
            ),
          // 底部留白：避开悬浮胶囊导航 (~56 + 安全区)。
          SliverToBoxAdapter(
            child: SizedBox(height: 88 + MediaQuery.of(context).padding.bottom),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineSliver(List<DayGroup> dayGroups) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final group = dayGroups[index];
            return Padding(
              padding: EdgeInsets.only(bottom: index == dayGroups.length - 1 ? 0 : 24),
              child: _buildDayGroup(context, group, showSearch: index == 0),
            );
          },
          childCount: dayGroups.length,
        ),
      ),
    );
  }

  Widget _buildDayGroup(BuildContext context, DayGroup group, {required bool showSearch}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Figma：日期(周三 07.09 + 日历) 在左，搜索框在右，同一行。
        // 日历图标 + 搜索框都只在第一个日期组显示，其余天只有日期。
        _DateRow(
          dateLabel: group.dateLabel,
          onCalendarTap: showSearch ? _pickDate : null,
          showCalendar: showSearch,
          search: showSearch
              ? _SearchPill(
                  hint: _searchHintText,
                  controller: _searchController,
                  focusNode: _searchFocus,
                  onChanged: _onSearchChanged,
                  onClear: _clearSearch,
                )
              : null,
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < group.entries.length; i++)
          _buildRailEntry(
            context,
            group.entries[i],
            isFirst: i == 0,
            isLast: i == group.entries.length - 1,
          ),
      ],
    );
  }

  /// 单个时间线条目 = 左侧 rail + 右侧内容。
  Widget _buildRailEntry(BuildContext context, TimelineEntry entry, {required bool isFirst, required bool isLast}) {
    // 空档条(高22，文字垂直居中)与章节 meta 行(高约22)文字中心都在 ~11，圆点统一对齐到此。
    final isGap = entry is CoverageGapEntry;
    final dotColor = isGap ? JXB.textPlaceholder : JXB.brandPrimary;
    const dotCenterY = 11.0;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TimelineRail(
            isFirst: isFirst,
            isLast: isLast,
            dotColor: dotColor,
            dotCenterY: dotCenterY,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
              child: _buildEntryContent(context, entry),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryContent(BuildContext context, TimelineEntry entry) {
    return switch (entry) {
      ProcessingEntry e => ProcessingCard(text: e.text),
      ChapterEntry e => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ChapterMetaRow(
              timeRange: e.timeRange,
              category: e.category,
              hasHighlight: e.hasHighlight,
            ),
            const SizedBox(height: 4),
            _buildChapterCard(context, e),
          ],
        ),
      CoverageGapEntry e => CoverageGapBar(text: e.text),
    };
  }

  /// 章节卡：有关联真实会话时，左滑露出删除按钮（同「标记说话人」页面手势）。
  Widget _buildChapterCard(BuildContext context, ChapterEntry e) {
    final sources = e.effectiveSources;
    final card = ChapterCard(
      title: e.title,
      observation: e.observation,
      discarded: e.conversation?.discarded ?? false,
      onTap: sources.isEmpty
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChapterDetailPage(
                    conversation: sources.first,
                    sources: sources,
                    chapter: e.chapter,
                  ),
                ),
              ),
    );
    if (sources.isEmpty) return card;

    return Dismissible(
      // key 覆盖全部源：合并成员变了就是另一张卡，不能沿用旧 key 的 dismissed 状态。
      key: ValueKey('chapter_${sources.map((c) => c.id).join('_')}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDeleteChapter(sources),
      onDismissed: (_) {
        final provider = context.read<ConversationProvider>();
        final timeline = context.read<TimelineProvider>();
        final owner = ApiConfig().externalUserId;
        context.read<UndoDeleteController>().add(UndoDeletion(
              key: 'chapter:${sources.map((c) => c.id).join(',')}',
              hiddenKeys: sources.map((c) => 'conversation:${c.id}').toSet(),
              kind: DeleteKind.chapter,
              title: e.title,
              commit: () async {
                var allSucceeded = true;
                for (final source in sources) {
                  if (owner != ApiConfig().externalUserId) return false;
                  final ok = await provider.commitConversationDeletion(source.id);
                  if (owner != ApiConfig().externalUserId) return false;
                  if (ok) timeline.forgetConversations({source.id});
                  allSucceeded = allSucceeded && ok;
                }
                return allSucceeded;
              },
            ));
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: const Color(0x14FF3B30),
          borderRadius: BorderRadius.circular(JXB.radiusControl),
        ),
        child: const Icon(Icons.delete_outline_rounded, size: 22, color: JXB.error),
      ),
      child: card,
    );
  }

  /// 左滑删除章节：二次确认 → 删掉这一章的**全部**源会话。
  ///
  /// 「删一章」= 删它的所有源 conversation，不是只删锚点那条。用户看到的是一张卡，
  /// 只删一条会让剩下的碎片在下次章节重算后重新冒出来——看起来像「删不掉」。
  /// 合并的章节在文案里点明会删几段，避免误删。
  ///
  /// 每个 `DELETE /v1/conversations/{id}` 后端都会 mark_timeline_day_dirty，
  /// 所以那一天会被重算；端上先做乐观更新（TimelineProvider.forgetConversations），
  /// 否则章节缓存里还留着指向已删会话的卡。
  /// 弹窗样式同 Ask 页麦克风权限弹窗（图标圆环 + 标题 + 说明 + 胶囊按钮）。
  Future<bool> _confirmDeleteChapter(List<ServerConversation> sources) async {
    if (sources.isEmpty) return false;
    final count = sources.length;
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          decoration: BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [BoxShadow(color: Color(0x1F264D78), blurRadius: 30, offset: Offset(0, 12))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56, height: 56, alignment: Alignment.center,
                decoration: const BoxDecoration(color: Color(0x14FF3B30), shape: BoxShape.circle),
                child: const Icon(Icons.delete_outline_rounded, size: 28, color: JXB.error),
              ),
              const SizedBox(height: 16),
              Text(revampText(context, en: 'Delete this chapter', zh: '删除本段'), textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 8),
              Text(
                  count > 1
                      ? revampText(context,
                          en:
                              'This chapter merges $count recordings. Deleting removes all of them. You can undo within 6 seconds.',
                          zh: '这一章由 $count 段录音合并而成，删除会一并删掉，6 秒内可以撤销。')
                      : revampText(context, en: 'Delete this chapter? You can undo within 6 seconds.', zh: '确定删除这段章节吗？6 秒内可以撤销。'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, false),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 48, alignment: Alignment.center,
                        decoration: BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(context, en: 'Cancel', zh: '取消'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, true),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 48, alignment: Alignment.center,
                        decoration: BoxDecoration(color: JXB.error, borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(context, en: 'Delete', zh: '删除'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return ok == true && mounted;
  }

  /// 「日记」tab：moments 渐变卡列表（GET /v1/moments → ServerMessage）。
  Widget _buildDiarySliver(BuildContext context) {
    return Consumer<MomentsProvider>(
      builder: (context, mp, _) {
        if (mp.isLoading && mp.moments.isEmpty) {
          return _buildLoadingSliver();
        }
        if (mp.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 60, 16, 0),
              child: Center(
                child: Text(
                    revampText(context,
                        en: 'No journal yet\nJixiaobao will create one each night from your conversations',
                        zh: '还没有日记\n记小宝会在每天晚上根据你的对话生成'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.6, color: JXB.textPlaceholder)),
              ),
            ),
          );
        }
        final moments = mp.moments;
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final m = moments[index];
                // 情绪化标题优先（后端 day_summary 生成），缺失时回退 MomentParser 解析标题。
                final emotionTitle = m.emotionTitle?.trim();
                final title = (emotionTitle != null && emotionTitle.isNotEmpty)
                    ? emotionTitle
                    : MomentParser.parse(m.text, date: m.createdAt).title;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: DiaryCard(
                    title: title,
                    dateLabel: _diaryDateLabel(context, m.createdAt),
                    imageUrl: m.summaryImageUrl,
                    gradientIndex: index,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DiaryDetailPage(moment: m, gradientIndex: index),
                      ),
                    ),
                  ),
                );
              },
              childCount: moments.length,
            ),
          ),
        );
      },
    );
  }

  /// 气泡卡两枚按钮的收尾：把三种结局翻译成用户能看懂的反馈。
  ///
  /// 在此之前这两个回调是 fire-and-forget，失败**完全静默** —— 2026-08-24 用户对一
  /// 张幽灵卡片连点了 12 次（9 次 DELETE + 3 次 PATCH，全 404），界面从头到尾没给过
  /// 任何交代。卡片按不掉是一个 bug，按不掉却不说话是另一个。
  Future<void> _handleTaskMutation(
    Future<ActionItemMutation> pending, {
    required bool notifyWhenGone,
  }) async {
    final result = await pending;
    if (!mounted) return;
    switch (result) {
      case ActionItemMutation.ok:
        break; // 卡片消失本身就是反馈
      case ActionItemMutation.gone:
        if (notifyWhenGone) {
          _toast(revampText(context,
              en: 'That one had already expired, so I let it go.', zh: '这条已经失效了，我先放下了'));
        }
      case ActionItemMutation.failed:
        _toast(revampText(context, en: "That didn't go through — check your connection.", zh: '没有成功，检查一下网络吧'));
    }
  }

  void _toast(String message) {
    UndoDeleteHost.showMessage(context, message);
  }

  static const List<String> _diaryWeekdaysZh = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static const List<String> _diaryWeekdaysEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String _diaryDateLabel(BuildContext context, DateTime d) => revampText(context,
      en: '${d.month}/${d.day} · ${_diaryWeekdaysEn[d.weekday - 1]}',
      zh: '${d.month}月${d.day}日 · ${_diaryWeekdaysZh[d.weekday - 1]}');

  Widget _buildAboutMePlaceholder(S l) {
    return const SliverToBoxAdapter(child: AboutMeBody());
  }

  Widget _buildLoadingSliver() {
    return const MemorionSkeletonCards(
      count: 4,
      withHeader: true,
      padding: EdgeInsets.symmetric(horizontal: 16),
    ).asSliver();
  }

  Widget _buildEmptySliver(S l) {
    final searching = _isSearchingOrFiltering;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 48, 32, 48),
        child: Column(
          children: [
            Icon(searching ? Icons.search_off_rounded : Icons.graphic_eq_rounded,
                size: 48, color: JXB.textPlaceholder),
            const SizedBox(height: 16),
            Text(searching ? l.todayNoResultTitle : l.todayEmptyTitle,
                style: JXB.sectionTitle, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(searching ? l.todayNoResultBody : l.todayEmptyBody,
                style: JXB.bodySmall, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  // ── 数据映射：真实会话 → 日期分组 → 时间线条目 ─────────────────────
  bool get _isSearchingOrFiltering =>
      _searchController.text.trim().isNotEmpty ||
      context.read<ConversationProvider>().selectedDate != null;

  /// 真实会话 + 后端章节 → 日期分组。
  ///
  /// **谁决定什么**：
  /// - [ConversationProvider] 保留录音历史；时光只展示有意义的保留内容，
  ///   已过滤录音和旧媒体占位标题由 planner 排除；
  /// - 「哪些会话属于同一章」由后端章节层决定（[TimelineProvider]）。端上**不重算
  ///   边界**——两套边界一定会在某次阈值改动后开始互相矛盾。
  ///
  /// 分组的日期是**章节起始日**（= 后端按 `started_at` 归日的那一天），而不是
  /// `createdAt`。批量转录的音频 `createdAt` 可能比录制时间晚一天以上，跟着它分组
  /// 会让同一章被劈到两天。
  ///
  /// ⚠️ **降级路径是必须的，不是保险**：没被任何章节收进去的会话仍然一条一张卡。
  /// 章节缓存可能还没重算（debounce 10min）、可能拉取失败、可能这条会话刚落库。
  /// 少一张卡 = 用户认为录音丢了。
  List<DayGroup> _buildDayGroups(ConversationProvider provider, TimelineProvider timeline) {
    final undo = context.watch<UndoDeleteController?>();
    final grouped = provider.groupedConversations;
    // 没有会话就是没有会话——交给 _buildEmptySliver 出真空态，不拿演示数据充场面。
    if (grouped.isEmpty) return const [];

    // 按「章节起始日」重新归拢 provider 已筛选出的会话（归日规则见
    // day_timeline_planner.dart 的 timelineStartOf）。
    final byDay = groupConversationsByDay(grouped.values.expand((c) => c));
    final completedByDay = <String, List<ServerConversation>>{};
    final requestIds = <String, Set<String>>{};
    byDay.forEach((dayKey, convos) {
      for (final c in convos) {
        if (c.status == ConversationStatus.processing || c.status == ConversationStatus.in_progress) {
          // 处理中的会话不可能进章节（后端还没摘要）。放进 requestIds 会让
          // TimelineProvider 每次都判这天 stale，于是每次 build 都打一发 refresh。
          continue;
        }
        (completedByDay[dayKey] ??= []).add(c);
        if (isVisibleTimelineConversation(c)) (requestIds[dayKey] ??= <String>{}).add(c.id);
      }
    });

    _scheduleTimelineSync(requestIds);

    final dayKeys = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    final List<DayGroup> result = [];
    for (final dayKey in dayKeys) {
      final dayConvos = byDay[dayKey]!;
      if (dayConvos.isEmpty) continue;

      // 章节 → 槽位（含降级路径）。排序与「谁被哪一章收走」全在 planner 里。
      final slots = planDayTimeline(
        completed: completedByDay[dayKey] ?? const [],
        chapters: timeline.chaptersFor(dayKey),
      ).where((slot) => !slot.sources.any((c) => undo?.hides('conversation:${c.id}') == true)).toList();

      final entries = <TimelineEntry>[];
      double totalSeconds = 0;
      // 空档候选：只取**槽位之间**的间隔（见 timelineGapCandidates）。
      final candidates = gapCandidatesForSlots(slots);
      for (var i = 0; i < slots.length; i++) {
        final slot = slots[i];
        totalSeconds += slot.seconds;
        // 候选间隔**扣除 BLE 连接时段与静默时段（睡觉）后**，剩余的"确实没戴"时长
        // > 阈值才插条。取并集扣除的模型兼容两种设备形态（当前无 SD 卡 / 未来离线
        // 同步），见 WearTracking。
        final gap = candidates[i];
        if (gap != null) {
          final uncovered = unrecordedGapRanges(gap, completedByDay[dayKey] ?? const [])
              .fold<Duration>(Duration.zero,
                  (sum, range) => sum + WearTracking.uncoveredDuration(range.start, range.end));
          if (uncovered > _kGapThreshold) {
            entries.add(CoverageGapEntry(text: _gapText(context, uncovered)));
          }
        }
        entries.add(slot.chapter != null
            ? _chapterEntryFrom(slot.chapter!, slot.sources)
            : _fallbackEntryFrom(slot.anchor));
      }

      if (entries.isEmpty) continue;
      result.add(DayGroup(
        dateLabel: _dayLabel(context, _dateOfKey(dayKey, dayConvos)),
        metaLabel: revampText(context,
                en: '${slots.length} chapters · ${_hours(totalSeconds)} h',
                zh: '${slots.length} 个章节 · ${_hours(totalSeconds)} 小时'),
        entries: entries,
      ));
    }
    return result;
  }

  /// 章节 → 章节卡。
  ///
  /// 标题/观察走后端章节摘要（多条合并时是二次归纳的结果）；分类与⭐高亮章节文档里
  /// 没有，从源会话取：
  /// - 分类用**首条源会话**的（章节按时间顺序，首条即章节的开场）；
  /// - ⭐高亮是**任一源**为真即为真——硬件按钮打在某一条上，合并后整章都该带星。
  ChapterEntry _chapterEntryFrom(TimelineChapter chapter, List<ServerConversation> sources) {
    final anchor = sources.first;
    final title = chapter.title.isNotEmpty
        ? chapter.title
        : (anchor.structured.title.isNotEmpty
            ? anchor.structured.title
            : revampText(context, en: 'A recording', zh: '一段记录'));
    final observation = chapter.observationWithFallback(anchor.structured.firstPersonObservation);
    return ChapterEntry(
      timeRange: _formatRange(chapter.start, chapter.end),
      title: title,
      observation: observation,
      category: localizeCategory(context, anchor.structured.category),
      hasHighlight: sources.any((c) => c.structured.isHighlighted),
      conversation: anchor,
      sources: sources,
      chapter: chapter,
    );
  }

  /// 降级路径：一条 conversation 一张卡（章节尚未覆盖它时）。
  ChapterEntry _fallbackEntryFrom(ServerConversation c) => ChapterEntry(
        timeRange: _timeRange(c),
        title: c.structured.title.isNotEmpty ? c.structured.title : revampText(context, en: 'A recording', zh: '一段记录'),
        // 第一人称观察全走真数据（structured.first_person_observation）；
        // 为空（老数据/生成失败/无内容）时传空串，章节卡整行隐藏，不兜底假文案。
        observation: c.structured.firstPersonObservation?.trim() ?? '',
        // 分类：后端真实 category（英文枚举），渲染时经 localizeCategory 本地化。
        category: localizeCategory(context, c.structured.category),
        // ⭐高亮标签：只看显式标记 structured.is_highlighted（未来由硬件按钮写入）。
        // 已与章节详情「值得回顾的时刻」(structured.highlights) 解耦——AI 自动生成
        // 的高亮原话不再让首页跟着高亮。当前无写入方 → 一律 false（预期行为）。
        hasHighlight: c.structured.isHighlighted,
        conversation: c,
        sources: [c],
      );

  /// 上一次发给 TimelineProvider 的请求签名，用于避免每帧重发。
  String? _lastTimelineSyncSignature;

  /// 在**当帧渲染之后**同步章节。
  ///
  /// 不能在 build 里直接调：TimelineProvider 会 notifyListeners，在 build 期间通知
  /// 会抛「setState() or markNeedsBuild() called during build」。签名去重是另一半——
  /// 每次 notify 都会重新 build，不去重就是无限循环。
  void _scheduleTimelineSync(Map<String, Set<String>> requestIds) {
    if (requestIds.isEmpty) return;
    final keys = requestIds.keys.toList()..sort();
    final signature = keys.map((k) => '$k:${requestIds[k]!.length}').join(',');
    if (signature == _lastTimelineSyncSignature) return;
    _lastTimelineSyncSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<TimelineProvider>().syncDays(requestIds);
    });
  }

  /// 下拉刷新：会话与章节一起刷。章节带 `refresh=true` 绕过服务端 debounce，
  /// 但服务端指纹校验仍在，没变过的天不会真的重算。
  Future<void> _refreshAll(ConversationProvider provider) async {
    // 在「日记」tab 下拉刷的应该是日记本身。缓存新鲜时 ensureLoaded 不发请求，
    // 所以这里必须走 refresh()（无条件打服务端）——否则用户在日记页下拉，看到的
    // 只有转圈动画，日记一个字都不会变。
    if (_segmentIndex == 1) {
      await context.read<MomentsProvider>().refresh();
      return;
    }
    // 同理，在「关于我」下拉刷的应该是这一页上的三块内容，而不是背后的章节时间线
    // —— 页面上一个字都不会变，用户只看到转圈，于是把「没刷出来」读成「云端就是空的」。
    if (_segmentIndex == 2) {
      await Future.wait([
        context.read<MemoriesProvider>().loadMemories(),
        context.read<InsightsProvider>().loadInsights(),
        context.read<DiscoverProvider>().loadActionItems(),
      ]);
      return;
    }
    final timeline = context.read<TimelineProvider>();
    await provider.getInitialConversations();
    await provider.refreshCloudProcessing();
    if (!mounted) return;
    final requestIds = <String, Set<String>>{};
    for (final convos in provider.groupedConversations.values) {
      for (final c in convos) {
        if (c.status == ConversationStatus.processing || c.status == ConversationStatus.in_progress) continue;
        if (c.discarded) continue;
        (requestIds[timelineDayKey(timelineStartOf(c))] ??= <String>{}).add(c.id);
      }
    }
    // 手动刷新走过一遍就重置签名，否则下一帧的自动同步会被当成重复请求跳过。
    _lastTimelineSyncSignature = null;
    await timeline.syncDays(requestIds, refresh: true);
  }

  /// `YYYY-MM-DD` → 用于显示日期标题的 DateTime。
  /// 解析失败时退回该天任意一条会话的起始时间（键就是从它算出来的）。
  DateTime _dateOfKey(String dayKey, List<ServerConversation> sameDay) =>
      DateTime.tryParse(dayKey) ?? timelineStartOf(sameDay.first);

  String _timeRange(ServerConversation c) {
    final start = c.startedAt ?? c.createdAt;
    final end = c.finishedAt;
    return end != null ? _formatRange(start, end) : _formatTime(start);
  }

  static String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _formatRange(DateTime start, DateTime end) => '${_formatTime(start)}-${_formatTime(end)}';

  String _hours(double seconds) => (seconds / 3600).toStringAsFixed(1);

  /// 空档阈值：扣除 BLE 连接 + 静默时段后，剩余"没戴"时长超过此值才显示空档条。
  static const Duration _kGapThreshold = Duration(hours: 1);

  /// 空档文案。措辞用「可能没戴」而非断言——判定基于「BLE 连接与否」近似佩戴
  /// （连着放桌上没戴仍算连），无硬件传感器，故留有余地。
  String _gapText(BuildContext context, Duration gap) {
    final h = gap.inMinutes / 60.0;
    return revampText(context,
        en: "I wasn't with you here (maybe not worn, ~${h.toStringAsFixed(1)} h)",
        zh: '这段我不在你身边（可能没戴，约 ${h.toStringAsFixed(1)} 小时）');
  }


  String _dayLabel(BuildContext context, DateTime date) {
    const weekdaysZh = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const weekdaysEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return revampText(context,
        en: '${weekdaysEn[date.weekday - 1]} $mm.$dd',
        zh: '${weekdaysZh[date.weekday - 1]} $mm.$dd');
  }

  ThemeData _lightTheme(BuildContext context) {
    final base = ThemeData.light(useMaterial3: false);
    return base.copyWith(
      scaffoldBackgroundColor: JXB.bgApp,
      colorScheme: const ColorScheme.light(
        primary: JXB.brandPrimary,
        surface: JXB.surface,
      ),
      textTheme: base.textTheme.apply(fontFamily: JXB.fontSans),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
  }
}

/// Segmented 右侧云朵吉祥物头像（白底圆角，轻阴影）。
class _MascotAvatar extends StatelessWidget {
  final VoidCallback? onTap;
  const _MascotAvatar({this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 62,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: JXB.surface,
          borderRadius: BorderRadius.circular(100),
          boxShadow: const [
            BoxShadow(color: Color(0x14264D78), offset: Offset(0, 2), blurRadius: 6.6),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Image.asset('assets/images/p01/mascot_cloud_tight.png', fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// 日期组头（Figma 结构）：左「周三 07.09 + 日历按钮」，右可选搜索框，同一行。
class _DateRow extends StatelessWidget {
  final String dateLabel;
  final VoidCallback? onCalendarTap;
  final bool showCalendar;
  final Widget? search;
  const _DateRow({required this.dateLabel, this.onCalendarTap, this.showCalendar = false, this.search});

  @override
  Widget build(BuildContext context) {
    // dateLabel 形如「周三 07.09」，拆成中文星期 + 日期。
    final parts = dateLabel.split(' ');
    final weekday = parts.isNotEmpty ? parts.first : dateLabel;
    final date = parts.length > 1 ? parts[1] : '';
    return Row(
      children: [
        Text(weekday,
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
        const SizedBox(width: 8),
        Text(date,
            style: const TextStyle(
                fontFamily: JXB.fontNumber, fontSize: 16, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
        if (showCalendar) ...[
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onCalendarTap,
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: JXB.brandTint, borderRadius: BorderRadius.circular(32)),
              child: const Icon(Icons.calendar_today_rounded, size: 18, color: JXB.brandPrimary),
            ),
          ),
        ],
        if (search != null) ...[
          const SizedBox(width: 10),
          Expanded(child: search!),
        ],
      ],
    );
  }
}

/// 搜索胶囊：可输入搜索框（走后端 searchConversations）+ 右侧搜索/清除图标。
class _SearchPill extends StatelessWidget {
  final String hint;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchPill({
    required this.hint,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.isNotEmpty;
    return Container(
      height: 36,
      padding: const EdgeInsets.only(left: 12, right: 10),
      decoration: BoxDecoration(
        color: const Color(0x66E8E8E8), // rgba(232,232,232,0.4)
        borderRadius: BorderRadius.circular(32),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPrimary),
              cursorColor: JXB.brandPrimary,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: hasText ? onClear : null,
            child: Icon(
              hasText ? Icons.close_rounded : Icons.search_rounded,
              size: 20,
              color: JXB.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 日期筛选激活时的提示 chip：显示所选日期 + 清除。
class _ActiveDateFilterChip extends StatelessWidget {
  final DateTime date;
  final VoidCallback onClear;
  const _ActiveDateFilterChip({required this.date, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final label = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return GestureDetector(
      onTap: onClear,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: JXB.brandTint, borderRadius: BorderRadius.circular(JXB.radiusFull)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.event_available, size: 14, color: JXB.brandPrimary),
            const SizedBox(width: 6),
            Text(revampText(context, en: 'Only $label', zh: '仅看 $label'),
                style: JXB.tagLabel.copyWith(color: JXB.brandPrimary, fontSize: 13)),
            const SizedBox(width: 6),
            const Icon(Icons.close_rounded, size: 14, color: JXB.brandPrimary),
          ],
        ),
      ),
    );
  }
}
