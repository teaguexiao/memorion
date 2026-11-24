import 'package:flutter/foundation.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/material.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/schema/insight.dart';
import 'package:memorion/backend/schema/memory.dart';
import 'package:memorion/pages/today_chapters/facts_page.dart';
import 'package:memorion/pages/today_chapters/first_impression_page.dart';
import 'package:memorion/pages/today_chapters/portrait_detail_page.dart';
import 'package:memorion/pages/today_chapters/widgets/due_chip.dart';
import 'package:memorion/pages/today_chapters/widgets/due_hint.dart';
import 'package:memorion/pages/today_chapters/widgets/fact_bubble_card.dart';
import 'package:memorion/pages/today_chapters/promises_page.dart';
import 'package:memorion/providers/discover_provider.dart';
import 'package:memorion/providers/insights_provider.dart';
import 'package:memorion/providers/memories_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/ui/atoms/memorion_skeleton.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// 「关于我」Tab 主体（Figma v2.4 node 343:16004）。
///
/// 全真数据（2026-07-27 起，原 `about_me_mock.dart` 已删除）：
/// - 「它看到的你」头卡 + 「最新洞察」列表 ← `InsightsProvider`（`GET /v1/insights`
///   涌现式洞察引擎，见 backend/routers/developer_insights.py）
/// - 「它记住的事实」← MemoriesProvider.memories
/// - 「你答应过的事」摘要 ← `DiscoverProvider.pendingActionItems`（点「查看全部」进
///   P-03 完整页）
///
/// 设计稿（0:3744）原为「固定 MBTI/archetype 人格卡 + Day2/Day7 排期里程碑」，
/// 与后端涌现式引擎（不预设卡片类型、不排期、证据够了才冒出来）冲突，故改为
/// 洞察流：
/// - 头卡 = 当前选中那条洞察（headline + body + 陪伴天数 + 命中率）
/// - 「最新洞察」= 横滑小卡片，沿用设计稿「里程碑」卡样式（圆点+短标题+日期），
///   点卡切换头卡内容，默认停在最新一条；低置信度（confidence<70）标「它猜的」
/// 完整证据与「准/不准」在 P-31 画像详情里（点头卡进入）。
class AboutMeBody extends StatefulWidget {
  const AboutMeBody({super.key});

  @override
  State<AboutMeBody> createState() => _AboutMeBodyState();
}

class _AboutMeBodyState extends State<AboutMeBody> {
  /// 当前选中的洞察（横滑小卡片选谁，上面的头卡就展示谁）。
  /// 0 = 最新一条（列表按释放时间倒序，默认停在最新）。
  int _selectedInsight = 0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 「它看到的你」头卡（真数据：展示当前选中的洞察）→ P-31 画像详情
          _InsightHeaderCard(selectedIndex: _selectedInsight),
          const SizedBox(height: 20),

          // 最新洞察：横滑小卡片（对齐设计稿「里程碑」卡样式），点击切换头卡
          _LatestInsightsSection(
            selectedIndex: _selectedInsight,
            onSelect: (i) => setState(() => _selectedInsight = i),
          ),
          const SizedBox(height: 20),

