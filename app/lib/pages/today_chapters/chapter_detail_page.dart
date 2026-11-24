import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/chapter_speakers.dart';
import 'package:memorion/backend/schema/chapter_speaker.dart';
import 'package:memorion/pages/today_chapters/widgets/chapter_speakers.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/pages/today_chapters/transcript_page.dart';
import 'package:memorion/pages/today_chapters/ask_page.dart';
import 'package:memorion/pages/today_chapters/chapter_ask_context.dart';
import 'package:memorion/pages/today_chapters/widgets/continue_chat_transition.dart';
import 'package:memorion/pages/today_chapters/widgets/chapter_ask_floating_button.dart';
import 'package:memorion/pages/today_chapters/widgets/chapter_ask_invitation.dart';
import 'package:memorion/pages/today_chapters/conversation_share_sheet.dart';
import 'package:memorion/pages/today_chapters/widgets/jxb_gradient_background.dart';
import 'package:memorion/pages/today_chapters/widgets/share_qr_footer.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/chapter_ask_controller.dart';
import 'package:memorion/providers/timeline_provider.dart';
import 'package:memorion/providers/vocabulary_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:memorion/utils/markdown_summary_selection.dart';
import 'package:memorion/widgets/summary_markdown.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

/// P-11 章节详情（记小宝 1.0 浅色改版，Figma v2.4 node 343:16615）。
///
/// 展示一个章节的：标题 + 参与人 chip + 时长、AI 叙事「它的回忆」、
/// 引用卡「值得回顾的时刻」、to-do「我从这段记下的」、查看完整原文入口、
/// 底部保存到相册 / 分享。
///
/// **一个章节可能由多条 conversation 合成**（后端章节层的二次归纳结果）：
/// - [conversation] 是锚点（首条源会话），单条入口只传它即可；
/// - [sources] 是全部源会话，长度 >1 即合并章节；
/// - [chapter] 是后端章节文档，标题/正文用它的归纳结果。
///
/// 标题铅笔与正文选区「修正」都可编辑。章节修正独立保存，不写入锚点会话，
/// 也不被同一章节的摘要重算覆盖；只有直接打开单条会话时才写回会话本身。
///
/// 数据：真数据来自传入的 [ServerConversation]（同现有 ConversationDetailPage 约定，
/// 直接接收对象而非按 id 拉取）。
/// - ✅ 真：标题(structured.title / 章节归纳)、参与人(transcript_segments 推导，
///   合并态跨全部源)、时长、to-do(structured.actionItems，合并态跨全部源且各自
///   回写自己那条)、完整原文转写段数、
///   「它的回忆」正文(structured.overview，单条态 inline 可编辑 → PATCH /v1/conversations/{id})、
///   「值得回顾的时刻」引用卡(structured.highlights，随 summary 一次生成的真实原话，0~3 句)。
///     注：此处只读渲染，**不会**让首页 P-01 章节卡跟着显示⭐高亮——首页高亮改由
///     structured.is_highlighted（硬件按钮）单独驱动，两者已解耦。
class ChapterDetailPage extends StatefulWidget {
  final ServerConversation conversation;

  /// 本章全部源会话（按时间顺序，首条应等于 [conversation]）。
  /// 单条入口（深链、Ask 页引用）可以不传。
  final List<ServerConversation>? sources;

  /// 后端章节文档；单条入口为 null，此时完全退回会话自身的 structured。
  final TimelineChapter? chapter;
  final ChapterAskController Function()? askControllerFactory;
  final ChapterSpeakerApi speakerApi;
  final Future<void> Function(ServerConversation, ActionItem, bool)? onActionItemToggle;

  const ChapterDetailPage({
    super.key,
    required this.conversation,
    this.sources,
    this.chapter,
    this.askControllerFactory,
    this.speakerApi = const ChapterSpeakerApi(),
    this.onActionItemToggle,
  });

  @override
  State<ChapterDetailPage> createState() => _ChapterDetailPageState();
}

class _ChapterDetailPageState extends State<ChapterDetailPage> {
  final GlobalKey _shareBoundaryKey = GlobalKey();
  bool _capturing = false; // 截图时隐藏底部按钮

  // 「它的回忆」正文改为选区工具条交互（复制 / 修正 / 加入词库），不再有 inline 编辑铅笔。
  // 「修正」保存中标志：避免重复提交。
  TimelineProvider? _timeline;
  bool _savingOverview = false;

  // 标题 inline 编辑态：同旧壳规则——点击铅笔进入编辑，失焦自动保存 PATCH /v1/conversations/{id}/title。
  final TextEditingController _titleController = TextEditingController();
  final FocusNode _titleFocus = FocusNode();
  bool _editingTitle = false;
  bool _savingTitle = false;
  TimelineChapter? _chapter;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final GlobalKey _readerViewportKey = GlobalKey();
  final GlobalKey _askInvitationKey = GlobalKey();
  bool _visibilityCheckPending = false;
  // 底部邀请卡在阅读视口里时隐藏右下角悬浮入口，两个入口不同时出现。
  bool _invitationVisible = false;
  // 章节 Ask 在栈上（含推入、返回动画途中）。
  ContinueChatRoute<void>? _askRoute;

