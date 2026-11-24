import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/utils/enums.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/source_stripper.dart';

/// 录音中 socket 意外断开时的收尾：**不结束会话、清掉过期缓冲、让 keepalive 重连**。
///
/// ## 改这块的理由（2026-08-22）
///
/// 原来的分支是「停掉录音 + POST /process + `return` 跳过 keepalive」，判据只认
/// `RecordingState.record`，把 BLE 的 `deviceRecord` 漏在外面。三处都有问题：
///
/// 1. **`return` 让录音彻底死掉。** `PureSocket.onDone` 只往上抛 `onClosed`，自己不重连
///    （内部 `_reconnect()` 只由网络状态变化触发），keepalive 是唯一恢复途径。跳过它之后
///    音频继续往已关闭的 socket 灌，而 `PureSocket.send` 在非 connected 时静默丢弃 ——
///    「UI 显示在录，一个字都不出」。
/// 2. **那次 POST 多余且抢锁。** 后端 WS 的 `finally` 里 `_locked_finalize()` 已经把剩余
///    段落交给 `_auto_process_conversation` 归档，客户端再 POST 是跟它抢同一把 Redis 锁。
/// 3. **缓冲必须清。** 重连是一条**新** session，后端每个 session 时间戳都从 0 归零。不清
///    的话新段落带着 0 起的轴接在 `end=250` 的旧段落后面（时间标签往回跳），而且用户点
///    「结束」时旧+新会一起提交给新 session_id —— 新 session 没 marker、dedup 拦不住，
///    旧那批就在第二条对话里重复出现。
///
/// 这些错法的共同点是**不报错**：要么静默丢音频，要么静默产出重复内容。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('真行为：onClosed 的四种情形', () {
    late CaptureProvider provider;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();
      provider = CaptureProvider();
    });

    tearDown(() {
      // onClosed 会排一个 15s 的 keepalive Timer，dispose 里负责取消它。
      provider.dispose();
    });

    /// 造一批「已经录了一会儿」的段落，时间轴推到 end=250s。
    void seedSegments(CaptureProvider p) {
      p.segments = [
        for (var i = 0; i < 5; i++)
          TranscriptSegment(
            id: 'old$i',
            text: '旧会话第 $i 句',
            speaker: 'SPEAKER_00',
            isUser: false,
            personId: null,
            start: i * 50.0,
            end: i * 50.0 + 50,
            translations: const [],
          ),
      ];
      p.hasTranscripts = true;
    }

    test('🚨 BLE 设备录音中断开：缓冲清掉，但录音状态保持（不许把录音停掉）', () {
      provider.updateRecordingState(RecordingState.deviceRecord);
      seedSegments(provider);

      provider.onClosed(1006); // 1006 = abnormal closure，网络掉线的典型码

      expect(provider.segments, isEmpty,
          reason: '过期会话缓冲没清 —— 新 session 的段落会带着 0 起的时间轴接在旧段落后面，'
              '而且点「结束」时旧那批会被重复提交');
      expect(provider.hasTranscripts, isFalse);
      expect(provider.recordingState, RecordingState.deviceRecord,
          reason: '录音状态被改掉了 —— 一旦翻成 stop，会话时钟被清、首页波纹变灰，'
              '而 BLE 那头其实还在发音频');
    });

    test('🚨 手机麦录音中断开：同样不再翻成 stop（原来会，且跳过 keepalive）', () {
      provider.updateRecordingState(RecordingState.record);
      seedSegments(provider);

      provider.onClosed(1006);

      expect(provider.recordingState, RecordingState.record,
          reason: '翻成 stop 之后 mic 仍在跑但 keepalive 被跳过，音频灌进死 socket');
      expect(provider.segments, isEmpty);
    });

    for (final code in [1011, 1013]) {
      for (final state in [RecordingState.record, RecordingState.deviceRecord]) {
        test('Soniox service close $code keeps $state active for existing reconnection', () {
          provider.updateRecordingState(state);
          seedSegments(provider);

          provider.onClosed(code);

          expect(provider.recordingState, state);
          expect(provider.segments, isEmpty);
          expect(provider.hasTranscripts, isFalse);
        });
      }
    }

    test('我们自己停的录音不算意外断开（停止路径先置 stop 再关 socket）', () {
      // `stopStreamRecording` / `stopStreamDeviceRecording` 刻意在 `_socket.stop()` 之前
      // 就把状态置成 stop，这条顺序就是用来分辨「谁关的」。
      provider.updateRecordingState(RecordingState.stop);
      seedSegments(provider);

      provider.onClosed(1000); // 1000 = normal closure

      expect(provider.segments, hasLength(5),
          reason: '主动停止时不该动缓冲 —— 那是调用方接着要读的东西');
      expect(provider.recordingState, RecordingState.stop);
    });

    test('4002（额度用尽）走原有分支，不清缓冲', () {
      provider.updateRecordingState(RecordingState.deviceRecord);
      seedSegments(provider);

      provider.onClosed(4002);

      expect(provider.segments, hasLength(5),
          reason: '4002 是计费侧关的，段落要留着让用户看到已经录到的内容');
    });

    test('重复触发是幂等的（keepalive 重连时 pool 会再关一次旧 socket）', () {
      // 网络掉线的真实时序会调到两次 onClosed：先是 onDone，15s 后 keepalive 走
      // `SocketServicePool.socket()`，它建新 socket 前又 `await _socket?.stop()` 一次。
      provider.updateRecordingState(RecordingState.deviceRecord);
      seedSegments(provider);

      provider.onClosed(1006);
      provider.onClosed(1006);

      expect(provider.segments, isEmpty);
      expect(provider.recordingState, RecordingState.deviceRecord);
    });
  });

  // ── 接线：只能扫源码的两条 ────────────────────────────────────
  //
  // ⚠️ 断言前必须剥注释：这次改动的注释里就写着 `_isProcessingConversation`、
  // `forceProcessingCurrentConversation`、`_isMidRecordingSession` 这些字样，不剥的话
  // 把真代码删掉照样绿（见 helpers/source_stripper.dart）。
  group('接线', () {
    late String src;

    setUpAll(() {
      src = stripCommentsAndStrings(
        File('lib/providers/capture_provider.dart').readAsStringSync(),
      );
    });

    test('🚨 意外断开那一支不结束会话、不早退（keepalive 是唯一恢复途径）', () {
      final body = functionBody(src, 'void onClosed')!;

      expect(body.contains('forceProcessingCurrentConversation'), isFalse,
          reason: '客户端又开始自己 POST /process 了 —— 后端 finally 的 _locked_finalize '
              '已经归档过，这次 POST 只会跟它抢同一把 Redis 锁');
      expect(body.contains('_startKeepAliveServices()'), isTrue);

      // 三段的先后顺序：意外断开 → 手机麦收尾 → keepalive。
      final unexpectedAt = body.indexOf('!_isProcessingConversation');
      final micFinishAt =
          body.indexOf('_isProcessingConversation && recordingState == RecordingState.record');
      final keepAliveAt = body.indexOf('_startKeepAliveServices()');
      expect(unexpectedAt, greaterThan(-1), reason: '意外断开的判据没了');
      expect(micFinishAt, greaterThan(unexpectedAt), reason: '手机麦收尾必须排在意外断开之后');
      expect(keepAliveAt, greaterThan(micFinishAt));

      // 意外断开那一支只清缓冲：不许早退（否则录音静默死掉），也不许改录音状态
      // （设备那头还在发音频）。
      final unexpectedBranch = body.substring(unexpectedAt, micFinishAt);
      expect(unexpectedBranch.contains('_resetSessionBufferSync()'), isTrue,
          reason: '必须走同步版复位 —— _resetStateVariables 是 async，裸调它「能同步跑完」'
              '只是因为体内恰好没有 await，加一个就会晚于 keepalive 排的重连');
      expect(unexpectedBranch.contains('return'), isFalse,
          reason: '早退回来了 —— PureSocket 的 onDone 自己不重连，keepalive 是唯一恢复途径，'
              '跳过它就是「UI 显示在录，音频灌进死 socket」');
      expect(unexpectedBranch.contains('updateRecordingState'), isFalse,
          reason: '意外断开不该改录音状态 —— 翻成 stop 会清掉会话时钟、波纹变灰，'
              '而设备那头还在发音频');
    });

    test('🚨 手机麦被我们自己关掉时收尾，不让 keepalive 续起来', () {
      // 两条路径语义相反，这个不对称是刻意的：设备是 always-on，「结束」结的是这一段对话；
      // 手机麦是用户显式发起的一次录音，「结束」就是要停。而 `LiveCapturePage._stop()` 只调
      // `forceProcessingCurrentConversation()`（不改状态、不停 mic），`stopStreamRecording()`
      // 全 lib 无调用者 —— 所以这一支是手机麦唯一的收尾。少了它：状态停在 record、15s 后
      // keepalive 按 `recordingState == record` 重建新 WS，mic 接着灌，用户点完「结束」还会
      // 静默录出第二条对话，且没有任何界面能停它。
      final body = functionBody(src, 'void onClosed')!;

      final micFinishAt =
          body.indexOf('_isProcessingConversation && recordingState == RecordingState.record');
      expect(micFinishAt, greaterThan(-1),
          reason: '手机麦收尾那一支没了 —— 按「结束」之后录音停不下来');

      final branch = body.substring(micFinishAt);
      expect(branch.contains('updateRecordingState(RecordingState.stop)'), isTrue,
          reason: '状态没置 stop —— 首页波纹继续红、会话时钟继续走');
      expect(branch.indexOf('return'), greaterThan(-1),
          reason: '没早退 —— keepalive 会把这条已经结束的手机麦录音续成新 session');
      expect(branch.indexOf('return'), lessThan(branch.indexOf('_startKeepAliveServices()')),
          reason: 'return 必须排在 keepalive 之前才拦得住它');

      // 判据不能换成 havingRecordingDevice：BLE 连着但用户拨了「这次用手机录」时
      // `_recordingDevice` 仍非空，只有 recordingState 如实反映当前采集源。
      expect(body.contains('havingRecordingDevice'), isFalse,
          reason: '判据换成设备存在性了 —— 「BLE 连着但用手机录」那种会判错');
    });

    test('意外断开的判据带上了 in-flight 标志，且清缓冲排在 keepalive 之前', () {
      final body = functionBody(src, 'void onClosed')!;

      final guardAt = body.indexOf('_isMidRecordingSession');
      expect(guardAt, greaterThan(-1), reason: '判据必须覆盖 record 和 deviceRecord 两种录音态');
      expect(body.contains('_isProcessingConversation'), isTrue,
          reason: '没排掉「我们自己关的」—— forceProcessingCurrentConversation 全程不改'
              '状态，只能靠它的 in-flight 标志分辨，漏掉会在用户点「结束」时提前清掉 _conversation');

      final resetAt = body.indexOf('_resetSessionBufferSync()');
      final keepAliveAt = body.indexOf('_startKeepAliveServices()');
      expect(resetAt, greaterThan(guardAt), reason: '清缓冲必须在守卫之内');
      expect(keepAliveAt, greaterThan(resetAt), reason: '顺序反了的话重连会带着过期缓冲跑');
    });

    test('🚨 keepalive 重连按「当前采集源的编码」，不按「有没有 BLE 设备」', () {
      // BLE 连着但用户拨了「这次用手机麦克风录」时 `_recordingDevice` 仍非空，按设备存在性
      // 选就会拿 opus 建会话而 mic 灌 pcm16 —— 后端按 opus 解码 pcm16，转录为空或乱码，
      // 零错误日志。以前这条路很难走到（手机麦意外断线时直接停录音、不启 keepalive），
      // 「意外断开只清缓冲 + 无条件 keepalive」之后它成了常规路径，所以必须一起改。
      final body = functionBody(src, '_startKeepAliveServices')!;

      final micAt = body.indexOf('recordingState == RecordingState.record');
      final deviceAt = body.indexOf('_recordingDevice != null');
      expect(micAt, greaterThan(-1),
          reason: '重连不看采集源了 —— 混合配置（BLE 连着 + 用手机麦录）会用设备编码建会话');
      expect(deviceAt, greaterThan(-1), reason: '找不到设备分支，假设过期了');
      expect(micAt, lessThan(deviceAt),
          reason: '设备存在性又排到前面了 —— 那正是用错编码的判据：BLE 连着时 '
              '`_recordingDevice` 恒非空，哪怕当前在用手机麦录');

      // 手机麦那一支必须显式给 pcm16/16k，跟 streamRecording 配的一致。
      expect(body.contains('BleAudioCodec.pcm16'), isTrue);
      expect(body.contains('sampleRate: 16000'), isTrue);

      // 🚨 判据不能换成 `_currentAudioCodec`：它停止录音时从不清空，是「上一次用过的编码」
      // 而不是「当前采集源」。先用手机麦录过一次、之后设备连上而 streamAudioToWs 还没跑到
      // 时，它会拿陈旧的 pcm16 给一台 opus 设备建会话 —— 同一个错的反方向。
      expect(body.contains('_currentAudioCodec'), isFalse,
          reason: '用上了「上一次用过的编码」—— 设备会话可能被建成 pcm16');
    });

    test('录音中途重连不回填 in-progress 会话（否则把刚归档的那批捞回来）', () {
      final body = functionBody(src, '_initiateWebsocket')!;

      expect(body.contains('!_isMidRecordingSession'), isTrue,
          reason: '中途重连又去查 in_progress 了 —— create_conversation 先写 '
              '`status: "in_progress"` 才 finish，那个窗口里查到的正是刚归档的上一批段落，'
              '捞回来就等着被重复提交');

      // 守卫的另一半不能丢：本地有段落时别用服务端快照覆盖。
      expect(body.contains('segments.isEmpty'), isTrue);
    });

    test('_isMidRecordingSession 不含 !isPaused（暂停时会话并没结束）', () {
      // 用 isRecording 做判据会让暂停期间的一次重连被当成首次建连去回填服务端快照。
      //
      // ⚠️ 这里不能用 `functionBody`：它按「参数列表的 `)` 之后紧跟 `{`」找声明，而 getter
      // 压根没有参数列表，`=>` 形式也不支持 —— 会从别处的括号起算截出无关代码。getter 到
      // 分号结束，直接截。
      const sig = 'bool get _isMidRecordingSession';
      final at = src.indexOf(sig);
      expect(at, greaterThan(-1), reason: '找不到 $sig —— 改名了就把这个测试一起改');
      final body = src.substring(at, src.indexOf(';', at));

      expect(body.contains('isPaused'), isFalse,
          reason: '掺进 isPaused 了 —— 那就等于复用 isRecording，暂停时判据会翻转');
      expect(body.contains('RecordingState.record'), isTrue);
      expect(body.contains('RecordingState.deviceRecord'), isTrue);
    });
  });
}
