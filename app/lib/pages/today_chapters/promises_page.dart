import 'package:memorion/backend/api_config.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/material.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/http/api/discover.dart';
import 'package:memorion/pages/today_chapters/widgets/due_hint.dart';
import 'package:memorion/pages/today_chapters/widgets/jxb_gradient_background.dart';
import 'package:memorion/pages/today_chapters/widgets/promise_row_content.dart';
import 'package:memorion/pages/today_chapters/widgets/swipe_action_row.dart';
import 'package:memorion/providers/discover_provider.dart';
import 'package:memorion/services/apple_reminders_service.dart';
import 'package:memorion/ui/atoms/memorion_skeleton.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// P-03 你答应过的事（记小宝 1.0 浅色改版，Figma v2.4 node 1069:2477）。
///
/// ✅ 真数据：`getActionItems()`（discover.dart，跨会话汇总 action_items），
/// 按会话标题分组；未完成/已完成两段。
///
/// 勾选落库走 `setConversationActionItemState`（PATCH 会话的 action-items），
/// 所以每条待办必须带着 `conversationId` + `itemIdx` —— 后端是按**下标**定位
/// 待办的，不是按描述文本。
/// 本页蓝色胶囊（左滑区的「加入提醒事项」、「已完成」右边的「清空」）的配色，取自设计稿
/// 的两个变量：`color/chat/user-bubble` = #DCECFF、`color/brand/secondary` = #54A4FD。
///
/// ⚠️ 底色不是 `JXB.brandTint`。brandTint 是 `0x1A007AFF`（品牌蓝 10% 透明），压在白卡
/// 上合成出来是 #E5F1FF，比设计稿浅一档。#DCECFF 目前在 app 里没有对应 token，是当
/// 字面量用的（`ask_page.dart` 的用户气泡同色）。
const Color _kPillBg = Color(0xFFDCECFF);
const Color _kPillFg = JXB.brandSecondary; // #54A4FD

/// 左滑区删除键的底色（设计稿量出来是 #FAE3E3）。同理不用 `JXB.errorTint`——那个是
/// 10% 不透明的 error，合成后 #FFEBEA 比设计稿浅，跟旁边实色的蓝胶囊并排会不成对。
const Color _kDeleteBg = Color(0xFFFAE3E3);

/// 左滑打开的那一行的底色（设计稿 #F2F2F7）。app 里没有这个 token：`JXB.bgApp` 是淡蓝的
/// #F6FAFF，那是页面底色，压在白卡上几乎看不出变化。
const Color _kRowOpenBg = Color(0xFFF2F2F7);

class PromisesPage extends StatefulWidget {
  const PromisesPage({super.key});

  @override
  State<PromisesPage> createState() => _PromisesPageState();
}

/// 一条待办在本页需要的字段：定位（会话 + 下标）+ 描述 + 截止信息 + 完成态。
///
/// `dueDate` 只在后端能确定到具体某天时才有值；`dueHint` 是人说的原话
/// （「本周内」「尽快」），二者都可能为空。
///
/// 用可变 class 而非 record：勾选是原地改 `completed`，列表不重新拉。
class _Promise {
  final String conversationId;
  final String conversationTitle;

  /// 后端定位下标。
  ///
  /// ⚠️ 不是 final：删一条待办后端做的是 `action_items.pop(idx)`，同会话内更大的
  /// 下标全部左移一位，本地这份也要跟着减（见 `_applyLocalDeletion`），否则接着
  /// 勾选/删除会静默打到隔壁那条上。
  int itemIdx;
  final String description;
  final DateTime? dueDate;
  final String dueHint;

  /// 这条待办所在对话发生的时刻（列表接口的 `created_at`）。
  /// `dueHint` 里的相对说法要以它为基准，不是以今天为基准。
  final DateTime? spokenAt;

  bool completed;

  _Promise({
    required this.conversationId,
    required this.conversationTitle,
    required this.itemIdx,
    required this.description,
    required this.dueDate,
    required this.dueHint,
    required this.spokenAt,
    required this.completed,
  });

  /// 后端定位键：同一条待办在两次拉取间靠这个认。
  String get key => '$conversationId#$itemIdx';

