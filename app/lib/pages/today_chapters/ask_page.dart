import 'dart:async';
import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/http/api/messages.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:memorion/pages/today_chapters/chapter_ask_context.dart';
import 'package:memorion/providers/chapter_ask_controller.dart';
import 'package:memorion/pages/today_chapters/widgets/jxb_gradient_background.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/message_provider.dart';
import 'package:memorion/services/press_to_talk_service.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// P-20 Ask·记忆检索（记小宝 1.0 浅色改版，Figma v2.4 node 343:18052 / 343:18357）。
///
/// ✅ 全部真数据（无 mock）：复用 `MessageProvider`（v2 流式 chat）。
/// - 发消息：`sendMessageStreamToServer`（SSE 流）
/// - 历史：`refreshMessages`（空历史后端自动回欢迎语）
/// - 清空对话：`clearChat`（More 菜单）
/// - 引用记忆卡：`ServerMessage.memories`（点「查看详情」→ 章节详情）
///
/// 建议问题为前端固定文案（同旧 chat 页，后端不下发）。
class AskPage extends StatefulWidget {
  const AskPage(
      {super.key, this.chapterContext, this.cardProgress, this.chapterController, this.controllerFactory, this.mic});
  final ChapterAskContext? chapterContext;

  /// 从章节详情进入时上下文卡的升起进度（由章节详情的转场路由驱动）；null 表示已经落位。
  final Animation<double>? cardProgress;
  final ChapterAskController? chapterController;
  final ChapterAskController Function()? controllerFactory;

  /// 语音输入的麦克风；测试注入，生产走 [ServiceManager]。
  final IMicRecorderService? mic;

  @override
  State<AskPage> createState() => _AskPageState();
}

class _AskPageState extends State<AskPage> with WidgetsBindingObserver {
  final TextEditingController _inputCtl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();
  final FocusNode _focus = FocusNode();
  ChapterAskController? _linked;
  MessageProvider? _shared;
  bool _scrollQueued = false;
  int _scrollGeneration = 0;
  // 上下文卡落位之前不显示消息、不接受输入（转场设计），落位后再跟到最新回复。
  bool _cardLanded = true;
  bool get _scoped => widget.chapterContext != null;
  IMicRecorderService get _mic => widget.mic ?? ServiceManager.instance().mic;

  String get _opening =>
      revampText(context, en: 'Help me recap this conversation and its important decisions.', zh: '帮我回顾一下这段对话和重要决定。');

  Future<void> _initializeLinked() => _linked!
      .initialize(title: widget.chapterContext!.title, ids: widget.chapterContext!.conversationIds, opening: _opening);

  void _linkedChanged() {
    if (!mounted) return;
    final follow = !_scrollCtl.hasClients || _scrollCtl.position.maxScrollExtent - _scrollCtl.offset < 100;
    setState(() {});
    if (follow) _scrollToLatest();
  }

  void _sharedChanged() {
    if (!mounted) return;
    if (!_scrollCtl.hasClients || _scrollCtl.position.extentAfter < 100) {
      _scrollToLatest();
    }
  }

  void _scrollToLatest() {
    if (_scrollQueued || !_cardLanded) return;
    _scrollQueued = true;
    final generation = ++_scrollGeneration;
    void follow(Duration _) {
      if (!mounted || generation != _scrollGeneration) return;
      if (!_scrollCtl.hasClients) {
        _scrollQueued = false;
        return;
      }
      final position = _scrollCtl.position;
      if (position.extentAfter <= 1) {
        _scrollQueued = false;
        return;
      }
      position.jumpTo(position.maxScrollExtent);
      // Lazy rows can change the estimated extent after a jump. Recheck after
      // layout so a long reply is fully visible, including its final paragraph.
      WidgetsBinding.instance.addPostFrameCallback(follow);
      WidgetsBinding.instance.scheduleFrame();
    }

    WidgetsBinding.instance.addPostFrameCallback(follow);
  }

  List<String> _suggestions(BuildContext context) => [
        revampText(context, en: 'What\'s on my schedule next week?', zh: '下周我有什么安排？'),
        revampText(context, en: 'Who did I talk to about project X last week?', zh: '上周我和谁聊了 X 项目？'),
        revampText(context, en: 'What did I promise but haven\'t done yet?', zh: '我答应过什么还没做？'),
      ];

