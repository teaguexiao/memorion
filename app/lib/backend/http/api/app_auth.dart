import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/api_key_recovery.dart';
import 'package:memorion/backend/auth.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/utils/logger.dart';

/// 用 Firebase ID token 换取「只能访问本人数据」的 bound API key。
///
/// 为什么需要：App 出厂时把一把 developer key 编进了二进制，全体用户共用。
/// 混淆不等于加密，那把 key 必须当成已公开；而它没有绑定用户，只要换个
/// external_user_id 就能读写任何人的数据。换成每用户 bound key 之后，
/// 后端会强制校验 external_user_id 必须等于绑定的 uid，越权就 403。
///
/// 这里不能用 makeApiCall：它会自动塞 Authorization=API key 和
/// external_user_id，而本端点要的恰好是 Firebase Bearer token。
Future<bool> exchangeBoundApiKey() async {
  final idToken = await _freshIdToken();
  if (idToken == null || idToken.isEmpty) {
    Logger.debug('[app-auth] no Firebase ID token, skipping key exchange');
    return false;
  }

  try {
    // 登录路径会 await 这个调用，所以必须有硬超时：接口抖动/挂住不能把用户
    // 挡在登录外面。超时按失败处理，下次冷启动再试。
    final response = await http
        .post(
          Uri.parse('${Env.apiBaseUrl}v1/auth/app-token'),
          headers: {
            'Authorization': 'Bearer $idToken',
            'Content-Type': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      Logger.debug('[app-auth] key exchange failed: ${response.statusCode} ${response.body}');
      return false;
    }

    final data = jsonDecode(response.body);
    final key = data['api_key'] as String?;
    final uid = data['external_user_id'] as String?;
    if (key == null || key.isEmpty || uid == null || uid.isEmpty) {
      Logger.debug('[app-auth] key exchange returned an incomplete payload');
      return false;
    }

    ApiConfig().saveBoundKey(key, uid);
    Logger.debug('[app-auth] bound API key stored for $uid');
    return true;
  } catch (e) {
    Logger.debug('[app-auth] key exchange error: $e');
    return false;
  }
}

/// 拿一个未过期、且确实属于当前登录用户的 Firebase ID token，优先用缓存里的。
///
/// 直接调 getIdToken() 会强制刷新（getIdTokenResult(true)），自带 10s 超时；
/// 叠上换发请求的 10s，登录最坏要等 20s。缓存 token 还有效时直接用它，
/// 把登录路径的额外开销压到一次 HTTP 往返。留 5 分钟余量，避免 token 在
/// 路上过期被后端 401。
///
/// **只看过期时间是不够的**：signOut() 不清 authToken，而 Firebase token 活 1 小时。
/// 同一次会话里 A 登出、B 登入，缓存里还是 A 的 token；拿它换发会得到绑定 A 的 key，
/// 归属校验（boundApiKeyUid != externalUserId）虽然会让 apiKey 忽略旧账号的 bound key，
/// 不会串数据，但 B 在这一小时里永远换不到自己的 bound key，迁移就悄悄失效了。
/// 所以必须比对 token 里的 sub 与当前 currentUser.uid，不符就强制刷新。
Future<String?> _freshIdToken() async {
  final cached = SharedPreferencesUtil().authToken;
  final expiry = SharedPreferencesUtil().tokenExpirationTime;
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  if (cached.isNotEmpty && expiry - nowMs > 5 * 60 * 1000 && _tokenBelongsToCurrentUser(cached)) {
    return cached;
  }
  return await getIdToken();
}

bool _tokenBelongsToCurrentUser(String token) {
  final currentUid = FirebaseAuth.instance.currentUser?.uid;
  if (currentUid == null || currentUid.isEmpty) return false;
  return uidFromIdToken(token) == currentUid;
}

/// 从 Firebase ID token 里读出它属于哪个 uid，读不出来返回 null。
///
/// ID token 是 JWT，payload 里的 `sub` 就是 uid，本地解一下即可判断归属，
/// 不用多一次网络往返。
///
/// 这里**不做签名校验**——真正的校验在后端（verify_id_token）。本地只用它回答
/// 「该不该复用这个缓存」，判错的代价只是多刷一次 token，不构成信任边界。
/// 所以解析失败一律返回 null，让调用方走强制刷新。
String? uidFromIdToken(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    // JWT 用的是 base64url 且去掉了填充，得自己补回来。
    final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    if (claims is! Map) return null;
    final sub = claims['sub'];
    return sub is String && sub.isNotEmpty ? sub : null;
  } catch (e) {
    Logger.debug('[app-auth] could not read uid from cached token: $e');
    return null;
  }
}

/// 确保当前登录用户持有自己的 bound key，没有则换发一次。
///
/// 换发失败时，下次启动可以再试。
Future<void> ensureBoundApiKey() async {
  if (ApiConfig().usingBoundKey) return;
  await exchangeBoundApiKey();
}

/// 全 App 共用一个自愈器 —— **必须是同一个实例**，单飞才拦得住并发换发。
final ApiKeyRecovery apiKeyRecovery = ApiKeyRecovery(exchange: exchangeBoundApiKey);

/// Refresh a key after a 401 and retry only when credentials are available.
///
/// An in-flight response can arrive after another request refreshed the key.
/// Compare [rejectedKey] before discarding the current bound key.
Future<bool> recoverFromUnauthorized({
  required String rejectedKey,
  @visibleForTesting ApiKeyRecovery? recovery,
}) async {
  if (await (recovery ?? apiKeyRecovery).recover()) return true;
  final config = ApiConfig();
  // 凭据在这个请求发出之后已经变过了 ⇒ 值得拿新的重试一次，而且绝不能在这里再清一次。
  if (rejectedKey != config.apiKey) return config.apiKey.isNotEmpty;
  if (!config.usingBoundKey) return false;
  Logger.debug('[app-auth] 换发没成功，丢弃已作废的 bound key');
  config.clearBoundKey();
  return config.apiKey.isNotEmpty;
}
