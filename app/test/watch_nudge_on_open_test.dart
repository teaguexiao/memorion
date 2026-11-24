import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_stripper.dart';

/// 打开手表 App 必须叫一声 iPhone。
///
/// 存在的理由（2026-08-16 用户报「经常没有自动同步」）：`transferFile` 的投递时机**完全由
/// 系统决定**，实测就是「iPhone 上的 Memorion 活过来的那一刻」—— 一段 13:24 录完、入队后
/// 立刻 `didFinish(kNoErr)` 的录音，直到 14:06 用户打开手机 App 才真正到达。中间 42 分钟
/// 手表侧一切正常、「待同步」不动（列表只由 iPhone 的 App 级回执驱动），用户唯一能得出的
/// 结论就是「没自动同步」。
///
/// `sendMessage`（`nudgeCompanion()`）是唯一能反过来推一把的通道，而它当时只挂在两处：
/// 停止录音之后、点「立即同步」。于是**最自然的那个动作 —— 抬腕打开手表 App 看一眼
/// 「怎么还没同步」—— 恰恰是唯一不推一把的动作**，而它本该和「立即同步」做同一件事。
///
/// 这里钉三条路，因为它们各自覆盖不同的进入方式，缺一条就有一整类情形回到「只能等用户
/// 自己去开手机 App」：
///
/// 1. `WatchTransfer` 激活完成 —— 冷启动。那时入队全部落进 `deferred`，是在激活回调里才
///    真正交给系统的，如果到此为止就没人推。
/// 2. `RecorderView.onAppear` —— 从表盘/Dock 打开。
/// 3. `scenePhase == .active` —— 息屏后抬腕回来（进程没重启，1 和 2 都不会再跑）。
///
/// ⚠️ 用 Dart 测试扫 Swift 源码是因为 watch target 没有 Swift 测试目标。同样的取向和
/// 同样的剥注释理由见 `watch_transfer_refuses_unfinalized_test.dart`。
void main() {
  final watchDir = Directory('ios/MemorionWatch');

  /// 🚨 **必须剥注释。** 上面那几段解释以及被测代码自己的文档注释里都写着
  /// `nudgeCompanion` / `handleBecameActive`，不剥的话把调用整个删掉也照样绿。
  String code(String name) => stripCommentsAndStrings(File('${watchDir.path}/$name').readAsStringSync());

  /// 从 `signature` 截到同缩进的下一个成员。比
  /// `watch_transfer_refuses_unfinalized_test.dart` 里那份多认 `private`/`@objc` 前缀
  /// —— 少认一个前缀不会报错，只会把函数体一路截到文件末尾，于是断言变成「全文里有没有
  /// 这个词」，静默失去分辨力。
  String functionBody(String src, String signature) {
    final start = src.indexOf(signature);
    expect(start, greaterThan(-1), reason: '找不到 $signature —— 这个测试的假设过期了');
    final rest = src.substring(start + signature.length);
    final end = rest.indexOf(RegExp(
        r'\n    (@discardableResult|@objc|(private |internal |fileprivate |public )?(nonisolated )?(static )?(func|var|let) )'));
    return end > 0 ? rest.substring(0, end) : rest;
  }

  test('激活完成后队列非空就 nudge —— 冷启动那条路的唯一机会', () {
    final body = functionBody(
      code('WatchTransfer.swift'),
      'func session(_ session: WCSession, activationDidCompleteWith state:',
    );

    expect(body.contains('enqueueAll'), isTrue, reason: '激活回调不再冲 deferred —— 冷启动时入队的录音永远交不到系统手里');
    expect(body.contains('nudgeCompanion'), isTrue, reason: '激活完只入队不 nudge：文件躺在系统队列里，只能等用户自己去打开手机 App');

    // 判据必须是 `outstandingFileTransfers`，不能是「这次冲了几条 deferred」——
    // 上个进程留下的「已交给系统、还没投递」根本不经过 deferred，而它们同样需要这一下。
    expect(body.contains('outstandingFileTransfers'), isTrue, reason: 'nudge 的判据不看系统队列，就会漏掉上个进程留下的待投递传输');
  });

  test('handleBecameActive 会 nudge，且不碰废文件清理、不抢 notice', () {
    final body = functionBody(code('WatchRecorder.swift'), 'func handleBecameActive()');

    expect(body.contains('nudgeCompanion'), isTrue, reason: '打开/回到前台不 nudge —— 这正是用户报的「经常没有自动同步」的真身');
    expect(body.contains(RegExp(r'pending\.isEmpty')), isTrue, reason: '队列空的时候不该叫 iPhone（白拉起一次后台 App）');

    // 🚨 这个方法在**录音中**也会被调到（通知横幅下来再回去就是一次 `.active`），而
    // 清理判据对正在写的那个文件同样成立 —— 放在这里就是当场删掉一段正在进行的好录音。
    expect(body.contains('dropUnfinalized'), isFalse,
        reason: 'handleBecameActive 里清废文件会删掉正在录的那一段：'
            '它在 stop() 之前同样没有 moov，而这条路径在录音中也会跑');

    // 这条路径不是用户主动要求同步，写 notice 会盖掉上一次真正重要的那句
    // （比如「这段录音没能完整保存」）——那是用户唯一的线索。
    expect(body.contains(RegExp(r'notice\s*=')), isFalse, reason: 'handleBecameActive 不该写 notice：它是后台动作，会盖掉更重要的提示');
  });

  test('App 生命周期的两个入口都走 handleBecameActive，不随页面导航消失', () {
    final view = code('MemorionWatchApp.swift');

    final onAppear = RegExp(r'\.onAppear\s*\{[^}]*\}').firstMatch(view)?.group(0) ?? '';
    expect(onAppear.contains('handleBecameActive'), isTrue,
        reason: 'onAppear 只 refreshPending 的话，从表盘打开手表 App 不会叫 iPhone —— '
            '而那正是用户「怎么还没同步」时会做的动作');

    // `.active` 分支：从 `newPhase == .active` 截到这一行结束。
    final activeLine = view.split('\n').firstWhere((l) => l.contains('phase == .active'), orElse: () => '');
    expect(activeLine, isNotEmpty, reason: '找不到 scenePhase .active 分支，假设过期了');
    expect(activeLine.contains('handleBecameActive'), isTrue,
        reason: '息屏后抬腕回来时进程没重启，onAppear 和激活回调都不会再跑 —— '
            '这条分支是那种情形唯一的机会');

    // 切段判定不许被这次改动碰到：`.background` 仍然只做 handleWentBackground。
    final bgLine = view.split('\n').firstWhere((l) => l.contains('phase == .background'), orElse: () => '');
    expect(bgLine.contains('handleWentBackground'), isTrue, reason: '.background 分支被改动波及了 —— 它是息屏切段的唯一触发点');
  });
}
