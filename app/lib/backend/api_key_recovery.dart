import 'package:memorion/utils/logger.dart';

/// 服务端不认识本机这把 API key 时，重新换发一把，让调用方能重试一次。
///
/// **为什么需要。** `POST /v1/auth/app-token` 的语义是「换发即撤销该用户此前的 App
/// key」，而撤销是**硬删除**。所以在第二台设备（或模拟器）上登录同一个账号，会把第一台
/// 手里那把 key 从服务端直接删掉。而 [ensureBoundApiKey] 只在本地**没有** bound key
/// 时才换发 —— 本地明明有一把（只是已经作废了），于是它永远不会自愈：那台设备之后每一个
/// 请求都 401，录音、人物、时间线、首页全挂，只有用户手动登出再登入才能恢复。
///
/// 2026-08-11 真发生过：一台设备连续 401 了 111 次、横跨 19 小时，而用户看到的只是
/// 「加载失败」——App 从不上报鉴权失败，服务端也不记 401 的原因，所以两边都没人知道。
///
/// **单飞是这个类存在的主要理由，不是优化。** 换发会撤销上一把 key，所以 N 个并发的
/// 401 各自换发会**互相撤销**：最后只有一把有效，另外 N-1 个请求拿着刚被顶掉的新 key
/// 继续 401。App 冷启动会并发发十几个请求，一定会撞上 —— 那会把一个可自愈的故障变成
/// 一轮雪崩。所以同一时刻只允许一次换发在跑，其余调用 await 同一个 Future。
///
/// 冷却是第二道闸：换发失败时别让每个失败请求都额外打一次换发（请求量翻倍）；换发刚
/// 成功时也不必再换，本地那把已经是最新的，直接让调用方重试即可。
class ApiKeyRecovery {
  ApiKeyRecovery({
    required Future<bool> Function() exchange,
    DateTime Function()? clock,
    Duration failureCooldown = const Duration(seconds: 60),
    Duration successCooldown = const Duration(seconds: 30),
  })  : _exchange = exchange,
        _clock = clock ?? DateTime.now,
        _failureCooldown = failureCooldown,
        _successCooldown = successCooldown;

  final Future<bool> Function() _exchange;
  final DateTime Function() _clock;
  final Duration _failureCooldown;
  final Duration _successCooldown;

  Future<bool>? _inFlight;
  DateTime? _lastSuccess;
  DateTime? _lastFailure;

  /// 实际发起过几次换发。给测试断言单飞用。
  int exchangeAttempts = 0;

  /// 试着换一把新 key。返回 true 表示本地 key 已经是新的、值得重试原请求。
  ///
  /// 调用方只应重试**一次**：若新 key 也被拒，那不是凭证过期的问题，重试无用。
  Future<bool> recover() {
    // 单飞：已经有一次换发在跑就搭它的车，绝不并发换发。
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final now = _clock();

    final lastFailure = _lastFailure;
    if (lastFailure != null && now.difference(lastFailure) < _failureCooldown) {
      return Future.value(false);
    }

    // 刚换到过一把新 key，本地已经是最新的了：直接让调用方重试，不再换发。
    // （这条同时兜住「单飞刚结束、下一批 401 紧接着到」的那一拍。）
    final lastSuccess = _lastSuccess;
    if (lastSuccess != null && now.difference(lastSuccess) < _successCooldown) {
      return Future.value(true);
    }

    final future = _run();
    _inFlight = future;
    // 在 recover() 里清而不是在 _run() 的 finally 里清：finally 有可能跑在上面那行
    // 赋值**之前**（_exchange 同步完成时），那样就会把自己的 in-flight 标记漏在原地，
    // 之后所有 401 都搭上一辆已经到站的车。identical 守卫是防止清掉后来者的那一次。
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  Future<bool> _run() async {
    exchangeAttempts++;
    try {
      final ok = await _exchange();
      if (ok) {
        // 这里不用清 _lastFailure：能跑到 _run() 就说明已经越过了失败冷却，
        // 之后任何时刻再查都只会更旧。清它是句读起来合理、但永远观察不到的死代码
        // （变异验证时它存活了，才发现这一点）。
        _lastSuccess = _clock();
        Logger.debug('[api-key-recovery] 换发成功，重试原请求');
      } else {
        _lastFailure = _clock();
        Logger.debug('[api-key-recovery] 换发失败，进入冷却');
      }
      return ok;
    } catch (e) {
      // 换发自己抛了（网络/解析）也要落冷却，否则每个 401 都会再抛一次。
      _lastFailure = _clock();
      Logger.debug('[api-key-recovery] 换发异常: $e');
      return false;
    }
  }
}
