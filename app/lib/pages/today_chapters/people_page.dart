import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/providers/people_provider.dart';
import 'package:memorion/ui/atoms/memorion_skeleton.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// P-30P 人物管理 / 识别其他人（记小宝 1.0 浅色改版，Figma v2.4 node 431:2296）。
///
/// 人物列表（首字母彩色头像 + 名称 + N 段样本）+ 搜索 + 新建（FAB）+
/// 人物详情（重命名 / 播放样本 / 删除样本 / 删除人物）。
///
/// 全真数据：`PeopleProvider`（getAllPeople / createPerson / updatePersonName /
/// deletePerson / deletePersonSpeechSample / playPause，走后端 `v1/people`）。
///
/// ⚠️ **列表只拿计数，样本 URL 在详情里按人拉。** 列表接口带上样本要为每个人各列一次
/// GCS 并逐 blob 签名，833 人的账号上单页实测 15.65s（不带是 2.38s），全量 27 秒——
/// 这期间锁屏或切走 App，iOS 挂起网络，整次拉取就失败。条数由后端
/// `speech_samples_count` 给出。
class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key});

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  String _query = '';

  // 人物头像配色（按 colorIdx / 名称确定性取用）。
  static const List<(Color, Color)> _avatarColors = [
    (Color(0xFF007AFF), Color(0xFFFFFFFF)),
    (Color(0xFF34C759), Color(0xFFFFFFFF)),
    (Color(0xFFF2B21A), Color(0xFFFFFFFF)),
    (Color(0xFFE5524D), Color(0xFFFFFFFF)),
    (Color(0xFF9B7BFF), Color(0xFFFFFFFF)),
    (Color(0xFF54A4FD), Color(0xFFFFFFFF)),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<PeopleProvider>().initialize());
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
                  child: Consumer<PeopleProvider>(
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
              child: Text(revampText(context, en: 'People', zh: '人物'),
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

  Widget _body(BuildContext context, PeopleProvider p) {
    final all = p.people;
    final filtered = _query.isEmpty
        ? all
        : all.where((x) => x.name.toLowerCase().contains(_query.toLowerCase())).toList();
    return Column(
      children: [
        _searchBox(context),
        const SizedBox(height: 16),
        Expanded(
          // 骨架屏只覆盖「一条都还没有」的窗口：有内容（含 cachedPeople 预填）
          // 就直接显示，别让骨架屏盖住缓存；hasLoadedOnce 补首帧空档（拉取要等
          // postFrame 才发起，这之前 loading 仍是 false，光看它会闪一下空态）。
          child: all.isEmpty && (!p.hasLoadedOnce || p.loading)
              ? const MemorionSkeletonRows(count: 6, rowHeight: 68, leadingCircle: 40, twoLine: true)
              : RefreshIndicator(
                  color: JXB.brandPrimary,
                  onRefresh: () => p.setPeople(),
                  // ⚠️ 空态也必须是可滚的，否则「一个人都没有」——恰好是拉取失败后用户
                  // 停在的那个状态——正是唯一下拉不动、没法重试的界面。
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

  /// 拉取失败时的可见提示 + 重试按钮。下拉刷新是隐性手势，光有它等于让用户猜；而
  /// 失败以前完全没有界面痕迹（只有一行 debugPrint），用户看到的是干净的空态。
  Widget _retryBanner(BuildContext context, PeopleProvider p) {
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
                revampText(context, en: 'Could not load people. Pull down to refresh.', zh: '人物列表加载失败，下拉可刷新'),
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
          ),
          GestureDetector(
            onTap: p.loading ? null : () => p.setPeople(),
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
                  hintText: revampText(context, en: 'Search people', zh: '搜索人物'),
                  hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPlaceholder),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listCard(BuildContext context, PeopleProvider p, List<Person> people) {
    return Container(
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (int i = 0; i < people.length; i++) ...[
            if (i != 0) const Padding(padding: EdgeInsets.only(left: 56), child: Divider(height: 1, color: JXB.border)),
            _personRow(context, p, people[i]),
          ],
        ],
      ),
    );
  }

  Widget _personRow(BuildContext context, PeopleProvider p, Person person) {
    // 用 count 而不是 `speechSamples!.length`：列表接口不返回 URL（每人一次 GCS 列举
    // + 逐 blob 签名，833 人实测 15.65s vs 2.38s），URL 只在详情里按人拉。
    final count = person.speechSamplesCount;
    return GestureDetector(
      onTap: () => _showPersonDetail(context, p, person),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 68,
        child: Row(
          children: [
            _avatar(person),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(person.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                  const SizedBox(height: 3),
                  Text(
                      count == 0
                          ? revampText(context, en: 'No samples yet', zh: '暂无样本')
                          : revampText(context, en: '$count sample${count == 1 ? '' : 's'}', zh: '$count 段样本'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: JXB.textPlaceholder),
          ],
        ),
      ),
    );
  }

  Widget _avatar(Person person, {double size = 44}) {
    // 颜色：优先用后端 colorIdx（>0 时），否则用名称字符和稳定散列，保证多彩分布。
    final ci = person.colorIdx ?? 0;
    final seed = ci > 0 ? ci : person.name.codeUnits.fold<int>(0, (a, b) => a + b);
    final idx = seed.abs() % _avatarColors.length;
    final (bg, fg) = _avatarColors[idx];
    final initial = person.name.isEmpty ? '?' : person.name.characters.first;
    return Container(
      width: size, height: size, alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(initial,
          style: TextStyle(fontFamily: JXB.fontSans, fontSize: size * 0.42, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  Widget _empty() {
    // 不用 Center：它在 ListView 里高度无界。空态必须待在可滚容器里，见 [_body]。
    return Padding(
      padding: const EdgeInsets.only(top: 72),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('👥', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 12),
          Text(
              _query.isEmpty
                  ? revampText(context, en: 'No people added yet', zh: '还没有添加人物')
                  : revampText(context, en: 'No matching people found', zh: '没有找到匹配的人物'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder)),
        ],
      ),
    );
  }

  Widget _fab() {
    return GestureDetector(
      onTap: () => _showNameSheet(context),
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

  // ── 新建 / 重命名（底部输入 sheet）───────────────────────────
  // 每种结果都要让用户看得到（与标记说话人卡片一致）：名字不合法就留在 sheet 里说明原因，
  // 保存失败弹统一 toast。以前这两种情况 sheet 都照样关、什么都不说，用户以为已经加上 /
  // 改好了。
  Future<void> _showNameSheet(BuildContext context, {Person? person}) async {
    final controller = TextEditingController(text: person?.name ?? '');
    final provider = context.read<PeopleProvider>();
    String? errorText;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          void submit() {
            if (controller.text.trim().length < 2) {
              setSheetState(() => errorText = revampText(ctx, en: 'Name must be 2-40 characters', zh: '姓名需为 2-40 个字符'));
              return;
            }
            Navigator.pop(ctx, true);
          }

          return Padding(
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
                  Text(
                      person == null
                          ? revampText(ctx, en: 'Add Person', zh: '添加人物')
                          : revampText(ctx, en: 'Rename', zh: '重命名'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 40,
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPrimary),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: revampText(ctx, en: 'Enter name', zh: '输入姓名'),
                      hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, color: JXB.textPlaceholder),
                      errorText: errorText,
                      filled: true,
                      fillColor: JXB.bgApp,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: JXB.brandPrimary, width: 1.5)),
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: submit,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      height: 48, alignment: Alignment.center,
                      decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
                      child: Text(
                          person == null
                              ? revampText(ctx, en: 'Add', zh: '添加')
                              : revampText(ctx, en: 'Save', zh: '保存'),
                          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).then((confirmed) async {
      final name = controller.text.trim();
      if (confirmed != true || name.length < 2) return;
      HapticFeedback.lightImpact();
      final ok = person == null
          ? (await provider.createPersonProvider(name)) != null
          : await provider.updatePersonProvider(person, name);
      if (!mounted) return;
      setState(() {});
      if (!ok) {
        UndoDeleteHost.showMessage(
            this.context,
            person == null
                ? revampText(this.context, en: 'Failed to add, please retry', zh: '添加失败，请重试')
                : revampText(this.context, en: 'Failed to save, please retry', zh: '保存失败，请重试'));
      }
    });
  }

  // ── 人物详情 sheet ─────────────────────────────────────────
  void _showPersonDetail(BuildContext context, PeopleProvider provider, Person person) {
    // 样本 URL 按需拉：列表里没有它们（见 _personRow）。放在 show 之前发起，sheet 里
    // 靠 Consumer 等结果。
    provider.loadPersonSamples(person.id);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ChangeNotifierProvider<PeopleProvider>.value(
        value: provider,
        child: Consumer<PeopleProvider>(
          builder: (ctx, p, _) {
            // 从最新列表取该人物（重命名/删样本后同步）。
            final cur = p.people.firstWhere((x) => x.id == person.id, orElse: () => person);
            final samples = p.samplesUrl[cur.id] ?? const <String>[];
            final samplesLoading = p.samplesLoadingFor(cur.id);
            final samplesFailed = p.samplesFailedFor(cur.id);
            return Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
              decoration: const BoxDecoration(
                color: JXB.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(width: 36, height: 4, decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 18),
                  _avatar(cur, size: 64),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(cur.name,
                          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 19, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          _showNameSheet(context, person: cur);
                        },
                        behavior: HitTestBehavior.opaque,
                        child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.edit_outlined, size: 18, color: JXB.brandPrimary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 条数用列表里就有的 count：样本 URL 还在路上时也能立刻显示，不会先
                  // 闪一下「暂无样本」再变成「3 段样本」。
                  Builder(builder: (_) {
                    final n = samplesLoading || samplesFailed ? cur.speechSamplesCount : samples.length;
                    return Text(
                        n == 0
                            ? revampText(ctx, en: 'No samples yet', zh: '暂无样本')
                            : revampText(ctx, en: '$n sample${n == 1 ? '' : 's'}', zh: '$n 段样本'),
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary));
                  }),
                  const SizedBox(height: 16),
                  if (samplesLoading)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: JXB.brandPrimary),
                      ),
                    )
                  else if (samplesFailed)
                    GestureDetector(
                      onTap: () => p.loadPersonSamples(cur.id, force: true),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Text(revampText(ctx, en: 'Could not load samples. Tap to retry.', zh: '样本加载失败，点击重试'),
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.brandPrimary)),
                      ),
                    )
                  else if (samples.isNotEmpty)
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        itemCount: samples.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: JXB.border),
                        itemBuilder: (_, i) {
                          final playing = p.currentPlayingPersonId == cur.id && p.currentPlayingIndex == i && p.isPlaying;
                          return SizedBox(
                            height: 56,
                            child: Row(
                              children: [
                                GestureDetector(
                                  onTap: () => p.playPause(cur.id, i, samples[i]),
                                  behavior: HitTestBehavior.opaque,
                                  child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 24, color: JXB.brandPrimary),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(revampText(ctx, en: 'Voice Sample ${i + 1}', zh: '声音样本 ${i + 1}'),
                                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
                                ),
                                GestureDetector(
                                  onTap: () => _confirmDeleteSample(ctx, p, cur.id, samples[i], i),
                                  behavior: HitTestBehavior.opaque,
                                  child: const Padding(padding: EdgeInsets.all(6), child: Icon(Icons.delete_outline_rounded, size: 20, color: JXB.textPlaceholder)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 16),
                  // 删除人物
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
                    child: GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        _confirmDeletePerson(context, provider, cur);
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 48, alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0x0FE55247),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: const Color(0x80E55247), width: 1),
                        ),
                        child: Text(revampText(ctx, en: 'Delete Person', zh: '删除人物'),
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.error)),
                      ),
                    ),
                  ),
                  SizedBox(height: MediaQuery.of(ctx).padding.bottom + 16),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmDeleteSample(BuildContext ctx, PeopleProvider p, String personId, String url, int sampleIdx) async {
    final ok = await _confirmDialog(ctx,
        title: revampText(ctx, en: 'Delete this sample?', zh: '删除这个样本？'),
        body: revampText(ctx, en: '"Voice Sample ${sampleIdx + 1}" cannot be recovered after deletion.', zh: '删除后「声音样本 ${sampleIdx + 1}」将无法找回。'));
    if (ok != true) return;
    HapticFeedback.mediumImpact();
    await p.deletePersonSample(personId, url);
  }

  Future<void> _confirmDeletePerson(BuildContext context, PeopleProvider p, Person person) async {
    final ok = await _confirmDialog(context,
        title: revampText(context, en: 'Delete person?', zh: '删除人物？'),
        body: revampText(context,
            en: 'This will delete "${person.name}" and all their voice samples. This action cannot be undone.',
            zh: '将删除「${person.name}」及其全部语音样本，此操作不可撤销。'));
    if (ok != true) return;
    HapticFeedback.mediumImpact();
    final deleted = await p.deletePersonProvider(person);
    if (!mounted) return;
    setState(() {});
    if (!deleted) {
      UndoDeleteHost.showMessage(this.context, revampText(this.context, en: "Couldn't delete the contact. Their data has been kept.", zh: '删除联系人失败，原数据已保留。'));
    }
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
              Text(revampText(ctx, en: 'Recognize Others', zh: '识别其他人'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 10),
              Text(
                  revampText(ctx,
                      en: 'Create profiles for the people you talk to often, so Memorion can recognize them in transcripts and make your remembered conversations clearer.',
                      zh: '为常和你对话的人建立档案，记小宝就能在转写里认出他们，让记忆里的对话更清晰。'),
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
