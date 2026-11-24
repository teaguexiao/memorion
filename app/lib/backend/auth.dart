import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/utils/logger.dart';
import 'package:google_sign_in/google_sign_in.dart' as standard_google_sign_in;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

Completer<String?>? _getIdTokenLock;

/// Generates a cryptographically secure random nonce
String generateNonce([int length = 32]) {
  const charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
  final random = Random.secure();
  return List.generate(length, (_) => charset[random.nextInt(charset.length)]).join();
}

/// Returns the sha256 hash of [input] in hex notation
String sha256ofString(String input) {
  final bytes = utf8.encode(input);
  final digest = sha256.convert(bytes);
  return digest.toString();
}

/// Sign in with Apple ID
Future<UserCredential?> signInWithApple() async {
  try {
    debugPrint('Signing out current user...');
    await FirebaseAuth.instance.signOut();

    final rawNonce = generateNonce();
    final nonce = sha256ofString(rawNonce);

    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
      nonce: nonce,
    );

    if (appleCredential.identityToken == null) {
      throw Exception('Apple Sign In failed - no identity token received.');
    }

    final oauthCredential = OAuthProvider("apple.com").credential(
      idToken: appleCredential.identityToken,
      rawNonce: rawNonce,
      accessToken: appleCredential.authorizationCode,
    );

    UserCredential userCred = await FirebaseAuth.instance.signInWithCredential(oauthCredential);
    var user = FirebaseAuth.instance.currentUser!;

    if (appleCredential.email != null) {
      SharedPreferencesUtil().email = appleCredential.email!;
    }
    if (appleCredential.givenName != null) {
      SharedPreferencesUtil().givenName = appleCredential.givenName!;
      SharedPreferencesUtil().familyName = appleCredential.familyName ?? '';
      await user.updateProfile(displayName: SharedPreferencesUtil().fullName);
      await user.reload();
      user = FirebaseAuth.instance.currentUser!;
    } else {
      var nameParts = user.displayName?.split(' ');
      SharedPreferencesUtil().givenName = nameParts?[0] ?? '';
      SharedPreferencesUtil().familyName = nameParts != null && nameParts.length > 1 ? nameParts.last : '';
    }
    if (SharedPreferencesUtil().email.isEmpty) {
      SharedPreferencesUtil().email = user.email ?? '';
    }

    // Set Firebase UID as external_user_id for Memorion API
    ApiConfig().setExternalUserIdFromFirebase(user.uid);
    await getIdToken();
    return userCred;
  } on FirebaseAuthException catch (e) {
    debugPrint('FirebaseAuthException: ${e.code} - ${e.message}');
    return null;
  } catch (e) {
    debugPrint('Error during Apple Sign In: $e');
    Logger.handle(e, null, message: 'An error occurred while signing in. Please try again later.');
    return null;
  }
}

/// Sign in with Google (standard iOS/Android flow)
Future<UserCredential?> signInWithGoogle() async {
  try {
    final googleUser = await standard_google_sign_in.GoogleSignIn(scopes: ['profile', 'email']).signIn();
    final googleAuth = await googleUser?.authentication;
    if (googleAuth == null) return null;
    if (googleAuth.accessToken == null && googleAuth.idToken == null) return null;

    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    var result = await FirebaseAuth.instance.signInWithCredential(credential);

    var givenName = result.additionalUserInfo?.profile?['given_name'] ?? '';
    var familyName = result.additionalUserInfo?.profile?['family_name'] ?? '';
    var email = result.additionalUserInfo?.profile?['email'] ?? '';

    if (email.isNotEmpty) SharedPreferencesUtil().email = email;
    if (givenName.isNotEmpty) {
      SharedPreferencesUtil().givenName = givenName;
      SharedPreferencesUtil().familyName = familyName;
    }

    var user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      ApiConfig().setExternalUserIdFromFirebase(user.uid);
    }

    await getIdToken();
    return result;
  } catch (e) {
    debugPrint('Failed to sign in with Google: $e');
    Logger.handle(e, null, message: 'An error occurred while signing in. Please try again later.');
    return null;
  }
}

/// Get Firebase ID token and store it.
/// Uses a lock to prevent concurrent getIdTokenResult(true) calls which
/// corrupt the iOS platform channel and cause silent hangs.
///
/// Capped at 10s — when the app has been backgrounded for hours, the iOS
/// Firebase SDK's first network call (DNS / TLS / securetoken endpoint
/// round-trip) can stall the platform channel for tens of seconds, leaving
/// auth-dependent chat flows hanging. The timeout falls into the same catch
/// path as a real refresh failure and the cached-token logic decides whether
/// to return the fallback or null.
Future<String?> getIdToken() async {
  if (_getIdTokenLock != null) {
    return _getIdTokenLock!.future;
  }
  _getIdTokenLock = Completer<String?>();
  try {
    IdTokenResult? newToken = await FirebaseAuth.instance.currentUser
        ?.getIdTokenResult(true)
        .timeout(const Duration(seconds: 10));
    if (newToken?.token != null) {
      var user = FirebaseAuth.instance.currentUser!;
      SharedPreferencesUtil().uid = user.uid;
      SharedPreferencesUtil().tokenExpirationTime = newToken?.expirationTime?.millisecondsSinceEpoch ?? 0;
      SharedPreferencesUtil().authToken = newToken?.token ?? '';
      if (SharedPreferencesUtil().email.isEmpty) {
        SharedPreferencesUtil().email = user.email ?? '';
      }
      if (SharedPreferencesUtil().givenName.isEmpty) {
        var parts = user.displayName?.split(' ') ?? [];
        if (parts.isNotEmpty) {
          SharedPreferencesUtil().givenName = parts[0];
          if (parts.length > 1) SharedPreferencesUtil().familyName = parts.sublist(1).join(' ');
        }
      }
      ApiConfig().setExternalUserIdFromFirebase(user.uid);
    }
    _getIdTokenLock!.complete(newToken?.token);
    return newToken?.token;
  } catch (e) {
    debugPrint('getIdToken error: $e');
    // Refresh failed (network blip, FirebaseAuth 5xx, time skew, ...). Fall
    // back to the cached token, but ONLY if it hasn't expired yet — Firebase
    // ID tokens last 1h, so a stale cached token will be rejected by the
    // backend with 401 "Invalid Firebase token: ExpiredIdTokenError" and
    // give the user a confusing chat startup failure.
    // Surface null instead so callers can route to a "please re-login"
    // path or retry later when refresh actually succeeds.
    final fallback = SharedPreferencesUtil().authToken;
    final expiry = SharedPreferencesUtil().tokenExpirationTime;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Treat as expired with a 60s safety margin to cover clock skew + the
    // travel time of the request being authorized with this token.
    if (fallback.isEmpty || expiry == 0 || expiry - nowMs < 60 * 1000) {
      debugPrint('getIdToken: cached token expired/missing — returning null');
      _getIdTokenLock!.complete(null);
      return null;
    }
    _getIdTokenLock!.complete(fallback);
    return fallback;
  } finally {
    _getIdTokenLock = null;
  }
}

