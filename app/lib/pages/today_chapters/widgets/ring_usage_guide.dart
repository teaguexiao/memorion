import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:memorion/services/devices/chiplet_ring/sync_controller.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// Manufacturer instructions; Z62 gesture defaults and physical motor remain
/// unverified. Keep this guide scoped to ring details.
class RingUsageGuide extends StatefulWidget {
  final RingSyncController controller;
  final bool connected;
  const RingUsageGuide({super.key, required this.controller, required this.connected});

  @override
  State<RingUsageGuide> createState() => _RingUsageGuideState();
}

class _RingUsageGuideState extends State<RingUsageGuide> {
  bool calibrating = false, failed = false;
  DateTime? calibratedAt;
  int epoch = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(RingUsageGuide old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(changed);
      widget.controller.addListener(changed);
    }
    if (old.controller != widget.controller || old.connected != widget.connected) {
      epoch++;
      calibratedAt = null;
      failed = false;
      calibrating = false;
    }
  }

  Future<void> calibrate() async {
    if (!widget.connected || widget.controller.busy || calibrating) return;
    final token = ++epoch;
    setState(() {
      calibrating = true;
      failed = false;
      calibratedAt = null;
    });
    try {
      final time = await widget.controller.synchronizeClock(DateTime.now().timeZoneOffset);
      if (mounted && token == epoch) setState(() => calibratedAt = time);
    } catch (_) {
      if (mounted && token == epoch) setState(() => failed = true);
    } finally {
      if (mounted && token == epoch) setState(() => calibrating = false);
    }
  }

  @override
  void dispose() {
    epoch++;
    widget.controller.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
            color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border)),
        child: ExpansionTile(
          key: const ValueKey('ring_usage_guide'), // i18n-ignore: Widget identity.
          title: Text(revampText(context, en: 'Ring instructions', zh: '戒指使用说明'), style: JXB.body),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            _item(
                revampText(context, en: 'Indicator lights', zh: '指示灯'),
                revampText(context,
                    en: 'Green during manual recording has been confirmed on this ring. Manufacturer guide: breathing light while charging; blue for 2 seconds on connection; 3 blue flashes on disconnection. The other light patterns may vary by firmware.',
                    zh: '这枚戒指手动录音时亮绿灯已确认。厂家另说明：充电时呼吸灯；连接成功蓝灯亮 2 秒；断开时蓝灯闪 3 次。其他灯光表现仍可能因固件而异。')),
            _item(
                revampText(context, en: 'Power and connection', zh: '开机与连接'),
                revampText(context,
                    en: 'Charging wakes a powered-off ring. If it cannot be found, charge it first and close Chiplering before connecting here. The manufacturer does not document a power-off gesture for this Z62 firmware.',
                    zh: '关机后的戒指通过充电唤醒。搜索不到时先充电，再退出 Chiplering 并在此连接。厂家没有说明这版 Z62 固件的关机手势。')),
            _item(
                revampText(context, en: 'Recording controls', zh: '录音操作'),
                revampText(context,
                    en: 'Use Start recording and Stop recording on the Device recordings page. The generic guide mentions long-pressing or double-tapping the matte area in voice mode, but Z62 defaults and its offline stop gesture need verification. Charging or a low-battery restart resets touch mode to off.',
                    zh: '可在“设备录音”页点击开始录音和停止录音。通用文档提到语音模式下长按或双击磨砂区域，但 Z62 的默认设置和离线停止手势还需确认。充电或低电重启会将触控模式重置为关闭。')),
            _item(
                revampText(context, en: 'Vibration feedback', zh: '震动提示'),
                revampText(context,
                    en: 'Short- and long-pulse tests on this 603/Z62 ring produced no vibration. The manufacturer’s 1.23 setting requests one long pulse at start and two at stop, but vibration has not worked on this ring. Check the green light and recording status on screen.',
                    zh: '这枚 603/Z62 戒指的短振和长振实测均没有震动。厂家 1.23 设置请求开始长振一次、结束长振两次，但震动功能目前未能生效。请看绿灯和页面录音状态。')),
            _item(
                revampText(context, en: 'Device time', zh: '设备时间'),
                revampText(context,
                    en: 'Calibration sets the phone time and verifies the ring reply. It has not been tested on this firmware yet. It only supports whole-hour time zones and does not correct existing recordings. Stop recording and wait for transfers to finish first.',
                    zh: '校准会设置手机时间并检查戒指回读；这版固件还未完成真机验证。目前仅支持整小时的时区，也不会修正已有录音。请先停止录音并等待传输结束。')),
            TextButton(
              key: const ValueKey('ring_calibrate_clock'), // i18n-ignore: Widget identity.
              onPressed: widget.connected && !widget.controller.busy && !calibrating ? calibrate : null,
              child: Text(calibrating
                  ? revampText(context, en: 'Calibrating…', zh: '正在校准…')
                  : revampText(context, en: 'Calibrate device time', zh: '校准设备时间')),
            ),
            if (failed)
              Text(
                  revampText(context,
                      en: 'Calibration was not verified. Check the connection and time zone, then retry. Firmware support may vary.',
                      zh: '未能验证校准结果，请检查连接与时区后重试；固件也可能不支持。'),
                  style: JXB.body),
            if (calibratedAt != null)
              Text(
                  revampText(context, en: 'Verified ring time: ', zh: '戒指回读时间：') +
                      DateFormat('yyyy-MM-dd HH:mm:ss').format(calibratedAt!.toLocal()),
                  style: JXB.body), // i18n-ignore: Numeric date format.
          ],
        ),
      );

  Widget _item(String title, String body) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: JXB.body.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(body, style: JXB.body.copyWith(color: JXB.textSecondary)),
        ]),
      );
}

Future<void> showRingFirmwareStatus(BuildContext context) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(revampText(context, en: 'Ring firmware', zh: '戒指固件')),
        content: Text(revampText(context,
            en: 'OTA is not integrated yet; no update check has been performed. It requires the manufacturer’s firmware package for this hardware, cloud authorization and the matching Apollo, Nordic or PHY upgrade protocol. Manufacturer guidance recommends more than 50% battery and a strong Bluetooth signal. Use Chiplering for upgrades for now.',
            zh: 'OTA 尚未接入，也尚未检查是否有新版本。升级需要厂家为这款硬件提供的固件包、云服务授权及对应的 Apollo、Nordic 或 PHY 升级协议。厂家建议电量超过 50%、蓝牙信号良好。目前请通过 Chiplering 升级。')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(revampText(context, en: 'OK', zh: '知道了')))
        ],
      ),
    );
