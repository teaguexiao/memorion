/// Covers key refresh failure and delayed unauthorized responses.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/api_key_recovery.dart';
import 'package:memorion/backend/http/api/app_auth.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    SharedPreferencesUtil().memorionApiKey = 'configured_key';
    SharedPreferencesUtil().externalUserId = 'uid_alice';
  });

  /// 换发结果可控的自愈器。真换发要 Firebase，单测里跑不了 —— 而这个函数的价值
  /// 恰恰在「换发失败之后做什么」。
  ApiKeyRecovery recoveryThatReturns(bool ok) => ApiKeyRecovery(exchange: () async => ok);

  Future<bool> recover({required String rejectedKey, required bool exchangeOk}) =>
      recoverFromUnauthorized(rejectedKey: rejectedKey, recovery: recoveryThatReturns(exchangeOk));

  test('ignores the shared key saved by an older build', () async {
    SharedPreferences.setMockInitialValues({'memorionApiKey': 'legacy_shared_key'});
    await SharedPreferencesUtil.init();

    expect(ApiConfig().apiKey, isEmpty);
    expect((await SharedPreferences.getInstance()).containsKey('memorionApiKey'), isFalse);
  });

  test('does not retry without a key when exchange fails', () async {
    SharedPreferencesUtil().memorionApiKey = '';
    ApiConfig().saveBoundKey('bound_alice', 'uid_alice');

    expect(await recover(rejectedKey: 'bound_alice', exchangeOk: false), isFalse);
    expect(await recover(rejectedKey: 'bound_alice', exchangeOk: false), isFalse);
    expect(ApiConfig().apiKey, isEmpty);
  });

  test('换发成功 → 保住本人的 bound key，不退回手工配置的 key', () async {
    ApiConfig().saveBoundKey('bound_alice', 'uid_alice');

    final retry = await recover(rejectedKey: 'bound_alice', exchangeOk: true);

    expect(retry, isTrue, reason: '换到新 key 了，原请求值得重试一次');
    expect(ApiConfig().usingBoundKey, isTrue,
        reason: '换发成功时清掉 bound key 会把本人专属凭据无谓地降级成手工配置的 key');
    expect(ApiConfig().apiKey, 'bound_alice');
  });

  test('被拒的就是当前那把 bound key + 换发失败 → 丢掉它退回手工配置的 key，并让调用方重试', () async {
    ApiConfig().saveBoundKey('bound_alice', 'uid_alice');

    final retry = await recover(rejectedKey: 'bound_alice', exchangeOk: false);

    expect(retry, isTrue, reason: '凭据换过了（退回手工配置的 key），这一次重试才是恢复功能的那次');
    expect(ApiConfig().usingBoundKey, isFalse);
    expect(ApiConfig().apiKey, 'configured_key');
  });

  test('手工配置的 key 自己也被拒 → 不重试（避免清空-重试-再清空的空转）', () async {
    expect(ApiConfig().usingBoundKey, isFalse);

    final retry = await recover(rejectedKey: 'configured_key', exchangeOk: false);

    expect(retry, isFalse,
        reason: '被拒的就是当前这把手工配置的 key，说明问题不在凭据上（被吊销/服务端故障），'
            '再清一次也变不出新的，第二个请求注定同样失败');
    expect(ApiConfig().apiKey, 'configured_key');
  });

  test('退回之后下一次冷启动会重新换发（usingBoundKey 是 ensureBoundApiKey 的判据）', () async {
    ApiConfig().saveBoundKey('bound_alice', 'uid_alice');
    await recover(rejectedKey: 'bound_alice', exchangeOk: false);

    // ensureBoundApiKey() 的早退条件就是这个 getter；false 意味着它会去换发。
    // 直接调它会打 Firebase + 网络，所以这里钉的是那个判据本身。
    expect(ApiConfig().usingBoundKey, isFalse,
        reason: '闭环靠这一点：退回手工配置的 key 之后，下次冷启动自己会换一把本人的，'
            '不需要用户登出重登');
  });

  group('同一批 401（冷启动扇出十几个请求，全部 401）', () {
    test('第一个退回之后，其余请求也必须重试 —— 否则这个修复只对一个请求成立', () async {
      ApiConfig().saveBoundKey('bound_alice', 'uid_alice');

      // 请求 A：被拒的就是当前那把，清掉它、退回手工配置的 key。
      expect(await recover(rejectedKey: 'bound_alice', exchangeOk: false), isTrue);
      expect(ApiConfig().apiKey, 'configured_key');

      // 请求 B/C/D…：带的也是那把旧 key，而当前凭据已经被 A 换成手工配置的 key 了。
      for (final label in ['B', 'C', 'D']) {
        expect(await recover(rejectedKey: 'bound_alice', exchangeOk: false), isTrue,
            reason: '请求 $label 带的旧 key 已不是当前凭据 ⇒ 换过了 ⇒ 值得重试。不让它重试'
                '就等于把已经修好的凭据浪费掉，那些只在冷启动拉一次的 Provider 会空到'
                '用户手动重启');
      }
      expect(ApiConfig().apiKey, 'configured_key', reason: '这些重试不该再清一次凭据');
    });
  });

  group('迟到的 401（本地已经换到一把新的有效 bound key）', () {
    test('绝不能清掉那把新 key —— 否则降级成手工配置的 key，还要等下次冷启动才换回来', () async {
      // 旧 key 被拒后本地换到了新的（登录 / 冷启动的 ensureBoundApiKey 都会走到这一步）。
      ApiConfig().saveBoundKey('fresh-key', 'uid_alice');

      // 一个用**旧** key 发出、迟到返回的 401 到达。第一级此刻正被 60s 失败冷却静音，
      // 所以 exchangeOk 给 false 才是真实情形。
      final retry = await recover(rejectedKey: 'old-key', exchangeOk: false);

      expect(retry, isTrue, reason: '凭据已经是新的了，这个请求值得用新 key 重试一次');
      expect(ApiConfig().apiKey, 'fresh-key',
          reason: '判「现在在用 bound key 就清掉」会把这把刚换好的有效 key 毁掉，'
              '退回手工配置的 key，而 ensureBoundApiKey 只在冷启动跑 ⇒ 长时间不自愈');
      expect(ApiConfig().usingBoundKey, isTrue);
    });
  });
}
