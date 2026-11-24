import 'dart:async';

import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/pages/onboarding/onboarding_background.dart';
import 'package:memorion/pages/onboarding/onboarding_lang.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/providers/speech_profile_provider.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/widgets/dialog.dart';
import 'package:provider/provider.dart';

/// O-06 声纹训练 · 教 Memorion 识别你的声音（记小宝 1.0 浅色改版，Figma node 776:1717）。
///
/// 复用 [SpeechProfileProvider] 的真实录音/上传流程（设备麦克风或手机麦克风），
/// 套浅色 UI：麦克风大圆钮 + 「录音中」药丸 + 进度条。
///
/// 两种用法：
/// - onboarding（默认）：由 wrapper 提供背景/返回键；完成或跳过走 [onDone]/[onSkip]。
/// - standalone（设置里「重新录制」）：`standalone=true` 时自带浅色 Scaffold+背景+返回键，
///   录完/完成后 pop 返回（替代旧深色 SpeechProfilePage，避免重复界面）。
class SpeechProfileOnboardingPage extends StatefulWidget {
  final VoidCallback onDone;
  final VoidCallback onSkip;
  final bool standalone;

  const SpeechProfileOnboardingPage({
    super.key,
    required this.onDone,
    required this.onSkip,
    this.standalone = false,
  });

  @override
  State<SpeechProfileOnboardingPage> createState() => _SpeechProfileOnboardingPageState();
}