  void _checkInvitationVisibility() {
    if (_visibilityCheckPending) return;
    _visibilityCheckPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckPending = false;
      if (!mounted) return;
      final viewport = _readerViewportKey.currentContext?.findRenderObject() as RenderBox?;
      final invitation = _askInvitationKey.currentContext?.findRenderObject() as RenderBox?;
      if (viewport == null || invitation == null || !viewport.hasSize || !invitation.hasSize) {
        _setInvitationVisible(false);
        return;
      }
      // Compare in viewport coordinates so scrolling and safe areas are respected.
      final origin = invitation.localToGlobal(Offset.zero, ancestor: viewport);
      final visible = (Offset.zero & viewport.size).intersect(origin & invitation.size);
      _setInvitationVisible(visible.width > 0 && visible.height > 0);
    });
  }

  void _setInvitationVisible(bool visible) {
    // Ask 打开期间详情在下面被变形或盖住，保持进入时的状态。
    if (_askRoute != null || visible == _invitationVisible) return;
    setState(() => _invitationVisible = visible);
  }

  /// 章节 Ask 与首页 Ask 同级：独立路由，切后台不会被收起、可以右滑返回；
  /// 「收缩进入口」的转场由 [ContinueChatRoute] 交给本页播放。
  /// [anchor] 是收缩落点（全局坐标），不传即右下角悬浮入口。
  void _openAsk([Offset? anchor]) {
    // 连点只开一页：Ask 还在栈上（包括返回动画途中）就不再打开第二个。
    if (_askRoute != null || ModalRoute.of(context)?.isCurrent == false) return;
    FocusScope.of(context).unfocus();
    HapticFeedback.lightImpact();
    final scope = ChapterAskContext(
      title: _displayTitle(context),
      // 时长文本自带「· 」前缀。
      subtitle: '${_chapterTimeRange(context)} ${_durationText(context, _sources)}',
      conversationIds: _chapter?.sourceConversationIds ?? _sources.map((s) => s.id).toList(),
      sources: _sources,
    );
    final size = MediaQuery.sizeOf(context);
    final route = ContinueChatRoute<void>(
      anchor: anchor ?? Offset(size.width - 48, size.height - ChapterAskFloatingButton.bottomInset(context) - 30),
      showEntry: anchor == null,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (_, cardProgress) =>
          AskPage(chapterContext: scope, cardProgress: cardProgress, controllerFactory: widget.askControllerFactory),
    );
    setState(() => _askRoute = route);
    Navigator.of(context).push(route);
    route.completed.whenComplete(() {
      if (mounted && identical(_askRoute, route)) setState(() => _askRoute = null);
    });
  }

  ServerConversation get conversation => widget.conversation;

  /// 本章的源会话。空列表不可能出现（锚点始终在），过滤掉与锚点重复的项。
  List<ServerConversation> get _sources {
    final given = widget.sources;
    if (given == null || given.isEmpty) return [conversation];
    return given;
  }

  /// 原文入口仍按源录音分流；编辑目标以章节文档为准。
  bool get _isMerged => (_chapter?.isMerged ?? false) || _sources.length > 1;
  bool get _canEdit => !_isMerged || _chapter != null;
  bool get _saving => _savingTitle || _savingOverview;

  @override
  void initState() {
    super.initState();
    _chapter = widget.chapter;
    // 失焦即保存（同旧壳标题编辑模式）。
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus && _editingTitle) {
        _saveTitle();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final timeline = context.read<TimelineProvider?>();
    if (!identical(_timeline, timeline)) {
      _timeline?.removeListener(_syncChapter);
      _timeline = timeline;
      _timeline?.addListener(_syncChapter);
    }
  }

  void _syncChapter() {
    final current = _chapter;
    if (!mounted || current == null) return;
    final date = current.date ?? timelineDayKey(current.start);
    for (final updated in _timeline?.chaptersFor(date) ?? <TimelineChapter>[]) {
      if (updated.start == current.start && updated.end == current.end &&
          setEquals(updated.sourceConversationIds.toSet(), current.sourceConversationIds.toSet()) &&
          !identical(updated, current)) {
        // Editing controllers keep the user's draft; only the stored projection changes.
        setState(() => _chapter = updated);
        return;
      }
    }
  }

  @override
  void dispose() {
    _timeline?.removeListener(_syncChapter);
    _titleController.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _startEditTitle() {
    if (_capturing || !_canEdit || _saving) return;
    _titleController.text = _displayTitle(context);
    setState(() => _editingTitle = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingTitle) _titleFocus.requestFocus();
    });
  }

  Future<void> _saveTitle() async {
    if (!mounted || _saving || !_editingTitle) return;
    final newTitle = _titleController.text.trim();
    final oldTitle = _displayTitle(context);
    setState(() => _editingTitle = false);
    if (newTitle.isEmpty || newTitle == oldTitle) return;
    setState(() => _savingTitle = true);
    final ok = await _saveSummary(title: newTitle);
    if (!mounted) return;
    setState(() => _savingTitle = false);
    if (!ok) {
      _toast(revampText(context, en: 'Failed to save, please retry', zh: '保存失败，请重试'));
    }
  }

  Future<bool> _saveSummary({String? title, String? overview}) async {
    try {
      final chapter = _chapter;
      if (chapter != null) {
        final updated = await context.read<TimelineProvider>().saveChapter(chapter,
            title: title, overview: overview == null ? null : ChapterSpeakerDisplay.restoreTokens(overview));
        if (updated == null) return false;
        if (mounted) setState(() => _chapter = updated);
        return true;
      }
      if (_isMerged) return false;
      final provider = context.read<ConversationProvider>();
      final ok = title != null
          ? await updateConversationTitle(conversation.id, title)
          : await updateConversationOverview(conversation.id, overview!);
      if (ok) {
        if (title != null) conversation.structured.title = title;
        if (overview != null) conversation.structured.overview = overview;
        provider.updateConversation(conversation);
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ── 「它的回忆」正文选区工具条：复制 / 修正 / 加入词库 ──────────────
  // narrative 是 trim 后的原始摘要。纯文本选区直接对应它；Markdown 选区先映射
  // 并验证渲染后的文字，再替换原文，不能把显示偏移直接用于 Markdown 源码。

  /// 选区工具条：复制 / 修正 / 加入词库。基于 SelectableText 的 editableState
  /// 拿选区偏移与选中文本，替换系统默认的复制菜单。
  Widget _overviewSelectionToolbar(BuildContext ctx, EditableTextState editableState, String narrative) {
    final selection = editableState.textEditingValue.selection;
    final buttons = <ContextMenuButtonItem>[];
    if (selection.isValid && !selection.isCollapsed) {
      final start = selection.start;
      final end = selection.end;
      final selected = narrative.substring(start.clamp(0, narrative.length), end.clamp(0, narrative.length));
      buttons.add(ContextMenuButtonItem(
        label: revampText(ctx, en: 'Copy', zh: '复制'),
        onPressed: () {
          editableState.hideToolbar();
          _copySelection(selected);
        },
      ));
      if (_canEdit && !_saving) {
        buttons.add(ContextMenuButtonItem(
          label: revampText(ctx, en: 'Correct', zh: '修正'),
          onPressed: () {
            editableState.hideToolbar();
            _correctSelection(start, end, selected);
          },
        ));
      }
      buttons.add(ContextMenuButtonItem(
        label: revampText(ctx, en: 'Add to Vocabulary', zh: '加入词库'),
        onPressed: () {
          editableState.hideToolbar();
          _addSelectionToVocabulary(selected);
        },
      ));
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableState.contextMenuAnchors,
      buttonItems: buttons,
    );
  }

  Widget _markdownSelectionToolbar(
      BuildContext ctx, SelectableRegionState state, String selected, MarkdownSummarySelection? selection) {
    final buttons = <ContextMenuButtonItem>[];
    if (selected.isNotEmpty) {
      buttons.add(ContextMenuButtonItem(
        label: revampText(ctx, en: 'Copy', zh: '复制'),
        onPressed: () {
          state.hideToolbar();
          _copySelection(selected);
        },
      ));
      if (selection != null && _canEdit && !_saving) {
        buttons.add(ContextMenuButtonItem(
          label: revampText(ctx, en: 'Correct', zh: '修正'),
          onPressed: () {
            state.hideToolbar();
            _correctSelection(selection.start, selection.end, selected, markdownSelection: selection);
          },
        ));
      }
      buttons.add(ContextMenuButtonItem(
        label: revampText(ctx, en: 'Add to Vocabulary', zh: '加入词库'),
        onPressed: () {
          state.hideToolbar();
          _addSelectionToVocabulary(selected);
        },
      ));
    }
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: buttons);
  }

  /// 复制：把选中片段放进剪贴板。
  void _copySelection(String selected) {
    Clipboard.setData(ClipboardData(text: selected));
    _toast(revampText(context, en: 'Copied', zh: '已复制'));
  }

  /// 加入词库：把选中片段作为词条加进个人词库（Phase 0：仅存词条）。
  Future<void> _addSelectionToVocabulary(String selected) async {
    final term = selected.trim();
    if (term.isEmpty) return;
    final word = await context.read<VocabularyProvider>().createWord(term);
    if (!mounted) return;
    _toast(word != null
        ? revampText(context, en: 'Added to vocabulary', zh: '已加入词库')
        : revampText(context, en: 'Failed to add, please retry', zh: '加入失败，请重试'));
  }

  /// 修正：弹编辑框，仅预填选中片段；保存时按选区偏移替换回整段 overview。
  Future<void> _correctSelection(int start, int end, String selected,
      {MarkdownSummarySelection? markdownSelection}) async {
    if (_saving || !_canEdit) return;
    final originalNarrative = _narrative();
    final corrected = await _showCorrectSheet(selected);
    if (corrected == null || !mounted) return;
    final trimmedNew = corrected.trim();
    if (trimmedNew.isEmpty || trimmedNew == selected.trim()) return;

    final narrative = _narrative();
    // 防御：选区偏移越界（文本已变）则放弃，避免错位改写。
    if (narrative != originalNarrative || start < 0 || end > narrative.length || start > end) {
      _toast(revampText(context, en: 'Selection changed, please retry', zh: '选区已变化，请重试'));
      return;
    }
    final newOverview = markdownSelection == null
        ? narrative.replaceRange(start, end, trimmedNew)
        : markdownSelection.source == narrative
            ? markdownSelection.replaceWith(trimmedNew)
            : null;
    if (newOverview == null) {
      _toast(revampText(context, en: 'Selection changed, please retry', zh: '选区已变化，请重试'));
      return;
    }
    setState(() => _savingOverview = true);
    final ok = await _saveSummary(overview: newOverview);
    if (!mounted) return;
    if (ok) {
      _toast(revampText(context, en: 'Saved', zh: '已保存'));
    } else {
      _toast(revampText(context, en: 'Failed to save, please retry', zh: '保存失败，请重试'));
    }
    setState(() => _savingOverview = false);
  }

  /// 修正编辑底部 sheet：预填选中片段，返回修正后的文本（取消返回 null）。
  Future<String?> _showCorrectSheet(String initial) {
    var corrected = initial;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(
            maxHeight:
                MediaQuery.of(ctx).size.height - MediaQuery.of(ctx).viewInsets.bottom - MediaQuery.of(ctx).padding.top,
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: const BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  revampText(ctx, en: 'Correct', zh: '修正'),
                  style: const TextStyle(
                    fontFamily: JXB.fontSans,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: JXB.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  revampText(ctx, en: 'Fix the selected text; the rest stays untouched.', zh: '只改选中的这一段，其余内容保持不变。'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  initialValue: initial,
                  onChanged: (value) => corrected = value,
                  autofocus: true,
                  maxLines: 6,
                  minLines: 2,
                  keyboardType: TextInputType.multiline,
                  style: JXB.body.copyWith(height: 1.6),
                  cursorColor: JXB.brandPrimary,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: JXB.bgApp,
                    contentPadding: const EdgeInsets.all(12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: JXB.brandPrimary, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx, corrected),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      revampText(ctx, en: 'Save', zh: '保存'),
                      style: const TextStyle(
                        fontFamily: JXB.fontSans,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Theme(
        data: ThemeData.light(useMaterial3: false).copyWith(
          colorScheme: const ColorScheme.light(primary: JXB.brandPrimary, surface: JXB.surface),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          // 正文选区不在这里声明——全局主题（main.dart 的 textSelectionTheme）已是
          // 半透明浅蓝，页面级 Theme 不写就继承它。写在这里只会多一份要同步的真相源。
        ),
        child: DefaultTextStyle(
          style: JXB.body,
          child: Stack(
            children: [
              Positioned.fill(
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: JxbGradientBackground(
                    fadeHeight: 280,
                    // 点击空白处收起键盘，退出标题/正文编辑态（同 Ask 页规则）。
                    child: GestureDetector(
                      onTap: () => FocusScope.of(context).unfocus(),
                      behavior: HitTestBehavior.translucent,
                      child: SafeArea(
                        child: Column(
                          children: [
                            _DetailBar(timeRange: _chapterTimeRange(context), onMore: () => _showMoreMenu(context)),
                            Expanded(child: _buildBody(context)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 悬浮入口按屏幕安全区定位（在 Scaffold 之外，键盘弹起时不跟着上移）。
              if (!_invitationVisible)
                Positioned(
                  right: 18,
                  bottom: ChapterAskFloatingButton.bottomInset(context),
                  // 转场期间由 Ask 路由画它的动画；右滑返回时露出来的详情页照常带着它。
                  child: ValueListenableBuilder<bool>(
                    valueListenable: Navigator.of(context).userGestureInProgressNotifier,
                    builder: (context, swiping, _) => _askRoute != null && !swiping
                        ? const SizedBox.shrink()
                        : ChapterAskFloatingButton(
                            buttonKey: const Key('continue-chat'), // i18n-ignore: widget identifier
                            onTap: _openAsk,
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final sources = _sources;
    final participants = _chapter == null ? _participants(context, sources) : <String>[];
    final narrative = _narrative();
    // 值得回顾的时刻：后端 structured.highlights 真实原话（随 summary 生成，0~3 句）。
    // 合并章节按源顺序拼接——章节文档里没有 highlights（二次归纳只产出标题/正文/观察），
    // 而原话本身是可追溯的真实引用，合并不会让它失真。
    final highlights = [for (final c in sources) ...c.structured.highlights];
    // 待确认的待办不在这里露面——它们只在 P-01 顶部气泡卡里等用户拍板。
    // 合并态跨全部源：待办挂在各自的 conversation 上，回写也要回写到对应那条
    // （见 _toggleTodo 的 owner 参数）。
    final todos = <_OwnedTodo>[
      for (final c in sources)
        for (final a in c.structured.actionItems)
          if (!a.deleted && a.confirmed) _OwnedTodo(owner: c, item: a),
    ];
    final transcriptMinutes = _transcriptMinutes(sources);

    final reader = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 可分享/保存的内容区（标题→to-do），用 RepaintBoundary 供截图。
          RepaintBoundary(
            key: _shareBoundaryKey,
            child: Container(
              color: _capturing ? const Color(0xFFF9FAFA) : null, // 截图时补白底
              padding: EdgeInsets.all(_capturing ? 16 : 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题 + 参与人 + 时长（标题 inline 可编辑，同「它的回忆」模式）
                  _editingTitle
                      ? TextField(
                          controller: _titleController,
                          focusNode: _titleFocus,
                          autofocus: true,
                          maxLines: null,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _titleFocus.unfocus(),
                          style: JXB.display.copyWith(
                              fontFamily: 'NotoSerifSC', fontSize: 24, height: 1.35, fontWeight: FontWeight.w600),
                          cursorColor: JXB.brandPrimary,
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            border: InputBorder.none,
                          ),
                        )
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: (_capturing || !_canEdit || _saving) ? null : _startEditTitle,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Flexible(
                                child: Text(_displayTitle(context),
                                    style: JXB.display.copyWith(
                                        fontFamily: 'NotoSerifSC',
                                        fontSize: 24,
                                        height: 1.35,
                                        fontWeight: FontWeight.w600)),
                              ),
                              if (!_capturing && _canEdit) ...[
                                const SizedBox(width: 12),
                                const Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: Icon(
                                    Icons.edit_outlined,
                                    key: Key('title-edit-pencil'),
                                    size: 24,
                                    color: JXB.textPlaceholder,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                  const SizedBox(height: 12),
                  if (_chapter != null)
                    ChapterSpeakersRow(
                        chapter: _chapter!,
                        duration: _durationText(context, sources),
                        onTap: (speaker, anchor) => _openSpeaker(speaker, anchor))
                  else
                    _ParticipantsRow(names: participants, durationText: _durationText(context, sources)),
                  const SizedBox(height: 16),
                  if (conversation.discarded) ...[
                    Text(revampText(context, en: 'Processed · filtered', zh: '处理完成 · 已过滤'),
                        style: JXB.body.copyWith(color: JXB.textSecondary)),
                    const SizedBox(height: 10),
                  ],

                  // 它的回忆（AI 生成；选中正文片段弹「复制/修正/加入词库」工具条）
                  _SectionLabel(revampText(context, en: 'Its Memory', zh: '它的回忆'), muted: true),
                  const SizedBox(height: 10),
                  narrative.isNotEmpty
                      ? SummaryMarkdown(
                          data: narrative,
                          onSpeakerTap: _capturing
                              ? null
                              : (id, anchor) {
                                  final speaker = _chapter?.speakerDisplay?.forEvidence(id);
                                  if (speaker != null) _openSpeaker(speaker, anchor, evidenceId: id);
                                },
                          style: JXB.body.copyWith(height: 1.8),
                          selectable: !_capturing,
                          plainContextMenuBuilder: (ctx, editableState) =>
                              _overviewSelectionToolbar(ctx, editableState, narrative),
                          markdownContextMenuBuilder: _markdownSelectionToolbar,
                        )
                      // 空态提示：选中正文后可「修正」补写。
                      : Text(
                          conversation.discarded
                              ? revampText(context,
                                  en: 'No summary was generated after content filtering. You can still open the transcript and audio below.',
                                  zh: '这段录音经过内容筛选，未生成摘要。仍可从下方查看原文和录音。')
                              : revampText(context, en: 'Nothing yet', zh: '暂无内容'),
                          style: JXB.body.copyWith(height: 1.8, color: JXB.textPlaceholder)),
                  const SizedBox(height: 16),

                  // 值得回顾的时刻（真数据 structured.highlights，可 0~3 条；空则不显示）
                  if (highlights.isNotEmpty) ...[
                    for (int i = 0; i < highlights.length; i++) ...[
                      _QuoteCard(text: '「${highlights[i]}」'),
                      if (i < highlights.length - 1) const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 12),
                    _SectionLabel(revampText(context, en: 'Moments Worth Revisiting', zh: '值得回顾的时刻')),
                    const SizedBox(height: 16),
                  ],

                  // 我从这段记下的（真 to-do）
                  if (todos.isNotEmpty) ...[
                    for (final todo in todos) ...[
                      _TodoRow(
                        item: todo.item,
                        onToggle: (v) => _toggleTodo(context, todo.owner, todo.item, v),
                      ),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 4),
                    _SectionLabel(revampText(context, en: 'What I Noted From This', zh: '我从这段记下的')),
                    const SizedBox(height: 8),
                  ],

                  // 二维码品牌带只在截图态出现：页面上它是噪音，分享图里它是传播出口。
                  if (_capturing) ...[
                    const SizedBox(height: 8),
                    const ShareQrFooter(kind: ShareCardKind.chapter),
                  ],
                ],
              ),
            ),
          ),

          // 查看完整原文（不入截图）
          if (!_capturing) ...[
            ChapterAskInvitation(
              key: _askInvitationKey,
              onTap: () {
                final invitation = _askInvitationKey.currentContext?.findRenderObject() as RenderBox?;
                // The full-width entry captures the page straight down into its center.
                _openAsk(invitation?.localToGlobal(invitation.size.center(Offset.zero)));
              },
            ),
            const SizedBox(height: 16),
            _ViewTranscriptRow(
              // 测试靠这个 key 断言「合并态每条源都能下钻到原文」。
              key: const Key('view-transcript-row'),
              minutes: transcriptMinutes,
              // 合并章节先让用户选哪一段原文——原文属于具体的 conversation，
              // 拼接多条会话的 transcript 会把说话人编号与时间戳混在一起。
              onTap: () => _isMerged ? _pickTranscript(sources) : _openTranscript(conversation),
            ),
            const SizedBox(height: 16),

            // 底部：保存到相册 / 分享
            Row(
              children: [
                Expanded(
                    child: _SecondaryButton(
                        label: revampText(context, en: 'Save to Album', zh: '保存到相册'), onTap: _saveToGallery)),
                const SizedBox(width: 12),
                Expanded(child: _PrimaryButton(label: revampText(context, en: 'Share', zh: '分享'), onTap: _share)),
              ],
            ),
            const SizedBox(height: 12),
            // AI 免责：全页最底部居中一行淡字（替代原醒目徽章）
            Center(
              child: Text(revampText(context, en: 'AI-generated content may be inaccurate', zh: '内容由 AI 生成，可能存在不准确的情况'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 11, color: JXB.textPlaceholder)),
            ),
          ],
        ],
      ),
    );
    return _trackInvitationVisibility(reader);
  }

  Widget _trackInvitationVisibility(Widget reader) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) _checkInvitationVisibility();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0) _checkInvitationVisibility();
          return false;
        },
        child: LayoutBuilder(builder: (context, constraints) {
          _checkInvitationVisibility();
          return SizedBox.expand(key: _readerViewportKey, child: reader);
        }),
      ),
    );
  }

  // ── More(···) 菜单：导出摘要 / 举报内容 / 删除本段 ──────────────
  // Figma v2.4 node 948:6940：白色圆角 sheet + 顶部拖动条 + 左上角圆形「×」关闭，
  // 三项各为独立圆角卡片（导出摘要蓝色高亮主按钮 / 举报内容 / 删除本段红字）。取消入口由「×」承担。
  void _showMoreMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x66000000), // 遮罩 40%（Figma rgba(0,0,0,0.4)）
      builder: (sheetCtx) => Container(
        decoration: const BoxDecoration(
          color: JXB.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部拖动条
                Container(
                  width: 32,
                  height: 5,
                  decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(99)),
                ),
                const SizedBox(height: 8),
                // 左上角圆形「×」关闭按钮
                Align(
                  alignment: Alignment.centerLeft,
                  child: GestureDetector(
                    onTap: () => Navigator.of(sheetCtx).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: Color(0xFFF8F8F8), shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded, size: 18, color: JXB.textSecondary),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _MoreItem(
                  label: revampText(context, en: 'Share a recording link', zh: '分享单条录音链接'),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _shareRecordingLink();
                  },
                ),
                const SizedBox(height: 12),
                _MoreItem(
                  label: revampText(context, en: 'Export Summary', zh: '导出摘要'),
                  variant: _MoreItemVariant.primary,
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _exportSummary();
                  },
                ),
                const SizedBox(height: 12),
                _MoreItem(
                  label: revampText(context, en: 'Report Content', zh: '举报内容'),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _report();
                  },
                ),
                const SizedBox(height: 12),
                _MoreItem(
                  label: revampText(context, en: 'Delete This Section', zh: '删除本段'),
                  variant: _MoreItemVariant.danger,
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    _confirmDelete();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 导出摘要：叙事文本 → 系统分享。合并章节导出的是归纳后的标题与正文
  /// （与页面上看到的一致），不是锚点那一条。
  Future<void> _exportSummary() async {
    final title = _displayTitle(context);
    final overview = _narrative(links: false);
    final buf = StringBuffer();
    if (title.isNotEmpty) buf.writeln(title);
    if (overview.isNotEmpty) {
      buf.writeln();
      buf.writeln(overview);
    }
    // 纯文本分享挂不了二维码，用明文官网链接补上传播出口。
    final signature = memorionShareSignature(context, ShareCardKind.summary);
    final box = context.findRenderObject() as RenderBox?;
    await Share.share(
      buf.toString().trim().isEmpty ? '$title$signature' : '${buf.toString().trimRight()}$signature',
      sharePositionOrigin: box != null ? box.localToGlobal(Offset.zero) & box.size : Rect.zero,
    );
  }

  /// 举报内容：走后端 reportConversationServer。合并章节逐条举报所有源——
  /// 被举报的内容出自哪一条不确定，只报锚点会漏。
  Future<void> _report() async {
    for (final c in _sources) {
      await reportConversationServer(c.id);
    }
    if (mounted) _toast(revampText(context, en: 'Reported, thanks for the feedback', zh: '已举报，感谢反馈'));
  }

  /// 删除本段：二次确认 → 后端删除 → 返回上一页。
  ///
  /// **删章节 = 删掉它的全部源 conversation**。章节本身是可重算投影，只删锚点会让
  /// 下一次重算把剩下的源重新聚成一章、卡片原地复活。所以文案要把「这一章由 N 段
  /// 录音合并而成」讲清楚——用户是在删 N 条录音。
  Future<void> _confirmDelete() async {
    final sources = _sources;
    final count = sources.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JXB.surface,
        title: Text(revampText(context, en: 'Delete This Section', zh: '删除本段'),
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
        content: Text(
            count > 1
                ? revampText(ctx,
                    en: 'This chapter merges $count recordings. All of them will be deleted and this cannot be undone.',
                    zh: '这一章由 $count 段录音合并而成，将一并删除且无法恢复。确定吗？')
                : revampText(ctx, en: 'This cannot be undone. Delete this chapter?', zh: '删除后无法恢复，确定删除这段章节吗？'),
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(revampText(context, en: 'Cancel', zh: '取消'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(revampText(context, en: 'Delete', zh: '删除'), style: const TextStyle(color: JXB.error)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final provider = context.read<ConversationProvider>();
    // 先让章节层忘掉这些源，再删会话：反过来的话会有一帧仍然渲染已删章节
    // （后端已把那天标 dirty，下一次 syncDays 会覆盖这里的近似结果）。
    context.read<TimelineProvider>().forgetConversations(sources.map((c) => c.id).toSet());
    // provider.deleteConversation 同时移除本地 + 调后端删除 + 重新分组。
    for (final c in sources) {
      provider.deleteConversation(c, 0);
    }
    Navigator.of(context).maybePop();
  }

  // ── 截图 / 保存 / 分享 ────────────────────────────────────────
  Future<Uint8List?> _capturePng() async {
    setState(() => _capturing = true);
    await Future.delayed(const Duration(milliseconds: 60)); // 等一帧重绘出白底
    try {
      final boundary = _shareBoundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _saveToGallery() async {
    final bytes = await _capturePng();
    if (bytes == null || !mounted) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/chapter_${conversation.id}_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);
      await Gal.putImage(file.path);
      if (mounted) _toast(revampText(context, en: 'Saved to album', zh: '已保存到相册'));
    } catch (e) {
      if (mounted) _toast(revampText(context, en: 'Failed to save, please retry', zh: '保存失败，请重试'));
    }
  }

  Future<void> _shareRecordingLink() async {
    final sources = _sources;
    ServerConversation? selected;
    if (widget.chapter == null && sources.length == 1) {
      selected = sources.first;
    } else {
      selected = await showModalBottomSheet<ServerConversation>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => SafeArea(
            child: SingleChildScrollView(
                child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(revampText(ctx, en: 'Choose a recording to share', zh: '选择要分享的单条录音'),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            Text(revampText(ctx,
                en: 'Shares that recording’s summary and transcript, not the merged chapter.',
                zh: '分享所选录音的摘要和全文，不包含合并章节。')),
            for (final source in sources)
              ListTile(
                  title: Text(source.structured.title),
                  subtitle: Text(_timeRange(ctx, source)),
                  onTap: () => Navigator.pop(ctx, source)),
          ]),
        ))),
      );
    }
    if (selected != null && mounted) await showConversationShareSheet(context, selected);
  }

  Future<void> _share() async {
    // 截图会触发 setState 重绘，先在 await 前取分享锚点与标题，避免用异步后的 context。
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : Rect.zero;
    final title = _displayTitle(context);
    final bytes = await _capturePng();
    if (bytes == null || !mounted) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/chapter_${conversation.id}_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);
      // iOS 需要 sharePositionOrigin（iPad 必需，iPhone 缺失偶发静默失败）。
      await Share.shareXFiles(
        [XFile(file.path)],
        text: title,
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (mounted) _toast(revampText(context, en: 'Failed to share, please retry', zh: '分享失败，请重试'));
    }
  }

  void _toast(String msg) {
    UndoDeleteHost.showMessage(context, msg);
  }

  // ── 原文下钻 ──────────────────────────────────────────────────
  void _openTranscript(ServerConversation c) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TranscriptPage(conversation: c)));
  }

  /// 合并章节的原文入口：先列出各段源录音，选中再进 TranscriptPage。
  ///
  /// 不把多条 transcript 拼成一篇：说话人编号是**每条会话独立**的
  /// （`speakerId` 由 STT 在单次会话内分配），拼起来会让同一个 speaker 0 在不同段
  /// 落里指向不同的人。原文的可信度比少点一次更重要。
  Future<void> _pickTranscript(List<ServerConversation> sources) async {
    final picked = await showModalBottomSheet<ServerConversation>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x66000000),
      isScrollControlled: true,
      builder: (sheetCtx) => Container(
        decoration: const BoxDecoration(
          color: JXB.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                      width: 32,
                      height: 5,
                      decoration: BoxDecoration(color: JXB.border, borderRadius: BorderRadius.circular(99))),
                ),
                const SizedBox(height: 16),
                Text(revampText(sheetCtx, en: 'Which recording?', zh: '看哪一段原文？'),
                    style: const TextStyle(
                        fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                const SizedBox(height: 4),
                Text(
                    revampText(sheetCtx,
                        en: 'This chapter merges ${sources.length} recordings.', zh: '这一章由 ${sources.length} 段录音合并而成。'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                const SizedBox(height: 14),
                // 源可能很多（实测一章最多 30 条）：可滚动，不要溢出。
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final c in sources) ...[
                          _TranscriptPickRow(
                            timeRange: _timeRange(sheetCtx, c),
                            title: c.structured.title.isNotEmpty
                                ? c.structured.title
                                : revampText(sheetCtx, en: 'A Record', zh: '一段记录'),
                            segmentCount: c.transcriptSegments.length,
                            onTap: () => Navigator.pop(sheetCtx, c),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked != null && mounted) _openTranscript(picked);
  }

  // ── 真数据映射 ────────────────────────────────────────────────
  Future<void> _toggleTodo(BuildContext context, ServerConversation owner, ActionItem item, bool value) async {
    if (widget.onActionItemToggle != null) {
      await widget.onActionItemToggle!(owner, item, value);
      if (mounted) setState(() {});
      return;
    }
    // 复用 ConversationProvider.updateGlobalActionItemState（内部走后端 setConversationActionItemState）。
    // owner 必须是**待办真正所属**的那条会话：合并章节里勾错 owner 会写到别人的
    // action_items 上（后端按 conversation_id + description 定位）。
    await context.read<ConversationProvider>().updateGlobalActionItemState(owner, item.description, value);
  }

  /// 标题：有章节文档时使用其最终标题（包括手工修正），直接会话入口退回源摘要。
  String _displayTitle(BuildContext context) {
    final fromChapter = _chapter?.title.trim() ?? '';
    if (fromChapter.isNotEmpty) return fromChapter;
    final own = conversation.structured.title;
    if (own.isNotEmpty) return own;
    return revampText(context, en: 'A Record', zh: '一段记录');
  }

  /// 参与人：从 transcript_segments 推导（多数投票 speaker → 人名）。
  ///
  /// 合并章节跨全部源统计，但**投票按 (会话, speaker) 分桶**——speakerId 只在单条
  /// 会话内有意义，跨会话把 speaker 0 合并统计会让两个不同的人共享一次投票。
  /// 已识别人物（包括你）优先；两组内部均保留首次出现的顺序。
  List<String> _participants(BuildContext context, List<ServerConversation> sources) {
    final Map<String, _SpeakerAgg> bySpeaker = {};
    final orderedKeys = <String>[];
    for (final c in sources) {
      for (final seg in c.transcriptSegments) {
        final key = '${c.id}#${seg.speakerId}';
        final agg = bySpeaker.putIfAbsent(key, () {
          orderedKeys.add(key);
          return _SpeakerAgg(speakerId: seg.speakerId);
        });
        agg.count++;
        if (seg.isUser) agg.userVotes++;
        if (seg.personId != null) {
          agg.personVotes[seg.personId!] = (agg.personVotes[seg.personId!] ?? 0) + 1;
        }
      }
    }
    final identifiedNames = <String>[];
    final unknownNames = <String>[];
    final seen = <String>{};
    for (final key in orderedKeys) {
      final agg = bySpeaker[key]!;
      final sid = agg.speakerId;
      String label;
      String identity;
      var identified = false;
      if (agg.userVotes * 2 >= agg.count) {
        final given = SharedPreferencesUtil().givenName;
        label = given.isNotEmpty ? given : revampText(context, en: 'You', zh: '你');
        identity = 'user';
        identified = true;
      } else if (agg.personVotes.isNotEmpty) {
        final personId = agg.personVotes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
        final person = SharedPreferencesUtil().getPersonById(personId);
        final name = person?.name.trim() ?? '';
        label = name.isNotEmpty ? name : revampText(context, en: 'Speaker $sid', zh: '说话人 $sid');
        identity = 'person:$personId';
        identified = true;
      } else {
        label = revampText(context, en: 'Speaker $sid', zh: '说话人 $sid');
        identity = 'speaker:$key';
      }
      // 人物按身份去重；未知 speaker 只在自己的录音内有意义，不能按显示名合并。
      if (seen.add(identity)) (identified ? identifiedNames : unknownNames).add(label);
    }
    return [...identifiedNames, ...unknownNames];
  }

  Future<void> _openSpeaker(ChapterSpeaker speaker, Offset? anchor, {String? evidenceId}) async {
    if (_chapter == null || _capturing || _saving) return;
    final provider = context.read<TimelineProvider>();
    final result = await showChapterSpeakerPicker(context,
        chapter: _chapter!,
        speaker: speaker,
        api: widget.speakerApi,
        anchor: anchor,
        evidenceId: evidenceId,
        reload: provider.reloadChapter,
        mutate: (action) => provider.saveChapterMutation(_chapter!, action),
        onChanged: (chapter) {
          if (mounted) setState(() => _chapter = chapter);
        });
    if (!mounted || result == null) return;
    final message = switch (result.enrollmentStatus) {
      'enrolled' => revampText(context, en: 'Chapter updated · voice sample saved', zh: '本章已修改，声纹样本已保存'),
      'already_enrolled' =>
        revampText(context, en: 'Chapter updated · this voice sample is already saved', zh: '本章已修改，这段声纹已保存，无需重复添加'),
      'too_short' || 'insufficient_speech' => revampText(context,
          en: 'Chapter saved · less than 10 seconds of speech; voice not saved', zh: '本章已保存；有效人声不足 10 秒，未保存声纹'),
      'quality_unavailable' => revampText(
          context,
          en: 'Chapter saved · quality check unavailable; voice not saved',
          zh: '本章已保存；音频检查暂不可用，未保存声纹',
        ),
      'overlapping_speech' =>
        revampText(context, en: 'Chapter saved · overlapping speech; try another clip', zh: '本章已保存；片段有重叠发言，请换一段'),
      'distorted_audio' =>
        revampText(context, en: 'Chapter saved · distorted audio; try another clip', zh: '本章已保存；片段失真较重，请换一段'),
      null => revampText(context, en: 'Updated for this chapter', zh: '已替换本章人物'),
      _ => revampText(context, en: 'Chapter updated · sample not eligible for learning', zh: '本章已修改，该原话未用于声纹学习'),
    };
    _speakerUndoToast(message, result);
  }

  void _speakerUndoToast(String message, SpeakerCorrectionResult result) {
    final provider = context.read<TimelineProvider>();
    final chapter = _chapter!;
    final api = widget.speakerApi;
    UndoDeleteHost.showMessage(context, message,
        duration: const Duration(seconds: 10),
        showProgress: true,
        actionLabel: revampText(context, en: 'Undo', zh: '撤销'),
        onAction: () async {
          if (!mounted) return;
          try {
            final updated = await provider.saveChapterMutation(
                chapter, () => api.correct(chapter, result.speakerId, result.operationId, undo: true));
            if (updated == null) throw const ChapterSpeakerFailure();
            if (mounted) {
              setState(() => _chapter = updated);
              _toast(revampText(context, en: 'Undone', zh: '已撤销'));
            }
          } catch (_) {
            if (mounted) _speakerUndoToast(revampText(context, en: 'Undo failed · retry', zh: '撤销失败，可重试'), result);
          }
        });
  }

  /// AI 叙事「它的回忆」：章节最终正文优先，直接会话入口用会话自身的正文。
  /// 都为空时返回空串（显示占位提示）。
  String _narrative({bool links = true}) {
    final chinese = isRevampChinese(context);
    final fromChapter =
        (links ? _chapter?.attributedOverview(chinese: chinese) : _chapter?.plainOverview(chinese: chinese))?.trim() ??
            '';
    if (fromChapter.isNotEmpty) return fromChapter;
    final own = conversation.structured.overview.trim();
    return own.isNotEmpty ? own : fromChapter;
  }

  /// 转写分钟数：合并章节按各源时长求和（不用章节的 duration_seconds——那个含
  /// 章节内部的静音，说「x 分钟转写」会虚高）。
  int _transcriptMinutes(List<ServerConversation> sources) {
    final secs = _chapter?.speechSeconds.round() ?? sources.fold<int>(0, (sum, c) => sum + c.getDurationInSeconds());
    return (secs / 60).ceil().clamp(1, 999);
  }

  String _durationText(BuildContext context, List<ServerConversation> sources) {
    final secs = _chapter?.durationSeconds.round() ?? sources.fold<int>(0, (sum, c) => sum + c.getDurationInSeconds());
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    if (h > 0) return revampText(context, en: '· ${h}h ${m}m', zh: '· $h 小时 $m 分');
    if (m > 0) return revampText(context, en: '· ${m}m', zh: '· $m 分');
    // 不足一分钟：显示秒数，避免真实时长被截断成「0 分」。
    return revampText(context, en: '· ${secs}s', zh: '· $secs 秒');
  }

  /// 顶栏时段：合并章节用章节的起止（跨越全部源），单条用会话自身。
  String _chapterTimeRange(BuildContext context) {
    final chapter = widget.chapter;
    if (chapter != null) {
      return _formatRange(context, chapter.start, chapter.end);
    }
    return _timeRange(context, conversation);
  }

  String _timeRange(BuildContext context, ServerConversation c) {
    final start = c.startedAt ?? c.createdAt;
    final end = c.finishedAt;
    String fmt(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (end == null) return '${fmt(start)} · ${_period(context, start)}';
    return _formatRange(context, start, end);
  }

  String _formatRange(BuildContext context, DateTime start, DateTime end) {
    String fmt(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return '${fmt(start)} – ${fmt(end)} · ${_period(context, start)}';
  }

  String _period(BuildContext context, DateTime start) => start.hour < 12
      ? revampText(context, en: 'AM', zh: '上午')
      : (start.hour < 18 ? revampText(context, en: 'PM', zh: '下午') : revampText(context, en: 'Evening', zh: '晚上'));
}

/// 一条待办 + 它真正所属的会话。
///
/// 合并章节的 to-do 来自多条 conversation，勾选要回写到**各自**那条——只记 item
/// 就无从知道该 PATCH 哪个 conversation_id。
class _OwnedTodo {
  final ServerConversation owner;
  final ActionItem item;
  const _OwnedTodo({required this.owner, required this.item});
}

/// 一个 (会话, speaker) 分桶的投票累计。
///
/// [speakerId] 留在桶里而不是从 key 里再解析出来：key 是 `'${会话id}#$speakerId'`，
/// 而会话 id 本身可能含 `#`，反向切分不可靠。
class _SpeakerAgg {
  final int speakerId;
  int count = 0;
  int userVotes = 0;
  final Map<String, int> personVotes = {};

  _SpeakerAgg({required this.speakerId});
}

/// 合并章节的原文选择行：时段 + 标题 + 段数。
class _TranscriptPickRow extends StatelessWidget {
  final String timeRange;
  final String title;
  final int segmentCount;
  final VoidCallback onTap;

  const _TranscriptPickRow({
    required this.timeRange,
    required this.title,
    required this.segmentCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFFF8F9FB),
          borderRadius: BorderRadius.circular(JXB.radiusControl),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(timeRange,
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textSecondary)),
                  const SizedBox(height: 4),
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(revampText(context, en: '$segmentCount segs', zh: '$segmentCount 段'),
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, size: 20, color: JXB.textPlaceholder),
          ],
        ),
      ),
    );
  }
}

/// 顶部 DetailBar：返回 + 时段 + 更多。
class _DetailBar extends StatelessWidget {
  final String timeRange;
  final VoidCallback onMore;
  const _DetailBar({required this.timeRange, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 68,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _CircleIconButton(icon: Icons.arrow_back_rounded, onTap: () => Navigator.of(context).maybePop()),
            Expanded(
              child: Text(
                timeRange,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w600, color: JXB.textPrimary),
              ),
            ),
            _CircleIconButton(icon: Icons.more_horiz_rounded, onTap: onMore),
          ],
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        child: Icon(icon, size: 24, color: JXB.textPrimary),
      ),
    );
  }
}

/// More 菜单项样式：普通（浅灰底深字）/ 主操作（蓝色高亮白字）/ 危险（浅灰底红字）。
enum _MoreItemVariant { normal, primary, danger }

/// More 菜单项（底部 ActionSheet 独立圆角卡片，Figma v2.4 node 948:4669）。
class _MoreItem extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final _MoreItemVariant variant;
  const _MoreItem({required this.label, required this.onTap, this.variant = _MoreItemVariant.normal});

  @override
  Widget build(BuildContext context) {
    final bool primary = variant == _MoreItemVariant.primary;
    final bool danger = variant == _MoreItemVariant.danger;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary ? JXB.brandSecondary : const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: primary ? Colors.white : (danger ? JXB.error : JXB.textPrimary))),
      ),
    );
  }
}