  /// 写进苹果提醒事项的到期时刻。见 [reminderDueAt]。
  DateTime? get reminderAt => reminderDueAt(dueDate: dueDate, dueHint: dueHint, spokenAt: spokenAt);
}

class _PromisesPageState extends State<PromisesPage> {
  bool _loading = true;

  /// 上一次拉取失败了没有。**空态必须靠它分岔**：「这次没拉到」和「真的没有答应过的
  /// 事」渲染成同一句话时，一次超时读起来就是一个结论。
  bool _loadFailed = false;

  /// 全量待办（未完成 + 已完成），分组在 build 时算，勾选只改本表里的 completed。
  final List<_Promise> _all = [];

  /// 本次会话内已加进提醒事项的待办描述（按钮变绿勾）。只是即时反馈，
  /// 不落库——真实来源始终是提醒事项本身，重进页面会重新按需判断。
  final Set<String> _addedToReminders = {};

  /// 正在写入提醒事项的那一条（转圈），null = 没有在写。
  String? _addingNow;

  /// 正在提交完成态的那几条（key），提交期间禁止再点，避免连点打乱顺序。
  final Set<String> _togglingKeys = {};

  /// 当前左滑展开的那一行（key），null = 都收着。**一次只开一行**：状态放页面这层
  /// 而不是每行自管，否则同时敞开好几行时用户没法一次收干净。
  String? _openRowKey;

  /// 正在删除的那几条（key）：行淡出、按钮不再响应，避免连点重复发 DELETE。
  final Set<String> _deletingKeys = {};

