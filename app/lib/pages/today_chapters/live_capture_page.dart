import 'dart:async';

import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/pages/today_chapters/speaker_mark_page.dart';
import 'package:memorion/pages/today_chapters/widgets/jxb_gradient_background.dart';
import 'package:memorion/pages/today_chapters/widgets/transcript_common.dart';
import 'package:memorion/providers/audio_input_device_provider.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/providers/recording_source_provider.dart';
import 'package:memorion/services/audio_input_device_service.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/enums.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// P-06 实时采集·进行中（记小宝 1.0 浅色改版，Figma v2.4 node 486:727）。
///
/// ✅ 全真数据（复用 CaptureProvider，与 P-12 同 `TranscriptSegment` model）：
/// - 实时转写：`CaptureProvider.segments`（socket 实时累加）
/// - 录音状态：`recordingState`(record/deviceRecord=录音中) + `isPaused`
/// - 累计时长：UI 层按 segment.end / 墙钟自算（同旧 capturing page）
/// - 底部：累计时长 + 声波动画（去掉无意义进度条）
/// - 顶部：麦克风选择器（AVAudioSession 输入路由：内置麦 / 蓝牙耳机 / 有线耳机）。
///   ⚠️ **不是**「用哪个设备录音」，Memorion BLE 硬件从来不出现在这个列表里。用哪个设备
///   录已经不需要选了（2026-08-19 取消三选一，见 `RecordingSourceProvider` 类注释）：
///   连着设备就用设备，没连接就用手机。唯一的例外是「设置 → 录音设备」里那个
///   「仅本次用手机麦克风录」。
class LiveCapturePage extends StatefulWidget {
  const LiveCapturePage({super.key});

  @override
  State<LiveCapturePage> createState() => _LiveCapturePageState();
}

/// 实时页顶部/底部那个累计时长（秒）：`max(会话时钟, 最大 segment.end)`。
///
/// ⚠️ **起点不能是「进本页那一刻」。** 以前这里拿 `initState` 里的
/// `_startWall = DateTime.now()` 当墙钟起点，而 always-on 录音下用户随时点进来看 ——
/// 已经录了 40 分钟的会话在这里从 00:00 起走，看着就像进页面重开了一段。这一条独立于
/// 那个真会重开会话的根因（见 `CaptureProvider._startSegmentTimeout` 的注释）：**根因修
/// 掉之后它仍然是错的**，因为 always-on 录音的起点本来就早于用户点进来的时刻。
///
/// 真正的会话起点只有 `CaptureProvider._sessionStartedAt` 知道：它由
/// `updateRecordingState` 在每次状态变更时维护、只在 stop/error 清空、前后台都覆盖得到，
/// 而且 `recordedDuration` 已经替我们扣掉了暂停时长。
///
/// `segEnd` 留作下限：回填进来的段落时间轴比会话时钟更能反映「后端认到哪儿了」。
///
/// 提成顶层函数只为可测：State 的私有方法没法真跑断言，而这条计算的每一种错法
/// （少一支、取错 max 方向、null 当 0 之外的值）都只是显示一个假数字、不会报错。
/// 见 `test/live_capture_session_clock_test.dart`。
int liveCaptureElapsedSeconds({
  required Duration? recorded,
  required List<TranscriptSegment> segments,
}) {
  double segEnd = 0;
  for (final s in segments) {
    if (s.end > segEnd) segEnd = s.end;
  }
  final recordedSeconds = recorded?.inSeconds ?? 0;
  return segEnd > recordedSeconds ? segEnd.floor() : recordedSeconds;
}

/// 实时采集页三态：初始化中 / 录音中 / 已暂停。
enum _CapturePhase { initializing, recording, paused }

class _LiveCapturePageState extends State<LiveCapturePage> {
  Timer? _timer;
  RecordingState? _prePauseState;

  /// 「初始化中」窗口期标记：initState 触发采集启动后、`recordingState`
  /// 尚未翻到 record/deviceRecord 之间为 true。用它把进入页面到真正开始
  /// 录音之间的过渡态与「用户主动暂停」区分开（详见三态判定 _phase）。
  bool _initializing = false;

