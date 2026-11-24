import 'package:flutter/material.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/pages/onboarding/wrapper.dart';
import 'package:memorion/pages/today_chapters/home_shell_wrapper.dart';
import 'package:memorion/providers/auth_provider.dart';
import 'package:provider/provider.dart';

/// Mobile app tree with Firebase authentication check
/// Shows onboarding (with Google/Apple login) if not signed in
class MobileApp extends StatefulWidget {
  const MobileApp({super.key});

  @override
  State<MobileApp> createState() => _MobileAppState();
}

class _MobileAppState extends State<MobileApp> {
  @override
  Widget build(BuildContext context) {
    // Listen to AuthenticationProvider so this rebuilds after sign-in
    final authProvider = context.watch<AuthenticationProvider>();
    final isSignedIn = authProvider.isSignedIn();

    if (isSignedIn && SharedPreferencesUtil().memorionOnboardingCompleted) {
      // 1.0 浅色正式壳（承接旧壳全部启动初始化，UI 用新版今日页）。
      return const HomeShellWrapper();
    } else {
      return const OnboardingWrapper();
    }
  }
}
