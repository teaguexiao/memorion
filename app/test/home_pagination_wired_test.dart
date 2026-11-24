// 首页必须有「往前翻页」的入口，且不能用「返回条数 < limit」判断到底。
//
// 这两条各自都曾经单独成立过，接起来就是「昨天之前的内容一条都看不到」：
//
// 1. 07-22 首页切到 TodayChaptersPage，07-25 删旧壳死代码时带走了
//    `getMoreConversationsFromServer` 的**唯一调用者**。此后首页只有第一页，而
//    `getMoreConversationsFromServer` 变成零引用的死代码——静态分析不会报，因为它
//    是 public 方法。
// 2. 那个方法第一行是 `if (conversations.length % 50 != 0) return;`。服务端当时把
//    `limit` 打在丢弃过滤**之前**，请求 50 条只回 21 条（2026-08-21 丢弃率 57%），
//    于是 `21 % 50 != 0` 恒成立 —— 就算入口还在，也一次都翻不动。
//
// 所以第一页能铺开几天，取决于那 50 条里有多少被丢弃吃掉。丢弃率低时能铺 4~5 天，
// 看着一切正常，缺口就这样藏了一个月。
//
// ⚠️ 断言前必须剥注释：本文件和被测文件的注释里都写着 `% 50` 和方法名，不剥的话
// 「代码里没有 % 50」会被注释里的字面量弄成假红/假绿（见 test/helpers/source_stripper.dart）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_stripper.dart';

void main() {
  final providerSrc = stripCommentsAndStrings(
    File('lib/providers/conversation_provider.dart').readAsStringSync(),
  );
  final pageSrc = stripCommentsAndStrings(
    File('lib/pages/today_chapters/today_chapters_page.dart').readAsStringSync(),
  );

  group('首页翻页入口', () {
    test('今日页真的调用了 getMoreConversationsFromServer', () {
      expect(
        pageSrc.contains('getMoreConversationsFromServer'),
        isTrue,
        reason: '首页没有任何翻页入口 —— 那就只有第一页，昨天之前的内容一条都看不到。'
            '这个方法是 public 的，失去调用者时分析器不会报任何东西。',
      );
    });

    test('翻页挂在滚动监听上（有 ScrollController 且交给了 CustomScrollView）', () {
      expect(pageSrc.contains('ScrollController'), isTrue,
          reason: '没有 ScrollController 就没法知道用户滚到底了');
      expect(
        RegExp(r'controller:\s*_scrollController').hasMatch(pageSrc),
        isTrue,
        reason: 'ScrollController 建了但没接到滚动视图上，监听永远不会触发',
      );
    });

    test('滚动监听里读的是 hasMoreConversations，不是自己算页数', () {
      final body = functionBody(pageSrc, '_onScroll');
      expect(body, isNotNull, reason: '_onScroll 不见了');
      expect(body!.contains('hasMoreConversations'), isTrue);
      expect(body.contains('getMoreConversationsFromServer'), isTrue);
    });
  });

  group('到底的判据', () {
    test('不能用「已加载条数 % 每页条数」判断还有没有更多', () {
      final body = functionBody(providerSrc, 'getMoreConversationsFromServer');
      expect(body, isNotNull);
      expect(
        RegExp(r'%\s*50').hasMatch(body!),
        isFalse,
        reason: '这就是把首页锁死一个月的那一行：服务端返回条数不等于 limit 时它恒成立',
      );
      expect(
        body.contains('length %'),
        isFalse,
        reason: '任何「已加载条数取模」的变体都会在服务端少给几条时锁死翻页',
      );
    });

    test('判据是「返回空」——客户端与服务端不同步发布时也必须能往前翻', () {
      final body = functionBody(providerSrc, 'getMoreConversationsFromServer')!;
      expect(
        body.contains('fetched.isEmpty'),
        isTrue,
        reason: '必须拿「这一页返回空」当到底的判据',
      );
      // ⚠️ 不能只断言「出现过 isEmpty」：函数里还有一处 `fresh.isEmpty`（防重复的
      // 那道保护），于是把判据换成 `fetched.length < conversationsPageSize` 时，
      // 宽松的正则照样匹配得上 —— 实测这个变异一度整批测试全绿。要直接把「少于一页
      // 就算到底」这个形态钉死。
      expect(
        RegExp(r'\.length\s*<|<\s*conversationsPageSize|<\s*50').hasMatch(body),
        isFalse,
        reason: '「返回条数 < limit 就算到底」在服务端少给几条时会立刻锁死翻页 —— '
            'App 先上线、服务端还没下推过滤时正是这种情形',
      );
    });

    test('新拉到的一条都不新时必须停下，否则无限请求同一页', () {
      final body = functionBody(providerSrc, 'getMoreConversationsFromServer')!;
      expect(
        body.contains('fresh'),
        isTrue,
        reason: 'offset 取自 conversations.length：一页全是重复时 length 不变 ⇒ '
            'offset 不变 ⇒ 同一页会被无限请求',
      );
    });

    test('重新拉第一页要重置翻页状态', () {
      final body = functionBody(providerSrc, 'fetchConversations');
      expect(body, isNotNull);
      expect(
        RegExp(r'hasMoreConversations\s*=\s*true').hasMatch(body!),
        isTrue,
        reason: '翻到底之后下拉刷新，列表回到 50 条却仍记着「没有更多」⇒ 再也翻不动',
      );
    });
  });
}
