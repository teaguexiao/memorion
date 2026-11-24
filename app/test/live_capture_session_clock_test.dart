import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/pages/today_chapters/live_capture_page.dart';
import 'package:memorion/pages/today_chapters/widgets/transcript_common.dart';
import 'package:memorion/providers/audio_input_device_provider.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/providers/recording_source_provider.dart';
import 'package:memorion/utils/enums.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/source_stripper.dart';

/// 钉住「DevKit1 连着就一直在实时转录，点进实时页只是打开一个观察窗口」。
///
/// ## 排查记录（2026-08-22）
///
/// 用户报「首页波纹是红的（在录），但点进实时页录音像重新初始化了：时间从 0 开始、显示
/// 『正在聆听，开始说话吧』」。页面本身是清白的 —— `LiveCapturePage.initState` 有
/// `if (recordingState == RecordingState.stop)` 守卫，BLE 场景走不进去，采集没被重启。
///
/// 真正的重开发生在点进去**之前**，由三件事叠出来：
///
/// 1. **根因**：`CaptureProvider._startSegmentTimeout` 这条客户端 120s 静音定时器会调
///    `forceProcessingCurrentConversation()`，而它第一件事是 `_socket.stop()`、接着
///    `_resetStateVariables()` 清空 `segments`。它与后端
///    `developer_listen.py:1108 _flush_conversation()` 完全重复，但后端那条**不关连接**
///    （只交出当前 batch 然后继续跑，注释写明「is SUPPOSED to fire repeatedly」）。
///    `recordingState` 全程停在 `deviceRecord`，所以首页波纹照红 —— 状态和事实脱钩了。
/// 2. **段落不回填**：`refreshInProgressConversations()` 在此之前**全仓库零调用者**，所以
///    本地缓冲空掉之后没人去后端把已有转录拉回来。
/// 3. **计时起点错**：`_startWall = DateTime.now()` 取的是进页面那一刻。
///
/// 三条各自都只是「显示一个假数字/假空态」，全链路零错误日志。而 1 还额外丢音频：那 15s
/// 空窗（keepalive 退避后最长 120s）里 BLE 帧照旧灌给已关闭的 socket，`PureSocket.send`
/// 静默丢弃，DevKit1 没有卡 ⇒ 永久丢失。
///
/// ⚠️ 三条必须一起钉。只修根因的话，App 冷启动 / 被系统挂起过之后本地缓冲照样是空的
/// （第 2 条），而 always-on 录音的起点本来就早于用户点进来的时刻（第 3 条）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── 真行为：累计时长的计算 ────────────────────────────────────
  group('累计时长取 max(会话时钟, 最大 segment.end)', () {
    List<TranscriptSegment> segs(List<double> ends) => [
          for (final e in ends)
            TranscriptSegment(
              id: 's$e',
              text: 'x',
              speaker: 'SPEAKER_00',
              isUser: false,
              personId: null,
              start: 0,
              end: e,
              translations: const [],
            ),
        ];

    test('没有段落时完全由会话时钟决定', () {
      // 这是修复的核心场景：录了 40 分钟、本地缓冲被清空、用户此刻点进来。旧实现在这里
      // 返回 0（墙钟起点 = 进页面那一刻），于是页面显示 00:00 起走。
      expect(
        liveCaptureElapsedSeconds(recorded: const Duration(minutes: 40), segments: const []),
        2400,
      );
    });

    test('段落时间轴更靠后时取它（后端认到哪儿了）', () {
      expect(
        liveCaptureElapsedSeconds(recorded: const Duration(seconds: 10), segments: segs([3, 42.7, 12])),
        42,
        reason: '要取最大的 end，不是最后一个；且向下取整',
      );
    });

    test('会话时钟更靠后时取它', () {
      expect(
        liveCaptureElapsedSeconds(recorded: const Duration(seconds: 90), segments: segs([12.5])),
        90,
        reason: '静音期间段落不再增长，但录音仍在继续 —— 时长不能停在最后一句话上',
      );
    });

    test('没在录音（时钟为 null）时按 0 起算，不抛', () {
      expect(liveCaptureElapsedSeconds(recorded: null, segments: const []), 0);
      expect(
        liveCaptureElapsedSeconds(recorded: null, segments: segs([7.9])),
        7,
        reason: '时钟没了但段落还在（刚停止那一帧），仍应显示段落时长',
      );
    });
  });

  // ── 真行为：会话时钟本身 ──────────────────────────────────────
  group('会话时钟的真相源是 CaptureProvider，与任何 UI 时刻无关', () {
    late CaptureProvider provider;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();
      provider = CaptureProvider();
    });

    test('没在录音时为 null，进入 deviceRecord 后开始走', () {
      expect(provider.recordedDuration, isNull);
      provider.updateRecordingState(RecordingState.deviceRecord);
      expect(provider.recordedDuration, isNotNull);
    });

    test('🚨 时钟起点早于「打开页面」那一刻 —— 这正是旧实现丢掉的信息', () async {
      // 模拟 always-on：设备先连上开始录，用户过一会儿才点进实时页。
      provider.updateRecordingState(RecordingState.deviceRecord);
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      final recorded = provider.recordedDuration!;
      expect(recorded.inMilliseconds, greaterThanOrEqualTo(1200),
          reason: '时钟必须从状态置位那一刻起算');

      // 此刻「打开页面」：页面读到的秒数应当已经非 0。旧实现在这里必然是 0，因为它的
      // 起点就是这一行的 DateTime.now()。
      expect(
        liveCaptureElapsedSeconds(recorded: recorded, segments: const []),
        greaterThanOrEqualTo(1),
        reason: '进页面时时长从 0 起走 —— 用户会读成「录音被重开了」',
      );
    });

    test('重复进入 deviceRecord 不会把起点往后挪（keepalive 重连、状态重推）', () async {
      provider.updateRecordingState(RecordingState.deviceRecord);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      provider.updateRecordingState(RecordingState.deviceRecord);
      expect(provider.recordedDuration!.inMilliseconds, greaterThanOrEqualTo(600),
          reason: '起点被重置了 —— 长录音的时长会每次状态重推就归零');
    });

    test('stop 才清时钟', () {
      provider.updateRecordingState(RecordingState.deviceRecord);
      provider.updateRecordingState(RecordingState.stop);
      expect(provider.recordedDuration, isNull);
    });
  });

  // ── 真行为：整页渲染 ──────────────────────────────────────────
  group('LiveCapturePage 真实渲染', () {
    /// 拖起页面需要四个 Provider。`CaptureProvider` 能直接实例化（构造函数只读一次
    /// SharedPreferences 并挂个网络监听），所以这一组是真跑的，不是扫源码。
    ///
    /// `takeException()` 是兜底：这一支（已经在录）现在不发任何网络请求，但 `Env` 在测试
    /// 环境下没初始化，将来若有人往 initState 里加请求会在这里炸出来 —— 兜住它比让整组
    /// 测试红得莫名其妙好。
    Future<CaptureProvider> pumpPage(
      WidgetTester tester, {
      required List<TranscriptSegment> segments,
      Duration? warmup,
    }) async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();

      final capture = CaptureProvider();
      // 设备录音已经在跑（BLE 连上时 DeviceProvider 就启动了采集）——这一步同时把会话
      // 时钟起点定在"现在"，正是 initState 的 `stop` 守卫要放行的状态。
      capture.updateRecordingState(RecordingState.deviceRecord);
      if (warmup != null) {
        // 真等一小会儿，让会话时钟走到 warmup 之后才"打开页面"。fake async 的
        // `tester.pump(d)` 推不动 `DateTime.now()`，所以必须 runAsync。
        await tester.runAsync(() => Future<void>.delayed(warmup));
      }
      capture.segments = segments;

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<CaptureProvider>.value(value: capture),
          ChangeNotifierProvider<DeviceProvider>(create: (_) => DeviceProvider()),
          ChangeNotifierProvider<RecordingSourceProvider>(create: (_) => RecordingSourceProvider()),
          ChangeNotifierProvider<AudioInputDeviceProvider>(create: (_) => AudioInputDeviceProvider()),
        ],
        child: const MaterialApp(home: LiveCapturePage()),
      ));
      tester.takeException();
      await tester.pump();
      return capture;
    }

    /// 卸载页面（让 `_timer` 在 dispose 里取消）并放掉网络监听那个一次性 10s timer，
    /// 否则 flutter_test 会报「A Timer is still pending」。
    Future<void> teardownPage(WidgetTester tester, CaptureProvider capture) async {
      await tester.pumpWidget(const SizedBox.shrink());
      capture.dispose();
      await tester.pump(const Duration(seconds: 11));
    }

    testWidgets('🚨 已经录了一会儿再点进来，时长不从 00:00 起走', (tester) async {
      // 用户报的正是这一幕：波纹红着（在录），点进去"时间从 0 开始"。segments 故意留空
      // —— 本地缓冲被清空/尚未回填时页面走的就是「正在聆听」那条空态分支。
      final capture = await pumpPage(
        tester,
        segments: const [],
        warmup: const Duration(milliseconds: 1200),
      );

      expect(find.textContaining('· 00:00'), findsNothing,
          reason: '底栏时长仍从 00:00 起走 —— 说明起点又变回「进页面那一刻」了');
      expect(find.textContaining('· 00:0'), findsOneWidget,
          reason: '应当显示已录到的秒数（00:01 起）');

      await teardownPage(tester, capture);
    });

    testWidgets('400 段能正常渲染，且只挂载可见的那几行', (tester) async {
      // 段落在一次连接期间只增不减（后端切分不通知 App），所以这个页面必须扛得住上千段。
      // 这条测的是「渲染不崩 + 懒挂载」。
      //
      // ⚠️ **它区分不了 `ListView` 和 `ListView.builder`** —— 变异验证时逮到了：把整个
      // `_transcriptList` 换成全量 `ListView(children: [...])`，这条断言照样绿（400 段仍
      // 然只挂 4 行）。因为 `SliverChildListDelegate` 本身就是懒挂载的，两种写法的差别只
      // 在「每帧要先构造多少个 Widget 对象」，而那个开销在 widget 树里不可观察。
      // 真正钉住 builder 的是下面接线组里那条源码断言。
      final capture = await pumpPage(
        tester,
        segments: [
          for (var i = 0; i < 400; i++)
            TranscriptSegment(
              id: 's$i',
              text: 'line $i',
              speaker: 'SPEAKER_00',
              isUser: false,
              personId: null,
              start: i.toDouble(),
              end: i + 1.0,
              translations: const [],
            ),
        ],
      );

      final built = find.byType(TranscriptSegmentRow).evaluate().length;
      expect(built, greaterThan(0), reason: '一行都没渲染出来，页面挂了');
      expect(built, lessThan(50),
          reason: '挂载了 $built/400 行 —— 列表变成了非懒挂载（注意这不等于退回全量 '
              'ListView，那种退化只有源码断言逮得到，见本测试上方注释）');

      await teardownPage(tester, capture);
    });
  });

  // ── 接线：只能扫源码的几条 ────────────────────────────────────
  //
  // ⚠️ 断言前必须剥掉注释和字符串：本次改动写进代码的解释性注释里就有
  // `havingRecordingDevice`、`refreshInProgressConversations`、`_startWall` 这些字样，
  // 不剥的话把真代码删掉照样绿（理由见 helpers/source_stripper.dart）。
  group('接线', () {
    late String captureProvider;
    late String page;

    setUpAll(() {
      String read(String p) => stripCommentsAndStrings(File(p).readAsStringSync());
      captureProvider = read('lib/providers/capture_provider.dart');
      page = read('lib/pages/today_chapters/live_capture_page.dart');
    });

    test('🚨 有录音设备时不启动客户端 120s 静音定时器', () {
      final body = functionBody(captureProvider, '_startSegmentTimeout');
      expect(body, isNotNull, reason: '找不到 _startSegmentTimeout —— 改名了就把这个测试一起改');

      final gateAt = body!.indexOf('havingRecordingDevice');
      expect(gateAt, greaterThan(-1),
          reason: '设备录音的 gate 没了 —— DevKit1 每静音 120s 就会自己关掉 WS 并清空 '
              'segments，那 15s 空窗里的 BLE 音频静默丢失且不可恢复');

      final returnAt = body.indexOf('return', gateAt);
      expect(returnAt, greaterThan(gateAt), reason: 'gate 后面没有 return，等于没 gate');

      final timerAt = body.indexOf('Timer.periodic');
      expect(timerAt, greaterThan(-1), reason: '找不到定时器，这个测试的假设过期了');
      expect(returnAt, lessThan(timerAt),
          reason: '早退必须排在 Timer.periodic 之前 —— 排在后面的话定时器已经挂上去了');
    });

    test('gate 的判据不是 recordingState（那样会漏掉整条设备路径）', () {
      // `_startSegmentTimeout` 由 `_initiateWebsocket` 调用，而设备路径上置 `deviceRecord`
      // 的 `_initiateDeviceAudioStreaming()` 排在 `_ensureDeviceSocketConnection()` 之后
      // —— 走到这里时 recordingState 还是上一个值。用它做判据的话 gate 恒不命中，而这种
      // 失败是静默的：定时器照旧挂上，120s 后照旧关 WS。
      final body = functionBody(captureProvider, '_startSegmentTimeout')!;
      expect(body.contains('RecordingState.deviceRecord'), isFalse,
          reason: '判据必须是 havingRecordingDevice；此处 recordingState 尚未置位');

      // 顺带钉住那个顺序本身 —— 它是上面这条判据的前提。
      //
      // ⚠️ 签名要带上返回类型：`functionBody` 按 `indexOf` 找名字，而 `_resetState` 是
      // `_resetStateVariables` 的前缀，光给名字会截到后者的函数体（它的
      // `({bool clearPhotos = false}) async {` 同样满足「参数列表后紧跟 async」）。
      final resetState = functionBody(captureProvider, 'Future<void> _resetState')!;
      final ensureSocket = resetState.indexOf('_ensureDeviceSocketConnection');
      final initStreaming = resetState.indexOf('_initiateDeviceAudioStreaming');
      expect(ensureSocket, greaterThan(-1));
      expect(initStreaming, greaterThan(ensureSocket),
          reason: '顺序反了的话上面那条判据的理由就不成立了，请一起复核');
    });

    test('🚨 进页面不去补拉 in-progress 转录（那会捞回上一条正在归档的会话）', () {
      // 这一条是「反向」不变式：曾经在 else 分支加过一次 `refreshInProgressConversations()`，
      // 想法是「本地缓冲空掉时补显示」，但前提不成立 —— 直播会话进行中后端**没有**
      // in-progress 对话（`create_conversation` 只在归档时被调，App 也不在录音开始时建）。
      // 于是那一刻只可能捞到上一条正在归档的会话（create 先写 in_progress 才 finish），
      // 而 `getConversations` 不按 session 过滤：另一套 id、另一条 0 起的时间轴被 append
      // 进当前缓冲，点「结束」时随新 session_id 重复提交，`_openSpeakerSheet` 的 PATCH
      // 还会打到那条已归档的对话上。
      //
      // 转录本来就不需要补：客户端不再每 120s 清缓冲之后，`CaptureProvider.segments` 在
      // 整条 BLE 连接期间持续累积，页面直接读它就够了。
      final initState = functionBody(page, 'void initState')!;

      expect(initState.contains('refreshInProgressConversations'), isFalse,
          reason: '进页面又去查 in-progress 了 —— 会把上一条正在归档的会话捞进当前缓冲');
      expect(initState.contains('_loadInProgressConversation'), isFalse, reason: '同上');

      // 守卫本身不能丢：它是「点进来不重开会话」的唯一保障。
      expect(initState.contains('RecordingState.stop'), isTrue,
          reason: 'stop 守卫没了 —— 每次进页面都会重启采集，那才真是用户报的现象');
      expect(initState.contains('streamDeviceRecording'), isTrue,
          reason: '找不到启动采集的分支，假设过期了');
    });

    test('refreshInProgressConversations 内部 await 了，调用方才拿得到落地信号', () {
      final body = functionBody(captureProvider, 'refreshInProgressConversations')!;
      expect(body.contains('await _loadInProgressConversation'), isTrue,
          reason: 'fire-and-forget 的话 await 它会在 segments 还没落地时就返回，'
              '调用方紧接着读到的仍是空的');
    });

    test('段落列表用 ListView.builder', () {
      // 🚨 **这是唯一能逮到「退回全量 ListView」的判据。** 上面那条 widget 测试看着像在
      // 管这件事，其实不管：`ListView(children: [...])` 同样只挂载可见 element，400 段
      // 照样只挂 4 行（变异验证时确认过）。两者的差别是每帧构造多少个 Widget 对象，而那
      // 在 widget 树里不可观察 —— 只能从源码形态上钉。
      //
      // 段落只增不减是本次修复的直接后果（客户端不再按静音清本地缓冲，见
      // `CaptureProvider._startSegmentTimeout`），所以这个约束不能随手退回去。
      //
      // ⚠️ 这条断言依赖 `page` 已经剥过注释：`_transcriptList` 的注释里就写着
      // `ListView.builder` 这几个字，不剥的话把代码换成全量 ListView 照样绿。
      expect(page.contains('ListView.builder'), isTrue,
          reason: '退回全量 ListView 了 —— 上千段时每秒都要重造上千个 Widget 对象');
    });

    test('页面不再自己拿「进页面时刻」当计时起点', () {
      expect(page.contains('_startWall'), isFalse,
          reason: '墙钟起点回来了 —— always-on 录音会在页面上从 00:00 重新起走');
      expect(page.contains('liveCaptureElapsedSeconds'), isTrue);

      // 时长必须来自 Provider 的会话时钟，而不是页面自己数。
      //
      // ⚠️ 这里不用 `functionBody('_elapsedSeconds')`：那个 helper 按大括号配平截函数体，
      // 而 `_elapsedSeconds` 现在是 `=>` 箭头形式 —— 它会从箭头之后的**下一个** `{` 起算，
      // 截出别的函数（第一版就这么误报了）。直接钉转发的实参更准。
      expect(page.contains('recorded: p.recordedDuration'), isTrue,
          reason: '时长的真相源必须是 CaptureProvider 的会话时钟（与锁屏卡片同一个源）');
    });
  });
}