class _SpeechProfileOnboardingPageState extends State<SpeechProfileOnboardingPage> {
  /// 录音是否已达 100%（即可继续，无需等后台上传完成）。
  bool _reached100 = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<SpeechProfileProvider>().close();
      await context.read<SpeechProfileProvider>().updateDevice();
    });
  }

  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    final connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return BleAudioCodec.pcm8;
    return connection.getAudioCodec();
  }

  Future<void> _restartDeviceRecording() async {
    if (!mounted) return;
    final capture = Provider.of<CaptureProvider>(context, listen: false);
    try {
      final started = await capture.streamDeviceRecording(
        device: Provider.of<SpeechProfileProvider>(context, listen: false).deviceProvider?.connectedDevice,
      );
      if (!started && mounted) {
        UndoDeleteHost.showMessage(context, obLRead(context, '请先结束手机录音，再开始设备录音。', 'Finish phone recording before using your device.'));
      }
    } catch (error) {
      debugPrint('Device recording restart failed: $error');
      if (mounted) {
        UndoDeleteHost.showMessage(context, obLRead(context, '设备录音未能开始，请重试。', 'Device recording could not start. Please try again.'));
      }
    }
  }

  Future<void> _stopDeviceRecording() async {
    if (!mounted) return;
    await Provider.of<CaptureProvider>(context, listen: false).stopStreamDeviceRecording();
  }

  Future<void> _startRecording(SpeechProfileProvider provider) async {
    HapticFeedback.mediumImpact();
    bool usePhoneMic = false;

    if (provider.device != null) {
      BleAudioCodec codec;
      try {
        codec = await _getAudioCodec(provider.device!.id);
      } catch (_) {
        usePhoneMic = true;
        codec = BleAudioCodec.pcm16;
      }
      if (!usePhoneMic && !codec.isOpusSupported()) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (c) => getDialog(
            context,
            () => Navigator.pop(context),
            () {},
            obLRead(context, '需要更新固件', 'Firmware update required'),
            obLRead(context, '当前设备固件不支持声纹录制，请先更新固件。',
                'Your device firmware does not support voice profile recording. Please update it first.'),
            singleButton: true,
          ),
          barrierDismissible: false,
        );
        return;
      }
    } else {
      usePhoneMic = true;
    }

    await _stopDeviceRecording();
    try {
      ServiceManager.instance().mic.stop();
    } catch (_) {}

    await provider.initialise(
      finalizedCallback: usePhoneMic ? null : _restartDeviceRecording,
      forcePhoneMic: usePhoneMic,
    );
    provider.forceCompletionTimer = Timer(Duration(seconds: provider.maxDuration), () => provider.finalize());
    provider.updateStartedRecording(true);
  }

  @override
  Widget build(BuildContext context) {
    final content = Consumer2<SpeechProfileProvider, CaptureProvider>(
      builder: (context, provider, _, child) {
        return MessageListener<SpeechProfileProvider>(
          showInfo: (_) {},
          showError: (error) {
            if (error == 'MULTIPLE_SPEAKERS' || error == 'TOO_SHORT' || error == 'INVALID_RECORDING') {
              showDialog(
                context: context,
                builder: (c) => getDialog(
                  context,
                  () {
                    provider.resetSegments();
                    Navigator.pop(context);
                  },
                  () {},
                  error == 'MULTIPLE_SPEAKERS'
                      ? obLRead(context, '检测到多个说话人', 'Multiple speakers detected')
                      : obLRead(context, '录音无效', 'Invalid recording'),
                  error == 'MULTIPLE_SPEAKERS'
                      ? obLRead(context, '请在安静环境下只由你一人说话再试。', 'Please try again in a quiet place with only you speaking.')
                      : obLRead(context, '录音太短或不清晰，请重试。', 'The recording was too short or unclear. Please try again.'),
                  okButtonText: obLRead(context, '重试', 'Retry'),
                  singleButton: true,
                ),
                barrierDismissible: false,
              );
            }
          },
          child: _body(context, provider),
        );
      },
    );
    if (!widget.standalone) return content;
    // standalone：自带浅色 Scaffold + 背景 + 返回键（设置内「重新录制」用）。
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: Scaffold(
        backgroundColor: JXB.bgApp,
        body: OnboardingBackground(
          child: Stack(
            children: [
              content,
              Positioned(
                top: MediaQuery.of(context).padding.top + 6,
                left: 16,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).maybePop(),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(color: Color(0x14808594), shape: BoxShape.circle),
                    child: const Icon(Icons.chevron_left_rounded, size: 24, color: JXB.textPrimary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, SpeechProfileProvider provider) {
    final isRecording = provider.startedRecording && !provider.profileCompleted && !provider.uploadingProfile;
    final isComplete = provider.profileCompleted;
    final percent = (provider.percentageCompleted * 100).toInt();
    // 录音达 100% 即标记可继续（一次性置位，上传在后台进行）。
    if (provider.percentageCompleted >= 1.0 && !_reached100) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _reached100 = true);
      });
    }

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
                    style: const TextStyle(fontFamily: JXB.fontDisplay, fontSize: 26, fontWeight: FontWeight.w700, height: 1.25),
                    children: obL(context, 'zh', 'en') == 'zh'
                        ? const [
                            TextSpan(text: '教 Memorion\n识别你的', style: TextStyle(color: JXB.textPrimary)),
                            TextSpan(text: '声音', style: TextStyle(color: JXB.brandPrimary)),
                          ]
                        : const [
                            TextSpan(text: 'Teach Memorion\nto know your ', style: TextStyle(color: JXB.textPrimary)),
                            TextSpan(text: 'voice', style: TextStyle(color: JXB.brandPrimary)),
                          ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                    obL(context, 'Memorion 需要学习你的声音以在对话中识别你。请自然说话约 30 秒。',
                        'Memorion needs to learn your voice to recognize you in conversations. Speak naturally for about 30 seconds.'),
                    style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary, height: 1.5)),
              ],
            ),
          ),
          const Spacer(),
          if (isRecording)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(color: JXB.warningTint, borderRadius: BorderRadius.circular(999)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _Dot(color: JXB.warning),
                  const SizedBox(width: 6),
                  Text(obL(context, '录音中…', 'Recording…'),
                      style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w600, color: JXB.warning)),
                ],
              ),
            ),
          const SizedBox(height: 28),
          _micCircle(context, provider, isRecording, isComplete),
          const SizedBox(height: 24),
          Text(
            (isComplete || _reached100)
                ? obL(context, '声纹创建完成！', 'Voice profile created!')
                : isRecording
                    ? obL(context, '继续说话，直到进度达到 100%', 'Keep talking until progress reaches 100%')
                    : provider.isInitialising
                        ? obL(context, '正在准备…', 'Preparing…')
                        : obL(context, '点击麦克风开始录制', 'Tap the mic to start recording'),
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary),
          ),
          const Spacer(),
          // 进度条卡（录音中显示）
          if (isRecording || (provider.percentageCompleted > 0 && !isComplete))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(16), boxShadow: JXB.cardShadow),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(obL(context, '进度', 'Progress'),
                            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 13, color: JXB.textSecondary)),
                        Text('$percent%',
                            style: const TextStyle(
                                fontFamily: JXB.fontNumber, fontSize: 14, fontWeight: FontWeight.w700, color: JXB.brandPrimary)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: provider.percentageCompleted,
                        backgroundColor: const Color(0xFFE9EDF2),
                        valueColor: const AlwaysStoppedAnimation<Color>(JXB.brandPrimary),
                        minHeight: 7,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, MediaQuery.of(context).padding.bottom + 12),
            child: Column(
              children: [
                _primaryButton(
                  (isComplete || _reached100) ? obL(context, '完成', 'Done') : obL(context, '下一步', 'Next'),
                  // 录音达 100% 即可继续（上传在后台完成），不必等 profileCompleted，避免 ~5s 等待。
                  (isComplete || _reached100)
                      ? widget.onDone
                      : (provider.startedRecording ? null : () => _startRecording(provider)),
                ),
                if (!provider.startedRecording && !widget.standalone) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: widget.onSkip,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(obL(context, '暂时跳过', 'Skip for now'),
                          style: const TextStyle(
                              fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w500, color: JXB.textSecondary)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _micCircle(BuildContext context, SpeechProfileProvider provider, bool isRecording, bool isComplete) {
    final color = isComplete ? JXB.success : JXB.brandPrimary;
    return GestureDetector(
      onTap: (provider.startedRecording || provider.isInitialising) ? null : () => _startRecording(provider),
      behavior: HitTestBehavior.opaque,
      child: _PulsingMic(
        color: color,
        // 录音中脉冲闪动（收音感）；完成/未录时静止。
        pulsing: isRecording,
        child: provider.isInitialising
            ? const CircularProgressIndicator(color: JXB.brandPrimary, strokeWidth: 2)
            : Icon(isComplete ? Icons.check_rounded : Icons.mic_rounded, color: color, size: 40),
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback? onTap) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? JXB.brandPrimary : JXB.brandPrimary.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}

/// 麦克风大圆钮：录音中向外扩散脉冲环 + 呼吸光晕（收音感）；静止时无动画。
class _PulsingMic extends StatefulWidget {
  final Color color;
  final bool pulsing;
  final Widget child;
  const _PulsingMic({required this.color, required this.pulsing, required this.child});

  @override
  State<_PulsingMic> createState() => _PulsingMicState();
}

class _PulsingMicState extends State<_PulsingMic> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 176,
      height: 176,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              if (widget.pulsing) ...[
                _ripple(0.0),
                _ripple(0.5),
              ],
              // 呼吸光晕的内圆
              Container(
                width: 132,
                height: 132,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: JXB.surface,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: widget.pulsing ? (0.2 + 0.25 * _breath()) : 0.22),
                      blurRadius: 24,
                      spreadRadius: widget.pulsing ? (4 + 6 * _breath()) : 4,
                    ),
                  ],
                ),
                child: Container(
                  width: 92,
                  height: 92,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: widget.color.withValues(alpha: 0.12), shape: BoxShape.circle),
                  child: widget.child,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  double _breath() {
    // 0..1..0 三角波
    final t = _c.value;
    return t < 0.5 ? t * 2 : (1 - t) * 2;
  }

  Widget _ripple(double phase) {
    final t = (_c.value + phase) % 1.0;
    final size = 132 + t * 44; // 132→176
    return Opacity(
      opacity: (1 - t) * 0.4,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: widget.color.withValues(alpha: 0.5), width: 1.5),
        ),
      ),
    );
  }
}