  /// 启动兜底超时：即使 streamRecording/streamDeviceRecording 卡住或失败，
  /// 也不让 UI 永远停在「正在初始化…」。
  Timer? _initTimeout;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // 兜底：若进入本页时未在录音（其它入口忘调 streamRecording），
    // 按 BLE 状态启动一次采集，避免出现「已暂停」且 socket 未建立。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final capture = context.read<CaptureProvider>();
      if (capture.recordingState == RecordingState.stop) {
        // 进入「初始化中」窗口期：启动前置 true，启动结束（成功/异常/超时）翻 false。
        setState(() => _initializing = true);
        _initTimeout = Timer(const Duration(seconds: 20), () {
          if (mounted) setState(() => _initializing = false);
        });
        final device = context.read<DeviceProvider>();
        final srcProvider = context.read<RecordingSourceProvider>();
        try {
          // 连着 BLE 就用 BLE，否则用手机 —— 唯一的例外是用户拨了「这次用手机录」
          // （设备在包里没戴上时要的就是它）。这里**没有持久化偏好可读**，2026-08-19
          // 取消了那个三选一，理由见 `RecordingSourceProvider` 的类注释。
          final source = srcProvider.resolve(
            bleConnected: device.canStreamAudio,
          );
          if (source == RecordingSource.bleDevice) {
            if (!await capture.streamDeviceRecording(device: device.connectedDevice)) {
              throw PlatformException(code: 'recording_busy');
            }
          } else {
            await capture.streamRecording();
          }
          // 采集已经起来了才清那个一次性开关。放在 `finally` 里是错的：启动抛异常时用户
          // 还没录上，开关得留着让他重试。
          srcProvider.consumeForcePhoneOnce();
        } catch (error) {
          debugPrint('Live capture startup failed: $error');
          if (mounted) {
            final permissionDenied = error is PlatformException && error.code == 'microphone_permission';
            UndoDeleteHost.showMessage(context, revampText(context,
                  en: permissionDenied
                      ? 'Allow microphone access for Memorion in Settings before recording.'
                      : 'Recording could not start. Please try again.',
                  zh: permissionDenied ? '请在系统设置中允许 Memorion 使用麦克风后再录音。' : '录音未能开始，请重试。'));
          }
        } finally {
          _initTimeout?.cancel();
          if (mounted) setState(() => _initializing = false);
        }
      }
      // 已经在录的那一支刻意什么都不做：本页只是个观察窗口，转录从
      // `CaptureProvider.segments` 直接读（那个缓冲在整条 BLE 连接期间持续累积 ——
      // 客户端不再每 120s 把它清一次，见 `CaptureProvider._startSegmentTimeout`）。
      //
      // 🚨 **别在这里「补拉一次 in-progress 转录」。** 这条看着很自然，但前提不成立：
      // 直播会话进行中后端**没有** in-progress 对话 —— `create_conversation` 只在归档时
      // （`_auto_process_conversation` / `_do_process_conversation`）被调，App 也不在录音
      // 开始时建（`POST /v1/conversations` 那个调用点是 `processInProgressConversation`
      // 里「没有段落」的兜底）。所以 `getConversations(in_progress, limit: 1)` 这一刻只可能
      // 捞到**上一条正在归档的**会话（`create_conversation` 先写 `status: "in_progress"`
      // 才 `finish_conversation`，中间有个窗口），而它不按 session 过滤。捞回来的后果是：
      // 另一套 id、另一条从 0 起的时间轴被 append 进当前缓冲（时间标签错乱），点「结束」时
      // 随新 session_id 重复提交，`_openSpeakerSheet` 的 PATCH 还会打到那条已归档的对话上。
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _initTimeout?.cancel();
    super.dispose();
  }

  /// 三态判定：初始化中 / 录音中 / 已暂停。
  ///
  /// - 初始化中：启动已触发（`_initializing`）但 `recordingState` 尚未翻到
  ///   record/deviceRecord —— 即「进入页面到真正开始录音之间的窗口期」。
  /// - 录音中：record/deviceRecord 且未暂停（复用 `CaptureProvider.isRecording`）。
  /// - 已暂停：record/deviceRecord 且 `isPaused`（用户主动点过暂停）。
  _CapturePhase _phase(CaptureProvider p) {
    final active = p.recordingState == RecordingState.record || p.recordingState == RecordingState.deviceRecord;
    if (_initializing && !active) return _CapturePhase.initializing;
    if (active && p.isPaused) return _CapturePhase.paused;
    if (active) return _CapturePhase.recording;
    // 兜底：非上述任一（如启动失败停在 stop）—— 归为初始化中的「等待」文案，
    // 避免误显示「已暂停」。
    return _initializing ? _CapturePhase.initializing : _CapturePhase.paused;
  }

  int _elapsedSeconds(CaptureProvider p) =>
      liveCaptureElapsedSeconds(recorded: p.recordedDuration, segments: p.segments);

  String _fmtElapsed(int s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '${two(h)}:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary, surface: JXB.surface),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: JxbGradientBackground(
            child: SafeArea(
              child: Consumer<CaptureProvider>(
                builder: (context, p, _) {
                  final segments = p.segments;
                  final labels = speakerLabels(context, segments);
                  final colorIndex = speakerColorIndex(segments);
                  final phase = _phase(p);
                  final recording = phase == _CapturePhase.recording;
                  final elapsed = _fmtElapsed(_elapsedSeconds(p));
                  return Column(
                    children: [
                      _topBar(context, p, phase),
                      Expanded(
                        child: segments.isEmpty
                            ? _waiting(context, phase)
                            : _transcriptList(context, p, segments, labels, colorIndex, recording, elapsed),
                      ),
                      _bottomBar(context, p, phase, elapsed),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 顶栏：← / 实时记录·进行中 / 设备选择 ─────────────────────
  Widget _topBar(BuildContext context, CaptureProvider p, _CapturePhase phase) {
    final String title;
    switch (phase) {
      case _CapturePhase.initializing:
        title = revampText(context, en: 'Live Recording · Initializing', zh: '实时记录 · 初始化中');
        break;
      case _CapturePhase.paused:
        title = revampText(context, en: 'Live Recording · Paused', zh: '实时记录 · 已暂停');
        break;
      case _CapturePhase.recording:
        title = revampText(context, en: 'Live Recording · In Progress', zh: '实时记录 · 进行中');
        break;
    }
    return SizedBox(
      height: 68,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _circleBtn(Icons.chevron_left_rounded, () => Navigator.of(context).maybePop()),
            Expanded(
              child: Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: JXB.textSecondary)),
            ),
            // 麦克风选择器（AVAudioSession 输入路由）—— 浅色弹窗
            Builder(
              builder: (btnCtx) => _circleBtn(
                Icons.headset_mic_outlined,
                () => _showDevicePicker(btnCtx),
              ),
            ),
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
        child: Icon(icon, size: 22, color: JXB.textPrimary),
      ),
    );
  }

  /// 浅色麦克风选择器：从耳麦按钮下方弹出，切 AVAudioSession 的输入路由
  /// （内置麦 / 蓝牙耳机 / 有线耳机 / 外接）。
  void _showDevicePicker(BuildContext btnCtx) {
    final box = btnCtx.findRenderObject() as RenderBox;
    final overlay = Overlay.of(btnCtx).context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
    const w = 240.0;
    final left = (pos.dx + box.size.width - w).clamp(12.0, overlay.size.width - w - 12);
    final top = pos.dy + box.size.height + 8;
    final audioProvider = btnCtx.read<AudioInputDeviceProvider>();

    showDialog(
      context: btnCtx,
      barrierColor: Colors.transparent,
      builder: (dialogCtx) => ChangeNotifierProvider<AudioInputDeviceProvider>.value(
        value: audioProvider,
        child: Stack(
          children: [
            Positioned.fill(
                child: GestureDetector(
                    onTap: () => Navigator.pop(dialogCtx), child: const ColoredBox(color: Color(0x0A000000)))),
            Positioned(
              top: top,
              left: left,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: w,
                  decoration: BoxDecoration(
                    color: JXB.surface,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const [BoxShadow(color: Color(0x1F264D78), blurRadius: 24, offset: Offset(0, 8))],
                  ),
                  child: Consumer<AudioInputDeviceProvider>(
                    builder: (context, provider, _) {
                      final devices = provider.availableDevices;
                      final selected = provider.selectedDevice;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                            // ⚠️ 这个列表来自 `ios/Runner/AudioInputService.swift:42
                            // getAvailableInputs()`（AVAudioSession 的输入路由：内置麦 /
                            // 蓝牙耳机 / 有线耳机 / 外接），**Memorion BLE 硬件从来不在里面**。
                            // 原来的「音频来源 / Audio Source」在暗示这里能切录音设备，
                            // 而「用哪个设备录」已经不需要选了（连着就用设备，没连接就用
                            // 手机；见 `RecordingSourceProvider` 类注释）。
                            child: Text(revampText(context, en: 'Microphone', zh: '麦克风'),
                                style: const TextStyle(
                                    fontFamily: JXB.fontSans,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: JXB.textSecondary)),
                          ),
                          for (final d in devices)
                            _deviceRow(d, selected?.id == d.id, () {
                              provider.switchDevice(d);
                              Navigator.pop(dialogCtx);
                            }),
                          const SizedBox(height: 8),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceRow(AudioInputDevice device, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: device.isConnected ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: device.isConnected ? 1 : 0.4,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0x14007AFF) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontFamily: JXB.fontSans,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: JXB.textPrimary)),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle, color: device.isConnected ? JXB.success : JXB.textPlaceholder)),
                        const SizedBox(width: 5),
                        Text(
                          device.isConnected
                              ? (device.type == AudioInputDeviceType.phone
                                  ? revampText(context, en: 'Built-in', zh: '手机内置')
                                  : revampText(context, en: 'Bluetooth connected', zh: '蓝牙已连接'))
                              : revampText(context, en: 'Not connected', zh: '未连接'),
                          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 11, color: JXB.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? JXB.brandPrimary : Colors.transparent,
                  border: selected ? null : Border.all(color: JXB.textPlaceholder, width: 1.5),
                ),
                child: selected ? const Icon(Icons.check_rounded, size: 11, color: Colors.white) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 转写列表 ────────────────────────────────────────────────
  //
  // ⚠️ **用 `ListView.builder`，别退回 `ListView(children: [...])`。**
  // 段落在一次 BLE 连接期间只增不减：后端每 120s 静音切一条对话，但它**不给 App 推任何
  // 事件**（下行只有 transcript / ready / error / complete 四种），所以本地缓冲没有随之
  // 清空的时机，always-on 一天下来能累到上千段。
  //
  // 差别**不在**挂载：`ListView(children:)` 走 `SliverChildListDelegate`，同样只 mount
  // 可见的那十几个 element（这一点实测过 —— 400 段两种写法都只挂 4 行，所以 widget 测试
  // 里数 `TranscriptSegmentRow` 的个数**区分不了**两者，别拿它当护栏）。差别在每一帧都要
  // 先把 N 个 Widget 对象构造出来才能交给 delegate，而这个页面带一个每秒 `setState` 的
  // 计时器 ⇒ 上千段就是每秒上千次无用分配。builder 只构造可见的那几个。
  //
  // 那为什么不在客户端按静音清掉本地缓冲：用户手动点「结束」时
  // `forceProcessingCurrentConversation()` 会把本地 `segments` 提交给
  // POST /v1/conversations/process，而那个请求会写 `app_processed_conversation_id`
  // ——后端见到这个 marker 会让整个 session 让路（见 `developer_listen.py`
  // `_flush_conversation` 的注释）。清早了就等于用一个缺段的快照顶掉后端手里的完整缓冲。
  // 累积是显示层的代价，丢段是数据层的代价，两者不对等。
  Widget _transcriptList(BuildContext context, CaptureProvider p, List<TranscriptSegment> segments,
      Map<int, String> labels, Map<int, int> colorIndex, bool recording, String elapsed) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 96),
      // index 0 是表头（红点 + 时长 + 说话人一排），其余每个 index 一段转写。
      itemCount: segments.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 「正在记录」红点 + 时长
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      _RecDot(active: recording),
                      const SizedBox(width: 8),
                      Text(
                          recording
                              ? revampText(context, en: 'Recording', zh: '正在记录')
                              : revampText(context, en: 'Paused', zh: '已暂停'),
                          style: const TextStyle(
                              fontFamily: JXB.fontSans,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: JXB.textPrimary)),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(60)),
                    child: Text(elapsed,
                        style: const TextStyle(fontFamily: JXB.fontNumber, fontSize: 13, color: JXB.textSecondary)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SpeakersRow(
                labels: labels,
                colorIndex: colorIndex,
                onTapSpeaker: (sid) => _openSpeakerSheet(context, p, sid),
                // 录音中时，最后一条 segment 的说话人头像呼吸闪烁（谁在说话）。
                activeSpeakerId: recording && segments.isNotEmpty ? segments.last.speakerId : null,
              ),
              const SizedBox(height: 14),
            ],
          );
        }

        final i = index - 1;
        final isLastSegment = i == segments.length - 1;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TranscriptSegmentRow(
              name: labels[segments[i].speakerId] ??
                  revampText(context, en: 'Speaker ${segments[i].speakerId}', zh: '说话人 ${segments[i].speakerId}'),
              color: kSpeakerColors[(colorIndex[segments[i].speakerId] ?? 0) % kSpeakerColors.length].$1,
              time: fmtSpeakerTimestamp(segments[i].start),
              text: segments[i].text.trim(),
              onTapName: () => _openSpeakerSheet(context, p, segments[i].speakerId),
              isLast: isLastSegment && recording,
            ),
            if (!isLastSegment)
              Container(height: 1, color: JXB.border, margin: const EdgeInsets.symmetric(vertical: 14)),
          ],
        );
      },
    );
  }

  Widget _waiting(BuildContext context, _CapturePhase phase) {
    final String text;
    switch (phase) {
      case _CapturePhase.initializing:
        text = revampText(context, en: 'Initializing…', zh: '正在初始化…');
        break;
      case _CapturePhase.recording:
        text = revampText(context, en: 'Listening, go ahead and speak…', zh: '正在聆听，开始说话吧…');
        break;
      case _CapturePhase.paused:
        text = revampText(context, en: 'Recording paused', zh: '录音已暂停');
        break;
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RecDot(active: phase == _CapturePhase.recording),
          const SizedBox(height: 16),
          Text(text, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, color: JXB.textSecondary)),
        ],
      ),
    );
  }

  // ── 底栏：累计时长 + 暂停/继续 + 停止 ───────────────────────
  Widget _bottomBar(BuildContext context, CaptureProvider p, _CapturePhase phase, String elapsed) {
    // 初始化中：采集尚未真正开始，暂停/继续无意义 → 禁用（置灰、不响应）。
    final initializing = phase == _CapturePhase.initializing;
    final String statusLabel;
    switch (phase) {
      case _CapturePhase.initializing:
        statusLabel = revampText(context, en: 'Initializing', zh: '初始化中');
        break;
      case _CapturePhase.paused:
        statusLabel = revampText(context, en: 'Paused', zh: '已暂停');
        break;
      case _CapturePhase.recording:
        statusLabel = revampText(context, en: 'Recording', zh: '录音中');
        break;
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 4, 16, MediaQuery.of(context).padding.bottom + 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 累计时长
          Text('$statusLabel · $elapsed',
              style: const TextStyle(
                  fontFamily: JXB.fontNumber, fontSize: 14, fontWeight: FontWeight.w600, color: JXB.textSecondary)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 暂停/继续（初始化中禁用）
              _controlButton(
                icon: p.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                label: p.isPaused
                    ? revampText(context, en: 'Resume', zh: '继续')
                    : revampText(context, en: 'Pause', zh: '暂停'),
                fg: JXB.brandPrimary,
                bg: const Color(0x14007AFF),
                enabled: !initializing,
                onTap: () => _togglePause(p),
              ),
              const SizedBox(width: 16),
              // 停止 → 结束并处理
              _controlButton(
                icon: Icons.stop_rounded,
                label: revampText(context, en: 'Stop', zh: '结束'),
                fg: JXB.error,
                bg: const Color(0x14E55247),
                onTap: () => _stop(context, p),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controlButton(
      {required IconData icon,
      required String label,
      required Color fg,
      required Color bg,
      required VoidCallback onTap,
      bool enabled = true}) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Icon(icon, size: 28, color: fg),
            ),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w500, color: fg)),
          ],
        ),
      ),
    );
  }

  Future<void> _togglePause(CaptureProvider p) async {
    if (p.isPaused) {
      if (_prePauseState == RecordingState.deviceRecord) {
        await p.resumeDeviceRecording();
      } else {
        await p.resumeMicRecording();
      }
      _prePauseState = null;
    } else {
      _prePauseState = p.recordingState;
      if (p.recordingState == RecordingState.deviceRecord) {
        await p.pauseDeviceRecording();
      } else {
        await p.pauseMicRecording();
      }
    }
  }

  Future<void> _stop(BuildContext context, CaptureProvider p) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => _StopConfirmDialog(),
    );
    if (ok != true || !context.mounted) return;
    p.forceProcessingCurrentConversation();
    Navigator.of(context).maybePop();
  }

  /// 点说话人（头像/名字）→ 与「完整原文」一致，弹「标记说话人」大卡片。
  /// 实时录音早期后端尚未创建会话（无 conversation / id 为空）时无法分配，
  /// 给出提示、待会话生成后再操作（优雅降级）。
  Future<void> _openSpeakerSheet(BuildContext context, CaptureProvider p, int speakerId) async {
    final ServerConversation? conversation = p.inProgressConversation;
    if (conversation == null || conversation.id.isEmpty) {
      UndoDeleteHost.showMessage(context, revampText(context, en: 'You can assign speakers after the conversation is created', zh: '会话生成后可分配说话人'));
      return;
    }
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SpeakerMarkSheet(conversation: conversation, speakerId: speakerId),
    );
  }
}