/// Sign out from Firebase and clear user-level config
Future<void> signOut() async {
  await FirebaseAuth.instance.signOut();
  try { await standard_google_sign_in.GoogleSignIn().signOut(); } catch (_) {}
  SharedPreferencesUtil().externalUserId = '';
  // 本人专属的 bound key 属于用户凭据，不能留给下一个登录的人。
  ApiConfig().clearBoundKey();
}

/// Check if user is signed in via Firebase (non-anonymous)
bool isSignedIn() {
  final user = FirebaseAuth.instance.currentUser;
  return user != null && !user.isAnonymous;
}

dynamic getFirebaseUser() => FirebaseAuth.instance.currentUser;

Future<void> updateGivenName(String fullName) async {
  try {
    final parts = fullName.split(' ');
    SharedPreferencesUtil().givenName = parts[0];
    SharedPreferencesUtil().familyName = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    var user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.updateProfile(displayName: fullName);
      await user.reload();
    }

    await setUserDisplayName(fullName);
  } catch (e) {
    debugPrint('Error in updateGivenName: $e');
  }
}

Future<void> signInAnonymously() async {
  try {
    await FirebaseAuth.instance.signInAnonymously();
    var user = FirebaseAuth.instance.currentUser!;
    SharedPreferencesUtil().uid = user.uid;
    await getIdToken();
  } catch (e) {
    Logger.handle(e, null, message: 'An error occurred while signing in. Please try again later.');
  }
}

/// Sign up with email and password
Future<UserCredential?> signUpWithEmail(String email, String password, String fullName) async {
  try {
    await FirebaseAuth.instance.signOut();

    UserCredential userCred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );

    var user = userCred.user!;
    await user.updateProfile(displayName: fullName);
    await user.sendEmailVerification();
    await user.reload();
    user = FirebaseAuth.instance.currentUser!;

    final parts = fullName.split(' ');
    SharedPreferencesUtil().givenName = parts[0];
    SharedPreferencesUtil().familyName = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    SharedPreferencesUtil().email = email;

    ApiConfig().setExternalUserIdFromFirebase(user.uid);
    await getIdToken();
    return userCred;
  } on FirebaseAuthException {
    rethrow;
  } catch (e) {
    debugPrint('Error during Email Sign Up: $e');
    Logger.handle(e, null, message: 'An error occurred while signing up. Please try again later.');
    return null;
  }
}

/// Sign in with email and password
Future<UserCredential?> signInWithEmail(String email, String password) async {
  try {
    await FirebaseAuth.instance.signOut();

    UserCredential userCred = await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email,
      password: password,
    );

    var user = userCred.user!;
    SharedPreferencesUtil().email = user.email ?? '';
    var nameParts = user.displayName?.split(' ');
    SharedPreferencesUtil().givenName = nameParts?[0] ?? '';
    SharedPreferencesUtil().familyName = nameParts != null && nameParts.length > 1 ? nameParts.last : '';

    ApiConfig().setExternalUserIdFromFirebase(user.uid);
    await getIdToken();
    return userCred;
  } on FirebaseAuthException {
    rethrow;
  } catch (e) {
    debugPrint('Error during Email Sign In: $e');
    Logger.handle(e, null, message: 'An error occurred while signing in. Please try again later.');
    return null;
  }
}

/// Send password reset email
Future<void> sendPasswordResetEmail(String email) async {
  await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
}

Future<UserCredential?> linkWithGoogle() async {
  try {
    final googleUser = await standard_google_sign_in.GoogleSignIn().signIn();
    if (googleUser == null) return null;
    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken, idToken: googleAuth.idToken,
    );
    try {
      return await FirebaseAuth.instance.currentUser?.linkWithCredential(credential);
    } catch (e) {
      if (e is FirebaseAuthException && e.code == 'credential-already-in-use') {
        await FirebaseAuth.instance.signOut();
        final result = await FirebaseAuth.instance.signInWithCredential(e.credential!);
        await getIdToken();
        SharedPreferencesUtil().uid = FirebaseAuth.instance.currentUser?.uid ?? '';
        SharedPreferencesUtil().email = FirebaseAuth.instance.currentUser?.email ?? '';
        return result;
      }
      rethrow;
    }
  } catch (e) {
    debugPrint('Failed to link with Google: $e');
    rethrow;
  }
}
