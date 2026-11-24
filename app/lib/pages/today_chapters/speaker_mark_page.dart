import 'dart:async';
import 'package:memorion/providers/timeline_provider.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/people_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// P-12A 标记说话人（记小宝 1.0 浅色改版，Figma v2.4 node 638:2542 / 648:4650）。
///
/// 弹出大卡片（bottom sheet）：顶部拖动条 + ✕/✓ header、当前片段卡、上一条/下一条、
/// 分配说话人（搜索 + 人物单选列表，人物行支持左滑删除，含「我」标记）。
///
/// 选中项是**可取消**的（再点一次已勾选的行 → 取消勾选）。取消勾选后按 ✓ 会把该
/// 说话人的归属清空，标签回落到「说话人 N」——`speakerLabels` 只在 `isUser` /
/// `personId` 都为空时才用序号兜底，所以清空即恢复默认，不需要额外的「重置」接口。
///
/// 后端（无 mock）：
/// - 指派 / 清空：`assignBulkConversationTranscriptSegments`（`personId: null` 即清空）
/// - 删除人物：`PeopleProvider.deletePersonProvider`（→ `deletePerson`）
typedef RecordingSpeakerAssigner = Future<bool> Function(
  String conversationId, List<String> segmentIds, {bool? isUser, String? personId});

class SpeakerMarkSheet extends StatefulWidget {
  final ServerConversation conversation;
  final int speakerId;
  final RecordingSpeakerAssigner assignSpeaker;

  const SpeakerMarkSheet({super.key, required this.conversation, required this.speakerId,
    this.assignSpeaker = assignBulkConversationTranscriptSegments});

  @override
  State<SpeakerMarkSheet> createState() => _SpeakerMarkSheetState();
}