          // 它记住的事实（真数据 memories）
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _SectionTitle(revampText(context, en: 'Facts It Remembers', zh: '它记住的事实')),
              GestureDetector(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FactsPage()),
                ),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: [
                    Text(revampText(context, en: 'View All', zh: '查看全部'),
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                    const Icon(Icons.chevron_right_rounded, size: 18, color: JXB.textSecondary),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _FactsCard(),
          const SizedBox(height: 20),

          // 你答应过的事（真数据摘要 → 点「查看全部」进 P-03）
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _SectionTitle(revampText(context, en: 'Promises You Made', zh: '你答应过的事')),
              GestureDetector(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PromisesPage()),
                ),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: [
                    Text(revampText(context, en: 'View All', zh: '查看全部'),
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                    const Icon(Icons.chevron_right_rounded, size: 18, color: JXB.textSecondary),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _PromisesCard(),

          // 待确认事实框（它猜的、还没跟你确认）：一次只出一条，用户不理会自动轮换。
          // 只有点「没错」才写进上面的「它记住的事实」；「不对」= 记住否决、不再问。
          Consumer<MemoriesProvider>(
            builder: (context, mp, _) {
              if (mp.pendingFactToConfirm case final fact?) {
                return Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: FactBubbleCard(
                    tagLabel: revampText(context, en: 'A guess', zh: '它猜的'),
                    body: fact.content,
                    confirmLabel: revampText(context, en: 'Correct', zh: '没错'),
                    dismissLabel: revampText(context, en: 'Not right', zh: '不对'),
                    onConfirm: () => mp.confirmFact(fact),
                    onDismiss: () => mp.rejectFact(fact),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }
}

/// 你答应过的事摘要卡（关于我底部）：显示前几条未完成 + 「还有 N 条」。
///
/// 数据直接读 `DiscoverProvider`——App 启动时 `loadAll()` 已经拉过一次并落了本地
/// 缓存，这里复用即可。**不要在这个 widget 里自己 fetch**：它挂在「关于我」tab 的
/// 条件分支下，切走会被销毁，自己拉就变成每次进 tab 都重新全量请求一次，而且要干等
/// 一整个网络往返（含 TLS 握手约 1.2s）才显示第一个字——旁边「事实」「洞察」两块
/// 都有缓存兜底能秒出，只有这块一直转圈，就是这么来的。
class _PromisesCard extends StatelessWidget {
  const _PromisesCard();

  @override
  Widget build(BuildContext context) {
    return Consumer<DiscoverProvider>(
      builder: (context, dp, _) {
        final promises = dp.pendingActionItems;
        // 只在**一次数据都还没拿到**时转圈；缓存命中或已有结果就直接出内容，
        // 后台刷新静默进行（与「它记住的事实」「最新洞察」的处理保持一致）。
        if (promises.isEmpty && !dp.actionItemsLoadedOnce) {
          return const MemorionSkeletonTextCard(lines: 3);
        }
        if (promises.isEmpty) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(28)),
            alignment: Alignment.center,
            child: Text(revampText(context, en: 'No promises yet', zh: '还没有答应过的事'),
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder)),
          );
        }
        final preview = promises.take(3).toList();
        final remaining = dp.pendingActionItemsCount - preview.length;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(28)),
          child: Column(
            children: [
              for (int i = 0; i < preview.length; i++) ...[
                _promiseRow(context, dp, preview[i]),
                if (i != preview.length - 1) Container(height: 1, color: JXB.border),
              ],
              if (remaining > 0) ...[
                Container(height: 1, color: JXB.border),
                GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PromisesPage()),
                  ),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    child: Text(revampText(context, en: '$remaining more to-dos', zh: '还有 $remaining 条待办'),
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.brandPrimary)),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _promiseRow(BuildContext context, DiscoverProvider dp, DiscoverActionItem p) {
    // `dueHint` 里的相对说法以「这句话是什么时候说的」为基准，不是今天。
    final spokenAt = p.createdAt == null ? null : DateTime.tryParse(p.createdAt!)?.toLocal();
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(vertical: 12),
      // 一行放下：圆圈 + 描述（收缩省略）+ 时间。与 P-03 保持一致。
      child: Row(
        children: [
          // 勾选即落库（与 P-03 同一条 PATCH）。这里勾完就从「未完成」摘要里消失，
          // 所以不画已完成态；完整的未完成/已完成两段在 P-03 里看。
          GestureDetector(
            onTap: () => _markDone(context, dp, p),
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 28,
              height: 32,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration:
                      BoxDecoration(shape: BoxShape.circle, border: Border.all(color: JXB.border, width: 1)),
                ),
              ),
            ),
          ),
          Flexible(
            child: Text(p.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.3, color: JXB.textPrimary)),
          ),
          // 判据是「有没有时间可显示」而不是「dueHint 非空」：不像时间的 hint
          // DueChip 会整个不渲染，只按非空判就会留下那 8px 的空隙。
          if (p.dueDate != null || readDueHint(p.dueHint, spokenAt: spokenAt).isTime) ...[
            const SizedBox(width: 8),
            DueChip(
              dueDate: p.dueDate,
              dueHint: p.dueHint,
              spokenAt: spokenAt,
              variant: DueChipVariant.inline,
            ),
          ],
        ],
      ),
    );
  }

  /// 摘要卡里勾掉一条：先乐观改本地（这条立刻从未完成摘要里消失），写失败再回滚。
  Future<void> _markDone(BuildContext context, DiscoverProvider dp, DiscoverActionItem p) async {
    if (p.conversationId.isEmpty) return;
    final showMessage = UndoDeleteHost.messageSink(context);
    final failedMsg = revampText(context, en: "Couldn't update the to-do", zh: '更新待办失败');
    dp.setActionItemCompleted(conversationId: p.conversationId, itemIdx: p.itemIdx, completed: true);
    final ok = await setConversationActionItemState(p.conversationId, [p.itemIdx], [true]);
    if (ok) return;
    dp.setActionItemCompleted(conversationId: p.conversationId, itemIdx: p.itemIdx, completed: false);
    showMessage(failedMsg);
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: JXB.textPrimary));
  }
}

/// 「它看到的你」头卡：展示**当前选中**的那条洞察（下方横滑小卡片切换）。
/// 沿用设计稿 0:3744 人格卡的深蓝渐变视觉，但内容全部来自真实洞察。
class _InsightHeaderCard extends StatelessWidget {
  final int selectedIndex;
  const _InsightHeaderCard({required this.selectedIndex});

