import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/schema/vocabulary_word.dart';
import 'package:memorion/providers/vocabulary_provider.dart';
import 'package:memorion/ui/atoms/memorion_skeleton.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// 词库管理（记小宝 1.0 浅色改版，设置「录音与识别」子页）。
///
/// 用户把常错的人名 / 术语 / 项目代号加入个人词库，未来用于提升转录与理解准确度。
/// Phase 0：增 / 删 / 查（不做改）；数据走 [VocabularyProvider] → 后端 `v1/vocabulary`。
///
/// ⚠️ **列表拉取失败必须留下界面痕迹，且随时能重试。** 词库没有本地缓存兜底，失败时
/// 屏幕上确实是空的——和「我一个词都没加过」长得一模一样。所以空态也待在
/// `RefreshIndicator` 的可滚容器里（见 [_body]、[_empty]），并额外出一条带「重试」的
/// 横幅（[_retryBanner]）：下拉是隐性手势，光有它等于让用户猜。
class VocabularyPage extends StatefulWidget {
  const VocabularyPage({super.key});

  @override
  State<VocabularyPage> createState() => _VocabularyPageState();
}

class _VocabularyPageState extends State<VocabularyPage> {
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<VocabularyProvider>().initialize());
  }

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
          backgroundColor: JXB.bgApp,
          floatingActionButton: _fab(),
          body: SafeArea(
            child: Column(
              children: [
                _detailBar(context),
                Expanded(
                  child: Consumer<VocabularyProvider>(
                    builder: (context, p, _) => _body(context, p),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailBar(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(width: 36, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary)),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Vocabulary', zh: '词库管理'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            GestureDetector(
              onTap: _showHelp,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 32, height: 32, alignment: Alignment.center,
                decoration: const BoxDecoration(color: Color(0x14808594), shape: BoxShape.circle),
                child: const Text('?', style: TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, VocabularyProvider p) {
    final all = p.words;
    final filtered = _query.isEmpty
        ? all
        : all.where((x) => x.term.toLowerCase().contains(_query.toLowerCase())).toList();
    return Column(
      children: [
        _searchBox(context),
        const SizedBox(height: 16),
        Expanded(
          // 骨架屏只覆盖「一条都还没有」的窗口：有内容就直接显示；
          // hasLoadedOnce 补首帧空档（拉取要等 postFrame 才发起，这之前
          // loading 仍是 false，光看它会闪一下空态）。
          child: all.isEmpty && (!p.hasLoadedOnce || p.loading)
              ? const MemorionSkeletonRows(count: 7)
              : RefreshIndicator(
                  color: JXB.brandPrimary,
                  onRefresh: () => p.reload(),
                  // ⚠️ 空态也必须是可滚的，否则「一个词条都没有」——恰好是拉取失败后
                  // 用户停在的那个状态——正是唯一下拉不动、没法重试的界面。
                  // `AlwaysScrollableScrollPhysics` 让内容不足一屏时依然响应下拉。
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 100),
                    children: [
                      if (p.loadFailed) _retryBanner(context, p),
                      if (filtered.isEmpty) _empty() else _listCard(context, p, filtered),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// 拉取失败时的可见提示 + 重试按钮。下拉刷新是隐性手势，光有它等于让用户猜；而失败
  /// 以前完全没有界面痕迹（`getAllVocabulary` 直接 `return []`），用户看到的是干净的
  /// 空态「还没有添加词条」。
  Widget _retryBanner(BuildContext context, VocabularyProvider p) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: const Color(0x0FE55247),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x40E55247), width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, size: 18, color: JXB.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                revampText(context, en: 'Could not load vocabulary. Pull down to refresh.', zh: '词库加载失败，下拉可刷新'),
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
          ),
          GestureDetector(
            onTap: p.loading ? null : () => p.reload(),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(revampText(context, en: 'Retry', zh: '重试'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: JXB.brandPrimary)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBox(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: JXB.border, width: 1)),
        child: Row(
          children: [
            const Icon(Icons.search_rounded, size: 18, color: JXB.textPlaceholder),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: revampText(context, en: 'Search words', zh: '搜索词条'),
                  hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPlaceholder),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listCard(BuildContext context, VocabularyProvider p, List<VocabularyWord> words) {
    return Container(
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (int i = 0; i < words.length; i++) ...[
            if (i != 0) const Divider(height: 1, color: JXB.border),
            _wordRow(context, p, words[i]),
          ],
        ],
      ),
    );
  }

  Widget _wordRow(BuildContext context, VocabularyProvider p, VocabularyWord word) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Expanded(
            child: Text(word.term,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _confirmDelete(context, p, word),
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.delete_outline_rounded, size: 20, color: JXB.textPlaceholder),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    // 不用 Center：它在 ListView 里高度无界。空态必须待在可滚容器里，见 [_body]。
    return Padding(
      padding: const EdgeInsets.only(top: 72),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('📖', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 12),
          Text(
              _query.isEmpty
                  ? revampText(context, en: 'No words added yet', zh: '还没有添加词条')
                  : revampText(context, en: 'No matching words found', zh: '没有找到匹配的词条'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder)),
        ],
      ),
    );
  }

  Widget _fab() {
    return GestureDetector(
      onTap: () => _showAddSheet(context),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 56, height: 56, alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: JXB.brandPrimary,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Color(0x33007AFF), blurRadius: 16, offset: Offset(0, 6))],
        ),
        child: const Icon(Icons.add_rounded, size: 30, color: Colors.white),
      ),
    );
  }

  // ── 新增词条（底部输入 sheet）───────────────────────────────
  Future<void> _showAddSheet(BuildContext context) async {
    final controller = TextEditingController();
    final provider = context.read<VocabularyProvider>();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: const BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(width: 36, height: 4, decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 18),
              Text(revampText(ctx, en: 'Add Word', zh: '添加词条'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 40,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPrimary),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: revampText(ctx, en: 'Name, term, or codename', zh: '人名、术语或项目代号'),
                  hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPlaceholder),
                  filled: true,
                  fillColor: JXB.bgApp,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: JXB.brandPrimary, width: 1.5)),
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => Navigator.pop(ctx, true),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 48, alignment: Alignment.center,
                  decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
                  child: Text(revampText(ctx, en: 'Add', zh: '添加'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((confirmed) async {
      final term = controller.text.trim();
      if (confirmed != true || term.isEmpty) return;
      HapticFeedback.lightImpact();
      await provider.createWord(term);
      if (mounted) setState(() {});
    });
  }

  Future<void> _confirmDelete(BuildContext context, VocabularyProvider p, VocabularyWord word) async {
    final ok = await _confirmDialog(context,
        title: revampText(context, en: 'Delete this word?', zh: '删除这个词条？'),
        body: revampText(context, en: '"${word.term}" will be removed from your vocabulary.', zh: '「${word.term}」将从你的词库中移除。'));
    if (ok != true) return;
    HapticFeedback.mediumImpact();
    await p.deleteWord(word);
    if (mounted) setState(() {});
  }

  Future<bool?> _confirmDialog(BuildContext context, {required String title, required String body}) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
          decoration: BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [BoxShadow(color: Color(0x1F264D78), blurRadius: 30, offset: Offset(0, 12))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 8),
              Text(body, textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, false),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 46, alignment: Alignment.center,
                        decoration: BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(ctx, en: 'Cancel', zh: '取消'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, true),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 46, alignment: Alignment.center,
                        decoration: BoxDecoration(color: JXB.error, borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(ctx, en: 'Delete', zh: '删除'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
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
  }

  void _showHelp() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
          decoration: BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [BoxShadow(color: Color(0x1F264D78), blurRadius: 30, offset: Offset(0, 12))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(revampText(ctx, en: 'Vocabulary', zh: '词库管理'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 10),
              Text(
                  revampText(ctx,
                      en: 'Add names, terms, and codenames that matter to you. Memorion will use them to make transcripts and summaries more accurate over time.',
                      zh: '把对你重要的人名、术语和项目代号加进来，记小宝会用它们让转写和摘要越来越准。'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.6, color: JXB.textSecondary)),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => Navigator.pop(ctx),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 46, width: double.infinity, alignment: Alignment.center,
                  decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
                  child: Text(revampText(ctx, en: 'Got it', zh: '知道了'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