class _SpeakerMarkSheetState extends State<SpeakerMarkSheet> {
  late List<TranscriptSegment> _speakerSegments;
  int _index = 0; // 当前片段在该说话人片段中的序号
  String _query = '';
  String? _selectedPersonId; // 选中的目标：'user' / personId；null = 未分配（按 ✓ 即清空）
  String? _initialPersonId; // 进来时的既有归属，用来区分「没动过」和「主动取消勾选」
  bool _saving = false;
  bool _initialUniform = true; // 进来时该说话人全部片段归属是否一致（不一致要重写以统一）
  /// 在这张卡片里新建的人（新的在前），排在列表最前、「我」之上。人物列表按名字排序，
  /// 人一多，新建的那个就埋在中间——勾是勾上了，用户却看不到，只能去搜索框里找。
  final List<String> _createdIds = [];
  final TextEditingController _searchCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _speakerSegments =
        widget.conversation.transcriptSegments.where((s) => s.speakerId == widget.speakerId).toList();
    if (_speakerSegments.isEmpty) {
      _speakerSegments = widget.conversation.transcriptSegments.isNotEmpty
          ? [widget.conversation.transcriptSegments.first]
          : [];
    }
    // 预选当前说话人已有归属。
    //
    // 口径必须和 `transcript_common.speakerLabels` 一致（多数票），不能只看第一段：
    // 同一个 speaker 的段落归属可能不齐（实时页逐段标过就会这样），那时转录页按多数票
    // 显示「张三」，而只看首段的预选会一个勾都不给，用户就以为「明明标了却没勾」。
    _selectedPersonId = _majorityOwner();
    _initialPersonId = _selectedPersonId;
    _initialUniform = _speakerSegments.every((s) => (s.isUser ? 'user' : s.personId) == _initialPersonId);
    // 拉人物列表。`PeopleProvider.people` 的初值只是 `cachedPeople`（本地缓存），
    // 而写这份缓存的只有「人物」设置页——没进过那一页的会话里，这里的列表就只剩
    // 「我」一行，用户根本选不到任何联系人。`ensureLoaded` 的注释早就写着
    // 「speaker-tagging sheet 会调」，但实际全仓库无人调用。
    //
    // 已有缓存时 `ensureLoaded` 直接返回、不发请求（见它的注释）：带样本的全量分页
    // 在人物多的账号上要 20 秒以上，为一张卡片付这个代价还要担失败风险，不值得。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<PeopleProvider>().ensureLoaded();
    });
  }

  /// 该说话人所有片段的多数归属（'user' / personId / null）。
  String? _majorityOwner() {
    if (_speakerSegments.isEmpty) return null;
    var userVotes = 0;
    final personVotes = <String, int>{};
    for (final s in _speakerSegments) {
      if (s.isUser) {
        userVotes++;
      } else if (s.personId != null) {
        personVotes[s.personId!] = (personVotes[s.personId!] ?? 0) + 1;
      }
    }
    if (userVotes * 2 >= _speakerSegments.length) return userVotes > 0 ? 'user' : null;
    if (personVotes.isEmpty) return null;
    return personVotes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  int _assignedCount(String personId) {
    return widget.conversation.transcriptSegments.where((s) {
      if (personId == 'user') return s.isUser;
      return s.personId == personId;
    }).length;
  }

  bool get _selectedContactPendingDeletion =>
      _selectedPersonId != null &&
      context.read<UndoDeleteController?>()?.hides('contact:$_selectedPersonId') == true;

  Future<void> _done() async {
    if (_saving || _selectedContactPendingDeletion) return;
    // 没动过（含「本来就没标记、也没选人」）——不发请求。注意这里不能只判
    // `_selectedPersonId == null`：那样「取消勾选」会被当成「什么都没选」而静默丢弃，
    // 正是用户没法清除标记的原因。
    // `_initialUniform` 那半个条件是为了别丢掉既有行为：该说话人段落归属不齐时，
    // 按 ✓ 仍要把整组重写成多数票那个人（否则少数派的残留标记永远清不掉）。
    if (_selectedPersonId == _initialPersonId && _initialUniform) {
      Navigator.of(context).maybePop();
      return;
    }
    final segmentIds = _speakerSegments.map((s) => s.id).toList();
    final isUser = _selectedPersonId == 'user';
    // `_selectedPersonId == null` → isUser=false + personId=null，即清空归属。
    final personId = isUser ? null : _selectedPersonId;
    setState(() => _saving = true);
    bool saved;
    try {
      saved = await widget.assignSpeaker(widget.conversation.id, segmentIds, isUser: isUser, personId: personId);
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    if (!saved) {
      setState(() => _saving = false);
      UndoDeleteHost.showMessage(context, revampText(context, en: 'Failed to save, please retry', zh: '保存失败，请重试'));
      return;
    }
    for (final id in segmentIds) {
      final idx = widget.conversation.transcriptSegments.indexWhere((s) => s.id == id);
      if (idx == -1) continue;
      widget.conversation.transcriptSegments[idx].isUser = isUser;
      widget.conversation.transcriptSegments[idx].personId = personId;
    }
    context.read<ConversationProvider>().updateConversation(widget.conversation);
    final timeline = context.read<TimelineProvider?>();
    if (timeline != null) {
      unawaited(timeline.refreshConversations({widget.conversation.id},
        fallbackDate: timelineDayKey(widget.conversation.startedAt ?? widget.conversation.createdAt)));
    }
    setState(() => _saving = false);
    Navigator.of(context).pop(true);
  }

  /// 左滑删除人物：二次确认 → PeopleProvider.deletePersonProvider（本地移除 + 后端删除）。
  Future<bool> _confirmDeletePerson(Person p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JXB.surface,
        title: Text(revampText(ctx, en: 'Delete Contact', zh: '删除联系人'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
        content: Text(
            revampText(ctx, en: 'Delete "${p.name}"? This contact and their voice samples will be removed.', zh: '确定删除「${p.name}」吗？该联系人及其声纹样本将被移除。'),
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(revampText(ctx, en: 'Cancel', zh: '取消'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(revampText(ctx, en: 'Delete', zh: '删除'), style: const TextStyle(color: JXB.error))),
        ],
      ),
    );
    return ok == true && mounted;
  }

  @override
  Widget build(BuildContext context) {
    final undo = context.watch<UndoDeleteController?>();
    final people = context.watch<PeopleProvider>().people.where((p) => undo?.hides('contact:${p.id}') != true).toList();
    final myName = SharedPreferencesUtil().givenName;
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty ? people : people.where((p) => p.name.toLowerCase().contains(q)).toList();
    final created = [for (final id in _createdIds) ...filtered.where((p) => p.id == id)];
    final rest = filtered.where((p) => !_createdIds.contains(p.id));
    final showYou = q.isEmpty || (myName.isNotEmpty && myName.toLowerCase().contains(q)) || '我'.contains(q); // i18n-ignore: 搜索匹配逻辑，非展示文案

    return PopScope(
      canPop: !_saving,
      child: Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: AbsorbPointer(
          absorbing: _saving,
          child: Container(
          height: MediaQuery.of(context).size.height * 0.86,
          decoration: const BoxDecoration(
            color: Color(0xFFF6FAFF),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // 顶部拖动条
              Container(
                width: 36, height: 5, margin: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(color: const Color(0xFFB2B2B2), borderRadius: BorderRadius.circular(3)),
              ),
              _header(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
                  children: [
                    _currentSegmentCard(),
                    const SizedBox(height: 14),
                    _nav(),
                    const SizedBox(height: 20),
                    Text(revampText(context, en: 'Assign Speaker', zh: '分配说话人'),
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
                    const SizedBox(height: 6),
                    // 提示随状态切换：勾着 → 告诉用户可以取消；已取消 → 说明按 ✓ 会恢复默认。
                    // 少了这行，「取消勾选」看起来跟「什么都没选」一模一样。
                    Text(
                      _initialPersonId != null && _selectedPersonId == null
                          ? revampText(context,
                              en: 'Unchecked — tap ✓ to reset this speaker to "Speaker ${widget.speakerId}"',
                              zh: '已取消勾选 —— 点 ✓ 将恢复为「说话人 ${widget.speakerId}」')
                          : revampText(context,
                              en: 'Tap the checked row again to clear this speaker\'s label',
                              zh: '再点一次已勾选的人可清除该说话人的标记'),
                      style: TextStyle(
                        fontFamily: JXB.fontSans,
                        fontSize: 12,
                        height: 1.4,
                        color: _initialPersonId != null && _selectedPersonId == null ? JXB.brandPrimary : JXB.textPlaceholder,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _searchBox(),
                    const SizedBox(height: 12),
                    // 「添加新人物」——始终在名字列表最前面
                    _addPersonButton(),
                    const SizedBox(height: 12),
                    // 刚新建的人紧跟在按钮下面（见 _createdIds）
                    for (final p in created) ...[
                      _dismissiblePerson(p),
                      const SizedBox(height: 12),
                    ],
                    // 「我」（user）行——不可删除
                    if (showYou) ...[
                      _personRow(id: 'user', name: myName.isNotEmpty ? myName : revampText(context, en: 'Me', zh: '我'), isYou: true),
                      const SizedBox(height: 12),
                    ],
                    for (final p in rest) ...[
                      _dismissiblePerson(p),
                      const SizedBox(height: 12),
                    ],
                  ],
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

  Widget _header() {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _circleBtn(Icons.close_rounded, JXB.textSecondary, const Color(0xFFF2F3F3), () => Navigator.of(context).maybePop()),
            Expanded(
              child: Text(revampText(context, en: 'Mark Speaker', zh: '标记说话人'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            _circleBtn(Icons.check_rounded, Colors.white,
                _selectedContactPendingDeletion ? JXB.textPlaceholder : JXB.brandPrimary,
                _saving || _selectedContactPendingDeletion ? null : _done),
          ],
        ),
      ),
    );
  }

  Widget _circleBtn(IconData icon, Color fg, Color bg, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36, height: 36, alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(icon, size: 20, color: fg),
      ),
    );
  }

  Widget _currentSegmentCard() {
    final seg = _speakerSegments.isNotEmpty ? _speakerSegments[_index] : null;
    final text = seg?.text.trim() ?? revampText(context, en: '(No transcript)', zh: '（无转写内容）');
    final time = seg != null ? _fmt(seg.start) : '0:00';
    return Container(
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(revampText(context, en: 'Current Segment', zh: '当前片段'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, fontWeight: FontWeight.w500, color: JXB.textSecondary)),
          const SizedBox(height: 10),
          Text(text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, height: 1.55, color: JXB.textPrimary)),
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(child: _MiniWave()),
              const SizedBox(width: 12),
              Text(time, style: const TextStyle(fontFamily: JXB.fontNumber, fontSize: 13, fontWeight: FontWeight.w600, color: JXB.textSecondary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _nav() {
    final total = _speakerSegments.length;
    return Row(
      children: [
        _navBtn(revampText(context, en: '‹ Previous', zh: '‹ 上一条'), enabled: _index > 0, onTap: () => setState(() => _index--)),
        Expanded(
          child: Center(
            child: Text('${_index + 1} / $total',
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w500, color: JXB.textSecondary)),
          ),
        ),
        _navBtn(revampText(context, en: 'Next ›', zh: '下一条 ›'), enabled: _index < total - 1, onTap: () => setState(() => _index++)),
      ],
    );
  }

  Widget _navBtn(String label, {required bool enabled, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 110, height: 44, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? const Color(0x14007AFF) : JXB.surface,
          borderRadius: BorderRadius.circular(12),
          border: enabled ? null : Border.all(color: JXB.border, width: 1),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w500,
                color: enabled ? JXB.brandPrimary : JXB.textPlaceholder)),
      ),
    );
  }

  Widget _searchBox() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: JXB.border, width: 1)),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtl,
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: revampText(context, en: 'Search contacts', zh: '搜索联系人'),
                hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder),
              ),
            ),
          ),
          const Icon(Icons.search_rounded, size: 18, color: JXB.textPlaceholder),
        ],
      ),
    );
  }

  /// 「添加新人物」按钮——点击弹出创建输入框，成功后新档案排到列表最前并自动选中。
  Widget _addPersonButton() {
    return GestureDetector(
      onTap: _showCreatePersonSheet,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: JXB.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x33007AFF), width: 1.2),
        ),
        child: Row(
          children: [
            Container(
              width: 40, height: 40, alignment: Alignment.center,
              decoration: const BoxDecoration(color: Color(0x14007AFF), shape: BoxShape.circle),
              child: const Icon(Icons.person_add_alt_1_rounded, size: 20, color: JXB.brandPrimary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(revampText(context, en: 'Add New Person', zh: '添加新人物'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.brandPrimary)),
                  const SizedBox(height: 2),
                  Text(revampText(context, en: 'Create a new speaker profile', zh: '创建新的说话人档案'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.add_rounded, size: 22, color: JXB.brandPrimary),
          ],
        ),
      ),
    );
  }

  /// 创建新人物输入框（浅色，匹配本 sheet 风格）。成功后新档案排到列表最前并自动选中，
  /// 用户直接按 ✓ 就行；失败要明说，否则用户只能猜到底加没加上。
  ///
  /// 注意：这里刻意**不**手动 dispose `nameCtl`。sheet 关闭是带退场动画的，
  /// `Navigator.pop` 后 `TextField`/`AnimatedPadding` 在动画期间仍会 rebuild 并
  /// `addListener(nameCtl)`；若在 await 返回后立刻 dispose，会命中
  /// 「TextEditingController was used after being disposed」并级联抛出
  /// RenderFlex infinite size / `_dependents.isEmpty` 等一串断言。局部 controller
  /// 交给 GC 回收即可（与 name_speaker_sheet 的既有做法一致）。
  ///
  /// 创建（`createPersonProvider` → `notifyListeners`）在 modal 完全关闭后于外层执行，
  /// 拿到名字再创建，避免通知触发的重建与 route 销毁交错。
  Future<void> _showCreatePersonSheet() async {
    final nameCtl = TextEditingController();
    String? errorText;
    // 搜索框先交出焦点：输入框 sheet 关掉时焦点会还给它、键盘重新弹起，正好盖住排到
    // 最前的新人物。
    FocusManager.instance.primaryFocus?.unfocus();

    final createName = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
            return AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFFF6FAFF),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36, height: 5, margin: const EdgeInsets.only(top: 10),
                      decoration: BoxDecoration(color: const Color(0xFFB2B2B2), borderRadius: BorderRadius.circular(3)),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(revampText(ctx, en: 'Add New Person', zh: '添加新人物'),
                              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                          GestureDetector(
                            onTap: () => Navigator.pop(ctx),
                            child: Container(
                              width: 30, height: 30, alignment: Alignment.center,
                              decoration: const BoxDecoration(color: Color(0xFFF2F3F3), shape: BoxShape.circle),
                              child: const Icon(Icons.close, color: JXB.textSecondary, size: 16),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: nameCtl,
                            autofocus: true,
                            maxLength: 40,
                            textCapitalization: TextCapitalization.words,
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 17, color: JXB.textPrimary),
                            cursorColor: JXB.brandPrimary,
                            buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: JXB.surface,
                              hintText: revampText(ctx, en: 'Name', zh: '姓名'),
                              hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 17, color: JXB.textPlaceholder),
                              errorText: errorText,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: JXB.border, width: 1)),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: JXB.border, width: 1)),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: JXB.brandPrimary, width: 1.5)),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  onTap: () => Navigator.pop(ctx),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    decoration: BoxDecoration(color: const Color(0xFFF2F3F3), borderRadius: BorderRadius.circular(12)),
                                    child: Center(child: Text(revampText(ctx, en: 'Cancel', zh: '取消'), style: const TextStyle(fontFamily: JXB.fontSans, color: JXB.textSecondary, fontSize: 16, fontWeight: FontWeight.w600))),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: GestureDetector(
                                  onTap: () {
                                    final raw = nameCtl.text.trim();
                                    if (raw.isEmpty || raw.length < 2 || raw.length > 40) {
                                      setSheetState(() => errorText = revampText(ctx, en: 'Name must be 2-40 characters', zh: '姓名需为 2-40 个字符'));
                                      return;
                                    }
                                    final name = raw[0].toUpperCase() + raw.substring(1);
                                    // 仅返回名字；实际创建在 modal 关闭后于外层进行（见方法注释）。
                                    Navigator.pop(ctx, name);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    decoration: BoxDecoration(
                                      color: JXB.brandPrimary,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [BoxShadow(color: JXB.brandPrimary.withOpacity(0.3), blurRadius: 16, offset: const Offset(0, 4))],
                                    ),
                                    child: Center(child: Text(revampText(ctx, en: 'Add', zh: '添加'), style: const TextStyle(fontFamily: JXB.fontSans, color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600))),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    // modal 已完全关闭、子树移除，此时创建才安全。
    if (createName == null || !mounted) return;
    final newPerson = await context.read<PeopleProvider>().createPersonProvider(createName);
    if (!mounted) return;
    if (newPerson == null) {
      UndoDeleteHost.showMessage(context, revampText(context, en: 'Failed to add, please retry', zh: '添加失败，请重试'));
      return;
    }
    // 清掉搜索词，免得一个不匹配的关键词把刚建的人滤掉。
    _searchCtl.clear();
    setState(() {
      _query = '';
      _createdIds
        ..remove(newPerson.id)
        ..insert(0, newPerson.id);
      _selectedPersonId = newPerson.id;
    });
  }

  /// 可左滑删除的人物行。
  Widget _dismissiblePerson(Person p) {
    return Dismissible(
      key: ValueKey('person_${p.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDeletePerson(p),
      onDismissed: (_) {
        final people = context.read<PeopleProvider>();
        context.read<UndoDeleteController>().add(UndoDeletion(
              key: 'contact:${p.id}',
              kind: DeleteKind.contact,
              title: p.name,
              commit: () async {
                final ok = await people.deletePersonProvider(p);
                if (ok && mounted && _selectedPersonId == p.id) setState(() => _selectedPersonId = null);
                return ok;
              },
            ));
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(color: const Color(0x14E55247), borderRadius: BorderRadius.circular(14)),
        child: const Icon(Icons.delete_outline_rounded, size: 24, color: JXB.error),
      ),
      child: _personRow(id: p.id, name: p.name, isYou: false),
    );
  }

  Widget _personRow({required String id, required String name, required bool isYou}) {
    final selected = _selectedPersonId == id;
    final count = _assignedCount(id);
    final initial = name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
    return GestureDetector(
      // 再点一次已勾选的行 = 取消勾选；配合 ✓ 就是「清除这个说话人的标记」。
      onTap: () => setState(() => _selectedPersonId = selected ? null : id),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0x0F007AFF) : JXB.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? JXB.brandPrimary : JXB.border, width: selected ? 1.5 : 1),
        ),
        child: Row(
          children: [
            Container(
              width: 40, height: 40, alignment: Alignment.center,
              decoration: BoxDecoration(color: selected ? JXB.brandPrimary : const Color(0xFFE5E7EB), shape: BoxShape.circle),
              child: Text(initial, style: TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: selected ? Colors.white : JXB.textSecondary)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                      ),
                      if (isYou) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: const Color(0x1F007AFF), borderRadius: BorderRadius.circular(6)),
                          child: Text(revampText(context, en: 'Me', zh: '我'),
                              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 11, fontWeight: FontWeight.w700, color: JXB.brandPrimary)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(revampText(context, en: '$count segment${count == 1 ? '' : 's'} assigned', zh: '已分配 $count 个片段'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _radio(selected),
          ],
        ),
      ),
    );
  }

  Widget _radio(bool selected) {
    return Container(
      width: 24, height: 24, alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? JXB.brandPrimary : Colors.transparent,
        shape: BoxShape.circle,
        border: selected ? null : Border.all(color: JXB.textPlaceholder, width: 1.5),
      ),
      child: selected ? const Icon(Icons.check_rounded, size: 15, color: Colors.white) : null,
    );
  }

  String _fmt(double seconds) {
    final s = seconds.floor();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// 当前片段卡里的静态蓝色小波形（视觉）。
class _MiniWave extends StatelessWidget {
  const _MiniWave();

  @override
  Widget build(BuildContext context) {
    const List<double> heights = [8, 14, 20, 10, 24, 16, 12, 22, 18, 10, 26, 14, 20, 12, 16, 8, 22, 14, 18, 10, 24, 16];
    return SizedBox(
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final h in heights) ...[
            Container(
              width: 2.5, height: h,
              decoration: BoxDecoration(color: const Color(0x99007AFF), borderRadius: BorderRadius.circular(1)),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}