  @override
  Widget build(BuildContext context) {
    return Consumer<InsightsProvider>(
      builder: (context, ip, _) {
        final list = ip.insights;
        final latest = list.isEmpty ? null : list[selectedIndex.clamp(0, list.length - 1)];
        final hitRate = ip.hitRate;
        final days = latest?.companionDays;

        return GestureDetector(
          // 直接进洞察卡（渐变蓝卡）；不再先过 P-31「它眼中的你」对质页——
          // 那页只从「最新洞察」右侧「查看全部」进。
          onTap: latest == null
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => FirstImpressionPage(card: latest)),
                  ),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white, width: 1),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0D2666), Color(0xFF017AFF)],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration:
                          BoxDecoration(color: const Color(0x33228AFF), borderRadius: BorderRadius.circular(20)),
                      alignment: Alignment.center,
                      child: const Icon(Icons.auto_awesome_rounded, size: 26, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(revampText(context, en: 'How it sees you', zh: '它眼中的你'),
                              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: Color(0xFFFFFFD9))),
                          // 命中率只在有真实反馈时显示（无反馈不造假数据）
                          if (hitRate != null)
                            Text(revampText(context, en: '$hitRate% accurate', zh: '命中率 $hitRate%'),
                                style: const TextStyle(
                                    fontFamily: JXB.fontSans,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  latest?.headline ?? revampText(context, en: "I'm still getting to know you", zh: '我还在慢慢认识你'),
                  style: const TextStyle(
                      fontFamily: JXB.fontSans,
                      fontSize: 20,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      color: Colors.white),
                ),
                if (latest != null && latest.body.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(latest.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 13, height: 1.5, color: Color(0xE6FFFFFF))),
                ],
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    days != null
                        ? revampText(context, en: 'Together for $days days', zh: '已陪伴你 $days 天')
                        : revampText(context, en: 'Keep talking — insights will surface', zh: '多聊聊，洞察会自己冒出来'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 11, color: Color(0x99FFFFFF)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 「最新洞察」区：横向滑动的小卡片（对齐设计稿 0:3744「里程碑」卡样式，
/// 148.72×77.84 圆点+标题+副标）。点某张卡 → 上方头卡切换成那条洞察；
/// 默认停在最新一条（索引 0）。
///
/// 只放很短的介绍（标题 + 日期），完整 body/证据/准不准在头卡与 P-31 里看。
/// 空态是**正常状态**——释放阀在证据不够时什么都不发，不造 mock 数据充场面。
class _LatestInsightsSection extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  const _LatestInsightsSection({required this.selectedIndex, required this.onSelect});

  @override
  State<_LatestInsightsSection> createState() => _LatestInsightsSectionState();
}

class _LatestInsightsSectionState extends State<_LatestInsightsSection> {
  final ScrollController _scroll = ScrollController();

