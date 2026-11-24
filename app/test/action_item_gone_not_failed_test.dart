import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/conversations.dart';

import 'helpers/source_stripper.dart';

/// 钉住「服务端已经没有这条待办」和「操作失败」是**两回事**。
///
/// ## 这条不变式破掉的样子
///
/// 后端的待办门禁在待办**已经下发给 App 之后**才撤销它们（`clear_action_items`，跑在
/// 声纹线程末尾）。2026-08-24 实测这个窗口是 **46 秒**：conv 56313829 于 12:50:40
/// 写入 1 条待办、12:51:26 被撤销。App 缓存里那一条于是指向一个不存在的对象 ——
/// 首页气泡卡照旧把它显示出来，而对它的每一次操作都 404。
///
/// 当时两个函数都把返回值收成 `bool`，404 和网络错误一起落进 `false`：
///
/// * 点「不是待办」→ DELETE 404 → `if (ok)` 不成立 → 本地不删 → **卡片赖着不走**。
///   用户连点 9 次，全是 404。
/// * 点「加入待办」→ 乐观更新让卡片先消失 → PATCH 404 → 回滚成待确认 → 既没进
///   「你答应过的事」，又把幽灵卡片放了回来。用户又点了 2 次。
///
/// 全过程界面一句话都没说。
///
/// ## 判据
///
/// 404 的语义是「服务端没有这条了」，它的正确处置和真失败**正好相反**：前者要本地跟着
/// 对齐（删掉），后者要保留着等重试。所以这里必须是三态，`bool` 在结构上装不下。
void main() {
  group('ActionItemMutation.fromStatus', () {
    test('404 是 gone，不是 failed —— 这就是那个 bug 本身', () {
      expect(
        ActionItemMutation.fromStatus(404, successCode: 204),
        ActionItemMutation.gone,
        reason: '404 归到 failed 就会让本地跳过删除，卡片永远按不掉',
      );
      expect(ActionItemMutation.fromStatus(404, successCode: 200), ActionItemMutation.gone);
    });

    test('DELETE 的成功码是 204，PATCH 是 200 —— 不能混用', () {
      expect(ActionItemMutation.fromStatus(204, successCode: 204), ActionItemMutation.ok);
      expect(ActionItemMutation.fromStatus(200, successCode: 200), ActionItemMutation.ok);
      // 反向：拿错成功码时必须落进 failed 而不是被当成成功放过去。
      expect(
        ActionItemMutation.fromStatus(204, successCode: 200),
        ActionItemMutation.failed,
        reason: 'DELETE 用 200 当成功码，会把每一次成功的删除都判成失败',
      );
    });

    test('请求没发出去（statusCode == null）是 failed，本地要回滚', () {
      expect(ActionItemMutation.fromStatus(null, successCode: 204), ActionItemMutation.failed);
    });

    test('其余非 404 的错误码都是 failed', () {
      for (final code in [400, 401, 403, 409, 500, 502, 503]) {
        expect(
          ActionItemMutation.fromStatus(code, successCode: 204),
          ActionItemMutation.failed,
          reason: '$code 不该被当成「服务端没有这条了」',
        );
      }
    });

    test('三态互不相等 —— 折叠回两态这套断言就没意义了', () {
      expect(ActionItemMutation.values.length, 3);
      expect({ActionItemMutation.ok, ActionItemMutation.gone, ActionItemMutation.failed}.length, 3);
    });
  });

  group('调用点接线（剥掉注释和字符串之后扫）', () {
    late String provider;
    late String homePage;
    late String promisesPage;

    setUpAll(() {
      String load(String rel) => stripCommentsAndStrings(File(rel).readAsStringSync());
      provider = load('lib/providers/conversation_provider.dart');
      homePage = load('lib/pages/today_chapters/today_chapters_page.dart');
      promisesPage = load('lib/pages/today_chapters/promises_page.dart');
    });

    test('两个 provider 方法都返回 ActionItemMutation，不是 void/bool', () {
      expect(provider, contains('Future<ActionItemMutation> confirmActionItem('));
      expect(provider, contains('Future<ActionItemMutation> rejectActionItem('));
    });

    test('confirmActionItem 的 gone 分支不许回滚成待确认', () {
      // 回滚会把幽灵卡片原样放回首页，而它按不掉 —— 那正是用户看到的死循环。
      final body = _dartBody(provider, 'Future<ActionItemMutation> confirmActionItem(');
      final goneAt = body.indexOf('ActionItemMutation.gone:');
      final failedAt = body.indexOf('ActionItemMutation.failed:');
      expect(goneAt, greaterThan(-1), reason: 'gone 必须被单独处置');
      expect(failedAt, greaterThan(goneAt), reason: 'failed 分支应排在 gone 之后');

      final goneBranch = body.substring(goneAt, failedAt);
      expect(
        goneBranch.contains('_setActionItemConfirmedLocal'),
        isFalse,
        reason: 'gone 分支一旦回滚 confirmed，幽灵卡片就会立刻回到首页',
      );
      expect(goneBranch, contains('_resyncConversationAfterGone('));
    });

    test('rejectActionItem 的 gone 与 ok 都要让本地对齐，只有 failed 不动', () {
      final body = _dartBody(provider, 'Future<ActionItemMutation> rejectActionItem(');
      final okAt = body.indexOf('ActionItemMutation.ok:');
      final goneAt = body.indexOf('ActionItemMutation.gone:');
      final failedAt = body.indexOf('ActionItemMutation.failed:');
      expect([okAt, goneAt, failedAt], everyElement(greaterThan(-1)));

      expect(body.substring(okAt, goneAt), contains('_removeActionItemLocal('));
      expect(body.substring(goneAt, failedAt), contains('_resyncConversationAfterGone('));
    });

    test('gone 之后整条重拉，不是只 removeAt —— 撤销是整条清空', () {
      // `clear_action_items` 清掉的是整条会话的待办，所以同会话剩下的那些也已经是
      // 幽灵。只删被点到的一条，用户得一条接一条点。
      final body = _dartBody(provider, 'Future<void> _resyncConversationAfterGone(');
      expect(body, contains('getConversationById('));
      expect(body, contains('upsertConversation('));
    });

    test('首页两枚按钮不再是 fire-and-forget', () {
      // 改之前是 `onConfirm: () => provider.confirmActionItem(...)`，返回的 Future
      // 没人接，失败完全静默。
      expect(homePage, contains('_handleTaskMutation('));
      expect(homePage, contains('notifyWhenGone: true'));
      expect(homePage, contains('notifyWhenGone: false'));
      expect(
        homePage.contains('onConfirm: () => provider.confirmActionItem('),
        isFalse,
        reason: '直接把 provider 方法挂上去就等于丢掉了结局',
      );
      expect(homePage.contains('onDismiss: () => provider.rejectActionItem('), isFalse);
    });

    test('首页的失败分支真的会提示用户', () {
      final body = _dartBody(homePage, 'Future<void> _handleTaskMutation(');
      final failedAt = body.indexOf('ActionItemMutation.failed:');
      expect(failedAt, greaterThan(-1));
      expect(body.substring(failedAt), contains('_toast('),
          reason: '按不动却不说话，是这次报障里独立的第二个问题');
    });

    test('「你答应过的事」页也按三态处理，不再把返回值当 bool', () {
      expect(promisesPage, contains('ActionItemMutation.gone'));
      expect(
        promisesPage.contains('final ok = await rejectConversationActionItem('),
        isFalse,
        reason: '收成 bool 就又把 404 和真失败混在一起了',
      );
    });

    test('gone 在「你答应过的事」页不能走下标左移那条路', () {
      // `_applyLocalDeletion` 的左移**以后端 pop 过一条为前提**；404 意味着后端什么都
      // 没 pop，左移只会让本地下标错得更深。那条路只能重拉。
      final body = _dartBody(promisesPage, 'Future<void> _confirmAndDelete(');
      final goneAt = body.indexOf('ActionItemMutation.gone');
      expect(goneAt, greaterThan(-1));
      final goneBranch = body.substring(goneAt, body.indexOf('final ok = result =='));
      expect(goneBranch.contains('_applyLocalDeletion'), isFalse);
      expect(goneBranch, contains('_resyncAfterStaleIndexes()'));
    });

    test('gone 之后 DiscoverProvider 的缓存也要重拉，不能只刷本页', () {
      // 正常删除靠 `_applyLocalDeletion` 返回的回调同步 DiscoverProvider（「关于我」
      // 摘要卡读那一份）。gone 绕开了它，只 `_load()` 会让那份缓存留着已经不存在的
      // 条目**和旧的 item_idx** —— 后端按下标 pop，从那张卡上再操作就打到隔壁待办上。
      final body = _dartBody(promisesPage, 'Future<bool> _resyncAfterStaleIndexes(');
      expect(body, contains('_load()'));
      expect(body, contains('loadActionItems()'));
    });

    // ⚠️ 这一组要用**两份**源码。`stripCommentsAndStrings` 连字符串字面量一起剥掉，所以
    // 剥过的源码里 `res['ok']` 变成 `res['']` —— 断言「有没有 ok 这个字段」只能看原文。
    // 反过来，位置断言只能看剥过的：解释这段改动的注释里就写着 `_all.clear()`，而它排在
    // 失败检查**之前**，拿原文比位置会假红。
    test('重拉失败不许被当成空列表 —— 错误路径上的重拉会把整页清空', () {
      // `getActionItems()` 失败时返回空 items，和「真的没有待办」不可分辨。而 gone
      // 路径是**错误路径**，紧接着的重拉更可能也失败；不分辨的话一次超时就把「你答应
      // 过的事」清空，`loadActionItems` 还会把空响应 cacheJson 落盘活到下次启动。
      final apiRaw = File('lib/backend/http/api/discover.dart').readAsStringSync();
      expect(apiRaw, contains("'ok': false"), reason: 'getActionItems 要能报告失败');
      expect(apiRaw, contains("'ok': true"), reason: '成功也要标出来，否则调用方分不清');

      final promisesRaw = File('lib/pages/today_chapters/promises_page.dart').readAsStringSync();
      expect(promisesRaw, contains("res['ok'] == false"));
      final discoverRaw = File('lib/providers/discover_provider.dart').readAsStringSync();
      expect(discoverRaw, contains("response['ok'] == false"));

      // 位置：失败检查必须在「清空 / 落盘」之前，否则等于没检查。剥过的源码里那两句
      // 分别塌成 `res[''] == false` / `response[''] == false`，用 `== false` 定位。
      final load = _dartBody(promisesPage, 'Future<bool> _load(');
      expect(
        load.indexOf('== false'),
        lessThan(load.indexOf('_all.clear()')),
        reason: '失败检查必须排在 _all.clear() 之前，否则列表已经被清了',
      );

      final discover = stripCommentsAndStrings(
          File('lib/providers/discover_provider.dart').readAsStringSync());
      final loadActions = _dartBody(discover, 'Future<void> loadActionItems(');
      expect(
        loadActions.indexOf('== false'),
        lessThan(loadActions.indexOf('cacheJson')),
        reason: '失败检查必须排在 cacheJson 之前，否则空响应已经落盘了',
      );
      expect(loadActions.indexOf('== false'), greaterThan(-1));
    });

    test('重拉没成功要明说，且只说一句 —— 装作成功比停在旧数据更糟', () {
      // resync 自己不 toast：两处各弹一句的话，一次失败的重拉会先说「列表刷新了一下」
      // 再说「没刷新成功」，或者反过来 —— 最后一句反而宣称成功。
      final resync = _dartBody(promisesPage, 'Future<bool> _resyncAfterStaleIndexes(');
      expect(resync.contains('_toast('), isFalse, reason: '提示由调用方拼，避免自相矛盾');

      final message = _dartBody(promisesPage, 'String _staleIndexMessage(');
      expect(message, contains('refreshed'), reason: '这句话必须如实反映重拉结果');

      // 两条 gone 路径都要「先重拉、再据实说话」。
      for (final fn in ['Future<void> _confirmAndDelete(', 'Future<void> _clearCompleted(']) {
        final body = _dartBody(promisesPage, fn);
        expect(
          body.indexOf('_resyncAfterStaleIndexes()'),
          lessThan(body.indexOf('_staleIndexMessage(')),
          reason: '$fn 在重拉之前就下结论了',
        );
      }
    });

    test('清空已完成撞上 gone 时，已删成功的那些仍要走本地收尾', () {
      // `deleted` 里是真的 204 成功、后端已经 pop 过下标的那些。跳过 `_applyLocalDeletion`
      // 而指望重拉兜住是不行的 —— 重拉自己会失败，那时本地还留着这些条目且 itemIdx 比
      // 服务端大一位，用户对同会话另一条左滑删除就砍到隔壁去了。
      final body = _dartBody(promisesPage, 'Future<void> _clearCompleted(');
      expect(
        body.indexOf('_applyLocalDeletion('),
        lessThan(body.indexOf('_resyncAfterStaleIndexes()')),
        reason: 'deleted 的本地收尾必须排在重拉之前，且不能被 gone 分支跳过',
      );
      // gone 的早退必须在收尾之后 —— 排在前面就等于跳过收尾。
      expect(
        body.indexOf('_applyLocalDeletion('),
        lessThan(body.indexOf('if (sawStaleIndexes)')),
      );
    });

    test('清空已完成的 gone 分支不许丢掉 failed 计数', () {
      // 这一支原先直接 return，真正的网络失败数被悄悄丢掉。
      final body = _dartBody(promisesPage, 'Future<void> _clearCompleted(');
      final at = body.indexOf('_staleIndexMessage(');
      expect(at, greaterThan(-1));
      expect(body.substring(at, body.indexOf(')', at) + 1), contains('failed'));
    });

    test('冷启动拉取失败也不能渲染成空态 —— 保留列表只治了一半', () {
      // `ok == false` 时保留现有列表，只救得了「已经有数据」的情形。首次进页面 `_all`
      // 本来就是空的，不置错误位的话空态照旧写「还没有答应过的事」—— 一次超时读起来
      // 就是一个结论。
      expect(promisesPage, contains('_loadFailed'));
      final load = _dartBody(promisesPage, 'Future<bool> _load(');
      expect(load, contains('_loadFailed = true'));
      expect(load, contains('_loadFailed = false'), reason: '成功之后要把错误位清掉');

      final content = _dartBody(promisesPage, 'Widget _content(');
      expect(
        content.indexOf('_loadFailed'),
        greaterThan(-1),
        reason: '空态必须按 _loadFailed 分岔，否则两种状态长得一样',
      );
    });

    test('失败提示说「下拉再试」，那这一页就得真有下拉刷新', () {
      // `_load()` 原先只有 initState 和 404 收尾两个调用点 —— 拉取失败后用户除了退出
      // 重进没有任何重试手段，而提示偏偏指着一个不存在的手势。
      expect(promisesPage, contains('RefreshIndicator'));
      final body = _dartBody(promisesPage, 'Widget _body(');
      expect(body, contains('RefreshIndicator'));
      expect(body, contains('_load()'), reason: '下拉要真的触发重拉');
    });

    test('空态待在可滚容器里，否则 RefreshIndicator 收不到手势', () {
      // 「空态点不动」这个坑这个仓库踩过一次：裹在 Center 里的空态不可滚，恰好在最需要
      // 重试的时候没法下拉。
      final placeholder = _dartBody(promisesPage, 'Widget _placeholder(');
      expect(placeholder, contains('ListView'));
      expect(placeholder, contains('AlwaysScrollableScrollPhysics'));
      expect(placeholder.contains('Center('), isFalse,
          reason: 'Center 不可滚 —— 这正是要避开的形态');
    });

    test('有数据的列表也要 AlwaysScrollableScrollPhysics —— 否则短列表下拉失效', () {
      // Android 默认 ClampingScrollPhysics 在内容不足一屏时不产生 overscroll ⇒
      // 只有一两条待办时（常态）RefreshIndicator 收不到手势，而提示写的就是「下拉再试」。
      final content = _dartBody(promisesPage, 'Widget _content(');
      expect(content, contains('AlwaysScrollableScrollPhysics'));
    });

    test('下拉刷新失败要提示 —— _loadFailed 只被空态读到', () {
      // 「已有数据 + 下拉失败」不提示，就和「刷新成功、内容没变」完全一样。
      final body = _dartBody(promisesPage, 'Widget _body(');
      final at = body.indexOf('onRefresh');
      expect(at, greaterThan(-1));
      expect(body.substring(at), contains('_toast('));
    });

    test('loadActionItems 与 loadMoreActionItems 必须一起尊重 ok', () {
      // 只改一个等于只修一半：分页请求失败时空 items 会被读成「翻到底了」，
      // `_actionItemsHasMore` 永久置 false ⇒ 列表静默截断、本次会话再也拉不动。
      final discover = stripCommentsAndStrings(
          File('lib/providers/discover_provider.dart').readAsStringSync());
      for (final fn in ['Future<void> loadActionItems(', 'Future<void> loadMoreActionItems(']) {
        expect(_dartBody(discover, fn), contains('== false'), reason: '$fn 没检查 ok');
      }
      final more = _dartBody(discover, 'Future<void> loadMoreActionItems(');
      expect(
        more.indexOf('== false'),
        lessThan(more.indexOf('_actionItemsHasMore = false')),
        reason: '失败检查必须排在「翻到底了」的结论之前',
      );
    });

    test('两条 gone 路径都走同一个收尾，不许只修一条', () {
      // `_confirmAndDelete`（单条左滑删）和 `_clearCompleted`（清空已完成）各有一条
      // gone 路径。只给其中一条接上缓存同步，另一条就静默留着错位的下标。
      for (final fn in ['Future<void> _confirmAndDelete(', 'Future<void> _clearCompleted(']) {
        expect(
          _dartBody(promisesPage, fn),
          contains('_resyncAfterStaleIndexes()'),
          reason: '$fn 的 gone 收尾没接上',
        );
      }
    });
  });
}

/// 从 `signature` 起截到花括号配平为止 —— 只看这一个函数体，避免断言被邻居满足。
///
/// ⚠️ 必须先配平**圆**括号跳过参数列表：命名参数写作 `{required bool x}`，直接找第一个
/// `{` 会把参数列表当成函数体，于是函数体在参数列表结束处就"配平"了，里面什么都搜不到
/// —— 断言以「找不到」失败，看起来像代码没写对。
String _dartBody(String src, String signature) {
  final start = src.indexOf(signature);
  if (start < 0) throw StateError('找不到 $signature');
  var cursor = src.indexOf('(', start);
  var paren = 0;
  for (; cursor < src.length; cursor++) {
    if (src[cursor] == '(') paren++;
    if (src[cursor] == ')') {
      paren--;
      if (paren == 0) break;
    }
  }
  final open = src.indexOf('{', cursor);
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(open, i + 1);
    }
  }
  throw StateError('$signature 的函数体括号不配平');
}