  /// 「清空已完成」正在跑（按钮转圈，期间不许再点）。
  bool _clearing = false;
  UndoDeleteController? _undoController;
  int _settledRevision = 0;
  int _loadRequest = 0;
  bool _indicesUntrusted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<UndoDeleteController?>();
    if (identical(controller, _undoController)) return;
    _undoController?.removeListener(_deletionSettled);
    _undoController = controller;
    _settledRevision = controller?.settledRevision(DeleteKind.promise) ?? 0;
    controller?.addListener(_deletionSettled);
  }

  void _deletionSettled() {
    final revision = _undoController?.settledRevision(DeleteKind.promise) ?? 0;
    if (!mounted || revision == _settledRevision) return;
    _settledRevision = revision;
    setState(() {
      _indicesUntrusted = true;
      _loading = true;
    });
    _load();
  }

  @override
  void dispose() {
    _undoController?.removeListener(_deletionSettled);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 返回这次拉取成功没有 —— gone 路径的重拉要靠它决定能不能覆盖本地列表。
  Future<bool> _load() async {
    final request = ++_loadRequest;
    final res = await getActionItems(status: 'all', limit: 100);
    if (!mounted || request != _loadRequest) return false;
    // ⚠️ 失败就保留现有列表。`_all.clear()` 之后填一份空的 items，等于把一次超时
    // 渲染成「你什么都没答应过」。
    //
    // ⚠️ 光保留列表只治了「已经有数据」那一半：**冷启动失败时 `_all` 本来就是空的**，
    // 不置 `_loadFailed` 的话空态照旧渲染「还没有答应过的事」，和真的没有待办不可
    // 分辨。这一页的空态就是这么长出来的（`_content()` 按它分岔）。
    if (res['ok'] == false) {
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      return false;
    }
    final untitled = revampText(context, en: 'Untitled conversation', zh: '未命名对话');
    final items = (res['items'] as List?) ?? [];
    _all.clear();
    for (final raw in items) {
      final m = raw as Map<String, dynamic>;
      final desc = (m['description'] ?? '').toString();
      if (desc.isEmpty) continue;
      final rawDue = m['due_date'];
      final rawCreated = m['created_at'];
      _all.add(_Promise(
        conversationId: (m['conversation_id'] ?? '').toString(),
        conversationTitle: (m['conversation_title'] ?? untitled).toString(),
        itemIdx: (m['item_idx'] as num?)?.toInt() ?? 0,
        description: desc,
        dueDate: rawDue == null ? null : DateTime.tryParse(rawDue.toString())?.toLocal(),
        dueHint: (m['due_hint'] ?? '').toString(),
        spokenAt: rawCreated == null ? null : DateTime.tryParse(rawCreated.toString())?.toLocal(),
        completed: m['completed'] == true,
      ));
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _loadFailed = false;
        _indicesUntrusted = false;
      });
    }
    return true;
  }

  List<_Promise> get _visible =>
      _all.where((p) => context.read<UndoDeleteController?>()?.hides('promise:${p.key}') != true).toList();
  bool get _undoBusy => _indicesUntrusted || context.read<UndoDeleteController?>()?.hasKind(DeleteKind.promise) == true;

  /// 未完成：按会话标题分组（保持服务端返回的先后次序）。
  Map<String, List<_Promise>> get _pendingByConv {
    final grouped = <String, List<_Promise>>{};
    for (final p in _visible.where((p) => !p.completed)) {
      grouped.putIfAbsent(p.conversationTitle, () => []).add(p);
    }
    return grouped;
  }

  List<_Promise> get _completed => _visible.where((p) => p.completed).toList();

  /// 勾选 / 取消勾选：先乐观改本地（立刻划线并移段），写失败再回滚 + 提示。
  Future<void> _toggleCompleted(_Promise p) async {
    if (_undoBusy || _clearing || _togglingKeys.contains(p.key)) return;
    if (p.conversationId.isEmpty) return;
    final failedMsg = revampText(context, en: "Couldn't update the to-do", zh: '更新待办失败');

    final next = !p.completed;
    setState(() {
      p.completed = next;
      _togglingKeys.add(p.key);
    });
    final ok = await setConversationActionItemState(p.conversationId, [p.itemIdx], [next]);
    if (!mounted) return;
    setState(() {
      _togglingKeys.remove(p.key);
      if (!ok) p.completed = !next;
    });
    if (!ok) {
      _toast(failedMsg);
      return;
    }
    // 「关于我」摘要卡读的是 DiscoverProvider 的缓存列表（本页自己 fetch），
    // 不同步一下会出现「这里划掉了、返回去还挂着」。
    if (!mounted) return;
    context.read<DiscoverProvider>().setActionItemCompleted(
          conversationId: p.conversationId,
          itemIdx: p.itemIdx,
          completed: next,
        );
  }

  /// Retain the original list during Undo; pop descending indices only after expiry.
  Future<void> _confirmAndDelete(_Promise p) async {
    final undo = context.read<UndoDeleteController>();
    if (_indicesUntrusted || _clearing || _togglingKeys.isNotEmpty || undo.committingKind(DeleteKind.promise) || p.conversationId.isEmpty)
      return;
    if (await _confirmDeleteOne(p) != true || !mounted) return;
    if (_indicesUntrusted || _clearing || _togglingKeys.isNotEmpty || undo.committingKind(DeleteKind.promise)) return;
    final discover = context.read<DiscoverProvider>();
    final owner = ApiConfig().externalUserId;
    final index = p.itemIdx;
    final description = p.description;
    final completed = p.completed;
    undo.add(UndoDeletion(
      key: 'promise:${p.key}',
      kind: DeleteKind.promise,
      title: description,
      order: index,
      commit: () async {
        // Other screens can change this array during the window. Never delete a
        // different item just because it now occupies the old numeric index.
        final conversation = await getConversationById(p.conversationId);
        if (owner != ApiConfig().externalUserId || conversation == null) return false;
        final items = conversation.structured.actionItems;
        if (index >= items.length ||
            items[index].description != description ||
            items[index].completed != completed ||
            items[index].dueDate != p.dueDate ||
            items[index].dueHint != p.dueHint) {
          if (mounted)
            await _resyncAfterStaleIndexes();
          else
            await discover.loadActionItems();
          return false;
        }
        final result = await rejectConversationActionItem(p.conversationId, index);
        if (owner != ApiConfig().externalUserId) return false;
        if (result == ActionItemMutation.gone) {
          if (mounted) {
            final refreshed = await _resyncAfterStaleIndexes();
            if (mounted) _toast(_staleIndexMessage(refreshed: refreshed, plural: false));
          } else {
            await discover.loadActionItems();
          }
          return false;
        }
        final ok = result == ActionItemMutation.ok;
        if (ok) {
          if (mounted && _all.contains(p)) {
            _applyLocalDeletion(p);
            setState(() {});
          }
          // This cache may have refreshed while DELETE was in flight. Reload it
          // from the server instead of shifting potentially newer indices again.
          await discover.loadActionItems();
        }
        return ok;
      },
    ));
  }

  /// 撞上 404 之后的收尾：本页和 DiscoverProvider **两份缓存都要重拉**。
  ///
  /// ⚠️ 只 `_load()` 不够。正常删除走的是 `_applyLocalDeletion`，它除了改本页数据，还
  /// 返回一个同步 `DiscoverProvider.removeActionItemAt` 的回调 —— 「关于我」摘要卡读的
  /// 是那一份。而 404 这条路绕开了 `_applyLocalDeletion`（它的下标左移前提不成立），
  /// 于是那份缓存既留着已经不存在的条目，又留着**旧的 item_idx**；后端按下标 pop，从
  /// 那张卡上再勾选/删除就会打到隔壁待办上，两次操作还都返回成功。
  ///
  /// `loadActionItems()` 整份覆盖 + 重写缓存，所以不需要逐条修正下标。
  ///
  /// ⚠️ 重拉自己也会失败（超时 / 5xx）。两个函数都尊重 `getActionItems` 的 `ok` 字段
  /// 而不是把空 items 当真，否则「点删除撞上 404、紧接着重拉超时」会把整页清空 ——
  /// 而 `loadActionItems` 还会把那份空响应落盘，假空态活到下次启动。
  ///
  /// **返回成功没有，自己不 toast** —— 提示由调用方拼成一句。两处各弹一句的话，一次
  /// 失败的重拉会先说「列表刷新了一下」再说「没刷新成功」，或者反过来（先失败提示、
  /// 最后一句反而宣称成功）。
  Future<bool> _resyncAfterStaleIndexes() async {
    final discover = context.read<DiscoverProvider>();
    // 两个都启动了再 await —— `Future.wait` 收不了 Future<bool> + Future<void> 的混合。
    final loading = _load();
    final discoverLoading = discover.loadActionItems();
    final refreshed = await loading;
    await discoverLoading;
    return refreshed;
  }

  /// 撞上 404 之后对用户说的那一句：本地下标已不可信，所以「刷没刷成功」必须说清楚。
  String _staleIndexMessage({required bool refreshed, required bool plural, int failed = 0}) {
    if (!refreshed) {
      return revampText(context, en: "Some of those were already gone, but the refresh didn't go through — pull down to retry.", zh: '有的已经不在了，但刷新没成功，下拉再试一次');
    }
    final tail = failed > 0
        ? revampText(context, en: ' $failed still failed.', zh: ' 另有 $failed 条没成功。')
        : '';
    return plural
        ? revampText(context, en: 'Some had already expired — refreshed the list.$tail', zh: '有几条已经失效了，列表刷新了一下。$tail')
        : revampText(context, en: 'That one was already gone — refreshed the list.$tail', zh: '这条已经不在了，列表刷新了一下。$tail');
  }

  /// 后端删成功之后同步本地：摘掉这条 + **同会话内更大的下标全部左移一位** +
  /// 同步 DiscoverProvider 的缓存（「关于我」摘要卡读的是那一份）。
  ///
  /// ⚠️ 左移不是可选项：后端 `delete_action_item` 是 `action_items.pop(idx)`
  /// （`database/developer_data.py`），删掉第 1 条后原来的第 2 条就成了第 1 条。
  /// 不修正的话下一次勾选/删除会打到隔壁那条待办上，而两次操作各自都返回成功
  /// ——错位只有等重新拉一遍列表才看得出来。
  ///
  /// 只改本页的数据（调用方负责 setState），返回一个「同步 DiscoverProvider」的回调
  /// —— 那一步会 `notifyListeners()`，放在 setState 的闭包里就是在一次重建里去标记
  /// 别的 widget 需要重建，所以留给调用方在 setState 之后再执行。
  VoidCallback _applyLocalDeletion(_Promise p) {
    final conversationId = p.conversationId;
    final itemIdx = p.itemIdx;
    _all.remove(p);
    for (final other in _all) {
      if (other.conversationId == conversationId && other.itemIdx > itemIdx) {
        other.itemIdx -= 1;
      }
    }
    if (_openRowKey == p.key) _openRowKey = null;
    return () => context.read<DiscoverProvider>().removeActionItemAt(
          conversationId: conversationId,
          itemIdx: itemIdx,
        );
  }

  /// 「清空」：把已完成的待办全删掉。
  ///
  /// ⚠️ **必须按下标降序删**，而且同一会话内必须串行。后端按下标 pop，先删小下标会
  /// 让同会话里所有更大的下标左移一位 —— 那之后每一次 DELETE 都会删错条目（比如把
  /// 一条还没做完的待办删掉）。降序删时被删的永远是当前最大的那个，剩下待删的下标
  /// 不受影响。
  ///
  /// 不同会话之间互不影响（各是一份 Firestore 文档），所以按会话并发、组内串行。
  Future<void> _clearCompleted() async {
    if (_clearing || _undoBusy || _togglingKeys.isNotEmpty) return;
    final targets = _completed;
    if (targets.isEmpty) return;
    if (await _confirmClearCompleted(targets.length) != true || !mounted) return;
    if (_undoBusy || _togglingKeys.isNotEmpty) return;

    setState(() {
      _clearing = true;
      _openRowKey = null;
    });

    final byConv = <String, List<_Promise>>{};
    for (final p in targets) {
      if (p.conversationId.isEmpty) continue;
      byConv.putIfAbsent(p.conversationId, () => []).add(p);
    }

    final deleted = <_Promise>[];
    var failed = 0;
    var sawStaleIndexes = false;
    await Future.wait(byConv.values.map((group) async {
      // 组内降序：先删下标大的那条。
      group.sort((a, b) => b.itemIdx.compareTo(a.itemIdx));
      for (int i = 0; i < group.length; i++) {
        final result = await rejectConversationActionItem(group[i].conversationId, group[i].itemIdx);
        if (result == ActionItemMutation.ok) {
          deleted.add(group[i]);
          continue;
        }
        if (result == ActionItemMutation.gone) {
          // 服务端这一条早就没了 ⇒ 本地这一组的下标全都对不上服务端了（同上：待办
          // 门禁会整条撤销）。不能计入 `deleted` —— `_applyLocalDeletion` 会按「后端
          // pop 过」左移下标，那只会让错位更深。整页重拉才是唯一可靠的收尾。
          sawStaleIndexes = true;
          return;
        }
        // 失败之后这一组就不再往下删了：失败可能是「超时但后端已经删了」，那样剩下
        // 的下标已经左移，照旧下标继续删就会砍到没做完的待办上。剩下的算失败，让用户
        // 重新拉一遍列表再清。
        failed += group.length - i;
        return;
      }
    }));

    if (!mounted) return;
    // 逐条走同一个收尾逻辑，让未完成待办的下标也跟着左移。
    //
    // ⚠️ **`sawStaleIndexes` 那一支也要先走这一步再重拉。** `deleted` 里是**真的删成
    // 功了**（204）的那些，后端已经 pop 过下标；跳过收尾就指望重拉兜住，可重拉自己会
    // 失败（这段代码自己就在处理那种情形）——那时本地还留着这些条目、且 itemIdx 比
    // 服务端大一位，用户对同会话里另一条左滑删除就会砍到隔壁那条，正是本函数注释开头
    // 要防的错删。重拉成功时这一步是多余的（整份覆盖），但多余无害。
    final syncs = <VoidCallback>[];
    setState(() {
      _clearing = false;
      for (final p in deleted) {
        syncs.add(_applyLocalDeletion(p));
      }
    });
    for (final s in syncs) {
      s();
    }

    if (sawStaleIndexes) {
      final refreshed = await _resyncAfterStaleIndexes();
      // `failed` 一起报出来：这一支原先直接 return，把真正的网络失败数悄悄丢了。
      if (mounted) _toast(_staleIndexMessage(refreshed: refreshed, plural: true, failed: failed));
      return;
    }
    if (failed > 0) {
      _toast(revampText(context, en: 'Cleared ${deleted.length}, $failed failed',
          zh: '已清空 ${deleted.length} 条，$failed 条失败'));
    }
  }

  Future<bool?> _confirmDeleteOne(_Promise p) {
    return _confirmDialog(
      title: revampText(context, en: 'Delete this to-do?', zh: '删掉这条待办？'),
      body: p.description,
      confirmLabel: revampText(context, en: 'Delete', zh: '删除'),
    );
  }

  Future<bool?> _confirmClearCompleted(int count) {
    return _confirmDialog(
      title: revampText(context, en: 'Clear completed?', zh: '清空已完成？'),
      body: revampText(context,
          en: '$count completed to-dos will be deleted for good.', zh: '$count 条已完成的待办会被永久删除。'),
      confirmLabel: revampText(context, en: 'Clear', zh: '清空'),
    );
  }

  /// 删除类确认弹窗（与「关于我·事实」页同款：白底、圆角 20、危险动作标红）。
  Future<bool?> _confirmDialog({
    required String title,
    required String body,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JXB.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title,
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
        content: Text(body,
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(revampText(ctx, en: 'Cancel', zh: '取消'),
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.error)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<UndoDeleteController?>();
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
                  Expanded(child: _body()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const MemorionSkeletonCards(count: 3, cardHeight: 132, withHeader: true);
    }
    // 下拉刷新是这一页唯一的重试手段 —— `_load()` 此前只有 initState 和 404 收尾两个
    // 调用点，拉取失败后用户除了退出重进没有任何办法，而失败提示偏偏写着「下拉再试」。
    return RefreshIndicator(
      onRefresh: () async {
        if (_undoController?.hasKind(DeleteKind.promise) == true) return;
        // ⚠️ 失败要说话。`_loadFailed` 只被空态读到，所以「已有数据 + 下拉失败」
        // 不提示就和「刷新成功、内容没变」完全一样 —— 又一个静默失败。
        final ok = await _load();
        if (!ok && mounted) {
          _toast(revampText(context, en: "Couldn't refresh — check your connection.", zh: '没刷新成功，检查一下网络吧'));
        }
      },
      child: _content(),
    );
  }

  Widget _content() {
    if (_visible.isEmpty) {
      // ⚠️ 空态要分得清「这次没拉到」和「真的没有答应过的事」，否则一次超时读起来就是
      // 一个结论。而且它必须待在**可滚**容器里，不然 RefreshIndicator 收不到手势
      // ——「空态点不动」在这个仓库里已经踩过一次。
      // en 与 `revampText(` 必须同行：i18n 守卫的 EN 规则只看本行，跨行会被判成硬编码。
      return _placeholder(_loadFailed
          ? revampText(context, en: "Couldn't load your promises — pull down to try again.", zh: '没能加载出来，下拉再试一次')
          : revampText(context, en: 'No promises yet', zh: '还没有答应过的事'));
    }
    final pendingByConv = _pendingByConv;
    final completed = _completed;
    final pendingCount = _visible.length - completed.length;
    return ListView(
      key: const PageStorageKey('promises_list'), // i18n-ignore: Scroll position key.
      // 设计稿左右边距 16、卡片间距 8。
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
      // ⚠️ 内容不足一屏时，Android 默认的 ClampingScrollPhysics 不产生 overscroll ⇒
      // RefreshIndicator 收不到手势。只有一两条待办时（这是常态）下拉就失效了，而
      // 失败提示写的正是「下拉再试一次」。
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (pendingByConv.isNotEmpty) ...[
          _sectionLabel(revampText(context, en: 'Pending·$pendingCount', zh: '未完成·$pendingCount')),
          const SizedBox(height: 8),
          for (final entry in pendingByConv.entries) ...[
            _groupCard(title: entry.key, items: entry.value, divided: false),
            const SizedBox(height: 8),
          ],
        ],
        if (completed.isNotEmpty) ...[
          if (pendingByConv.isNotEmpty) const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child: _sectionLabel(
                      revampText(context, en: 'Completed·${completed.length}', zh: '已完成·${completed.length}'))),
              _clearCompletedButton(),
            ],
          ),
          const SizedBox(height: 8),
          // 已完成不再按会话分组（设计稿同款：一张卡里若干行，分隔线隔开）。
          _groupCard(title: null, items: completed, divided: true),
        ],
      ],
    );
  }

  /// 把单条待办加进苹果「提醒事项」，带上到期日（只有模糊说法的不编日期）。
  ///
  /// 已经在提醒事项里的直接标成「已加入」而不重复写——判断靠标题比对，
  /// 与原生侧 getReminders 用同一个列表解析（同名 → 默认）。
  Future<void> _addOneToReminders(_Promise p) async {
    final service = AppleRemindersService();
    // 文案在 await 之前取好——之后再用 context 会踩 use_build_context_synchronously。
    final notes = revampText(context, en: 'From Memorion', zh: '来自记小宝');
    final denied = revampText(context,
        en: 'Reminders access denied — enable it in Settings › Privacy › Reminders',
        zh: '没有提醒事项权限，去「设置 › 隐私 › 提醒事项」开启');
    final failedMsg = revampText(context, en: 'Could not add to Reminders', zh: '加入提醒事项失败');
    final okMsg = revampText(context, en: 'Added to Reminders', zh: '已加入提醒事项');
    final dupMsg = revampText(context, en: 'Already in Reminders', zh: '已经在提醒事项里了');

    setState(() => _addingNow = p.description);
    try {
      if (!await service.hasPermission() && !await service.requestPermission()) {
        if (mounted) _toast(denied);
        return;
      }
      if (await service.reminderExists(p.description)) {
        if (!mounted) return;
        setState(() => _addedToReminders.add(p.description));
        _toast(dupMsg);
        return;
      }
      final ok = await service.addReminder(title: p.description, notes: notes, dueDate: p.reminderAt);
      if (!mounted) return;
      if (ok) setState(() => _addedToReminders.add(p.description));
      _toast(ok ? okMsg : failedMsg);
    } finally {
      if (mounted) setState(() => _addingNow = null);
    }
  }

  /// 空态 / 错误态。用 ListView 而不是 Center：RefreshIndicator 只对可滚的 child 起
  /// 作用，裹在 Center 里的话恰好在最需要重试的时候没法下拉。
  Widget _placeholder(String text) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 120, 32, 30),
      children: [
        Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder)),
      ],
    );
  }

  void _toast(String message) {
    UndoDeleteHost.showMessage(context, message);
  }

  Widget _sectionLabel(String text) {
    return Text(text,
        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder));
  }

  /// 「已完成」右侧的清空键（设计稿：品牌浅蓝药丸 + 蓝字，高 28）。
  Widget _clearCompletedButton() {
    return Semantics(
      identifier: 'promises_clear_completed',
      button: true,
      enabled: !_clearing && !_undoBusy,
      // container 必须显式开：不开的话这个节点会被合并进外层的 Row（连带左边的
      // 「已完成·N」文字），无障碍焦点框和 maestro 的元素框都会变成整行宽度 —— 按
      // identifier 点会落在文字上，maestro 照样报 success 而按钮压根没被点到。
      container: true,
      child: GestureDetector(
        onTap: _clearing || _undoBusy ? null : _clearCompleted,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _kPillBg,
            borderRadius: BorderRadius.circular(JXB.radiusFull),
          ),
          alignment: Alignment.center,
          child: _clearing
              ? const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8, color: _kPillFg))
              : Text(revampText(context, en: 'Clear', zh: '清空'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: _kPillFg)),
        ),
      ),
    );
  }

  /// 一张待办卡。设计稿：白底、圆角 28、内边距 16、无边框无阴影。
  ///
  /// [divided] 决定行与行之间怎么分：
  /// - `false`（未完成卡）—— 12px 空隙、**没有**分隔线。未完成的行是两行高的，中间再压
  ///   一条 hairline 会把「时间 + 按钮」那行看成下一条待办的开头。
  /// - `true`（已完成卡）—— 0.5px 分隔线。已完成的行只有一行高，靠线才分得开。
  Widget _groupCard({required String? title, required List<_Promise> items, required bool divided}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.circular(28),
      ),
      // 左滑露出的删除键是有底色的：不裁的话首/末行的按钮会画到卡片圆角外面去。
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(revampText(context, en: 'From: $title', zh: '来自：$title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.brandPrimary)),
            const SizedBox(height: 8),
          ],
          for (int i = 0; i < items.length; i++) ...[
            if (i != 0)
              divided
                  ? Container(height: 0.5, color: JXB.border)
                  : const SizedBox(height: 12),
            _promiseRow(items[i]),
          ],
        ],
      ),
    );
  }

  /// 一条待办：左滑露出「删除」+「加入提醒事项」两个胶囊（Figma node 1130:2509）。
  ///
  /// 顺序按设计稿：**删除在左、铃铛在右**。行里不再有「加入待办」的常驻胶囊——中途试过
  /// 把它做成第二行右侧一颗文字胶囊（node 1069:2477），已按设计稿撤回，两个动作都只在
  /// 左滑区出现。
  ///
  /// ⚠️ 已加入的那条用 `disabled` 灰掉而**不是**把 action 摘掉：`_maxReveal` 是按
  /// 按钮个数算的，个数一变展开态的行会横跳一截（`SwipeActionRow.didUpdateWidget`
  /// 刻意只对 `open` 变化做动画）。`disabled` 这个字段就是为这种情形留的。
  Widget _promiseRow(_Promise p) {
    final done = p.completed;
    final deleting = _deletingKeys.contains(p.key);
    final added = _addedToReminders.contains(p.description);
    final adding = _addingNow == p.description;
    final open = _openRowKey == p.key;
    return SwipeActionRow(
      // 下标左移后 key 会变，行的展开态因此重建成收起 —— 正是想要的。
      key: ValueKey(p.key),
      open: open,
      onOpenChanged: (v) => setState(() => _openRowKey = v ? p.key : null),
      actions: deleting
          ? const []
          : [
              SwipeAction(
                icon: Icons.delete_outline_rounded,
                iconColor: JXB.error,
                // 设计稿 #FAE3E3。不用 JXB.errorTint：那是 10% 不透明的 error，压在白卡上
                // 合成出来是 #FFEBEA，比设计稿浅一档 —— 单独看不出来，跟右边那颗实色的
                // 铃铛并排就明显不成对了。
                background: _kDeleteBg,
                semanticLabel: revampText(context, en: 'Delete', zh: '删除'),
                onTap: () => _confirmAndDelete(p),
              ),
              // 已完成的事不用再加进提醒事项；Android 上压根没有「提醒事项」这个 App，
              // 那边左滑就只有删除一个键（露出宽度按个数算，不会留空位）。
              if (!done && AppleRemindersService().isAvailable)
                SwipeAction(
                  // 已加入换成实心响铃：光靠 disabled 灰掉分不清「不能点」和「已经加过了」。
                  icon: added ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
                  iconColor: added ? JXB.success : _kPillFg,
                  background: added ? JXB.successTint : _kPillBg,
                  semanticLabel: added
                      ? revampText(context, en: 'Added to Reminders', zh: '已加入提醒事项')
                      : revampText(context, en: 'Add to Reminders', zh: '加入提醒事项'),
                  busy: adding,
                  disabled: added,
                  onTap: () => _addOneToReminders(p),
                ),
            ],
      child: Opacity(
        opacity: deleting ? 0.4 : 1,
        // 布局（一行还是两行）都在 PromiseRowContent 里，见那里的文档。
        child: PromiseRowContent(
          description: p.description,
          dueDate: p.dueDate,
          dueHint: p.dueHint,
          spokenAt: p.spokenAt,
          completed: done,
          onToggle: _undoBusy || _clearing ? null : () => _toggleCompleted(p),
          // 设计稿：滑开的那一行底色转灰。短描述会被左移出裁剪区，不换底色的话滑开
          // 之后那一行看着就是一片空白，分不清是哪条待办正开着。
          background: open ? _kRowOpenBg : null,
        ),
      ),
    );
  }

  Widget _detailBar(BuildContext context) {
    return SizedBox(
      height: 54,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            // 设计稿返回键：白 60% 半透明圆底 + 细白描边（40.9px）。
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 41,
                height: 41,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.6),
                  border: Border.all(color: Colors.white, width: 0.5),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.chevron_left_rounded, size: 24, color: JXB.textPrimary),
              ),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Promises You Made', zh: '你答应过的事'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
            ),
            // 加入提醒事项改成每行一个按钮（见 _promiseRow），这里不再放批量入口。
            // 设计稿右上角「…」更多菜单暂无定义动作，先不占位。
            const SizedBox(width: 41),
          ],
        ),
      ),
    );
  }
}