  // 设计稿里程碑卡是 149×78（两卡并排）；洞察 headline 比「初见卡片」长，
  // 加宽到 168 让单行标题显示更多字，高度 84 容下圆点+标题+日期三行。
  static const double _cardWidth = 168;
  static const double _cardHeight = 84;
  static const double _gap = 12;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 选中卡片滚入视野（点击靠边的卡时也能看全）。
  void _ensureVisible(int index) {
    if (!_scroll.hasClients) return;
    final target = (index * (_cardWidth + _gap)).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<InsightsProvider>(
      builder: (context, ip, _) {
        final cards = ip.insights;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _SectionTitle(revampText(context, en: 'Latest Insights', zh: '最新洞察')),
                if (cards.isNotEmpty)
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PortraitDetailPage()),
                    ),
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        Text(revampText(context, en: 'View All', zh: '查看全部'),
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                        const Icon(Icons.chevron_right_rounded, size: 18, color: JXB.textSecondary),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (ip.isLoading && cards.isEmpty)
              // 横滑洞察卡的骨架：并排两张半，暗示「右边还有」。
              SizedBox(
                height: _cardHeight,
                child: MemorionSkeleton(
                  child: Row(
                    children: [
                      for (int i = 0; i < 3; i++) ...[
                        if (i != 0) const SizedBox(width: 12),
                        const SkeletonBox(width: 200, height: _cardHeight, radius: 28),
                      ],
                    ],
                  ),
                ),
              )
            else if (cards.isEmpty)
              const _InsightsEmptyCard()
            else
              SizedBox(
                height: _cardHeight,
                // 卡片可能超出一屏 → 横向滑动；负 margin 让卡片贴屏幕边缘滑出
                child: ListView.separated(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  itemCount: cards.length,
                  separatorBuilder: (_, __) => const SizedBox(width: _gap),
                  itemBuilder: (context, i) => _InsightMiniCard(
                    card: cards[i],
                    width: _cardWidth,
                    selected: i == widget.selectedIndex,
                    onTap: () {
                      widget.onSelect(i);
                      _ensureVisible(i);
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 洞察小卡片（设计稿「里程碑」卡样式）：圆点图标 + 短标题 + 日期副标。
/// 选中态用蓝边+浅蓝渐变（同设计稿已解锁态），未选中用白底。
class _InsightMiniCard extends StatelessWidget {
  final InsightCard card;
  final double width;
  final bool selected;
  final VoidCallback onTap;

  const _InsightMiniCard({
    required this.card,
    required this.width,
    required this.selected,
    required this.onTap,
  });

  /// 低置信度标「它猜的」，高置信度标日期。
  bool get _isGuess => card.confidence < 70;

  String _subtitle(BuildContext context) {
    if (_isGuess) return revampText(context, en: 'A guess', zh: '它猜的');
    final d = card.releasedAt ?? card.createdAt;
    if (d == null) return '';
    return revampText(context, en: '${d.month}/${d.day}', zh: '${d.month}月${d.day}日');
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? JXB.brandSecondary : JXB.border, width: 1),
          color: selected ? null : JXB.surface,
          gradient: selected
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x6668ACFF), Color(0x66FFFFFF)],
                )
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: selected ? Colors.white : const Color(0xFFF2F3F3),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                _isGuess ? Icons.help_outline_rounded : Icons.auto_awesome_rounded,
                size: 12,
                color: selected ? JXB.brandSecondary : JXB.textPlaceholder,
              ),
            ),
            const SizedBox(height: 5),
            // 卡片只有 78px 高，标题限 1 行；完整标题在头卡里看
            Text(
              card.headline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 13,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: selected ? JXB.brandSecondary : JXB.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _subtitle(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 11,
                color: selected ? JXB.brandSecondary : JXB.textPlaceholder,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态：引导多聊，而不是造假数据（对齐设计稿「还没抓到线索」的语气）。
/// debug 下附「立即生成」按钮（一轮 40s+ 且消耗 LLM，正式版不给入口）。
class _InsightsEmptyCard extends StatelessWidget {
  const _InsightsEmptyCard();

  @override
  Widget build(BuildContext context) {
    return Consumer<InsightsProvider>(
      builder: (context, ip, _) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          decoration: BoxDecoration(
            color: const Color(0x80FFFFFF),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: JXB.border, width: 1),
          ),
          child: Column(
            children: [
              Text(
                revampText(context,
                    en: "I'm still getting to know you. Keep talking — when I notice something worth saying, it'll show up here.",
                    zh: '我还在认识你。多聊聊，等我注意到值得说的事，就会出现在这里。'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, height: 1.6, color: JXB.textSecondary),
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: ip.isRunningEngine ? null : () => _runEngine(context, ip),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: JXB.brandSecondary, borderRadius: BorderRadius.circular(99)),
                    child: Text(
                      ip.isRunningEngine ? '生成中…（约 40s）' : 'DEBUG：立即生成', // i18n-ignore: kDebugMode 内的调试按钮
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _runEngine(BuildContext context, InsightsProvider ip) async {
    final showMessage = UndoDeleteHost.messageSink(context);
    final reason = await ip.runEngine();
    if (!context.mounted) return;
    // i18n-ignore: 仅 kDebugMode 调试入口可触发
    showMessage(reason == null ? '已生成一条洞察' : '本轮未释放：$reason');
  }
}

/// 它记住的事实：真数据 MemoriesProvider.memories。
class _FactsCard extends StatelessWidget {
  const _FactsCard();

  @override
  Widget build(BuildContext context) {
    return Consumer<MemoriesProvider>(
      builder: (context, mp, _) {
        final memories = mp.memories.take(5).toList();
        if (mp.memories.isEmpty && mp.loading) {
          return const MemorionSkeletonTextCard(lines: 3);
        }
        if (memories.isEmpty) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(28)),
            alignment: Alignment.center,
            child: Text(revampText(context, en: 'No facts remembered yet', zh: '还没有记住的事实'),
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder)),
          );
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(28)),
          child: Column(
            children: [
              for (int i = 0; i < memories.length; i++) ...[
                _factRow(context, memories[i]),
                if (i != memories.length - 1) Container(height: 1, color: JXB.border),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _factRow(BuildContext context, Memory m) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(m.content,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPrimary)),
          ),
          const SizedBox(width: 12),
          Text(_fmtDate(context, m.createdAt),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
        ],
      ),
    );
  }

  String _fmtDate(BuildContext context, DateTime d) =>
      revampText(context, en: '${d.month}/${d.day}', zh: '${d.month}月${d.day}日');
}
