import 'package:memorion/pages/today_chapters/a1_recordings_page.dart';
import 'plaud_recordings_page.dart';
import 'ring_recordings_page.dart';
import 'widgets/ring_storage_card.dart';
import 'widgets/ring_health_card.dart';
import 'widgets/ring_usage_guide.dart';
import 'package:memorion/services/devices/chiplet_ring/sync_controller.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/pages/today_chapters/device_pairing_page.dart';
import 'package:memorion/pages/today_chapters/firmware_update_page.dart';
import 'package:memorion/pages/today_chapters/sync_status_page.dart';
import 'package:memorion/pages/today_chapters/soundcore_recordings_page.dart';
import 'package:memorion/pages/today_chapters/widgets/device_product_showcase.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/providers/onboarding_provider.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:memorion/widgets/info_dialog.dart';
import 'package:provider/provider.dart';

/// P-04 设备详情（记小宝 1.0 浅色改版，Figma v2.4 node 0:3213）。
///
/// ✅ 全真数据，复用 `DeviceProvider`（电量/充电/固件/LED/断开都是现成真实能力）。
/// - 实物图 + 电量 / 充电状态：`batteryLevel` / `isCharging`（真 BLE 数据）
/// - 更新固件 → `FirmwareUpdate`；LED 三档 → `setLedMode`
/// - 自动同步：开关（默认开，本地偏好）
/// - 查找设备入口已删（2026-08-07）：硬件无喇叭做不了响铃，LED 找回意义有限，
///   与其留「即将支持」占位不如不出现；未来硬件带蜂鸣器再加回。
class DeviceDetailPage extends StatefulWidget {
  final RingSyncController? ringController;
  const DeviceDetailPage({super.key, this.ringController});

  @override
  State<DeviceDetailPage> createState() => _DeviceDetailPageState();
}

