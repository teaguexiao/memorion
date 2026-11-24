import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_stripper.dart';

/// 没收尾的 m4a 绝不许交给 `transferFile`。
///
/// 存在的理由（2026-08-15 生产）：`rec_1786778452129.m4a` —— 息屏切段开的后半段在后台
/// 录了约 24 秒后进程被系统挂起，`AVAudioRecorder.stop()` 没机会跑，文件缺 moov atom
/// 变成任何解码器都打不开的废文件。它一路传到 iPhone、上传，42 分钟后被后端 ffmpeg 判
/// 400（`Failed to convert audio file to WAV format`），搬进 `rejected/`，用户看到的是
/// 一句无从下手的「无法转录」。
///
/// 判据（`PendingRecordingStore.isFinalized`）当时**已经存在**，但只以「启动时扫一遍并
/// 删掉」的形式挂在 `WatchRecorder.init()` 上，而从 `pending()` 取文件入队的地方有三个：
/// 冷启动重入队、用户点「立即同步」（`retryPending`）、激活后冲 `deferred`。后两个绕过了
/// 那次清理。所以这里钉的不是「判据存在」，而是**判据挂在三条路唯一的汇聚点上**。
///
/// ⚠️ 用 Dart 测试扫 Swift 源码是因为 watch target 没有 Swift 测试目标（也不该为这一条
/// 单开一个：真正要防的是「有人把检查挪回调用方」，那是源码结构的事）。
void main() {
  final watchDir = Directory('ios/MemorionWatch');

  /// 🚨 **断言前必须剥掉注释和字符串，两者都不能省。** 不剥注释的话，上面那几段解释
  /// `isFinalized` 的文档注释本身就能让下面所有断言通过 —— 断言退化成同义反复，把检查
  /// 整个删掉也照样绿。剥的实现见 `helpers/source_stripper.dart`（那里写了为什么两次
  /// `replaceAll` 无论哪个顺序都不成立）。
  String code(String name) =>
      stripCommentsAndStrings(File('${watchDir.path}/$name').readAsStringSync());

  /// 从 `func <name>(` 截到下一个 `\n    func ` / `\n    @discardableResult`（同缩进的下
  /// 一个成员），拿到函数体。够用且不需要 Swift parser。
  String functionBody(String src, String signature) {
    final start = src.indexOf(signature);
    expect(start, greaterThan(-1), reason: '找不到 $signature —— 这个测试的假设过期了');
    final rest = src.substring(start + signature.length);
    final end = rest.indexOf(RegExp(r'\n    (@discardableResult|func |var |static )'));
    return end > 0 ? rest.substring(0, end) : rest;
  }

  test('enqueue 在调 transferFile 之前先判文件收尾了没有', () {
    final body = functionBody(code('WatchTransfer.swift'), 'func enqueue(_ recording: PendingRecording)');

    final checkAt = body.indexOf('isFinalized');
    final sendAt = body.indexOf('transferFile');
    expect(checkAt, greaterThan(-1),
        reason: 'enqueue 没有查 isFinalized —— 废文件会从三条入队路径里没有守卫的那两条漏出去');
    expect(sendAt, greaterThan(-1), reason: 'enqueue 里找不到 transferFile，假设过期了');
    expect(checkAt, lessThan(sendAt),
        reason: '收尾判据必须在 transferFile 之前：交给系统之后再判等于没判');
  });

  test('判据挂在 enqueue 这一层，而不是各个调用方', () {
    // 三条路都汇到 enqueue。判据放调用方就一定会漏掉将来新增的第四条路 ——
    // 2026-08-15 漏的正是「立即同步」这一条。
    final recorder = code('WatchRecorder.swift');
    final transfer = code('WatchTransfer.swift');

    expect(transfer.contains('isFinalized'), isTrue,
        reason: '判据从 WatchTransfer 里消失了');

    // enqueueAll 只是循环调 enqueue，不许自己另加一套过滤（两套判据必然漂移）。
    final all = functionBody(transfer, 'func enqueueAll(');
    expect(all.contains('isFinalized'), isFalse,
        reason: 'enqueueAll 不该自己判一遍 —— 判据只能有一处，在 enqueue 里');

    // finalize 里那次单条入队也必须走 enqueue，不许直接碰 transferFile。
    expect(recorder.contains('transferFile'), isFalse,
        reason: 'WatchRecorder 直接调了 transferFile，绕过了收尾判据');
  });

  test('「立即同步」在没录音时先清废文件，否则它永久占着一格', () {
    final body = functionBody(code('WatchRecorder.swift'), 'func retryPending()');

    expect(body.contains('dropUnfinalized'), isTrue,
        reason: 'retryPending 不清废文件：enqueue 现在会拒绝它，于是它既传不走又不消失，'
            '用户点多少次都一样 —— 这正是「点了没反应」的另一种真身');

    final guardAt = body.indexOf(RegExp(r'phase\s*!=\s*\.recording'));
    final dropAt = body.indexOf('dropUnfinalized');
    expect(guardAt, greaterThan(-1),
        reason: '清理必须被 phase != .recording 守住 —— 正在录的那个文件同样没有 moov，'
            '不守就会当场删掉一段正在进行的好录音');
    expect(guardAt, lessThan(dropAt), reason: '守卫要在清理之前');
  });

  test('清理绝不出现在 pending() 的列举路径上', () {
    final store = code('PendingRecordingStore.swift');
    final pending = functionBody(store, 'func pending()');
    expect(pending.contains('dropUnfinalized'), isFalse,
        reason: 'pending() 里做清理会删掉正在录的那个文件（它在 stop() 前也没有 moov）');
    expect(pending.contains('isFinalized'), isFalse,
        reason: 'pending() 不许按收尾状态过滤：录音中的 UI 要能看见正在录的这一段');
  });

  test('box 走查把「延伸到文件末尾」判成没收尾', () {
    // 这是检测的**唯一**着力点：录制中的 mdat 就是 size==0（一直到文件末尾）的形态。
    // 把它当成「继续往后找」会走出文件范围，当成 finalized 就等于这个检查不存在。
    final walk = code('PendingRecordingStore.swift');
    final at = walk.indexOf(RegExp(r'size32\s*==\s*0'));
    expect(at, greaterThan(-1), reason: 'box 走查不再处理 size == 0 —— 录制中被中断的形态漏了');
    final after = walk.substring(at, at + 120);
    expect(after.contains('return false'), isTrue,
        reason: 'size == 0 必须判成「没收尾」');
  });
}
