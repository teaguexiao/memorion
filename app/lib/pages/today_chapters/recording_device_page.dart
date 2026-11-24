import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:flutter/material.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/providers/recording_source_provider.dart';
import 'package:memorion/services/watch_recording_service.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// P-30R 录音设备（设置 →「录音与识别」→ 录音设备）。
///
/// 🚫 **这一页不再是选择器（2026-08-19）。** 它是**状态 + 说明**：所有支持的方式各自现在可不
/// 可用、以及各自怎么开始。取消三选一的完整理由见 `RecordingSourceProvider` 的类注释与
/// `docs/architecture/录音源与转录路径设计.md` §3.2 —— 一句话是：那个单选把三个性质不同
/// 的东西并列了，而每一条的触发动作本身已经表达了选择。
///
/// 每种设备始终展示，连接状态只更新对应行。页面须写清不同链路：
/// - 手机 / BLE 硬件：实时转录（WS `/v1/listen`），边录边出字。
/// - Soundcore Work / DingTalk A1 / PLAUD Note：设备录音完成后同步，不占用手机实时录音入口。
/// - Apple Watch：手表本地录音 → 靠近手机自动同步 → 离线转录。**没有实时字幕**，
///   而且要在手表上按开始（手机这边点不动它 —— watchOS 不允许 iPhone 唤起手表 App 录音）。
///
/// 数据源：
/// - ✅ BLE 连接状态：`DeviceProvider.isConnected`
/// - ✅ 手表状态与待同步条数：`WatchRecordingService.getStatus()`（原生 WCSession）
/// - ✅ 「仅本次用手机录」：`RecordingSourceProvider.forcePhoneOnce`（**不持久化**）
///
/// ⚠️ **这一页藏得深从此是对的，别把它挪到首页。** 需要上首页的是「现在在不在录、谁在
/// 录」那个状态条（设计文档 §3.2），不是这一页 —— 它现在只在用户问「都支持什么方式」
/// 时才需要打开。
class RecordingDevicePage extends StatefulWidget {
  const RecordingDevicePage({super.key});

  @override
  State<RecordingDevicePage> createState() => _RecordingDevicePageState();
}

class _RecordingDevicePageState extends State<RecordingDevicePage> {
  WatchStatus? _watch;
  bool _syncing = false;
  bool _clearingRejected = false;
  String? _syncMessage;

  @override
  void initState() {
    super.initState();
    _refreshWatch();
    WatchRecordingService.instance.refreshItems();
    // 后台自动同步（收到新录音 / 自动重试）跑完时刷新这张卡。没有它的话，用户停在这一页
    // 看着「手机上有 1 段待上传」，而那一段其实早就传完了 —— 看起来像卡住了。
    WatchRecordingService.instance.onQueueChanged = () {
      if (mounted) _refreshWatch();
    };
    // 逐段进度：每段开始上传/传完都会来一次，只重画，不去重新轮询原生状态
    // （轮询那条路带最多 4 轮重试，按每段两三次调它就是几十次多余的 channel 调用）。
    WatchRecordingService.instance.onItemsChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    WatchRecordingService.instance.onQueueChanged = null;
    WatchRecordingService.instance.onItemsChanged = null;
    super.dispose();
  }

