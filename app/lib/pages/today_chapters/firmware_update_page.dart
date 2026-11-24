import 'package:flutter/material.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/pages/home/firmware_mixin.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:memorion/widgets/info_dialog.dart';
import 'package:provider/provider.dart';

/// P-04B 固件更新（记小宝 1.0 浅色改版，Figma v2.4 node 431:2101）。
///
/// ✅ 全真数据，复用 `FirmwareMixin`：
/// - 版本：`DeviceProvider.currentFirmwareVersion` / `latestFirmwareDetails`
/// - 检查更新：`getLatestVersion` + `shouldUpdateFirmware`
/// - 立即更新：`downloadFirmware` → `startDfu`（下载/安装进度真实流式）
class FirmwareUpdatePage extends StatefulWidget {
  final BtDevice device;
  const FirmwareUpdatePage({super.key, required this.device});

  @override
  State<FirmwareUpdatePage> createState() => _FirmwareUpdatePageState();
}

class _FirmwareUpdatePageState extends State<FirmwareUpdatePage> with FirmwareMixin {
  bool _shouldUpdate = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    await getLatestVersion(
      deviceModelNumber: widget.device.modelNumber,
      firmwareRevision: widget.device.firmwareRevision,
      hardwareRevision: widget.device.hardwareRevision,
      manufacturerName: widget.device.manufacturerName,
    );
    final result = await shouldUpdateFirmware(currentFirmware: widget.device.firmwareRevision);
    if (mounted) {
      setState(() {
        _shouldUpdate = result.$2;
        _checking = false;
      });
    }
  }

  Future<void> _startUpdate() async {
    await downloadFirmware();
    await startDfu(widget.device);
  }

  @override
  Widget build(BuildContext context) {
    final busy = isDownloading || isInstalling;
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: PopScope(
          canPop: !busy,
          child: Scaffold(
            backgroundColor: JXB.bgApp,
            body: SafeArea(
              child: Column(
                children: [
                  _detailBar(context, busy),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
                      children: [
                        _sectionLabel(revampText(context, en: 'Current Version', zh: '当前版本')),
                        const SizedBox(height: 10),
                        _currentVersionCard(),
                        const SizedBox(height: 22),
                        _sectionLabel(revampText(context, en: 'Available Update', zh: '可用更新')),
                        const SizedBox(height: 10),
                        _availableCard(busy),
                        if (busy || isInstalled) ...[
                          const SizedBox(height: 22),
                          _sectionLabel(revampText(context, en: 'Update Progress', zh: '更新进度')),
                          const SizedBox(height: 10),
                          _progressCard(),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailBar(BuildContext context, bool busy) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            GestureDetector(
              onTap: busy ? null : () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: SizedBox(width: 36, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: busy ? JXB.textPlaceholder : JXB.textPrimary)),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Firmware Update', zh: '固件更新'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            // 更新指南（更新前须知 / 更新中 / 失败怎么办）。这个入口原先挂在旧深色
            // 固件页上，那个页面 2026-08-20 删除后指南就没有入口了——文案和弹窗都还在，
            // 只是没人调用。接到这里是为了让删除保持功能中立。
            GestureDetector(
              onTap: () => showFirmwareUpdateGuideDialog(context),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                width: 36,
                height: 36,
                child: Icon(Icons.help_outline_rounded, size: 20, color: JXB.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Row(
      children: [
        Container(width: 3, height: 13, decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 7),
        Text(text, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
      ],
    );
  }

  Widget _currentVersionCard() {
    final dp = context.read<DeviceProvider>();
    final version = _fmt(dp.currentFirmwareVersion);
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border, width: 1)),
      child: Row(
        children: [
          Container(
            width: 40, height: 40, alignment: Alignment.center,
            decoration: BoxDecoration(color: const Color(0x17007AFF), borderRadius: BorderRadius.circular(11)),
            child: const Icon(Icons.memory_rounded, size: 20, color: JXB.brandPrimary),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(revampText(context, en: 'Current Version', zh: '当前版本'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
              const SizedBox(height: 3),
              Text(version, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _availableCard(bool busy) {
    if (_checking) {
      return Container(
        height: 72,
        decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border, width: 1)),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(color: JXB.brandPrimary, strokeWidth: 2),
      );
    }
    if (!_shouldUpdate) {
      // 已是最新
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border, width: 1)),
        child: Row(
          children: [
            const Icon(Icons.check_circle_rounded, size: 20, color: JXB.success),
            const SizedBox(width: 10),
            Text(revampText(context, en: 'Firmware is up to date', zh: '固件已是最新版本'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
          ],
        ),
      );
    }
    final newVersion = _fmt('${latestFirmwareDetails['version'] ?? ''}');
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x0F007AFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: JXB.brandPrimary, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(revampText(context, en: 'New Version Found', zh: '发现新版本'), style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
                child: Text(newVersion, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: busy ? null : _startUpdate,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 46, alignment: Alignment.center,
              decoration: BoxDecoration(color: busy ? JXB.textPlaceholder : JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
              child: Text(busy ? revampText(context, en: 'Updating…', zh: '更新中…') : revampText(context, en: 'Update Now', zh: '立即更新'),
                  style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressCard() {
    final int pct = isInstalled ? 100 : (isInstalling ? installProgress : downloadProgress);
    final String label = isInstalled
        ? revampText(context, en: 'Update Complete', zh: '更新完成')
        : (isInstalling ? revampText(context, en: 'Installing', zh: '正在安装') : revampText(context, en: 'Downloading', zh: '正在下载'));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border, width: 1)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
              Text('$pct%', style: const TextStyle(fontFamily: JXB.fontNumber, fontSize: 14, fontWeight: FontWeight.w600, color: JXB.brandPrimary)),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: pct / 100.0,
              minHeight: 8,
              backgroundColor: JXB.border,
              valueColor: const AlwaysStoppedAnimation<Color>(JXB.brandPrimary),
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(String v) {
    if (v.isEmpty || v == 'Unknown') return '--';
    return v.startsWith('v') ? v : 'v$v';
  }
}
