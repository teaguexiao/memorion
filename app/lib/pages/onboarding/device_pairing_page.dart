import 'package:memorion/pages/today_chapters/a1_setup_page.dart';
import 'package:memorion/pages/today_chapters/plaud_setup_page.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/pages/onboarding/onboarding_lang.dart';
import 'package:memorion/providers/onboarding_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:memorion/widgets/dialog.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// O-05 连接你的设备（记小宝 1.0 浅色改版，Figma node 769:1966）。
///
/// 请求蓝牙/通知权限 → 扫描 → 发现设备卡「连接」。
/// BLE 扫描/连接全部复用 `OnboardingProvider`（无 mock）。
class DevicePairingPage extends StatefulWidget {
  final VoidCallback goNext;
  final VoidCallback onSkip;

  const DevicePairingPage({super.key, required this.goNext, required this.onSkip});

  @override
  State<DevicePairingPage> createState() => _DevicePairingPageState();
}

class _DevicePairingPageState extends State<DevicePairingPage> {
  bool _permissionsGranted = false;
  bool _requestingPermissions = false;
  late OnboardingProvider _provider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestPermissionsAndScan());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider = Provider.of<OnboardingProvider>(context, listen: false);
  }

  Future<void> _requestPermissionsAndScan() async {
    setState(() => _requestingPermissions = true);
    final provider = Provider.of<OnboardingProvider>(context, listen: false);

    await provider.askForBluetoothPermissions();
    await Permission.notification.request();
    if (Platform.isAndroid) {
      await provider.askForBackgroundPermissions();
    }

    setState(() {
      _permissionsGranted = true;
      _requestingPermissions = false;
    });

    provider.scanDevices(
      onShowDialog: () {
        if (mounted) {
          showDialog(
            context: context,
            builder: (c) => getDialog(
              context,
              () => Navigator.of(context).pop(),
              () {},
              obLRead(context, '请打开蓝牙', 'Turn on Bluetooth'),
              obLRead(context, '连接设备需要打开蓝牙', 'Bluetooth is required to connect your device'),
              singleButton: true,
            ),
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _provider.stopScanDevices();
    super.dispose();
  }

  void _openOfficialWebsite() {
    HapticFeedback.lightImpact();
    MixpanelManager().pageOpened('Onboarding Pairing Visit Website');
    launchUrl(Uri.parse('https://memorion.me/shop'), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 40),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: const TextStyle(
                        fontFamily: JXB.fontDisplay, fontSize: 26, fontWeight: FontWeight.w700, height: 1.2),
                    children: obL(context, 'zh', 'en') == 'zh'
                        ? const [
                            TextSpan(text: '连接你的', style: TextStyle(color: JXB.textPrimary)),
                            TextSpan(text: '设备', style: TextStyle(color: JXB.brandPrimary)),
                          ]
                        : const [
                            TextSpan(text: 'Connect your ', style: TextStyle(color: JXB.textPrimary)),
                            TextSpan(text: 'device', style: TextStyle(color: JXB.brandPrimary)),
                          ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                    obL(context, '打开设备电源并靠近手机，Memorion 会自动搜索附近的设备。',
                        'Power on your device and keep it close — Memorion will search automatically.'),
                    style:
                        const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary, height: 1.5)),
              ],
            ),
          ),
          Expanded(
            child: Consumer<OnboardingProvider>(
              builder: (context, provider, child) {
                if (_requestingPermissions || !_permissionsGranted) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(strokeWidth: 2, color: JXB.brandPrimary)),
                        const SizedBox(height: 16),
                        Text(obL(context, '正在准备权限…', 'Preparing permissions…'),
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
                      ],
                    ),
                  );
                }
                return _scanBody(provider);
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 4, 24, MediaQuery.of(context).padding.bottom + 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: _openOfficialWebsite,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(obL(context, '还没有设备？了解更多', "Don't have a device? Learn more"),
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                        const SizedBox(width: 4),
                        const Icon(Icons.open_in_new_rounded, size: 13, color: JXB.textSecondary),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                _skipButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scanBody(OnboardingProvider provider) {
    return MessageListener<OnboardingProvider>(
      showError: (error) => UndoDeleteHost.showMessage(context, error),
      showInfo: (info) => UndoDeleteHost.showMessage(context, info),
      child: Column(
        children: [
          const Spacer(),
          // 扫描动画：同心圆 + 中心 M
          _ScanRipple(connected: provider.isConnected),
          const SizedBox(height: 24),
          if (provider.isConnected)
            Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle_rounded, color: JXB.success, size: 18),
                    const SizedBox(width: 6),
                    Text(obL(context, '连接成功', 'Connected'),
                        style: const TextStyle(
                            fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w600, color: JXB.success)),
                  ],
                ),
                const SizedBox(height: 6),
                Text('${provider.deviceName} (${BtDevice.shortId(provider.deviceId)})',
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
              ],
            )
          else
            Text(
              provider.deviceList.isEmpty
                  ? obL(context, '正在搜索附近的 Memorion…', 'Searching for nearby Memorion…')
                  : obL(context, '发现 ${provider.deviceList.length} 台设备',
                      'Found ${provider.deviceList.length} device(s)'), // i18n-ignore: Bilingual via obL.
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary),
            ),
          const Spacer(),
          // 发现设备列表
          if (!provider.isConnected)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(children: provider.deviceList.map((d) => _deviceCard(provider, d)).toList()),
            ),
          if (provider.isConnected)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _primaryButton(obL(context, '下一步', 'Next'), widget.goNext),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _deviceCard(OnboardingProvider provider, BtDevice device) {
    final isConnecting = provider.connectingToDeviceId == device.id;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
      decoration: BoxDecoration(
        color: JXB.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: JXB.cardShadow,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text('${device.displayName} (${device.getShortId()})',
                style: const TextStyle(
                    fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w500, color: JXB.textPrimary)),
          ),
          GestureDetector(
            onTap: (provider.isClicked || isConnecting)
                ? null
                : () async {
                    if (!await ensureA1Identity(context, device) || !mounted) return;
                    if (!await ensurePlaudIdentity(context, device) || !mounted) return;
                    await provider.handleTap(device: device, isFromOnboarding: true, goNext: widget.goNext);
                    if (mounted && device.type == DeviceType.plaudNote && provider.connectionError != null) {
                      UndoDeleteHost.showMessage(context, plaudErrorText(context, provider.connectionError));
                    }
                    if (mounted && device.type == DeviceType.dingtalkA1 && provider.connectionError != null) {
                      UndoDeleteHost.showMessage(context, a1ErrorText(context, provider.connectionError));
                    }
                  },
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
              decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
              child: isConnecting
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(obL(context, '连接', 'Connect'),
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _skipButton() {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onSkip();
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(obL(context, '暂时跳过，稍后连接', 'Skip for now, connect later'),
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textSecondary)),
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
        child: Text(label,
            style: const TextStyle(
                fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }
}

/// 同心圆扫描动画 + 中心蓝 M 圆点。
class _ScanRipple extends StatefulWidget {
  final bool connected;
  const _ScanRipple({required this.connected});

  @override
  State<_ScanRipple> createState() => _ScanRippleState();
}

class _ScanRippleState extends State<_ScanRipple> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (!widget.connected)
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                size: const Size(200, 200),
                painter: _RipplePainter(_c.value),
              ),
            ),
          Container(
            width: 60,
            height: 60,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.connected ? JXB.success : JXB.brandPrimary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: (widget.connected ? JXB.success : JXB.brandPrimary).withValues(alpha: 0.35),
                    blurRadius: 16,
                    spreadRadius: 2),
              ],
            ),
            child: widget.connected
                ? const Icon(Icons.check_rounded, color: Colors.white, size: 30)
                : const Text('M', // i18n-ignore: 品牌首字母
                    style: TextStyle(
                        fontFamily: JXB.fontSans, fontSize: 26, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  final double progress;
  _RipplePainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;
    for (int i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final r = 30 + t * (maxR - 30);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = JXB.brandPrimary.withValues(alpha: (1 - t) * 0.5);
      canvas.drawCircle(center, r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter oldDelegate) => oldDelegate.progress != progress;
}
