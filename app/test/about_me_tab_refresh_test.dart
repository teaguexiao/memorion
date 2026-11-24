// 「关于我」tab 上的三块内容（事实 / 洞察 / 你答应过的事）必须由这一页自己刷新。
//
// 症状：「你答应过的事」摘要卡显示空，点「查看全部」进 P-03 却看得到那条待办。
//
// 根因不是数据问题，是**摘要卡这一份数据没有任何刷新点**：
//  - `DiscoverProvider.actionItems` 只在 `HomeShellWrapper` 冷启动那一次 `loadAll()` 里拉过；
//  - 切到「关于我」时只刷了 memories 和 insights，漏掉待办；
//  - 在「关于我」下拉刷新，`_refreshAll` 落到默认分支去刷**章节时间线**，屏幕上一个字不变。
// 而 P-03（PromisesPage）每次进页面都自己 `getActionItems()`，所以永远是新的。
// 气泡卡「加入待办」走 `ConversationProvider.confirmActionItem`，它只改那条会话、碰不到
// 这份列表 —— 于是刚确认的待办要等下一次冷启动才进摘要卡。
//
// ⚠️ 断言前必须剥注释：上面这段注释里就写着 `loadActionItems`，不剥的话把真调用删掉照样绿
// （见 test/helpers/source_stripper.dart）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_stripper.dart';

/// 取 [marker] 之后那一对大括号里的内容（用于 `if (i == 2) { ... }` 这种匿名块，
/// `functionBody` 抓不到）。
String? blockAfter(String src, String marker) {
  final idx = src.indexOf(marker);
  if (idx < 0) return null;
  final open = src.indexOf('{', idx + marker.length);
  if (open < 0) return null;
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  return null;
}

void main() {
  final pageSrc = stripCommentsAndStrings(
    File('lib/pages/today_chapters/today_chapters_page.dart').readAsStringSync(),
  );

  // 三块内容各自的拉取入口。少任何一个，那一块就只有冷启动那一份快照。
  const loaders = {
    'loadMemories': '它记住的事实',
    'loadInsights': '最新洞察',
    'loadActionItems': '你答应过的事',
  };

  group('切到「关于我」tab', () {
    test('三块内容都刷新（漏掉哪个，哪个就停在冷启动那一份）', () {
      final branch = blockAfter(pageSrc, 'if (i == 2)');
      expect(branch, isNotNull, reason: '切到「关于我」的分支不见了 —— 那一页再没有任何刷新点');
      for (final entry in loaders.entries) {
        expect(branch!.contains(entry.key), isTrue,
            reason: '「${entry.value}」没在切 tab 时刷新：${entry.key} 不在 i == 2 的分支里');
      }
    });

    test('不能加「已有数据就不拉」的守卫', () {
      final branch = blockAfter(pageSrc, 'if (i == 2)')!;
      expect(
        RegExp(r'is(Initialized|Empty)|LoadedOnce').hasMatch(branch),
        isFalse,
        reason: '这三个 provider 都会被本地缓存预填/在失败后仍标记为已初始化，'
            '任何"已有数据就跳过"的守卫都会让服务端那份永远拉不到',
      );
    });
  });

  group('在「关于我」下拉刷新', () {
    test('刷的是这一页上的三块内容，不是背后的章节时间线', () {
      final body = functionBody(pageSrc, '_refreshAll');
      expect(body, isNotNull, reason: '_refreshAll 不见了');
      expect(body!.contains('_segmentIndex == 2'), isTrue,
          reason: '没有「关于我」这一支 ⇒ 落到默认分支去刷会话时间线，'
              '用户只看到转圈、页面一个字不变，于是把「没刷出来」读成「云端就是空的」');
      final aboutMe = blockAfter(body, '_segmentIndex == 2')!;
      for (final entry in loaders.entries) {
        expect(aboutMe.contains(entry.key), isTrue,
            reason: '下拉刷新没刷「${entry.value}」：${entry.key} 不在这一支里');
      }
      expect(aboutMe.contains('return'), isTrue,
          reason: '这一支必须自己 return，否则接着去刷章节时间线（那一段有它自己的多轮请求）');
    });
  });
}
