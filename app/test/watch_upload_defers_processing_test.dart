import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/watch_recording_service.dart';

import 'helpers/source_stripper.dart';

/// 手表补传必须让后端**异步**处理，而且只有手表这一条路可以这样。
///
/// `POST /v1/conversations/upload-audio` 原来把 ffmpeg + Silero VAD + Soniox + LLM 摘要
/// 全塞在一个请求里：2026-08-16 实测 **p50 69.3s，25 次里 4 次跑满 600s 被砍成 504**。
/// 而队列是串行的、`syncNow` 在冷启动和每次回前台都触发 —— 用户报的「同步转很久」就是这条。
/// ⚠️ 那些 504 **不是失败而是「白等」**：被放弃的请求照样跑完并写了对话，下一次重试拿到
/// `200 already processed`（后端幂等段），用户干等的十分钟一点用没有。
///
/// 三条不变式各自的失败方式都**静默**，所以只能扫源码钉住（这两个文件里没有可注入的接缝，
/// 为一行命名参数搭一套 HTTP mock 也不划算）：
///
/// 1. 手表调用点开了这个开关 —— 忘了开，性能就悄悄退回去，功能全对。
/// 2. 客户端默认值仍是 `false` —— 默认 true 会让**每个**调用方一起拿不到转录稿。
/// 3. `uploadAudioAndCreateConversation` **不许**开 —— 它 5 秒后去 fetch 对话，而异步路径
///    在转录完成之前**根本没有对话文档**（刻意的：提前建一条会在用户时间线上挂一张无标题
///    空卡片直到转录结束）。开了它就永远走进那个「fetch 失败」的兜底分支，手机本地录音变成
///    一张空对话。
///
/// 🚨 **断言前必须剥掉注释和字符串**，否则上面这段解释里的 `deferProcessing: true` 自己就
/// 能让断言通过 —— 把真参数删掉照样绿。见 `helpers/source_stripper.dart`。
void main() {
  String stripped(String path) => stripCommentsAndStrings(File(path).readAsStringSync());

  /// 从 `uploadAudioForConversation(` 到它的 `);` 之间那段参数列表。
  String argsOf(String src, {int from = 0}) {
    final callAt = src.indexOf('uploadAudioForConversation(', from);
    expect(callAt, greaterThan(-1), reason: '找不到上传调用 —— 这个测试的假设过期了');
    final close = src.indexOf(');', callAt);
    expect(close, greaterThan(callAt));
    return src.substring(callAt, close);
  }

  test('手表同步传了 deferProcessing: true', () {
    final args = argsOf(stripped('lib/services/watch_recording_service.dart'));

    expect(
      RegExp(r'deferProcessing:\s*true').hasMatch(args),
      isTrue,
      reason: '手表补传没有让后端异步处理 —— 端点会重新变成同步的 p50 69s / 最长 600s 超时，'
          '而队列串行且每次回前台都触发，用户看到的就是「同步一直在转」',
    );

    // 后端拒绝在没有云端副本的情况下提前返回（提前答应 ⇒ 手机删掉唯一那一份 ⇒ 服务端一崩
    // 录音就没了），此时会**静默降级成同步**。两行是一体的，缺一行不报错、只是白开。
    expect(
      RegExp(r'saveRecording:\s*true').hasMatch(args),
      isTrue,
      reason: 'deferProcessing 需要 saveRecording: true 才被后端接受，否则静默降级回同步',
    );
  });

  test('客户端默认值保持 false（这个 true 必须是显式的）', () {
    final src = stripped('lib/backend/http/api/audio_upload.dart');
    expect(
      RegExp(r'bool\s+deferProcessing\s*=\s*false').hasMatch(src),
      isTrue,
      reason: 'uploadAudioForConversation 的 deferProcessing 默认值不再是 false —— '
          '默认异步会让每个调用方都拿到空转录稿',
    );
  });

  test('uploadAudioAndCreateConversation 不开异步（它要的就是同步结果）', () {
    // 这个文件里只有一处 `uploadAudioForConversation(` 调用，就在那个包装函数里；参数声明
    // 写作 `bool deferProcessing = false`、透传写作 `deferProcessing.toString()`，两者都不
    // 是 `deferProcessing:` 这个形状，所以命名参数的出现只可能来自调用点。
    final src = stripped('lib/backend/http/api/audio_upload.dart');
    expect(
      RegExp(r'deferProcessing:').hasMatch(src),
      isFalse,
      reason: 'uploadAudioAndCreateConversation 开了异步 —— 它 5 秒后 fetch 对话，而异步路径'
          '那时还没有对话文档，手机本地录音会变成一张空对话卡',
    );
  });

  test('按后端返回的 status 分支，不是无条件当成「已转录」', () {
    final src = stripped('lib/services/watch_recording_service.dart');

    // 后端在两种情形下会静默降级成同步（`save_recording=false`、GCS 落盘失败），老后端更
    // 是完全不认这个参数 —— 所以「走的是哪条路」只能问返回值要，不能从我们传了什么去推断。
    expect(
      RegExp(r'resp\.status\s*==').hasMatch(src),
      isTrue,
      reason: '没有读后端返回的 status —— 从「我们传了 deferProcessing: true」推断走了异步，'
          '在降级和老后端两种情形下都是错的',
    );

    // 而分支的两头必须落在不同的状态上：`uploaded`（服务端还在转录）和 `processed`
    // （同一个请求里已经转完）。都写成 `processed` 的话，UI 会在什么都还没转录出来的时候
    // 告诉用户「N 段已转录并生成摘要」。
    expect(
      RegExp(r'WatchItemState\.uploaded').hasMatch(src),
      isTrue,
      reason: '异步返回被当成 processed —— 那句「已转录并生成摘要」在转录开始之前就出现了',
    );
  });

  test('月度额度 429 保留文件并暂停自动重传', () {
    final src = stripped('lib/services/watch_recording_service.dart');
    expect(RegExp(r'isMonthlyQuotaResponse\(code,\s*body\)').hasMatch(src), isTrue);
    expect(RegExp(r'_pauseQuotaUntilNextMonth\(\)').hasMatch(src), isTrue);
    expect(RegExp(r'WatchSyncOutcome\.quotaBlocked').hasMatch(src), isTrue);
    expect(RegExp(r'WatchSyncOutcome\.uploadTooLarge').hasMatch(src), isTrue);
    expect(RegExp(r'ignoreQuotaPause:\s*ignoreQuotaPause').hasMatch(src), isTrue);
    expect(RegExp(r'ignoreOversizedPause:\s*ignoreOversizedPause').hasMatch(src), isTrue);
    expect(RegExp(r'_scheduleQuotaRecheck\(').hasMatch(src), isTrue);
    expect(
      WatchRecordingService.isMonthlyQuotaResponse(
        429,
        '{"detail":{"code":"monthly_cloud_transcription_allowance_exceeded","message":"changed copy"}}',
      ),
      isTrue,
    );
    expect(
      WatchRecordingService.isMonthlyQuotaResponse(429, '{"detail":"changed copy"}'),
      isFalse,
    );
    expect(
      WatchRecordingService.isMonthlyUploadTooLargeResponse(
        429,
        '{"detail":{"code":"monthly_cloud_transcription_upload_exceeds_remaining"}}',
      ),
      isTrue,
    );
  });

  test('单个超大录音不会每次前台同步都重新上传，也不掩盖本轮成功', () {
    final src = stripped('lib/services/watch_recording_service.dart');

    expect(RegExp(r'_pausedOversizedItems\(\)').hasMatch(src), isTrue);
    expect(RegExp(r'oversizedItems\.contains\(parsed\.key\)').hasMatch(src), isTrue);
    expect(RegExp(r'_pauseOversizedItemUntilNextMonth\(parsed\.key\)').hasMatch(src), isTrue);

    final uploadedOutcome = src.indexOf('if (uploaded > 0)');
    final exhaustedOutcome = src.indexOf('else if (allowanceExhausted)');
    final quotaOutcome = src.indexOf('else if (quotaBlocked > 0)');
    expect(uploadedOutcome, greaterThan(-1));
    expect(exhaustedOutcome, greaterThan(uploadedOutcome), reason: '有成功上传时不能被本轮额度耗尽掩盖');
    expect(quotaOutcome, greaterThan(exhaustedOutcome), reason: '有成功上传时不能误报为本月额度已用完');
    expect(
      src.indexOf('outcome = WatchSyncOutcome.uploadTooLarge'),
      greaterThan(quotaOutcome),
      reason: '单文件放不下必须与整月额度耗尽使用不同结果',
    );

    final fileCheck = src.indexOf('file.existsSync()');
    final oversizedSkip = src.indexOf('oversizedItems.contains(parsed.key)');
    expect(fileCheck, greaterThan(-1));
    expect(oversizedSkip, greaterThan(fileCheck), reason: '已删除文件不能重新产生等待上传的幽灵条目');
    expect(RegExp(r'Timer\?\s+_quotaTimer').hasMatch(src), isTrue, reason: '月初复查必须与网络重试使用独立 timer');
  });
}