class _DeviceDetailPageState extends State<DeviceDetailPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final dp = context.read<DeviceProvider>();
      await dp.getDeviceInfo();
      await dp.readLedMode();
    });
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
                Expanded(
                  child: Consumer<DeviceProvider>(
                    builder: (context, dp, _) => _body(context, dp),
                  ),
                ),
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
            Semantics(
              button: true,
              label: revampText(context, en: 'Back', zh: '返回'),
              child: GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                behavior: HitTestBehavior.opaque,
                child: const SizedBox(
                    width: 36, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary)),
              ),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Device', zh: '设备'),
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

  Widget _body(BuildContext context, DeviceProvider dp) {
    final connected = dp.isConnected && dp.connectedDevice != null;
    final device = dp.connectedDevice ?? dp.pairedDevice;
    final battery = dp.batteryLevel;
    final charging = dp.isCharging;
    final batteryColor = _batteryColor(battery);

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        if (device != null &&
            (device.type == DeviceType.memorion ||
                device.type == DeviceType.soundcore ||
                device.type == DeviceType.dingtalkA1 ||
                device.type == DeviceType.plaudNote ||
                device.type == DeviceType.chipletRing))
          DeviceProductShowcase(
            device: device,
            battery: battery,
            charging: charging,
            caseBattery: dp.caseBatteryLevel,
            caseCharging: dp.isCaseCharging,
          )
        else
          _batteryGauge(battery, charging),
        const SizedBox(height: 16),
        // 设备名
        Center(
          child: Text(device?.displayName ?? 'Memorion',
              style: const TextStyle(
                  fontFamily: JXB.fontSans, fontSize: 19, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
        ),
        const SizedBox(height: 10),
        // 状态药丸：充电中 / 已连接 / 未连接
        Center(child: _statusPill(context, connected, charging, dp.isBatteryDisconnected)),
        const SizedBox(height: 18),
        // 电量 + 固件 chip
        Row(
          children: [
            Expanded(
                child: _statChip(
              icon: charging ? Icons.battery_charging_full_rounded : Icons.battery_full_rounded,
              iconColor: batteryColor,
              text: battery < 0 ? '--' : '$battery%',
              textColor: batteryColor,
            )),
            const SizedBox(width: 10),
            Expanded(
                child: _statChip(
              text: connected
                  ? _fmtFirmware(dp.currentFirmwareVersion)
                  : revampText(context, en: 'Disconnected', zh: '未连接'),
              textColor: JXB.textSecondary,
            )),
          ],
        ),
        const SizedBox(height: 18),

        // 操作
        _sectionLabel(revampText(context, en: 'Actions', zh: '操作')),
        const SizedBox(height: 10),
        _actionMenu(context, dp),
        const SizedBox(height: 18),

        if (device?.type == DeviceType.chipletRing) ...[
          RingStorageCard(
            key: ValueKey('ring_storage_${device!.id}'), // i18n-ignore: Internal widget identity.
            controller: widget.ringController ?? ServiceManager.instance().ringSync.controllerFor(device),
            connected: connected,
          ),
          const SizedBox(height: 18),
          RingUsageGuide(
            key: ValueKey('ring_usage_${device.id}'), // i18n-ignore: Internal widget identity.
            controller: widget.ringController ?? ServiceManager.instance().ringSync.controllerFor(device),
            connected: connected,
          ),
          const SizedBox(height: 18),
          RingHealthCard(
            key: ValueKey('ring_health_details_${device.id}'), // i18n-ignore: Internal widget identity.
            controller: widget.ringController ?? ServiceManager.instance().ringSync.controllerFor(device),
            connected: connected,
          ),
          const SizedBox(height: 18),
        ],

        // LED 指示灯
        if (device?.usesOfflineImport != true) ...[
          _sectionLabel(revampText(context, en: 'LED Indicator', zh: 'LED 指示灯')),
          const SizedBox(height: 10),
          _ledCard(context, dp),
          const SizedBox(height: 18),
        ],

        // 设备信息
        _sectionLabel(revampText(context, en: 'Device Info', zh: '设备信息')),
        const SizedBox(height: 10),
        _infoCard(context, device),
        const SizedBox(height: 14),

        // 充电指南
        if (device?.usesOfflineImport != true) ...[
          _chargingGuideCard(context),
          const SizedBox(height: 14),
        ],

        // 断开设备
        if (device?.type == DeviceType.chipletRing)
          ListenableBuilder(
            listenable: widget.ringController ?? ServiceManager.instance().ringSync.controllerFor(device!),
            builder: (_, __) => _disconnectButton(context, dp, connected, disabled: _ringMaintenanceBusy(dp)),
          )
        else
          _disconnectButton(context, dp, connected),
      ],
    );
  }

  Widget _batteryGauge(int battery, bool charging, {String? label, Key? valueKey}) {
    final color = _batteryColor(battery);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 116,
          height: 116,
          child: CustomPaint(
            painter: _BatteryRingPainter(percent: battery < 0 ? 0 : battery, color: color),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(battery < 0 ? '--' : '$battery%',
                    key: valueKey,
                    style:
                        TextStyle(fontFamily: JXB.fontSans, fontSize: 25, fontWeight: FontWeight.w700, color: color)),
                if (charging) const Icon(Icons.bolt_rounded, size: 14, color: Color(0xFFF2B21A)),
              ]),
            ),
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 8),
          Text(label, style: JXB.body.copyWith(color: JXB.textSecondary)),
        ],
      ],
    );
  }

  Widget _statusPill(BuildContext context, bool connected, bool charging, bool batteryDisconnected) {
    if (charging) {
      return _pill(
        icon: Icons.bolt_rounded,
        text: revampText(context, en: 'Charging', zh: '充电中'),
        fg: const Color(0xFFF2B21A),
        bg: const Color(0x1FF2B21A),
        border: const Color(0xFFF2B21A),
      );
    }
    if (batteryDisconnected) {
      return _pill(
        icon: Icons.power_off_rounded,
        text: revampText(context, en: 'Turn on battery switch', zh: '请打开电池开关'),
        fg: const Color(0xFFF2B21A),
        bg: const Color(0x1FF2B21A),
        border: const Color(0xFFF2B21A),
      );
    }
    if (connected) {
      return _pill(
          icon: Icons.check_circle_rounded,
          text: revampText(context, en: 'Connected', zh: '已连接'),
          fg: JXB.success,
          bg: const Color(0x1F34C759),
          border: JXB.success);
    }
    return _pill(
        icon: Icons.bluetooth_disabled_rounded,
        text: revampText(context, en: 'Disconnected', zh: '未连接'),
        fg: JXB.textSecondary,
        bg: const Color(0x14808594),
        border: JXB.textPlaceholder);
  }

  Widget _pill(
      {required IconData icon, required String text, required Color fg, required Color bg, required Color border}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(99), border: Border.all(color: border, width: 1)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: fg)),
        ],
      ),
    );
  }

  Widget _statChip({IconData? icon, Color? iconColor, required String text, required Color textColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border, width: 1)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: iconColor),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Tooltip(
              message: text,
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w700, color: textColor)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Row(
      children: [
        Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 7),
        Text(text,
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
      ],
    );
  }

  Widget _actionMenu(BuildContext context, DeviceProvider dp) {
    final device = dp.connectedDevice ?? dp.pairedDevice;
    if (device?.usesOfflineImport == true) {
      return Container(
        decoration: BoxDecoration(
            color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border)),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Column(children: [
          _actionRow(
            title: revampText(context, en: 'Device recordings', zh: '设备录音'),
            subtitle: device?.type == DeviceType.chipletRing
                ? revampText(context, en: 'AI Ring · Experimental', zh: 'AI 戒指 · 实验性支持')
                : device?.type == DeviceType.plaudNote
                    ? revampText(context, en: 'PLAUD Note', zh: 'PLAUD Note')
                    : device?.type == DeviceType.dingtalkA1
                        ? revampText(context, en: 'DingTalk A1 · Experimental', zh: '钉钉 A1 · 实验性支持')
                        : revampText(context, en: 'soundcore Work', zh: 'soundcore Work'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => device?.type == DeviceType.chipletRing
                  ? RingRecordingsPage(device: device!, controller: widget.ringController)
                  : device?.type == DeviceType.plaudNote
                      ? PlaudRecordingsPage(device: device!)
                      : device?.type == DeviceType.dingtalkA1
                          ? A1RecordingsPage(device: device!)
                          : SoundcoreRecordingsPage(device: device!),
            )),
          ),
          if (device?.type == DeviceType.chipletRing) ...[
            const Divider(height: 1, color: JXB.border),
            _actionRow(
              title: revampText(context, en: 'Firmware Update', zh: '更新固件'),
              subtitle: revampText(context, en: 'OTA not integrated · Updates not checked', zh: 'OTA 尚未接入 · 未检查更新'),
              onTap: () => showRingFirmwareStatus(context),
            ),
          ],
        ]),
      );
    }
    return Container(
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        children: [
          _actionRow(
            title: revampText(context, en: 'Firmware Update', zh: '更新固件'),
            subtitle: dp.havingNewFirmware
                ? revampText(context,
                    en: 'New version ${dp.latestFirmwareVersion}', zh: '有新版本 ${dp.latestFirmwareVersion}')
                : revampText(context, en: 'Firmware is up to date', zh: '固件已是最新版本'),
            highlight: dp.havingNewFirmware,
            onTap: () {
              final device = dp.connectedDevice ?? dp.pairedDevice;
              if (device == null) return;
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => FirmwareUpdatePage(device: device)),
              );
            },
          ),
          const Divider(height: 1, color: JXB.border),
          _actionRow(
            title: revampText(context, en: 'Sync Status', zh: '同步状态'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SyncStatusPage()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow({required String title, String? subtitle, bool highlight = false, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: BoxConstraints(minHeight: subtitle != null ? 54 : 48),
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontFamily: JXB.fontSans,
                            fontSize: 12,
                            color: highlight ? JXB.brandPrimary : JXB.textSecondary)),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: JXB.textPlaceholder),
          ],
        ),
      ),
    );
  }

  Widget _ledCard(BuildContext context, DeviceProvider dp) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border, width: 1)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(revampText(context, en: 'Device LED Brightness', zh: '设备 LED 亮度'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textPlaceholder)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: JXB.bgApp, borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                _ledSeg(context, dp, LedMode.standard, Icons.wb_sunny_outlined,
                    revampText(context, en: 'Standard', zh: '标准')),
                const SizedBox(width: 8),
                _ledSeg(context, dp, LedMode.gentle, Icons.nightlight_outlined,
                    revampText(context, en: 'Gentle', zh: '柔和')),
                const SizedBox(width: 8),
                _ledSeg(context, dp, LedMode.night, Icons.visibility_off_outlined,
                    revampText(context, en: 'Night', zh: '夜间')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _ledSeg(BuildContext context, DeviceProvider dp, LedMode mode, IconData icon, String label) {
    final selected = dp.ledMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => dp.setLedMode(mode),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0x1F007AFF) : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: selected ? Border.all(color: JXB.brandPrimary, width: 1) : null,
          ),
          child: Column(
            children: [
              Icon(icon, size: 16, color: selected ? JXB.brandPrimary : JXB.textPlaceholder),
              const SizedBox(height: 5),
              Text(label,
                  style: TextStyle(
                      fontFamily: JXB.fontSans,
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? JXB.brandPrimary : JXB.textPlaceholder)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoCard(BuildContext context, BtDevice? device) {
    final id = device?.id ?? '';
    return Container(
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border, width: 1)),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        children: [
          _infoRow(revampText(context, en: 'Product Name', zh: '产品名称'), device?.displayName ?? 'Memorion',
              copy: device?.displayName),
          const Divider(height: 1, color: JXB.border),
          _infoRow(revampText(context, en: 'Model', zh: '型号'), device?.displayModelNumber ?? '--',
              copy: device?.displayModelNumber),
          const Divider(height: 1, color: JXB.border),
          // 设备 ID 完整显示（较长，右对齐可换行，用 Inter 等宽感字体）。
          _infoRow(revampText(context, en: 'Device ID', zh: '设备 ID'), id.isEmpty ? '--' : id, copy: id, mono: true),
          if (device?.type == DeviceType.chipletRing) ...[
            const Divider(height: 1, color: JXB.border),
            _infoRow(revampText(context, en: 'Bluetooth name', zh: '蓝牙名称'), device!.name, copy: device.name),
            const Divider(height: 1, color: JXB.border),
            _infoRow(revampText(context, en: 'Hardware version', zh: '硬件版本'),
                device.hardwareRevision.isEmpty ? '--' : device.hardwareRevision,
                copy: device.hardwareRevision),
            const Divider(height: 1, color: JXB.border),
            _infoRow(revampText(context, en: 'Firmware version', zh: '固件版本'),
                device.firmwareRevision.isEmpty ? '--' : device.firmwareRevision,
                copy: device.firmwareRevision),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, {String? copy, bool mono = false}) {
    return GestureDetector(
      onTap: copy == null || copy.isEmpty
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: copy));
              UndoDeleteHost.showMessage(context, revampText(context, en: 'Copied', zh: '已复制'));
            },
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 46),
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child:
                  Text(label, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontFamily: mono ? JXB.fontNumber : JXB.fontSans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                      color: JXB.textPrimary)),
            ),
            const SizedBox(width: 6),
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.copy_rounded, size: 13, color: JXB.textPlaceholder),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chargingGuideCard(BuildContext context) {
    return GestureDetector(
      onTap: () => showChargingGuideDialog(context),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
            color: JXB.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: JXB.border, width: 1)),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0x1FF2B21A), borderRadius: BorderRadius.circular(11)),
              child: const Icon(Icons.help_outline_rounded, size: 19, color: Color(0xFFF2B21A)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(revampText(context, en: 'Charging issues?', zh: '设备充电有问题？'),
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                  const SizedBox(height: 3),
                  Text(revampText(context, en: 'Tap to view guide', zh: '点击查看指南'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: JXB.textPlaceholder),
          ],
        ),
      ),
    );
  }

  bool _ringMaintenanceBusy(DeviceProvider dp) {
    final device = dp.connectedDevice ?? dp.pairedDevice;
    return device?.type == DeviceType.chipletRing &&
        (widget.ringController ?? ServiceManager.instance().ringSync.controllerFor(device!)).maintenanceBusy;
  }

  Widget _disconnectButton(BuildContext context, DeviceProvider dp, bool connected, {bool disabled = false}) {
    return GestureDetector(
      key: const ValueKey('device_disconnect'),
      onTap: disabled ? null : () => _confirmDisconnect(context, dp, connected),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0x0FE55247),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x80E55247), width: 1),
        ),
        child: Text(
            disabled
                ? revampText(context, en: 'Storage operation in progress', zh: '正在操作存储')
                : connected
                    ? revampText(context, en: 'Disconnect', zh: '断开设备')
                    : revampText(context, en: 'Unpair', zh: '取消配对'),
            style:
                const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.error)),
      ),
    );
  }

  Future<void> _confirmDisconnect(BuildContext context, DeviceProvider dp, bool connected) async {
    if (_ringMaintenanceBusy(dp)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JXB.surface,
        title: Text(
            connected
                ? revampText(context, en: 'Disconnect', zh: '断开设备')
                : revampText(context, en: 'Unpair', zh: '取消配对'),
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w600, color: JXB.textPrimary)),
        content: Text(
            connected
                ? revampText(context, en: 'Disconnect from this device?', zh: '确定断开与设备的连接吗？')
                : revampText(context, en: 'Unpair this device?', zh: '确定取消配对这台设备吗？'),
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(revampText(context, en: 'Cancel', zh: '取消'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(revampText(context, en: 'Confirm', zh: '确定'), style: const TextStyle(color: JXB.error))),
        ],
      ),
    );
    if (ok != true || !context.mounted || _ringMaintenanceBusy(dp)) return;

    HapticFeedback.mediumImpact();
    final target = dp.connectedDevice ?? dp.pairedDevice;
    await SharedPreferencesUtil().btDeviceSet(BtDevice.empty());
    SharedPreferencesUtil().deviceName = '';
    if (target != null && target.id.isNotEmpty) {
      await ServiceManager.instance().device.forceDisconnect(target.id);
    }
    dp.setConnectedDevice(null);
    dp.setIsConnected(false);
    dp.updateConnectingStatus(false);
    if (!context.mounted) return;
    final onboarding = context.read<OnboardingProvider>();
    onboarding.stopScanDevices();
    onboarding.deviceAlreadyUnpaired();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const DevicePairingPage()),
      (route) => route.isFirst,
    );
  }

  String _fmtFirmware(String v) => v == 'Unknown' ? '--' : (v.toLowerCase().startsWith('v') ? v : 'v$v');

  Color _batteryColor(int battery) {
    if (battery < 0) return JXB.textPlaceholder;
    if (battery > 50) return JXB.success;
    if (battery >= 20) return const Color(0xFFF2B21A);
    return JXB.error;
  }
}

/// 大电量环画笔（底环 + 进度弧）。
class _BatteryRingPainter extends CustomPainter {
  final int percent;
  final Color color;
  _BatteryRingPainter({required this.percent, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 8.0;
    final center = size.center(Offset.zero);
    final radius = (size.width - stroke) / 2;
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFE5E5EA);
    canvas.drawCircle(center, radius, bg);

    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    final sweep = 2 * math.pi * (percent / 100.0);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2, sweep, false, fg);
  }

  @override
  bool shouldRepaint(covariant _BatteryRingPainter old) => old.percent != percent || old.color != color;
}