class _ParticipantsRow extends StatefulWidget {
  final List<String> names;
  final String durationText;
  const _ParticipantsRow({required this.names, required this.durationText});

  @override
  State<_ParticipantsRow> createState() => _ParticipantsRowState();
}

class _ParticipantsRowState extends State<_ParticipantsRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final hiddenCount = widget.names.length - 3;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final name in _expanded ? widget.names : widget.names.take(3)) _PersonChip(name: name),
        if (hiddenCount > 0)
          TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            style: TextButton.styleFrom(
              foregroundColor: JXB.brandPrimary,
              backgroundColor: JXB.brandTint,
              minimumSize: const Size(44, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              shape: const StadiumBorder(),
              textStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, fontWeight: FontWeight.w500),
            ),
            child: Text(
              _expanded ? revampText(context, en: 'Collapse', zh: '收起') : '+$hiddenCount',
              semanticsLabel: _expanded
                  ? revampText(context, en: 'Collapse participants', zh: '收起参与人')
                  : revampText(context, en: 'Show $hiddenCount more participants', zh: '展开其余 $hiddenCount 位参与人'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(widget.durationText,
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
        ),
      ],
    );
  }
}

class _PersonChip extends StatelessWidget {
  final String name;
  const _PersonChip({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 12, top: 5, bottom: 5),
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(99.32)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 8, height: 8, decoration: const BoxDecoration(color: JXB.brandSecondary, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(name,
                style: const TextStyle(
                    fontFamily: JXB.fontSans, fontSize: 12, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final bool muted;
  const _SectionLabel(this.text, {this.muted = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: JXB.fontSans,
        fontSize: muted ? 12 : 16,
        fontWeight: FontWeight.w500,
        color: muted ? JXB.textPlaceholder : JXB.textPrimary,
      ),
    );
  }
}

class _QuoteCard extends StatelessWidget {
  final String text;
  const _QuoteCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
                width: 3, decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, height: 1.55, color: JXB.textPrimary)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodoRow extends StatelessWidget {
  final ActionItem item;
  final ValueChanged<bool> onToggle;
  const _TodoRow({required this.item, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => onToggle(!item.completed),
            child: item.completed
                ? const Icon(Icons.check_circle_rounded, size: 18, color: JXB.brandPrimary)
                : Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(color: JXB.brandPrimary, shape: BoxShape.circle)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.description,
              style: TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 14,
                color: item.completed ? JXB.textPlaceholder : JXB.textPrimary,
                decoration: item.completed ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
              item.completed
                  ? revampText(context, en: 'Done', zh: '已完成')
                  : revampText(context, en: 'Added to to-dos', zh: '已加入待办'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 11, color: JXB.textPlaceholder)),
        ],
      ),
    );
  }
}

class _ViewTranscriptRow extends StatelessWidget {
  final int minutes;
  final VoidCallback onTap;
  const _ViewTranscriptRow({super.key, required this.minutes, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: Text(revampText(context, en: 'View full transcript · $minutes min', zh: '查看完整原文 · $minutes 分钟转写'),
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, size: 16, color: JXB.textPlaceholder),
          ],
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PrimaryButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: JXB.brandSecondary, borderRadius: BorderRadius.circular(99.32)),
        child: Text(label,
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white)),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SecondaryButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF2F3F3),
          borderRadius: BorderRadius.circular(99.32),
          border: Border.all(color: JXB.border, width: 1),
        ),
        child: Text(label,
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
      ),
    );
  }
}
