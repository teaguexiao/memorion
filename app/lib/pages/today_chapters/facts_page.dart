import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:flutter/material.dart';
import 'package:memorion/backend/schema/memory.dart';
import 'package:memorion/pages/today_chapters/widgets/jxb_gradient_background.dart';
import 'package:memorion/providers/memories_provider.dart';
import 'package:memorion/ui/atoms/memorion_skeleton.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// 「它记住的事实」完整页（从「关于我」的「查看全部」进）。
///
/// 真数据 `MemoriesProvider.memories`，样式对齐 P-03 你答应过的事（PromisesPage）。
/// 事实按「它自己记住的」/「你告诉它的」（manuallyAdded）两段分开——手动添加的
/// 天然可信，混在一起看不出区别。
///
/// 后端 fact 提取是概率性的，用户得有纠正的手，两种纠正给的是不同信号：
/// **左滑删除**＝这条不该记（负反馈，走 deleteMemoryServer 硬删）；
/// **长按编辑**＝该记但记错了，改字比删掉重记划算。加右上角手动添加。
///
/// 手势分工照抄章节卡与「标记说话人」页：删除一律左滑，长按留给编辑。
class FactsPage extends StatelessWidget {
  const FactsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: JxbGradientBackground(
            child: SafeArea(
              child: Column(
                children: [
                  _detailBar(context),
                  const Expanded(child: _FactsList()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailBar(BuildContext context) {
    return SizedBox(
      height: 68,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                  width: 42, height: 42, child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary)),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Facts It Remembers', zh: '它记住的事实'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            GestureDetector(
              onTap: () => showFactSheet(context),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                  width: 42, height: 42, child: Icon(Icons.add_rounded, size: 24, color: JXB.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }

  /// 添加 / 编辑事实的输入面板。`existing` 为空是添加，非空是编辑。
  ///
  /// 两件事共用一个面板：字段、校验、键盘避让都一样，分成两份只会各改一半。
  static Future<void> showFactSheet(BuildContext context, {Memory? existing}) async {
    final isEdit = existing != null;
    final provider = context.read<MemoriesProvider>();
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _FactSheetContent(isEdit: isEdit, initialText: existing?.content ?? ''),
    );
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty) return;
    if (isEdit) {
      // 内容没变就别发请求，否则每次打开面板点保存都会刷一次 updatedAt。
      if (trimmed == existing.content) return;
      provider.editMemory(existing, trimmed);
    } else {
      provider.createMemory(trimmed, MemoryVisibility.private, MemoryCategory.system);
    }
  }
}

/// 输入面板本体，独立成 StatefulWidget 只为一件事：让 controller 的 dispose
/// 挂在这个 widget 自己的生命周期上。之前 controller 是在 showFactSheet 里
/// `await showModalBottomSheet(...)` 之后手动 dispose 的——但那个 await 在
/// `Navigator.pop()` 调用的瞬间就 resolve，此时底部弹层的收起动画还没播完，
/// TextField 仍挂在树上用着这个 controller，一 dispose 就是
/// "TextEditingController was used after being disposed"。挂在 State.dispose()
/// 上，framework 自己会等这棵子树真正卸载了才调用。
class _FactSheetContent extends StatefulWidget {
  final bool isEdit;
  final String initialText;

  const _FactSheetContent({required this.isEdit, required this.initialText});

  @override
  State<_FactSheetContent> createState() => _FactSheetContentState();
}

class _FactSheetContentState extends State<_FactSheetContent> {
  late final _controller = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        decoration: const BoxDecoration(
          color: JXB.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                widget.isEdit
                    ? revampText(context, en: 'Fix what it got wrong', zh: '改掉它记错的地方')
                    : revampText(context, en: 'Tell it a fact about you', zh: '告诉它一件关于你的事'),
                style: const TextStyle(
                    fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPrimary),
              decoration: InputDecoration(
                hintText: revampText(context, en: 'e.g. I am allergic to peanuts', zh: '例如：我对花生过敏'),
                hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder),
                filled: true,
                fillColor: JXB.bgApp,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(revampText(context, en: 'Cancel', zh: '取消'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: JXB.brandPrimary,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  ),
                  child: Text(revampText(context, en: 'Save', zh: '保存'),
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FactsList extends StatefulWidget {
  const _FactsList();

  @override
  State<_FactsList> createState() => _FactsListState();
}

class _FactsListState extends State<_FactsList> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Provider 一页只拉 100 条，这里是完整列表页，滚到底继续翻。
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
        context.read<MemoriesProvider>().loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final undo = context.watch<UndoDeleteController?>();
    return Consumer<MemoriesProvider>(
      builder: (context, mp, _) {
        if (mp.loading && mp.memories.isEmpty) {
          return const MemorionSkeletonCards(count: 5, cardHeight: 76, withHeader: true);
        }
        final all = mp.memories.where((m) => undo?.hides('fact:${m.id}') != true).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        if (all.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Center(
              child: Text(
                revampText(context,
                    en: "Nothing yet. It only remembers what looks lasting about you — most conversations add nothing.",
                    zh: '还没有。它只记下看起来长久的事，多数对话不会留下什么。'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.6, color: JXB.textPlaceholder),
              ),
            ),
          );
        }

        final byUser = all.where((m) => m.manuallyAdded).toList();
        final byAi = all.where((m) => !m.manuallyAdded).toList();

        return RefreshIndicator(
          color: JXB.brandPrimary,
          onRefresh: mp.refresh,
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 30),
            children: [
              if (byAi.isNotEmpty) ...[
                _sectionLabel(revampText(context, en: 'It noticed · ${byAi.length}', zh: '它注意到的 · ${byAi.length}')),
                const SizedBox(height: 12),
                _factsCard(context, mp, byAi),
                const SizedBox(height: 20),
              ],
              if (byUser.isNotEmpty) ...[
                _sectionLabel(revampText(context, en: 'You told it · ${byUser.length}', zh: '你告诉它的 · ${byUser.length}')),
                const SizedBox(height: 12),
                _factsCard(context, mp, byUser),
              ],
              const SizedBox(height: 16),
              if (mp.loadingMore)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(color: JXB.brandPrimary, strokeWidth: 2)),
                  ),
                ),
              Text(
                revampText(context,
                    en: 'Swipe left to forget a fact, long-press to edit it.', zh: '左滑可以忘掉，长按可以改写。'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionLabel(String text) {
    return Text(text,
        style: const TextStyle(
            fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w500, color: JXB.textPlaceholder));
  }

  Widget _factsCard(BuildContext context, MemoriesProvider mp, List<Memory> facts) {
    return Container(
      width: double.infinity,
      // 左右内边距下移到行里，卡片自己不留 padding：左滑要能滑到卡片边缘，
      // 边距留在外层的话行会从 padding 区域探出去，露在圆角之外。
      // clipBehavior 同理——不裁剪的话滑动中的行会盖住圆角和描边。
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: JXB.border, width: 1),
        boxShadow: const [BoxShadow(color: Color(0x0D2B2926), blurRadius: 14, offset: Offset(0, 4))],
      ),
      child: Column(
        children: [
          for (int i = 0; i < facts.length; i++) ...[
            _factRow(context, mp, facts[i]),
            if (i != facts.length - 1)
              Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 18), color: JXB.border),
          ],
        ],
      ),
    );
  }

  /// 一条事实：左滑露出删除（同章节卡手势），长按进编辑。
  Widget _factRow(BuildContext context, MemoriesProvider mp, Memory m) {
    return Dismissible(
      key: ValueKey('fact_${m.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(context, m),
      // 数据变更放这里，不放 confirmDismiss：confirmDismiss 返回 true 之后
      // Dismissible 还要放退场动画，若在那之前就 notifyListeners() 把这条从
      // 列表里摘掉，父级 ListView 会在动画播放中把这个 Dismissible 提前拆除，
      // 两边同时抢着卸载同一个 element，导致 framework 断言
      // `_dependents.isEmpty` 崩溃。onDismissed 保证动画放完了才改数据。
      onDismissed: (_) => context.read<UndoDeleteController>().add(UndoDeletion(
            key: 'fact:${m.id}',
            kind: DeleteKind.fact,
            title: m.content,
            commit: () => mp.deleteMemory(m),
          )),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        color: const Color(0x14FF3B30),
        child: const Icon(Icons.delete_outline_rounded, size: 20, color: JXB.error),
      ),
      child: GestureDetector(
        onLongPress: () => FactsPage.showFactSheet(context, existing: m),
        behavior: HitTestBehavior.opaque,
        child: Container(
          // 左滑时下层背景要露出来，行本身不能是透明的，否则删除底色会透到文字后面。
          color: JXB.surface,
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(m.content,
                    style: const TextStyle(
                        fontFamily: JXB.fontSans, fontSize: 14, height: 1.45, color: JXB.textPrimary)),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(_fmtDate(context, m.createdAt),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 只回答「要不要删」，不动数据——数据变更在 onDismissed 里做（见上面注释）。
  Future<bool> _confirmDelete(BuildContext context, Memory m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JXB.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(revampText(ctx, en: 'Forget this?', zh: '忘掉这条？'),
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
        content: Text(m.content,
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(revampText(ctx, en: 'Keep', zh: '保留'),
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(revampText(ctx, en: 'Forget', zh: '忘掉'),
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.error)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  String _fmtDate(BuildContext context, DateTime d) =>
      revampText(context, en: '${d.month}/${d.day}', zh: '${d.month}月${d.day}日');
}