  /// 查一次手表状态；`WCSession` 还没激活完就再等一下重查。
  ///
  /// ⚠️ **重试不是「保险起见」，是必需的。** 激活是异步的（`AppDelegate` 里发起），冷启动后
  /// 立刻进这个页面拿到的是「全 false」，渲染出来是「未配对手表」—— 一个看起来很确定的
  /// 结论，让用户去配一块已经配好的表。所以没激活就不下结论，最多等 ~2s。
  Future<void> _refreshWatch({int attemptsLeft = 4}) async {
    final status = await WatchRecordingService.instance.getStatus();
    if (!mounted) return;
    setState(() => _watch = status);
    if (status.supported && !status.activated && attemptsLeft > 1) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) await _refreshWatch(attemptsLeft: attemptsLeft - 1);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _syncMessage = null;
    });
    final result = await WatchRecordingService.instance.syncNow(
      reason: 'settings page', // i18n-ignore: 日志用的触发原因，不进 UI
      // A manual retry may re-check an account whose entitlement just changed,
      // but must not re-upload every known-oversized file in the same month.
      ignoreQuotaPause: true,
    );
    await _refreshWatch();
    await WatchRecordingService.instance.refreshItems();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncMessage = _syncResultText(result);
    });
  }

  /// 清掉被后端永久拒绝的那几段。
  ///
  /// ⚠️ **删之前必须确认，而且必须说清「找不回来」。** 手表上的原件在回执那一刻就删了
  /// （`WatchSessionService.sendAck`），`rejected/` 里那一份是唯一的一份 —— 后端「搬而不删」
  /// 留的正是这个后悔的机会（那种 400 也可能来自我们自己的 bug，比如某一版构建产出缺 moov
  /// 的文件）。所以这里不做「点一下就删」。
  Future<void> _clearRejected(int count) async {
    final ok = await _confirmClear(count);
    if (ok != true) return;
    setState(() => _clearingRejected = true);
    final deleted = await WatchRecordingService.instance.clearRejected();
    await _refreshWatch();
    if (!mounted) return;
    setState(() {
      _clearingRejected = false;
      // 删了 0 条也要说话：`removeItem` 失败（极少见）时静默会让人以为点没生效，
      // 而下一步该做的事完全不同。
      _syncMessage = deleted > 0
          ? revampText(context, en: 'Removed $deleted recording(s)', zh: '已清掉 $deleted 段')
          : revampText(context, en: 'Nothing was removed', zh: '没有清掉任何录音');
    });
  }

  Future<bool?> _confirmClear(int count) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
          decoration: BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [BoxShadow(color: Color(0x1F264D78), blurRadius: 30, offset: Offset(0, 12))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(revampText(ctx, en: 'Remove $count recording(s)?', zh: '清掉这 $count 段录音？'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 18, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              const SizedBox(height: 8),
              Text(
                  revampText(ctx,
                      en:
                          'These couldn\'t be transcribed and won\'t be retried. The audio is only on this phone — once removed it can\'t be recovered.',
                      zh: '这几段没能转录，也不会再重试。音频只存在这台手机上，清掉之后找不回来。'),
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, height: 1.5, color: JXB.textSecondary)),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx, false),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 46,
                        alignment: Alignment.center,
                        decoration:
                            BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(ctx, en: 'Keep', zh: '先留着'),
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
                      onTap: () => Navigator.pop(ctx, true),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 46,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: JXB.error, borderRadius: BorderRadius.circular(999)),
                        child: Text(revampText(ctx, en: 'Remove', zh: '清掉'),
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
      ),
    );
  }

  /// 把一次同步的结果翻译成一句话。
  ///
  /// ⚠️ **判据必须落在 `outcome` 上，不能只看传成功几条。** 这里原来的写法是「0 条 = 同步
  /// 失败，稍后会自动重试」，而 0 条有四种完全不同的原因：已经有一轮在传、鉴权还没就绪、
  /// 队列本来就是空的、真的传失败了。前三种都不是失败，而其中「已经在传了」是用户连点两下
  /// 就能撞上的最常见那一种 —— 于是一个**成功**的同步会当场报「同步失败」。用户报的
  /// 「有时候会提示同步失败」有一半是这个，另一半是后端 `language=multi` 那个真故障
  /// （见 `uploadAudioForConversation` 的 `language` 注释）。
  String? _syncResultText(WatchSyncResult result) {
    switch (result.outcome) {
      case WatchSyncOutcome.uploaded:
        return revampText(context, en: 'Synced ${result.uploaded} recording(s)', zh: '已同步 ${result.uploaded} 段录音');
      case WatchSyncOutcome.busy:
        return revampText(context, en: 'Already syncing…', zh: '正在同步中…');
      case WatchSyncOutcome.notAuthenticated:
        return revampText(context, en: 'Signing in — will sync automatically', zh: '正在登录，稍后会自动同步');
      case WatchSyncOutcome.retryable:
        return revampText(context,
            en: '${result.retryable} recording(s) didn\'t go through, retrying automatically',
            zh: '有 ${result.retryable} 段没传成功，稍后会自动重试');
      case WatchSyncOutcome.quotaBlocked:
        return revampText(context,
            en: 'Cloud transcription allowance used — recordings are safely kept', // i18n-ignore: revampText 双语文案
            zh: '本月云端转录额度已用完，录音已安全保留');
      case WatchSyncOutcome.uploadTooLarge:
        return revampText(context,
            en: 'Some recordings need more allowance — they are safely kept', // i18n-ignore: revampText 双语文案
            zh: '部分录音超过剩余额度，已安全保留');
      case WatchSyncOutcome.rejected:
        // 刻意不出文案：卡片里「N 段无法转录」那一行已经说了这件事，这里再说一遍只会
        // 让用户以为是两回事。
        return null;
      case WatchSyncOutcome.empty:
        return revampText(context, en: 'Nothing to sync', zh: '没有待同步的录音');
      case WatchSyncOutcome.unsupported:
        return revampText(context, en: 'Not available on this phone', zh: '此手机不支持');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: JXB.bgApp,
          body: SafeArea(
            child: Column(
              children: [
                _detailBar(context),
                Expanded(child: _body(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailBar(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                  width: 36, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary)),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Recording Device', zh: '录音设备'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            const SizedBox(width: 36),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final srcProvider = context.watch<RecordingSourceProvider>();
    final bleConnected = context.select<DeviceProvider, bool>((d) => d.canStreamAudio);
    final connectedType =
        context.select<DeviceProvider, DeviceType?>((d) => d.isConnected ? d.connectedDevice?.type : null);
    final watch = _watch;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        _sectionLabel(revampText(context, en: 'Ways to record', zh: '支持的录音方式')),
        const SizedBox(height: 10),
        _card([
          // Keep the product catalog independent of the connected device.
          // Legacy live-audio adapters remain in the existing Memorion hardware family.
          _hardwareSourceRow(context, DeviceType.memorion, connected: bleConnected),
          _divider(),
          _hardwareSourceRow(context, DeviceType.soundcore, connected: connectedType == DeviceType.soundcore),
          _divider(),
          _hardwareSourceRow(context, DeviceType.dingtalkA1, connected: connectedType == DeviceType.dingtalkA1),
          _divider(),
          _hardwareSourceRow(context, DeviceType.plaudNote, connected: connectedType == DeviceType.plaudNote),
          _divider(),
          _hardwareSourceRow(context, DeviceType.chipletRing, connected: connectedType == DeviceType.chipletRing),
          _divider(),
          _sourceRow(
            id: 'recording_source_phone',
            emoji: '📱',
            leading: const Icon(Icons.smartphone_rounded, size: 32),
            title: revampText(context, en: 'Phone microphone', zh: '手机麦克风'),
            subtitle: revampText(context,
                en: 'Used when no live-audio device is connected. Tap the wave button on the home screen to start.',
                zh: '没有连接实时录音设备时用它。点首页顶部的声波按钮开始。'),
            status: null,
          ),
          _divider(),
          _sourceRow(
            id: 'recording_source_watch',
            emoji: '⌚️',
            leading: const Icon(Icons.watch_outlined, size: 32),
            title: revampText(context, en: 'Apple Watch', zh: 'Apple Watch'), // i18n-ignore: 产品名，中英一致
            subtitle: revampText(context,
                en: 'Start on your watch or from its Memorion complication. Recording continues where watchOS permits; calls and Siri can interrupt it. Audio syncs to iPhone for processing, with no live captions.',
                zh: '在手表 App 或 Memorion 表盘组件上开始录音。系统允许时会继续录制，来电和 Siri 可能打断。音频同步到手机后处理，没有实时字幕。'),
            status: _watchStatusText(watch),
          ),
        ]),
        const SizedBox(height: 14),
        // ⚠️ 这段是**告知**，不是操作说明的省略版。取消三选一之后（2026-08-19，见
        // `RecordingSourceProvider` 类注释）这一页不再有「选哪个」，用户需要知道的是
        // 「什么时候会用哪个」，否则他会来这里找那个已经不存在的开关。
        Text(
          revampText(context,
              en: 'Each device has its own way to record. Live-audio devices provide live captions while connected. Soundcore Work, DingTalk A1 and PLAUD Note sync completed recordings. Start phone recordings on the home screen and watch recordings on the watch.',
              zh: '各设备按自己的方式开始录音：实时录音设备连接后提供字幕；安克录音豆、钉钉 A1 和 PLAUD Note 同步已完成的录音。手机录音从首页开始，手表录音在手表上开始。'),
          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, height: 1.55, color: JXB.textPlaceholder),
        ),
        // 「这次用手机录」只在设备连着时才有意义 —— 没连接时本来就是手机在录，摆一个
        // 恒等于当前行为的开关只会让人以为它有别的作用。
        if (bleConnected) ...[
          const SizedBox(height: 22),
          _sectionLabel(revampText(context, en: 'Just this once', zh: '仅本次')),
          const SizedBox(height: 10),
          _card([_forcePhoneRow(context, srcProvider)]),
        ],
        if (watch != null && watch.supported) ...[
          const SizedBox(height: 22),
          _sectionLabel(revampText(context, en: 'Watch recordings', zh: '手表上的录音')),
          const SizedBox(height: 10),
          _watchSyncCard(watch),
          const SizedBox(height: 10),
          _card([
            Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(revampText(context, en: 'Quick recording entry', zh: '快捷录音入口'),
                        style: const TextStyle(
                            fontFamily: JXB.fontSans, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                    const SizedBox(height: 8),
                    Text(
                        revampText(context,
                            en:
                                'Long-press your watch face → Edit → Complications → Memorion. A tap opens the app and starts recording. You can also add Memorion to the Smart Stack.',
                            zh: '长按表盘 → 编辑 → 复杂功能 → Memorion。轻点即可打开 App 并开始录音，也可把 Memorion 加入智能叠放。'),
                        style: const TextStyle(
                            fontFamily: JXB.fontSans, fontSize: 13, height: 1.5, color: JXB.textSecondary)),
                    const SizedBox(height: 12),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      title: Text(revampText(context, en: 'Pinch shortcut setup', zh: '捏合快捷入口设置'),
                          style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPrimary)),
                      children: [
                        Text(
                            revampText(context,
                                en:
                                    '1. Install and open Memorion on your watch, and allow microphone access.\n2. In iPhone Shortcuts, create a shortcut using Memorion → Start recording, then enable Show on Apple Watch. Run it on your watch first.\n3. On your watch, open Settings → Accessibility → AssistiveTouch → Hand Gestures. Assign Pinch to that Siri shortcut. Use your AssistiveTouch activation gesture before pinching.',
                                zh:
                                    '1. 在手表上安装并打开 Memorion，允许使用麦克风。\n2. 在 iPhone「快捷指令」中，用 Memorion →「开始录音」创建指令，开启「在 Apple Watch 上显示」，先在手表运行一次。\n3. 在手表「设置」→「辅助功能」→ AssistiveTouch →「手势」中，把「捏合」绑定到这条 Siri 快捷指令。捏合前，先用设置的激活手势启用 AssistiveTouch。'),
                            style: const TextStyle(
                                fontFamily: JXB.fontSans, fontSize: 13, height: 1.5, color: JXB.textSecondary)),
                        const SizedBox(height: 8),
                        Text(
                            revampText(context,
                                en:
                                    'These settings are managed by watchOS and must be configured manually. Enabling AssistiveTouch disables the system double-tap gesture.',
                                zh: '这些系统设置需手动配置。开启 AssistiveTouch 后，系统双指互点手势会停用。'),
                            style: const TextStyle(
                                fontFamily: JXB.fontSans, fontSize: 12, height: 1.5, color: JXB.textSecondary)),
                      ],
                    ),
                  ],
                ))
          ]),
        ],
      ],
    );
  }

  Widget _hardwareSourceRow(BuildContext context, DeviceType type, {required bool connected}) {
    final artwork = switch (type) {
      DeviceType.memorion => 'assets/images/memorion-v1.webp',
      DeviceType.openglass ||
      DeviceType.frame ||
      DeviceType.soundcore ||
      DeviceType.dingtalkA1 ||
      DeviceType.plaudNote ||
      DeviceType.chipletRing =>
        null,
    };
    final title = switch (type) {
      DeviceType.memorion ||
      DeviceType.openglass ||
      DeviceType.frame =>
        revampText(context, en: 'Memorion device', zh: 'Memorion 硬件'),
      DeviceType.soundcore => revampText(context, en: 'Soundcore Work', zh: '安克录音豆 · Soundcore Work'),
      DeviceType.dingtalkA1 => revampText(context, en: 'DingTalk A1', zh: '钉钉 A1'),
      DeviceType.chipletRing => 'ChipletRing', // i18n-ignore: Product name.
      DeviceType.plaudNote => 'PLAUD Note', // i18n-ignore: Product name.
    };
    final subtitle = switch (type) {
      DeviceType.chipletRing => revampText(context,
          en: 'Open Device → Ring recordings to record and sync audio while connected.',
          zh: '连接后，在「设备 → 戒指录音」中开始录音和同步音频。'),
      DeviceType.plaudNote => revampText(context,
          en: 'Use the Note button to record. Completed recordings sync automatically while connected.',
          zh: '通过 Note 按键录音，连接后自动同步已完成的录音。'),
      DeviceType.soundcore => revampText(context,
          en: 'Use the recorder button. Completed recordings sync automatically while connected.',
          zh: '通过设备按键录音，连接后自动同步已完成的录音。'),
      DeviceType.dingtalkA1 => revampText(context,
          en: 'Use the recorder button or Device → Recordings. Sync completed recordings there; automatic sync is optional.',
          zh: '通过设备按键或「设备 → 设备录音」录音，结束后在该页面同步，也可开启自动同步。'),
      DeviceType.memorion || DeviceType.openglass || DeviceType.frame => revampText(context,
          en: 'Records whenever it is connected. Live captions while you record.', // i18n-ignore: Bilingual via revampText.
          zh: '连上就在记录，边录边出实时字幕。'),
    };
    return _sourceRow(
      id: type == DeviceType.memorion ? 'recording_source_ble' : 'recording_source_${type.name}',
      emoji: type == DeviceType.chipletRing
          ? '💍'
          : type == DeviceType.frame || type == DeviceType.openglass
              ? '👓'
              : '🎙️',
      leading: artwork == null ? null : _productIcon(artwork),
      title: title,
      subtitle: subtitle,
      status: connected
          ? revampText(context, en: 'Connected', zh: '已连接')
          : revampText(context, en: 'Not connected', zh: '未连接'),
    );
  }

  Widget _productIcon(String asset, {double size = 40}) {
    return Image.asset(asset,
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true);
  }

  /// 「这一次用手机麦克风录」。
  ///
  /// 这是原来那个三选一唯一真正解决的场景（设备连着、但落在包里没戴上）。它被保留下来，
  /// 只是降级成一次性的、不写盘的 —— 理由见 `RecordingSourceProvider.forcePhoneOnce`。
  ///
  /// ⚠️ 副文案必须写明「下一次录音之后自动关掉」。不写的话它看起来就是个普通设置项，
  /// 而用户下次戴着设备录音时发现走的是设备麦，会以为开关坏了。
  Widget _forcePhoneRow(BuildContext context, RecordingSourceProvider srcProvider) {
    final on = srcProvider.forcePhoneOnce;
    return Semantics(
      container: true,
      identifier: 'force_phone_once',
      value: on ? '1' : '0',
      child: SizedBox(
        height: 76,
        child: Row(
          children: [
            const Icon(Icons.smartphone_rounded, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(revampText(context, en: 'Use the phone microphone', zh: '用手机麦克风录'),
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                  const SizedBox(height: 3),
                  Text(
                      revampText(context,
                          en:
                              'For the next recording only, then turns itself off. Use it when the device is in your bag rather than on you.',
                          zh: '只对下一次录音生效，之后自动关掉。设备在包里没戴上时用它。'),
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 13, height: 1.45, color: JXB.textSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch.adaptive(
              value: on,
              activeTrackColor: JXB.success,
              onChanged: srcProvider.setForcePhoneOnce,
            ),
          ],
        ),
      ),
    );
  }

  /// 手表状态文案。四个布尔各自独立，**刻意不合成一句「不可用」** —— 用户要做的事完全不同：
  /// 没配表去配表、没装 App 去手表上装、只是不可达则什么都不用做（传输是排队式的）。
  String? _watchStatusText(WatchStatus? watch) {
    if (watch == null) return null; // 还在查
    if (!watch.supported) return revampText(context, en: 'Not available on this phone', zh: '此手机不支持');
    // ⚠️ 这一条必须排在 paired / appInstalled 之前：`WCSession` 没激活完时那两个都是
    // false，直接往下走会把「还没查出来」说成「未配对手表」。
    if (!watch.activated) return revampText(context, en: 'Checking…', zh: '正在检查…');
    if (!watch.paired) return revampText(context, en: 'No watch paired', zh: '未配对手表');
    if (!watch.appInstalled)
      return revampText(context,
          en: 'Install Memorion on your watch', zh: '请在手表上安装 Memorion'); // i18n-ignore: 品牌名+中文，守卫误判
    if (!watch.reachable) return revampText(context, en: 'Ready (watch not nearby)', zh: '可用（手表当前不在附近）');
    return revampText(context, en: 'Ready', zh: '可用');
  }

  Widget _watchSyncCard(WatchStatus watch) {
    final pending = watch.pendingCount;
    final items = WatchRecordingService.instance.syncItems;
    final busy = items.any((i) => i.state == WatchItemState.uploading);
    return _card([
      // ⚠️ 不要写死高度：被拒的那行是第三行，而中英文案换行数也不同 —— 固定 64 会截断，
      // 而截掉的正好是「有几段没转成」这句。
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题刻意不叫「待同步」：全传完之后那三个字就成了谎话，而这张卡在
                  // 处理完之后还要继续显示「哪几段已经生成摘要了」。
                  Text(revampText(context, en: 'Sync status', zh: '同步状态'),
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
                  const SizedBox(height: 3),
                  Text(
                    _summaryLine(items, pending, watch.rejectedCount, busy),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // ⚠️ 手动重发按钮是刻意保留的：上传失败时文件留在手机上，用户需要一个「再试一次」
            // 的动作，否则只能等下次冷启动 —— 而那看起来像录音丢了。
            GestureDetector(
              onTap: (_syncing || pending == 0) ? null : _syncNow,
              behavior: HitTestBehavior.opaque,
              child: Opacity(
                opacity: (_syncing || pending == 0) ? 0.4 : 1,
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: JXB.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: JXB.brandPrimary, width: 1),
                  ),
                  child: Text(
                      _syncing
                          ? revampText(context, en: 'Syncing…', zh: '同步中…')
                          : revampText(context, en: 'Sync now', zh: '立即同步'),
                      style: const TextStyle(
                          fontFamily: JXB.fontSans,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: JXB.brandPrimary)),
                ),
              ),
            ),
          ],
        ),
      ),
      // 逐段明细。用户问的正是这四件事：几段、每段多长、什么时候开始录的、后端处理完没有。
      // 只给一个「N 段待上传」的计数不够 —— 上传成功后那一条就从队列里消失了，用户完全
      // 看不到中间发生过什么（「点击之后响应很久，我也不知道音频处理了没有」）。
      if (items.isNotEmpty) ...[
        _divider(),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: [for (final item in items) _segmentRow(item)]),
        ),
      ],
      // ⚠️ **这句在有段落正在处理时必须出现。** `POST /v1/conversations/upload-audio`
      // 是同步的：一个请求里做完上传 + 离线转录 + LLM 摘要才返回（生产 p50 约 10 秒，
      // 长录音更久）。不说这件事，用户看到的就是「点了同步之后卡住不动」，而实际上
      // 那段时间正是他要的结果在被算出来。
      if (busy)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              revampText(context,
                  en: 'Uploading also transcribes and summarises on the spot, so a long recording can take a while. You can leave this page — it keeps going.',
                  zh: '上传的同时后端就把转录和摘要一起做完了，所以录得长会等久一点。可以离开这一页，不会中断。'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, height: 1.5, color: JXB.textPlaceholder),
            ),
          ),
        ),
      // ⚠️ 被拒的那几段必须单独说一句总数。它们已经搬出重传队列（否则每次回前台都白传
      // 一遍，吃的是跟实时转录共享的 Soniox 额度），于是 `pending` 归零 —— 只看上面那行
      // 就会说「全部已同步」，而那几段一条对话都没生成。
      //
      // 这个数来自**磁盘**（含历史遗留），上面列表里的 `rejected` 行只有本次会话被拒的
      // 那几段，两者刻意都留着：一个是「这一段怎么了」，一个是「总共积了几段、能清掉」。
      if (watch.rejectedCount > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  revampText(context,
                      en: '${watch.rejectedCount} could not be transcribed (too short, or no speech detected)',
                      zh: '${watch.rejectedCount} 段无法转录（太短，或没检测到人说话）'),
                  style:
                      const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, height: 1.5, color: JXB.textPlaceholder),
                ),
              ),
              const SizedBox(width: 10),
              // ⚠️ **必须给用户一条出路。** 这几段永远不会再被上传（客户端把 400 当永久失败，
              // 正确），所以上面那行会一直挂在这里，而用户除了看着它没有任何可做的事 ——
              // 一个说「有问题」却不给动作的界面，比不说更难受。
              GestureDetector(
                onTap: _clearingRejected ? null : () => _clearRejected(watch.rejectedCount),
                behavior: HitTestBehavior.opaque,
                child: Text(
                  _clearingRejected
                      ? revampText(context, en: 'Removing…', zh: '正在清除…')
                      : revampText(context, en: 'Remove them', zh: '清掉这几段'),
                  style: TextStyle(
                      fontFamily: JXB.fontSans,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _clearingRejected ? JXB.textPlaceholder : JXB.error),
                ),
              ),
            ],
          ),
        ),
    ]);
  }

  /// 卡片顶部那句话。
  ///
  /// ⚠️ **正在处理时不能显示 `_syncMessage`。** 那是**上一次**同步的结果，而一次同步里
  /// 每段都会重画好几次 —— 让「已同步 2 段」压在正在跑的第 3 段上面，用户会以为已经完事了。
  String _summaryLine(List<WatchSyncItem> items, int pending, int rejectedOnDisk, bool busy) {
    if (busy) {
      final done = items.where((i) => i.state.isFinal).length;
      return revampText(context,
          en: 'Processing ${done + 1} of ${items.length}…',
          zh: '正在处理第 ${done + 1} / ${items.length} 段…'); // i18n-ignore: Bilingual via revampText.
    }
    if (_syncMessage != null) return _syncMessage!;
    if (pending > 0) {
      // 队列是自动跑的（收到就传、失败自动退避重试），所以默认文案要说「会自动上传」；
      // 那个按钮只是「不想等」时的加速手段。说成「待上传」会让用户以为不点就不会传。
      return revampText(context,
          en: '$pending recording(s) on this phone — uploading automatically', zh: '手机上有 $pending 段，会自动上传');
    }
    // ⚠️ 这两句必须分开说。`uploaded` 的转录还在服务端跑，把它算进「已转录并生成摘要」
    // 就又是一句「两句各自成立、拼出来是假的」的话（同下面那条 rejected 注释）。
    final uploaded = items.where((i) => i.state == WatchItemState.uploaded).length;
    if (uploaded > 0) {
      return revampText(context,
          en: '$uploaded recording(s) uploaded — transcribing on the server', zh: '$uploaded 段已上传，正在服务器上转录');
    }
    final processed = items.where((i) => i.state == WatchItemState.processed).length;
    if (processed > 0) {
      return revampText(context, en: '$processed recording(s) transcribed and summarised', zh: '$processed 段已转录并生成摘要');
    }
    // ⚠️ **有转不出来的段落时不许说「全部已同步」。** 实测撞到过：两段合成音被后端拒掉，
    // 列表里两行都是红色的「无法转录」，而上面这句写着「全部已同步」—— 队列的确空了，
    // 但用户读到的是「都好了」，而那两段一条对话都没生成。这正是本仓库反复出现的那类
    // 缺陷（把失败呈现成正常），只不过这次是两句各自成立的话拼出了一个假结论。
    if (rejectedOnDisk > 0 || items.any((i) => i.state == WatchItemState.rejected)) {
      return revampText(context, en: 'Nothing waiting to upload', zh: '没有待上传的录音');
    }
    return revampText(context, en: 'All recordings synced', zh: '全部已同步');
  }

  /// 一段录音一行：开始时间 · 时长 → 状态。
  Widget _segmentRow(WatchSyncItem item) {
    final (label, color) = _segmentState(item);
    return Semantics(
      container: true,
      identifier: 'watch_segment_${item.key}', // i18n-ignore: maestro 断言用的 id，不显示给用户
      value: item.state.name,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 9),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            Expanded(
              child: Text(
                // 「开始时间 · 时长」。时长解不出来显示 `--` 而不是 0 秒 —— 5 秒以下的
                // 录音在手表侧就丢掉了，这里出现 0 秒只会让人以为录空了。
                '${_clockLabel(item.startedAt)} · ${_durationLabel(item.duration)}',
                style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary),
              ),
            ),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(fontFamily: JXB.fontSans, fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }

  (String, Color) _segmentState(WatchSyncItem item) {
    switch (item.state) {
      case WatchItemState.uploading:
        // 现在真的只是上传（后端异步了，见 `WatchItemState.uploading` 的注释）。
        // ⚠️ 这行以前刻意写成「正在转录…」，因为那时转录确实发生在这个请求里；后端一改成
        // 异步，那句话就变成了假的 —— 状态机的语义变了，文案必须跟着变。
        return (revampText(context, en: 'Uploading…', zh: '正在上传…'), JXB.brandPrimary);
      case WatchItemState.uploaded:
        // ⚠️ 只说「已上传」，不说「已转录」：转录还在服务端跑，而且可能失败（详见枚举注释）。
        return (revampText(context, en: 'Uploaded', zh: '已上传'), JXB.success);
      case WatchItemState.processed:
        return (revampText(context, en: 'Done', zh: '已处理完'), JXB.success);
      case WatchItemState.rejected:
        return (revampText(context, en: 'Can\'t transcribe', zh: '无法转录'), JXB.error);
      case WatchItemState.waiting:
        if (item.preparationFailed) {
          return (revampText(context, en: 'Preparation failed; audio kept', zh: '处理失败，原录音已保留'), JXB.warning);
        }
        // 409 = 后端说「这一段我已经在转录了」（同一个时间锚点上有另一次尝试在飞，
        // 见 `audio_upload.py` 的幂等段）。它拿到了状态码，但**不是失败**：这一段正在
        // 被处理，用户什么都不用做。混进「稍后重试」会把一次正常的等待染成告警色。
        if (item.statusCode == 409) {
          return (revampText(context, en: 'Transcribing…', zh: '正在转录…'), JXB.brandPrimary);
        }
        // 上一次真失败过（拿到了状态码）跟「还没轮到它」不是一回事：前者用户可能想手动
        // 重试，后者什么都不用做。合成一句「等待中」会把一次失败藏起来。
        return item.statusCode != null
            ? (revampText(context, en: 'Will retry', zh: '稍后重试'), JXB.warning)
            : (revampText(context, en: 'Queued', zh: '等待上传'), JXB.textPlaceholder);
    }
  }

  /// 录音开始时刻。当天只显示时分，跨天带上日期 —— 手表上的录音可能在手机不在身边时
  /// 攒好几天，只显示 `09:41` 会让用户以为是今天早上的。
  String _clockLabel(DateTime t) {
    final local = t.toLocal();
    final hm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;
    return sameDay ? hm : '${local.month}/${local.day} $hm';
  }

  String _durationLabel(Duration? d) {
    if (d == null) return '--'; // 原生没解出时长。不是 0 秒。
    final total = d.inSeconds;
    if (total < 60) return revampText(context, en: '${total}s', zh: '$total 秒');
    final m = total ~/ 60;
    final s = total % 60;
    if (s == 0) return revampText(context, en: '${m}m', zh: '$m 分');
    return revampText(context, en: '${m}m ${s}s', zh: '$m 分 $s 秒');
  }

  // ── 通用行/卡 ──────────────────────────────────────────────
  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(text,
          style: const TextStyle(
              fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
    );
  }

  Widget _card(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: children),
    );
  }

  Widget _divider() => const Divider(height: 1, color: JXB.border);

  /// 单选行。
  ///
  /// ⚠️ `Semantics` 必须带 `container: true`：不带的话按 id 点会落到父级 Row 的中心，
  /// 而 maestro **依然报 success** —— 断言就白做了（见 memory
  /// `reference_simulator_ui_verification`）。`value` 用 selected 的字面量，让「选中了哪个」
  /// 可断言，而不是靠文案在不在反推。
  /// 一种录音方式的**状态与说明**。
  ///
  /// ⚠️ **刻意没有选中态、也不可点。** 2026-08-19 取消三选一之前这里是一行 radio，而那个
  /// 单选把三个性质不同的东西并列了（见 `RecordingSourceProvider` 类注释）。留着一个不可
  /// 点的 radio 图标会更糟 —— 用户会一直点它。
  Widget _sourceRow({
    required String id,
    required String emoji,
    required String title,
    required String subtitle,
    required String? status,
    Widget? leading,
  }) {
    return Semantics(
      container: true,
      identifier: id,
      key: ValueKey(id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 40,
                height: 40,
                child: Center(child: leading ?? Text(emoji, style: const TextStyle(fontSize: 20)))),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 13, height: 1.45, color: JXB.textSecondary)),
                  if (status != null) ...[
                    const SizedBox(height: 4),
                    Text(status,
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
