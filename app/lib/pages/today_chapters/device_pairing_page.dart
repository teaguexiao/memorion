import 'package:memorion/pages/today_chapters/a1_setup_page.dart';
import 'package:memorion/pages/today_chapters/device_detail_page.dart';
import 'plaud_setup_page.dart';
import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/providers/onboarding_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// P-04A 查找设备（记小宝 1.0 浅色改版，Figma v2.4 node 431:749）。
///
/// ✅ 真实扫描：复用 `OnboardingProvider.scanDevices` / `handleTap`（BLE 扫描 + 连接）。
class DevicePairingPage extends StatefulWidget {
  const DevicePairingPage({super.key});

  @override
  State<DevicePairingPage> createState() => _DevicePairingPageState();
}

class _DevicePairingPageState extends State<DevicePairingPage> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))
    ..repeat();
  // 缓存 provider 引用，dispose 时不能再通过 context.read（context 已 deactivated 会抛异常）。
  OnboardingProvider? _ob;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScan());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ob = context.read<OnboardingProvider>();
  }

  Future<void> _startScan() async {
    final ob = context.read<OnboardingProvider>();
    await ob.scanDevices(onShowDialog: () {
      if (mounted) {
        UndoDeleteHost.showMessage(
            context, revampText(context, en: 'Enable Bluetooth permission and retry', zh: '请开启蓝牙权限后重试'));
      }
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _ob?.stopScanDevices(); // 用缓存引用，避免 dispose 时 context.read 抛异常
    super.dispose();
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
                const SizedBox(height: 18),
                Text(revampText(context, en: 'Bring the device close and keep it on', zh: '把设备靠近手机，保持开机'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                  child: Text(
                    revampText(context,
                        en: 'For soundcore Work, DingTalk A1 or PLAUD Note, wake the recorder and close other apps connected to it.',
                        zh: '连接 soundcore Work、钉钉 A1 或 PLAUD Note 时，请唤醒设备，并关闭其他连接它的 App。'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: JXB.textSecondary),
                  ),
                ),
                const SizedBox(height: 40),
                _radar(),
                const SizedBox(height: 24),
                Text(revampText(context, en: 'Searching…', zh: '正在搜索…'),
                    style: const TextStyle(
                        fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.brandPrimary)),
                const SizedBox(height: 24),
                Expanded(
                  child: Consumer<OnboardingProvider>(
                    builder: (context, ob, _) {
                      final devices = ob.deviceList;
                      return ListView(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                        children: [
                          for (final d in devices) ...[
                            _deviceCard(context, ob, d),
                            const SizedBox(height: 12),
                          ],
                          const SizedBox(height: 20),
                          Center(
                            child: Text(
                                revampText(context,
                                    en: "Can't find it? Make sure the device is on",
                                    zh: '没有找到？确保设备已开机'), // i18n-ignore: Bilingual via revampText.
                                style: const TextStyle(
                                    fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textPlaceholder)),
                          ),
                        ],
                      );
                    },
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
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                  width: 36, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary)),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Find Device', zh: '查找设备'),
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

  /// 中心蓝色设备图标 + 同心圆扩散动画。
  Widget _radar() {
    return SizedBox(
      width: 200,
      height: 200,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              for (int i = 0; i < 3; i++) _pulseRing((i * 0.33 + _pulse.value) % 1.0),
              // 中心图标
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: JXB.brandPrimary, shape: BoxShape.circle),
                child: const Icon(Icons.memory_rounded, size: 30, color: Colors.white),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _pulseRing(double t) {
    final size = 64.0 + t * 136.0; // 64 → 200
    final opacity = (1.0 - t) * 0.35;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: JXB.brandPrimary.withValues(alpha: opacity), width: 1.5),
      ),
    );
  }

  Widget _deviceCard(BuildContext context, OnboardingProvider ob, BtDevice d) {
    final connecting = ob.connectingToDeviceId == d.id;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: const Color(0x17007AFF), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.memory_rounded, size: 20, color: JXB.brandPrimary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(d.displayName,
                    style: const TextStyle(
                        fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
                const SizedBox(height: 3),
                Text(_signalLabel(context, d.rssi),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textSecondary)),
              ],
            ),
          ),
          GestureDetector(
            onTap: connecting ? null : () => _connect(context, ob, d),
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(999)),
              child: connecting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child:
                          CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
                  : Text(revampText(context, en: 'Connect', zh: '连接'),
                      style: const TextStyle(
                          fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _connect(BuildContext context, OnboardingProvider ob, BtDevice d) async {
    if (!await ensureA1Identity(context, d) || !context.mounted) return;
    if (!await ensurePlaudIdentity(context, d) || !context.mounted) return;
    await ob.handleTap(device: d, isFromOnboarding: false);
    if (context.mounted && d.type == DeviceType.plaudNote && ob.connectionError != null) {
      UndoDeleteHost.showMessage(context, plaudErrorText(context, ob.connectionError));
    }
    if (context.mounted && d.type == DeviceType.dingtalkA1 && ob.connectionError != null) {
      UndoDeleteHost.showMessage(context, a1ErrorText(context, ob.connectionError));
    }
    if (!context.mounted || ModalRoute.of(context)?.isCurrent != true || ob.connectionError != null) return;
    if (ob.deviceProvider?.pairedDevice?.id == d.id) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const DeviceDetailPage()));
    }
  }

  String _signalLabel(BuildContext context, int rssi) {
    // rssi 越接近 0 越强；粗略估算距离。
    final String strength = rssi > -60
        ? revampText(context, en: 'Strong', zh: '信号强')
        : (rssi > -75 ? revampText(context, en: 'Medium', zh: '信号中') : revampText(context, en: 'Weak', zh: '信号弱'));
    final double meters = rssi >= -50 ? 0.5 : (rssi >= -70 ? 2.0 : 5.0);
    return revampText(context, en: '$strength · ~$meters m', zh: '$strength · 约 $meters 米');
  }
}
