import 'package:flutter/material.dart';
import 'package:memorion/backend/auth.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/pages/onboarding/ai_data_consent_page.dart';
import 'package:memorion/pages/onboarding/auth.dart';
import 'package:memorion/pages/onboarding/device_pairing_page.dart';
import 'package:memorion/pages/onboarding/personalization_page.dart';
import 'package:memorion/pages/onboarding/speech_profile_onboarding_page.dart';
import 'package:memorion/providers/auth_provider.dart';
import 'package:memorion/providers/home_provider.dart';
import 'package:memorion/pages/onboarding/onboarding_background.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:provider/provider.dart';

/// Onboarding 浅色壳（记小宝 1.0 改版）。
///
/// 5 步：0 登录 / 1 个性化 / 2 关于你的数据 / 3 连接设备 / 4 声纹训练。
/// 进度点只在 1-4 步显示（4 个点）。渐变背景全程使用 [JxbGradientBackground]。
/// 步进 / 老用户判定 / 完成写盘等业务逻辑保留自旧壳。
class OnboardingWrapper extends StatefulWidget {
  const OnboardingWrapper({super.key});

  @override
  State<OnboardingWrapper> createState() => _OnboardingWrapperState();
}

class _OnboardingWrapperState extends State<OnboardingWrapper> with TickerProviderStateMixin {
  static const int kPersonalizationPage = 1;
  static const int kAiDataConsentPage = 2;

  TabController? _controller;
  bool _isReturningUser = false;

  @override
  void initState() {
    _controller = TabController(length: 5, vsync: this);
    _controller!.addListener(() => setState(() {}));

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (isSignedIn()) {
        if (mounted) {
          context.read<HomeProvider>().setupHasSpeakerProfile();
          if (!SharedPreferencesUtil().memorionOnboardingCompleted) {
            _checkReturningUser();
          }
        }
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _goNext() {
    if (_controller!.index < _controller!.length - 1) {
      _controller!.animateTo(_controller!.index + 1);
    }
  }

  Future<void> _checkReturningUser() async {
    String? language;
    try {
      language = await getUserPrimaryLanguage();
    } catch (_) {
      // 网络错误当作新用户，避免卡住。
    }
    if (!mounted) return;

    if (language != null && language.isNotEmpty) {
      _isReturningUser = true;
      if (!SharedPreferencesUtil().aiDataConsentAccepted) {
        _controller!.animateTo(kAiDataConsentPage);
      } else {
        _completeOnboarding();
      }
    } else {
      _goNext(); // → 个性化
    }
  }

  void _completeOnboarding() {
    SharedPreferencesUtil().onboardingCompleted = true;
    SharedPreferencesUtil().memorionOnboardingCompleted = true;
    // MobileApp 监听 AuthenticationProvider，memorionOnboardingCompleted=true 后自动切主页。
    if (mounted) {
      context.read<AuthenticationProvider>().notifyListeners();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Theme(
        data: ThemeData.light(useMaterial3: false).copyWith(
          scaffoldBackgroundColor: JXB.bgApp,
          colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
        ),
        child: Scaffold(
          backgroundColor: JXB.bgApp,
          resizeToAvoidBottomInset: true,
          body: OnboardingBackground(
            child: _buildCurrentPage(),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentPage() {
    final index = _controller!.index;
    return Stack(
      children: [
        _buildPages()[index],
        // 进度点（步骤 1-4）
        if (index >= kPersonalizationPage)
          Positioned(
            top: MediaQuery.of(context).padding.top + 14,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (i) {
                final stepIndex = i + 1;
                final isCurrent = stepIndex == index;
                final isCompleted = stepIndex < index;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: isCurrent ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? JXB.brandPrimary
                        : isCompleted
                            ? JXB.brandPrimary.withValues(alpha: 0.4)
                            : const Color(0x33808594),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
          ),
        // 返回键（第 2 步起）
        if (index > kPersonalizationPage)
          Positioned(
            top: MediaQuery.of(context).padding.top + 6,
            left: 16,
            child: GestureDetector(
              onTap: () => _controller!.animateTo(_controller!.index - 1),
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
    );
  }

  List<Widget> _buildPages() {
    return [
      // 0: 登录
      AuthComponent(
        onSignIn: () {
          if (!mounted) return;
          SharedPreferencesUtil().hasMemorionDevice = true;
          MixpanelManager().onboardingStepCompleted('Auth');
          context.read<HomeProvider>().setupHasSpeakerProfile();
          if (SharedPreferencesUtil().memorionOnboardingCompleted) {
            // 本机已完成 onboarding — MobileApp 会自动切主页。
          } else {
            _checkReturningUser();
          }
        },
      ),

      // 1: 个性化（昵称 + 语言 + 时区 + 记录内容偏好）
      PersonalizationPage(
        goNext: () {
          MixpanelManager().onboardingStepCompleted('Personalization');
          _goNext();
        },
      ),

      // 2: 关于你的数据（AI 同意）
      AiDataConsentPage(
        goNext: () {
          MixpanelManager().onboardingStepCompleted('AI Data Consent');
          if (_isReturningUser) {
            _completeOnboarding();
          } else {
            _goNext();
          }
        },
      ),

      // 3: 连接设备
      DevicePairingPage(
        goNext: () {
          MixpanelManager().onboardingStepCompleted('Device Pairing');
          _goNext();
        },
        onSkip: () {
          MixpanelManager().onboardingStepCompleted('Device Pairing Skipped');
          _goNext(); // 无设备也进声纹步（可用手机麦克风录制），声纹步可再跳过完成
        },
      ),

      // 4: 声纹训练
      SpeechProfileOnboardingPage(
        onDone: () {
          MixpanelManager().onboardingStepCompleted('Speech Profile');
          _completeOnboarding();
        },
        onSkip: () {
          MixpanelManager().onboardingStepCompleted('Speech Profile Skipped');
          _completeOnboarding();
        },
      ),
    ];
  }
}
