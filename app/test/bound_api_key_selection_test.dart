import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/http/api/app_auth.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 验证 `ApiConfig.apiKey` 的三级优先级：bound key > 存储的 key > 手工配置的 key。
///
/// 这是阶段 1 迁移「零客户端影响」的关键判定点。两个必须成立的性质：
///
/// 1. **换账号后必须回落**。bound key 只能访问它绑定的那个 uid，拿去请求别人
///    的数据后端一律 403。所以 boundApiKeyUid 与当前 externalUserId 不一致时，
///    必须退回手工配置的 key——否则登录第二个账号会整个 App 全接口 403。
/// 2. **换发失败必须能退回**。没有 bound key（首次登录未换发成功、旧版本、
///    接口抖动）时行为与改动前完全一致，功能不受影响。
///
/// 测试通过 memorionApiKey 设置手工配置的 key，
/// 这也正是 initializeFromEnv() 在真机上写入的那个值。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  test('没有 bound key 时，行为与改动前一致（用存储/手工配置的 key）', () {
    SharedPreferencesUtil().memorionApiKey = 'configured_key';
    SharedPreferencesUtil().externalUserId = 'uid_alice';

    expect(ApiConfig().apiKey, 'configured_key');
    expect(ApiConfig().usingBoundKey, isFalse);
  });

  test('bound key 归属当前用户时优先生效', () {
    SharedPreferencesUtil().memorionApiKey = 'configured_key';
    SharedPreferencesUtil().externalUserId = 'uid_alice';
    ApiConfig().saveBoundKey('bound_key_alice', 'uid_alice');

    expect(ApiConfig().apiKey, 'bound_key_alice');
    expect(ApiConfig().usingBoundKey, isTrue);
  });

  test('换账号后 bound key 归属不符，回落到手工配置的 key', () {
    SharedPreferencesUtil().memorionApiKey = 'configured_key';
    SharedPreferencesUtil().externalUserId = 'uid_alice';
    ApiConfig().saveBoundKey('bound_key_alice', 'uid_alice');

    // Bob 登录：uid 变了，但存储里还是 Alice 的 key。
    SharedPreferencesUtil().externalUserId = 'uid_bob';

    expect(ApiConfig().apiKey, 'configured_key',
        reason: '拿 Alice 的 key 请求 Bob 的数据会被后端 403');
    expect(ApiConfig().usingBoundKey, isFalse);
  });

  test('clearBoundKey 后回落，且不动手工配置的 key', () {
    SharedPreferencesUtil().memorionApiKey = 'configured_key';
    SharedPreferencesUtil().externalUserId = 'uid_alice';
    ApiConfig().saveBoundKey('bound_key_alice', 'uid_alice');

    ApiConfig().clearBoundKey();

    expect(ApiConfig().apiKey, 'configured_key');
    expect(ApiConfig().usingBoundKey, isFalse);
    expect(SharedPreferencesUtil().boundApiKey, isEmpty);
  });

  test('clear() 同时清掉 bound key，不给下一个登录的人留凭据', () {
    SharedPreferencesUtil().memorionApiKey = 'configured_key';
    SharedPreferencesUtil().externalUserId = 'uid_alice';
    ApiConfig().saveBoundKey('bound_key_alice', 'uid_alice');

    ApiConfig().clear();

    expect(SharedPreferencesUtil().boundApiKey, isEmpty);
    expect(SharedPreferencesUtil().boundApiKeyUid, isEmpty);
  });

  test('saveBoundKey 拒绝空值，避免把有效 key 覆盖成空', () {
    SharedPreferencesUtil().externalUserId = 'uid_alice';
    ApiConfig().saveBoundKey('bound_key_alice', 'uid_alice');

    ApiConfig().saveBoundKey('', 'uid_alice');
    ApiConfig().saveBoundKey('another_key', '');

    expect(ApiConfig().apiKey, 'bound_key_alice');
  });

  /// 换发前必须确认缓存的 ID token 属于当前用户，否则会拿上一个账号的 token
  /// 去换 key。signOut() 不清 authToken，而 token 活 1 小时——同一会话里
  /// A 登出 B 登入时，只看过期时间就会复用 A 的 token，B 在这一小时内永远
  /// 换不到自己的 bound key（归属校验会让它安全回落到手工配置的 key，不串数据，
  /// 但迁移悄悄失效）。归属判断靠解 JWT 的 sub。
  group('uidFromIdToken', () {
    test('读出 payload 里的 sub', () {
      expect(uidFromIdToken(_fakeIdToken({'sub': 'uid_alice'})), 'uid_alice');
    });

    test('无填充的 base64url payload 也能解（JWT 规范去掉了 =）', () {
      // 构造一个长度不是 4 的倍数、且含 base64url 专用字符的 uid。
      final uid = 'uid_${'x' * 7}-_';
      expect(uidFromIdToken(_fakeIdToken({'sub': uid})), uid);
    });

    test('缺 sub / 空 sub / 段数不对 / 非法 base64 一律返回 null，触发强制刷新', () {
      expect(uidFromIdToken(_fakeIdToken({'user_id': 'uid_alice'})), isNull);
      expect(uidFromIdToken(_fakeIdToken({'sub': ''})), isNull);
      expect(uidFromIdToken('not-a-jwt'), isNull);
      expect(uidFromIdToken('aaa.!!!not-base64!!!.ccc'), isNull);
      expect(uidFromIdToken(''), isNull);
    });

    test('payload 不是 JSON 对象时返回 null', () {
      final payload = base64Url.encode(utf8.encode('"just-a-string"')).replaceAll('=', '');
      expect(uidFromIdToken('header.$payload.sig'), isNull);
    });
  });
}

/// 拼一个结构合法的 JWT（签名是假的）。本地只解 payload、不验签，够用。
String _fakeIdToken(Map<String, dynamic> claims) {
  final header = base64Url.encode(utf8.encode('{"alg":"RS256","typ":"JWT"}')).replaceAll('=', '');
  final payload = base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
  return '$header.$payload.fake-signature';
}
