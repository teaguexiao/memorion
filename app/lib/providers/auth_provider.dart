import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:memorion/backend/auth.dart' as backend_auth;
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/http/api/app_auth.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/providers/base_provider.dart';
import 'package:memorion/services/notifications.dart';
import 'package:memorion/services/watch_moment_service.dart';
import 'package:memorion/utils/alerts/app_snackbar.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:memorion/utils/localization_helper.dart';
import 'package:url_launcher/url_launcher.dart';

/// AuthenticationProvider with Firebase Auth (Google + Apple Sign In)
/// After login, Firebase UID is used as external_user_id for Memorion Developer API
class AuthenticationProvider extends BaseProvider {
  FirebaseAuth get _auth => FirebaseAuth.instance;

  User? user;
  String? authToken;
  bool _loading = false;
  @override
  bool get loading => _loading;

  AuthenticationProvider() {
    _initializeAuthListeners();
  }

  void _initializeAuthListeners() {
    Future.microtask(() {
      _auth.authStateChanges().distinct((p, n) => p?.uid == n?.uid).listen((User? user) {
        this.user = user;
        SharedPreferencesUtil().uid = user?.uid ?? '';
        SharedPreferencesUtil().email = user?.email ?? '';
        SharedPreferencesUtil().givenName = user?.displayName?.split(' ')[0] ?? '';
        // Sync Firebase UID to ApiConfig
        if (user != null) {
          ApiConfig().setExternalUserIdFromFirebase(user.uid);
        }
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          unawaited(WatchMomentService.instance.accountChanged().catchError((Object error) {
            debugPrint('[Watch moments] account snapshot will retry: $error');
          }));
        }
      });
      _auth.idTokenChanges().distinct((p, n) => p?.uid == n?.uid).listen((User? user) async {
        if (user == null) {
          SharedPreferencesUtil().authToken = '';
          authToken = null;
        } else {
          try {
            if (SharedPreferencesUtil().authToken.isEmpty ||
                DateTime.now().millisecondsSinceEpoch > SharedPreferencesUtil().tokenExpirationTime) {
              authToken = await backend_auth.getIdToken();
            }
          } catch (e) {
            authToken = null;
            debugPrint('Failed to get token: $e');
          }
        }
        notifyListeners();
      });
    });
  }

  /// Signed in = Firebase user exists AND API config has key + user ID
  bool isSignedIn() => _auth.currentUser != null && !_auth.currentUser!.isAnonymous;

  void setLoading(bool value) {
    _loading = value;
    notifyListeners();
  }

  Future<void> onGoogleSignIn(Function() onSignIn) async {
    if (!loading) {
      setLoadingState(true);
      await backend_auth.signInWithGoogle();
      if (isSignedIn()) {
        await _signIn(onSignIn);
      } else {
        AppSnackbar.showSnackbarError(appT(
          (s) => s.authFailedSignInGoogle,
          'Failed to sign in with Google, please try again.',
        ));
      }
      setLoadingState(false);
    }
  }

  Future<void> onAppleSignIn(Function() onSignIn) async {
    if (!loading) {
      setLoadingState(true);
      await backend_auth.signInWithApple();
      if (isSignedIn()) {
        await _signIn(onSignIn);
      } else {
        AppSnackbar.showSnackbarError(appT(
          (s) => s.authFailedSignInApple,
          'Failed to sign in with Apple, please try again.',
        ));
      }
      setLoadingState(false);
    }
  }

  Future<String?> onEmailSignIn(S s, String email, String password, Function() onSignIn) async {
    if (!loading) {
      setLoadingState(true);
      try {
        await backend_auth.signInWithEmail(email, password);
        if (isSignedIn()) {
          await _signIn(onSignIn);
          setLoadingState(false);
          return null;
        } else {
          setLoadingState(false);
          return s.authErrorFailedSignIn;
        }
      } on FirebaseAuthException catch (e) {
        setLoadingState(false);
        return _mapFirebaseAuthError(s, e.code);
      } catch (e) {
        setLoadingState(false);
        return s.authErrorUnexpected;
      }
    }
    return null;
  }

  Future<String?> onEmailSignUp(S s, String email, String password, String fullName, Function() onSignIn) async {
    if (!loading) {
      setLoadingState(true);
      try {
        await backend_auth.signUpWithEmail(email, password, fullName);
        if (isSignedIn()) {
          await _signIn(onSignIn);
          setLoadingState(false);
          return null;
        } else {
          setLoadingState(false);
          return s.authErrorFailedCreateAccount;
        }
      } on FirebaseAuthException catch (e) {
        setLoadingState(false);
        return _mapFirebaseAuthError(s, e.code);
      } catch (e) {
        setLoadingState(false);
        return s.authErrorUnexpected;
      }
    }
    return null;
  }

  Future<String?> onForgotPassword(S s, String email) async {
    try {
      await backend_auth.sendPasswordResetEmail(email);
      return null;
    } on FirebaseAuthException catch (e) {
      return _mapFirebaseAuthError(s, e.code);
    } catch (e) {
      return s.authErrorFailedToSendResetEmail;
    }
  }

  String _mapFirebaseAuthError(S s, String code) {
    switch (code) {
      case 'invalid-email':
        return s.authErrorInvalidEmail;
      case 'user-disabled':
        return s.authErrorUserDisabled;
      case 'user-not-found':
        return s.authErrorUserNotFound;
      case 'wrong-password':
        return s.authErrorWrongPassword;
      case 'email-already-in-use':
        return s.authErrorEmailAlreadyInUse;
      case 'weak-password':
        return s.authErrorPasswordMinLength;
      case 'operation-not-allowed':
        return s.authErrorEmailSignInNotEnabled;
      case 'too-many-requests':
        return s.authErrorTooManyRequests;
      case 'invalid-credential':
        return s.authErrorInvalidCredential;
      default:
        return s.authErrorGeneric;
    }
  }

  Future<String?> _getIdToken() async {
    try {
      if (SharedPreferencesUtil().authToken.isNotEmpty &&
          DateTime.now().millisecondsSinceEpoch < SharedPreferencesUtil().tokenExpirationTime) {
        return SharedPreferencesUtil().authToken;
      }
      return await backend_auth.getIdToken();
    } catch (e) {
      AppSnackbar.showSnackbarError(appT(
        (s) => s.authFailedRetrieveToken,
        'Failed to retrieve firebase token, please try again.',
      ));
      return null;
    }
  }

  Future<void> _signIn(Function() onSignIn) async {
    String? token = await _getIdToken();
    if (token != null) {
      User user;
      try {
        user = FirebaseAuth.instance.currentUser!;
      } catch (e) {
        AppSnackbar.showSnackbarError(appT(
          (s) => s.authUnexpectedSignInError,
          'Unexpected error signing in, please try again.',
        ));
        return;
      }
      SharedPreferencesUtil().uid = user.uid;
      ApiConfig().setExternalUserIdFromFirebase(user.uid);
      // 换发本人专属的 bound API key，替掉全体共用的内嵌 key。
      // 上一个账号残留的 bound key 归属对不上（boundApiKeyUid != 新 uid），
      // 必须在这里换掉，否则 apiKey 会退回内嵌 key 一直用下去。
      ApiConfig().clearBoundKey();
      await exchangeBoundApiKey();
      MixpanelManager().identify();
      onSignIn();
      NotificationService.instance.saveNotificationToken();
    } else {
      AppSnackbar.showSnackbarError(appT(
        (s) => s.authUnexpectedSignInError,
        'Unexpected error signing in, please try again.',
      ));
    }
  }

  void openTermsOfService() {
    _launchUrl('https://memorion.me/terms-of-service');
  }

  void openPrivacyPolicy() {
    _launchUrl('https://memorion.me/privacy');
  }

  void openEula() {
    _launchUrl('https://memorion.me/eula');
  }

  void _launchUrl(String url) async {
    if (!await launchUrl(Uri.parse(url))) throw 'Could not launch $url';
  }

  Future<void> linkWithGoogle() async {
    setLoading(true);
    try {
      await backend_auth.linkWithGoogle();
    } catch (e) {
      AppSnackbar.showSnackbarError(appT(
        (s) => s.authFailedLinkGoogle,
        'Failed to link with Google, please try again.',
      ));
      rethrow;
    } finally {
      setLoading(false);
    }
  }

  Future<void> linkWithApple() async {
    setLoading(true);
    try {
      final appleProvider = AppleAuthProvider();
      try {
        await FirebaseAuth.instance.currentUser?.linkWithProvider(appleProvider);
      } catch (e) {
        if (e is FirebaseAuthException && e.code == 'credential-already-in-use') {
          final existingCred = e.credential;
          await FirebaseAuth.instance.signOut();
          await FirebaseAuth.instance.signInWithCredential(existingCred!);
          await backend_auth.getIdToken();
          SharedPreferencesUtil().uid = FirebaseAuth.instance.currentUser?.uid ?? '';
          SharedPreferencesUtil().email = FirebaseAuth.instance.currentUser?.email ?? '';
          return;
        }
        rethrow;
      }
    } catch (e) {
      AppSnackbar.showSnackbarError(appT(
        (s) => s.authFailedLinkApple,
        'Failed to link with Apple, please try again.',
      ));
      rethrow;
    } finally {
      setLoading(false);
    }
  }

  Future<bool> migrateAppOwnerId(String oldId) async => true;
}