  // ── Push-to-talk 语音输入（复用 PressToTalkService + 本地麦克风）──
  bool _isRecording = false;
  bool _pttTransitioning = false;
  PressToTalkService? _pttService;
  bool _listeningToPtt = false;
  String _pttBaseText = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cardLanded = (widget.cardProgress?.value ?? 1) >= 1;
    widget.cardProgress?.addListener(_cardMoved);
    if (_scoped) {
      _linked = widget.chapterController ??
          widget.controllerFactory?.call() ??
          ChapterAskController(context.read<MessageProvider>());
      _linked!.addListener(_linkedChanged);
    } else {
      _shared = context.read<MessageProvider>();
      _shared!.addListener(_sharedChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scoped) {
        _initializeLinked().then((_) => _scrollToLatest());
        return;
      }
      final mp = context.read<MessageProvider>();
      mp.ensureSharedHistory().then((_) => _scrollToLatest()).catchError((Object _) {
        if (!mounted) return;
        UndoDeleteHost.showMessage(context, revampText(context, en: 'Could not load chat history. Please try again.', zh: '未能加载聊天记录，请重试。'));
      });
    });
  }

  @override
  void didUpdateWidget(covariant AskPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cardProgress != widget.cardProgress) {
      oldWidget.cardProgress?.removeListener(_cardMoved);
      widget.cardProgress?.addListener(_cardMoved);
      _cardMoved();
    }
  }

  void _cardMoved() {
    final landed = (widget.cardProgress?.value ?? 1) >= 1;
    if (!mounted || landed == _cardLanded) return;
    setState(() => _cardLanded = landed);
    if (landed) _scrollToLatest();
  }

  // App 不在前台时不再收音：停下语音输入，已识别的文字留在输入框里当草稿。
  // 只看 hidden/paused——拉下控制中心、来电浮层只是 inactive，页面仍在眼前。
  bool get _appInForeground => switch (WidgetsBinding.instance.lifecycleState) {
        null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
        _ => false,
      };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 正在启动或收尾时由 _startRecording / _stopRecording 自己收口。
    if (!_appInForeground && _isRecording && !_pttTransitioning) _stopRecording();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.cardProgress?.removeListener(_cardMoved);
    _shared?.removeListener(_sharedChanged);
    _linked?.removeListener(_linkedChanged);
    _linked?.dispose();
    if (_isRecording) _mic.stop();
    if (_pttService != null && _pttService!.state != PttSessionState.idle) {
      _pttService!.cancelSession();
    }
    _detachPttListener();
    _pttService = null;
    _inputCtl.dispose();
    _scrollCtl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ── PTT：监听实时 partial → 回填输入框 ──────────────────────
  void _attachPttListener(PressToTalkService s) {
    if (_listeningToPtt) return;
    s.addListener(_onPttChanged);
    _listeningToPtt = true;
  }

  void _detachPttListener() {
    if (!_listeningToPtt) return;
    _pttService?.removeListener(_onPttChanged);
    _listeningToPtt = false;
  }

  String _composeVoiceText(String transcript) {
    final t = transcript.trim();
    if (t.isEmpty) return _pttBaseText;
    if (_pttBaseText.isEmpty) return t;
    return '$_pttBaseText $t';
  }

  void _setInputText(String text) {
    _inputCtl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _onPttChanged() {
    if (!_isRecording || !mounted) return;
    final partial = _pttService?.partialText.trim() ?? '';
    if (partial.isEmpty) return;
    _setInputText(_composeVoiceText(partial));
  }

  Future<void> _toggleRecording() async {
    if (_scoped && (!_cardLanded || !_linked!.linked || _linked!.linking)) return;
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    if (_pttTransitioning || _isRecording) return;
    _pttTransitioning = true;

    _pttService = context.read<PressToTalkService>();
    final ptt = _pttService!;
    _pttBaseText = _inputCtl.text.trimRight();

    if (ptt.state != PttSessionState.idle) {
      _pttTransitioning = false;
      return;
    }

    // 麦克风权限：直接 request()——iOS 首次未决定必弹系统授权窗；
    // 若之前已被拒绝，request() 会立即返回（不再弹窗），此时引导去系统设置。
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _pttTransitioning = false;
      if (mounted) _showMicSettingsDialog();
      return;
    }

    HapticFeedback.mediumImpact();
    ptt.prepareSession(showOverlay: false);
    _attachPttListener(ptt);
    if (mounted) setState(() => _isRecording = true);
    _focus.unfocus();

    try {
      await _mic.start(onByteReceived: (bytes) {
        if (_isRecording && mounted) ptt.sendAudio(bytes.toList());
      });
    } catch (e) {
      ptt.cancelSession();
      if (mounted) setState(() => _isRecording = false);
      _detachPttListener();
      _pttTransitioning = false;
      return;
    }

    final ok = await ptt.startSession(language: 'zh', sampleRate: 16000, codec: 'pcm16', showOverlay: false);
    if (!ok && mounted) {
      _mic.stop();
      setState(() => _isRecording = false);
      _detachPttListener();
      UndoDeleteHost.showMessage(context, revampText(context, en: 'Voice transcription connection failed, please retry', zh: '语音转写连接失败，请重试'));
    }
    _pttTransitioning = false;
    // 启动途中（等权限、建连）App 被切走了：启动一完成就停下。
    if (_isRecording && !_appInForeground) await _stopRecording();
  }

  Future<void> _stopRecording() async {
    if (_pttTransitioning || !_isRecording) return;
    _pttTransitioning = true;

    final ptt = _pttService;
    if (ptt == null) {
      _pttTransitioning = false;
      return;
    }

    HapticFeedback.lightImpact();
    _mic.stop();

    if (!ptt.hasAudioData) {
      ptt.cancelSession();
      if (mounted) setState(() => _isRecording = false);
      _detachPttListener();
      _pttTransitioning = false;
      return;
    }

    if (mounted) setState(() => _isRecording = false);
    _detachPttListener();

    // 只回填草稿，不自动发送。
    final text = await ptt.endSession();
    if (mounted && text != null && text.isNotEmpty) {
      _setInputText(_composeVoiceText(text));
    }
    _pttTransitioning = false;
  }

  // 麦克风权限被拒 → 浅色引导弹框跳系统设置。
  Future<void> _showMicSettingsDialog() async {
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
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: Color(0x14007AFF), shape: BoxShape.circle),
                child: const Icon(Icons.mic_rounded, size: 28, color: JXB.brandPrimary),
              ),
              const SizedBox(height: 16),
              Text(revampText(context, en: 'Microphone Access Needed', zh: '需要麦克风权限'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 8),
              Text(
                  revampText(context,
                      en: 'Voice input needs the microphone. Please enable it in system settings and try again.',
                      zh: '语音输入需要使用麦克风。请前往系统设置中开启后再试。'),
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, false),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration:
                            BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(context, en: 'Cancel', zh: '取消'),
                            style: const TextStyle(
                                fontFamily: JXB.fontSans,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: JXB.textPrimary)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, true),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(context, en: 'Open Settings', zh: '前往设置'),
                            style: const TextStyle(
                                fontFamily: JXB.fontSans,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
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
    if (ok == true) await openAppSettings();
  }

  void _send(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    if (_scoped) {
      if (!_cardLanded || !_linked!.linked || _linked!.sending || _linked!.linking) return;
      _inputCtl.clear();
      _focus.unfocus();
      _linked!.send(t);
      _scrollToLatest();
      return;
    }
    final mp = context.read<MessageProvider>();
    if (mp.sendingMessage || mp.isClearingChat) return;
    try {
      await mp.ensureSharedHistory();
    } catch (_) {
      return; // Keep the draft; loading errors are shown by the page initializer.
    }
    if (!mounted || mp.sendingMessage || mp.isClearingChat) return;
    _inputCtl.clear();
    _focus.unfocus();
    // 先本地插入用户气泡：后端 SSE 只回 AI 消息，不回本轮 human 消息，
    // 不插的话自己说的话要等下次 refreshMessages 才出现（本轮界面只有 AI 回复）。
    // 同 CaptureProvider BLE PTT 路径的做法。
    mp.addMessageLocally(t);
    mp.sendMessageStreamToServer(t, context: context);
    _scrollToLatest();
  }

  @override
  Widget build(BuildContext context) {
    if (_scoped) return _linkedPage();
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: true,
          body: JxbGradientBackground(
            // 点击空白处收起键盘。
            child: GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              behavior: HitTestBehavior.translucent,
              child: SafeArea(
                child: Column(
                  children: [
                    _detailBar(context),
                    Expanded(
                      child: Consumer<MessageProvider>(
                        builder: (context, mp, _) {
                          // 只有欢迎语（或空）→ 空状态引导页。
                          final realMsgs = mp.messages.where((m) => m.type != MessageType.daySummary).toList();
                          final onlyWelcome = realMsgs.where((m) => m.sender == MessageSender.human).isEmpty;
                          if (onlyWelcome && !mp.isLoadingMessages) {
                            return _emptyState();
                          }
                          return _chatList(mp);
                        },
                      ),
                    ),
                    _inputBar(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── DetailBar ─────────────────────────────────────────────
  Widget _detailBar(BuildContext context) {
    return SizedBox(
      height: 68,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _circleBtn(Icons.chevron_left_rounded, () => Navigator.of(context).maybePop()),
            Expanded(
              child: Text(revampText(context, en: 'Ask', zh: '回想'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: JXB.textSecondary)),
            ),
            _circleBtn(Icons.more_horiz_rounded, () => _showMoreMenu(context)),
          ],
        ),
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.5), shape: BoxShape.circle),
        child: Icon(icon, size: 24, color: JXB.textPrimary),
      ),
    );
  }

  Widget _designIcon(String name, double width, double height) =>
      SvgPicture.asset('assets/images/continue_chat/$name.svg', width: width, height: height);

  Widget _linkedPage() {
    final linked = _linked!;
    final ready = _cardLanded;
    final scope = widget.chapterContext!;
    return Theme(
      data: ThemeData.light(useMaterial3: false)
          .copyWith(colorScheme: const ColorScheme.light(primary: JXB.brandSecondary)),
      child: DefaultTextStyle(
          style: JXB.body,
          child: Scaffold(
            backgroundColor: const Color(0xFFF9FAFA),
            resizeToAvoidBottomInset: true,
            body: Stack(children: [
              const Positioned.fill(
                  child: Opacity(opacity: .26, child: JxbGradientBackground(child: SizedBox.expand()))),
              SafeArea(
                  child: Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Column(children: [
                        SizedBox(
                            height: 54,
                            child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14),
                                child: Row(children: [
                                  Semantics(
                                      button: true,
                                      label: revampText(context, en: 'Back to chapter', zh: '返回章节详情'),
                                      child: GestureDetector(
                                          key: const Key('back-to-chapter'),
                                          onTap: () => Navigator.of(context).maybePop(),
                                          child: SizedBox(
                                              width: 44,
                                              height: 44,
                                              child: Stack(alignment: Alignment.center, children: [
                                                _designIcon('imgGroup1940699513', 40.8858, 40.8859),
                                                Transform.rotate(
                                                    angle: 3.141592653589793,
                                                    child: _designIcon('imgChevronRight2', 20.4429, 20.4429)),
                                              ])))),
                                  const Expanded(
                                      child: Text('Ask',
                                          textAlign: TextAlign.center, // i18n-ignore: product page name
                                          style: TextStyle(
                                              fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF323333)))),
                                  Semantics(
                                      button: true,
                                      label: revampText(context, en: 'Clear all chats', zh: '清空全部对话'),
                                      child: GestureDetector(
                                          key: const Key('clear-chapter-chat'),
                                          onTap: _confirmClear,
                                          child: SizedBox(
                                              width: 44,
                                              height: 44,
                                              child: Stack(alignment: Alignment.center, children: [
                                                _designIcon('imgRectangle346241889', 42, 42),
                                                _designIcon('imgIconTrash', 32, 32),
                                              ])))),
                                ]))),
                        Expanded(child: LayoutBuilder(builder: (context, box) {
                          return _chatList(linked.sharedMessages,
                              showMessages: ready,
                              header: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: AnimatedBuilder(
                                      animation: widget.cardProgress ?? kAlwaysCompleteAnimation,
                                      builder: (context, card) {
                                        final progress = widget.cardProgress?.value ?? 1;
                                        // Same flight path and gentle overshoot as the SwiftUI delivery.
                                        final flight = MediaQuery.disableAnimationsOf(context)
                                            ? 1.0
                                            : Curves.easeOutBack.transform(progress);
                                        return Transform.translate(
                                            offset: Offset(
                                                0,
                                                MediaQuery.disableAnimationsOf(context)
                                                    ? 0
                                                    : (box.maxHeight - 110).clamp(0.0, double.infinity) * (1 - flight)),
                                            child: Transform.scale(
                                                scale: MediaQuery.disableAnimationsOf(context) ? 1 : .88 + .12 * flight,
                                                alignment: Alignment.bottomRight,
                                                child: Opacity(opacity: .75 + .25 * progress, child: card)));
                                      },
                                      child: Container(
                                          key: const Key('chapter-context-card'),
                                          width: 226,
                                          constraints: const BoxConstraints(minHeight: 96),
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                          decoration: const BoxDecoration(
                                              color: Color(0xFFDFEDFF),
                                              borderRadius: BorderRadius.only(
                                                  topLeft: Radius.circular(16),
                                                  topRight: Radius.circular(16),
                                                  bottomLeft: Radius.circular(16))),
                                          child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                    revampText(context,
                                                        en: 'Chat about this conversation',
                                                        zh: '聊聊这次对话'), // i18n-ignore: revampText supplies both locales
                                                    style: const TextStyle(
                                                        fontSize: 12, height: 1.5, color: Color(0xFF5896DF))),
                                                const SizedBox(height: 8),
                                                Text(scope.title,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontSize: 14,
                                                        height: 22 / 14,
                                                        fontWeight: FontWeight.w500,
                                                        color: Color(0xFF292D35))),
                                                const SizedBox(height: 4),
                                                Text(scope.subtitle,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontSize: 12, height: 1.5, color: Color(0xFF9AA8BC))),
                                              ]))),
                                ),
                                if (ready) ...[
                                  const SizedBox(height: 20),
                                  SizedBox(
                                      height: 30,
                                      child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                              linked.linked
                                                  ? revampText(context,
                                                      en: 'This conversation is linked',
                                                      zh: '已关联这次对话') // i18n-ignore: revampText supplies both locales
                                                  : revampText(context,
                                                      en: linked.failed ? 'Link failed' : 'Linking this conversation…',
                                                      zh: linked.failed ? '关联失败' : '正在关联这次对话…'),
                                              key: const Key('chapter-link-status'),
                                              style: const TextStyle(fontSize: 11, color: Color(0xFF99A8BA))))),
                                  const SizedBox(height: 12),
                                ],
                              ]),
                              footer: ready
                                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      if (linked.failed)
                                        Padding(
                                            padding: const EdgeInsets.symmetric(vertical: 12),
                                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                              Text(
                                                  linked.clearFailed
                                                      ? revampText(context,
                                                          en: 'Could not clear this chat. Please retry.',
                                                          zh: '未能清空聊天记录，请重试。')
                                                      : linked.linked
                                                          ? revampText(context,
                                                              en: 'Reply failed. Your conversation is still linked.',
                                                              zh: '回复失败，当前对话仍保持关联。')
                                                          : revampText(context,
                                                              en: 'Could not link this conversation. Please retry.',
                                                              zh: '未能关联这次对话，请重试。'),
                                                  style: const TextStyle(fontSize: 14, color: JXB.textSecondary)),
                                              TextButton(
                                                  key:
                                                      const Key('retry-chapter-chat'), // i18n-ignore: widget identifier
                                                  onPressed: () {
                                                    if (linked.clearFailed) {
                                                      linked.clear(
                                                          title: scope.title,
                                                          ids: scope.conversationIds,
                                                          opening: _opening);
                                                    } else if (linked.linked)
                                                      linked.retry();
                                                    else
                                                      _initializeLinked();
                                                  },
                                                  child: Text(revampText(context, en: 'Retry', zh: '重试'))),
                                            ])),
                                    ])
                                  : null);
                        })),
                        Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Column(children: [
                              Container(
                                  key: const Key('chapter-context-strip'),
                                  height: 26,
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  decoration: BoxDecoration(
                                      color: const Color(0xFFEFF4FC), borderRadius: BorderRadius.circular(13)),
                                  child: Row(children: [
                                    const Text('•', style: TextStyle(fontSize: 11, color: JXB.brandSecondary)),
                                    const SizedBox(width: 6),
                                    Expanded(
                                        child: Text(
                                            linked.linked
                                                ? revampText(context,
                                                    en: 'Chatting about: ${scope.title}', zh: '正在聊：${scope.title}')
                                                : revampText(context,
                                                    en: 'Waiting to link this conversation',
                                                    zh: '等待关联这次对话'), // i18n-ignore: revampText supplies both locales
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 11, color: Color(0xFF8294AD)))),
                                  ])),
                              _inputBar(),
                            ])),
                      ]))),
            ]),
          )),
    );
  }

  // ── More 菜单：清空对话 ─────────────────────────────────────
  void _showMoreMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16)),
                child: _menuItem(revampText(context, en: 'Clear Conversation', zh: '清空对话'), danger: true, onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _confirmClear();
                }),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16)),
                child:
                    _menuItem(revampText(context, en: 'Cancel', zh: '取消'), onTap: () => Navigator.of(sheetCtx).pop()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuItem(String label, {required VoidCallback onTap, bool danger = false}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 56,
        alignment: Alignment.center,
        child: Text(label,
            style: TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 16,
                fontWeight: danger ? FontWeight.w600 : FontWeight.w400,
                color: danger ? JXB.error : JXB.textPrimary)),
      ),
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JXB.surface,
        title: Text(revampText(context, en: 'Clear Conversation', zh: '清空对话'),
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
        content: Text(
            revampText(context,
                en: 'Clear all your conversations with Memorion? This cannot be undone.',
                zh: '确定清空和记小宝的全部对话吗？此操作无法撤销。'),
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(revampText(context, en: 'Cancel', zh: '取消'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(revampText(context, en: 'Clear', zh: '清空'), style: const TextStyle(color: JXB.error))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_scoped) {
      await _linked!
          .clear(title: widget.chapterContext!.title, ids: widget.chapterContext!.conversationIds, opening: _opening);
      return;
    }
    try {
      await context.read<MessageProvider>().clearChat();
    } catch (_) {
      if (!mounted) return;
      UndoDeleteHost.showMessage(context, revampText(context, en: 'Could not clear chat history. Please try again.', zh: '未能清空聊天记录，请重试。'));
    }
  }

  // ── 空状态 ────────────────────────────────────────────────
  Widget _emptyState() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
      children: [
        // 大标题（左蓝竖条）
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                  width: 3.6,
                  decoration: BoxDecoration(color: JXB.brandSecondary, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 8),
              Text(
                  revampText(context,
                      en: 'I remember everything you\'ve said.\nAsk me here.',
                      zh: '我记得你说过的一切。\n在这里问我。'), // i18n-ignore: revampText supplies both locales
                  style: const TextStyle(
                      fontFamily: JXB.fontSans,
                      fontSize: 20,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF202736))),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
            revampText(context,
                en: 'You don\'t have to remember the day — just ask, and I\'ll help you recall.',
                zh: '你不必记得是哪天——只要问，我帮你想起来。'),
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
        const SizedBox(height: 16),
        for (final q in _suggestions(context)) ...[
          _suggestionCard(q),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _suggestionCard(String q) {
    return GestureDetector(
      onTap: () => _send(q),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16)),
        child: Row(
          children: [
            Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(color: JXB.brandSecondary, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(q, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: Color(0xFF323333))),
            ),
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0x14007AFF), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.arrow_forward_rounded, size: 14, color: JXB.brandSecondary),
            ),
          ],
        ),
      ),
    );
  }

  // ── 对话列表 ──────────────────────────────────────────────
  Widget _chatList(MessageProvider mp, {Widget? header, Widget? footer, bool showMessages = true}) {
    final msgs = showMessages ? mp.messages : <ServerMessage>[]; // 倒序，最新在 index 0
    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 && notification.direction != ScrollDirection.idle) {
          ++_scrollGeneration;
          _scrollQueued = false;
        }
        return false;
      },
      child: ListView.builder(
        controller: _scrollCtl,
        key: const Key('ask-history'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(16, header == null ? 16 : 12, 16, 16),
        itemCount: msgs.length + (header == null ? 0 : 1) + (footer == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (header != null && index == 0) return header;
          final messageIndex = index - (header == null ? 0 : 1);
          if (messageIndex == msgs.length) return footer;
          final i = msgs.length - 1 - messageIndex;
          final m = msgs[i];
          final bubble = m.sender == MessageSender.human
              ? _userBubble(m.text)
              : _aiMessage(m, showActions: i == 0 && !mp.sendingMessage);
          // 按时间从上到下展示，时间戳显示在该条消息上方。
          // 规则同旧壳：最老消息 / 间隔≥5分钟 / 跨天 时才显示，避免每条都显示。
          if (_shouldShowTimestamp(msgs, i)) {
            return Column(
              children: [
                _timestampLabel(m.createdAt),
                bubble,
              ],
            );
          }
          return bubble;
        },
      ),
    );
  }

  bool _shouldShowTimestamp(List<ServerMessage> msgs, int i) {
    // Provider 中 i 越大越旧。最老一条（i == length-1）总显示。
    if (i == msgs.length - 1) return true;
    final current = msgs[i].createdAt;
    final older = msgs[i + 1].createdAt;
    if (current.day != older.day || current.month != older.month || current.year != older.year) {
      return true;
    }
    if (current.difference(older).inMinutes.abs() >= 5) return true;
    return false;
  }

  Widget _timestampLabel(DateTime time) {
    final now = DateTime.now();
    final isToday = time.year == now.year && time.month == now.month && time.day == now.day;
    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday = time.year == yesterday.year && time.month == yesterday.month && time.day == yesterday.day;
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final label = isToday
        ? timeStr
        : isYesterday
            ? revampText(context, en: 'Yesterday $timeStr', zh: '昨天 $timeStr')
            : revampText(context, en: '${time.month}/${time.day} $timeStr', zh: '${time.month}月${time.day}日 $timeStr');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Center(
        child: Text(label, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
      ),
    );
  }

  Widget _userBubble(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                color: Color(0xFFDCECFF),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(2),
                ),
              ),
              child: Text(text,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.4, color: JXB.textPrimary)),
            ),
          ),
        ],
      ),
    );
  }

  /// AI 回复走 markdown 渲染（后端答复含 **加粗**/### 标题/- 列表/[来源](url)，
  /// 旧代码用纯 Text 导致原文显示）。样式对齐原 Text：PingFang SC / 14 / 行高 1.6。
  Widget _markdownBody(String data) {
    const base = TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.6, color: JXB.textPrimary);
    return MarkdownBody(
      data: data,
      selectable: true,
      onTapLink: (text, href, title) {
        if (href == null) return;
        launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
      },
      styleSheet: MarkdownStyleSheet(
        p: base,
        a: base.copyWith(color: JXB.brandPrimary, decoration: TextDecoration.underline),
        strong: base.copyWith(fontWeight: FontWeight.w700),
        em: base.copyWith(fontStyle: FontStyle.italic),
        listBullet: base,
        h1: base.copyWith(fontSize: 18, fontWeight: FontWeight.w700, height: 1.4),
        h2: base.copyWith(fontSize: 16, fontWeight: FontWeight.w700, height: 1.4),
        h3: base.copyWith(fontSize: 15, fontWeight: FontWeight.w700, height: 1.4),
        code: base.copyWith(
          fontFamily: 'monospace',
          backgroundColor: JXB.textSecondary.withValues(alpha: 0.12),
        ),
        blockquote: base.copyWith(color: JXB.textSecondary),
        // MarkdownBody 自身外边距归零，间距由父 Column 控制。
        pPadding: EdgeInsets.zero,
      ),
    );
  }

  Widget _aiMessage(ServerMessage m, {required bool showActions}) {
    final text = m.text.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (text.isEmpty && m.memories.isEmpty)
            // 流式起步、还没有内容 → 打字指示
            const _TypingDots()
          else
            _markdownBody(text.isEmpty ? '…' : text),
          // 引用记忆卡
          for (final mem in m.memories) ...[
            const SizedBox(height: 8),
            _QuoteCard(memory: mem),
          ],
          // 回复下方：重新生成 / 复制
          if (showActions && text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                _actionIcon(Icons.outlined_flag, () => _reportMessage(m)),
                const SizedBox(width: 4),
                _actionIcon(Icons.content_copy_rounded, () {
                  Clipboard.setData(ClipboardData(text: text));
                  UndoDeleteHost.showMessage(context, revampText(context, en: 'Copied', zh: '已复制'));
                }),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionIcon(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        child: Icon(icon, size: 17, color: JXB.textSecondary),
      ),
    );
  }

  // 举报回复：确认后本地移除并上报后端。
  Future<void> _reportMessage(ServerMessage m) async {
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
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: Color(0x14E55247), shape: BoxShape.circle),
                child: const Icon(Icons.outlined_flag, size: 28, color: JXB.error),
              ),
              const SizedBox(height: 16),
              Text(revampText(context, en: 'Report this reply?', zh: '举报这条回复？'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 8),
              Text(revampText(context, en: 'This reply will be removed and reported for review.', zh: '这条回复将被移除并上报审核。'),
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, false),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration:
                            BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(context, en: 'Cancel', zh: '取消'),
                            style: const TextStyle(
                                fontFamily: JXB.fontSans,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: JXB.textPrimary)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, true),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: JXB.error, borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(context, en: 'Report', zh: '举报'),
                            style: const TextStyle(
                                fontFamily: JXB.fontSans,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
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
    if (ok != true || !mounted) return;
    if (_scoped)
      _linked!.removeMessage(m.id);
    else
      context.read<MessageProvider>().removeLocalMessage(m.id);
    reportMessageServer(m.id);
    if (!mounted) return;
    UndoDeleteHost.showMessage(context, revampText(context, en: 'Reported, thanks for the feedback', zh: '已举报，感谢反馈'));
  }

  // ── 输入框（贴底；右侧单按钮：无输入=灰麦克风，有输入=深色发送箭头）──
  Widget _inputBar() {
    return Padding(
      padding: _scoped ? const EdgeInsets.only(top: 10, bottom: 2) : const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        key: _scoped ? const Key('chapter-composer') : null,
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.only(left: 14, right: 6),
        decoration: BoxDecoration(
          color: _scoped ? const Color(0xFFEFF1F3) : JXB.surface,
          borderRadius: BorderRadius.circular(24),
          border: _scoped ? null : Border.all(color: const Color(0x6668ACFF), width: 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtl,
                focusNode: _focus,
                key: const Key('ask-input'),
                enabled: !_scoped || (_cardLanded && _linked!.linked && !_linked!.linking),
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  border: InputBorder.none,
                  hintText: revampText(context, en: 'Ask me…', zh: '问问我…'),
                  hintStyle: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textPlaceholder),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // 单按钮：随输入内容切换麦克风↔发送。
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _inputCtl,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                if (hasText) {
                  return GestureDetector(
                    onTap: () => _send(_inputCtl.text),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: Color(0xFF25282D), shape: BoxShape.circle),
                      child: const Icon(Icons.arrow_upward_rounded, size: 18, color: Colors.white),
                    ),
                  );
                }
                // 无输入：麦克风 push-to-talk（点击开始录音/再点结束，实时转写回填）
                return GestureDetector(
                  onTap: _toggleRecording,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: _isRecording ? const BoxDecoration(color: JXB.error, shape: BoxShape.circle) : null,
                    child: _scoped && !_isRecording
                        ? Stack(alignment: Alignment.topCenter, children: [
                            Positioned(
                                top: 4,
                                child: Container(
                                    width: 10.154,
                                    height: 13.846,
                                    decoration: BoxDecoration(
                                        border: Border.all(color: const Color(0xFF323333), width: 2),
                                        borderRadius: BorderRadius.circular(10)))),
                            Positioned(top: 12, child: _designIcon('imgVectorIconPath', 17.6923, 13.0769)),
                          ])
                        : Icon(_isRecording ? Icons.stop_rounded : Icons.mic_none_rounded,
                            size: _isRecording ? 18 : 20, color: _isRecording ? Colors.white : JXB.textPlaceholder),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 引用记忆卡：「引用自这段记忆」+ 竖条 + 会话标题 + 日期 + 查看详情。
class _QuoteCard extends StatefulWidget {
  final MessageConversation memory;
  const _QuoteCard({required this.memory});

  @override
  State<_QuoteCard> createState() => _QuoteCardState();
}

class _QuoteCardState extends State<_QuoteCard> {
  static const List<String> _weekdaysZh = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static const List<String> _weekdaysEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  bool _loading = false;

  MessageConversation get memory => widget.memory;

  @override
  Widget build(BuildContext context) {
    final d = memory.createdAt;
    final dateLabel = revampText(context,
        en: '${d.month}/${d.day} · ${_weekdaysEn[d.weekday - 1]}',
        zh: '${d.month}月${d.day}日 · ${_weekdaysZh[d.weekday - 1]}');
    // 设计稿 v2.4：无「引用自这段记忆」标题头，卡片矮化。
    // 结构：[蓝竖条 + 会话标题] + [日期·周几 左 ｜ 详情> 右]。
    // 整张卡可点（热区更大），而非只有「详情」小文字。
    return GestureDetector(
      onTap: _loading ? null : () => _openConversation(context),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                      width: 3,
                      decoration: BoxDecoration(color: JXB.brandSecondary, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        '${memory.structured.emoji.isNotEmpty ? '${memory.structured.emoji} ' : ''}${memory.structured.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontFamily: JXB.fontSans,
                            fontSize: 15,
                            height: 1.35,
                            fontWeight: FontWeight.w500,
                            color: JXB.textPrimary)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(dateLabel,
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
                ),
                _loading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, valueColor: AlwaysStoppedAnimation(JXB.brandSecondary)),
                      )
                    : Row(
                        children: [
                          Text(revampText(context, en: 'Details', zh: '详情'),
                              style: const TextStyle(
                                  fontFamily: JXB.fontSans,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: JXB.brandSecondary)),
                          const Icon(Icons.chevron_right_rounded, size: 15, color: JXB.brandSecondary),
                        ],
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openConversation(BuildContext context) async {
    // 先查已加载缓存（秒开）；命中不到才走网络，期间显示 loading 反馈。
    final provider = context.read<ConversationProvider>();
    ServerConversation? convo;
    for (final c in provider.conversations) {
      if (c.id == memory.id) {
        convo = c;
        break;
      }
    }
    if (convo == null) {
      setState(() => _loading = true);
      convo = await getConversationById(memory.id);
      if (mounted) setState(() => _loading = false);
    }
    if (!context.mounted) return;
    if (convo != null) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChapterDetailPage(conversation: convo!)),
      );
    } else {
      UndoDeleteHost.showMessage(context, revampText(context, en: 'Failed to open, please retry', zh: '打开失败，请重试'));
    }
  }
}

/// AI 流式起步时的打字指示（三点）。
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          children: List.generate(3, (i) {
            final t = ((_c.value + i * 0.2) % 1.0);
            final opacity = 0.3 + 0.7 * (t < 0.5 ? t * 2 : (1 - t) * 2);
            return Padding(
              padding: const EdgeInsets.only(right: 5),
              child: Opacity(
                opacity: opacity,
                child: Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(color: JXB.textPlaceholder, shape: BoxShape.circle)),
              ),
            );
          }),
        );
      },
    );
  }
}