/// 结束记录确认弹框（统一浅色卡片风格：圆角卡 + 图标 + 胶囊按钮）。
class _StopConfirmDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Dialog(
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
              decoration: const BoxDecoration(color: Color(0x14FF3B30), shape: BoxShape.circle),
              child: const Icon(Icons.stop_rounded, size: 30, color: JXB.error),
            ),
            const SizedBox(height: 16),
            Text(revampText(context, en: 'End this recording?', zh: '结束这段记录？'),
                style: const TextStyle(
                    fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            const SizedBox(height: 8),
            Text(
                revampText(context,
                    en: "Once you stop, I'll organize this conversation and create chapters for you.",
                    zh: '结束后我会整理这段对话，为你生成章节。'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context, false),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration:
                          BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(999)),
                      child: Text(revampText(context, en: 'Keep recording', zh: '继续记录'),
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
                    onTap: () => Navigator.pop(context, true),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
                      child: Text(revampText(context, en: 'Stop', zh: '结束'),
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
    );
  }
}

/// 「正在记录」红点（录音中脉冲）。
class _RecDot extends StatefulWidget {
  final bool active;
  const _RecDot({required this.active});

  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.active ? JXB.error : JXB.textPlaceholder;
    if (!widget.active) {
      return Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Opacity(
        opacity: 0.4 + 0.6 * _c.value,
        child: Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      ),
    );
  }
}
