import 'dart:async';

import 'package:flutter/foundation.dart';

/// 保证「同一个 key 上最多只有一个活着的订阅」，并把同一个 key 上的**创建**操作串行化。
///
/// ## 为什么需要它（2026-08-17）
///
/// `flutter_blue_plus` 里所有特征的通知都从**同一条广播流**
/// （`FlutterBluePlus._methodStream`）分流出来，`characteristic.onValueReceived` /
/// `lastValueStream` 只是在它上面加了几层 `where`。所以同一个特征上挂 N 个 `listen`，
/// 设备发来一包音频就会触发 N 次回调 —— 而音频回调体里是 `_socket?.send(...)`，
/// 于是**同一帧被发给服务器 N 遍**。
///
/// 后果不是「多一点流量」，而是三件事：
/// 1. 服务端存下的音频时长按 N 倍膨胀（实测 2026-08-17 中位 9.2 倍、最高 14.8 倍）；
/// 2. 复制的粒度是**一个 opus 帧 = 10ms**，所以听起来不是「你你好好」而是每个音素
///    卡碟抖 N 下 —— 到 6 倍以上 Soniox 就一个字都转不出来，且它**合法地**返回
///    0 段、不报错，全链路零错误日志；
/// 3. 按流入音频计费的话，账单也按 N 倍走（08-03~08-14 单账号实录 93h 送出 145h）。
///
/// ⚠️ **单纯 `await` 掉旧订阅的 `cancel()` 不够**，这是这个类存在的真正理由：
/// `capture_provider.streamAudioToWs` 里「取消旧的」和「记住新的」之间隔着一个
/// `await`（`ensureConnection` / `requestMtu` / `setNotifyValue`，几百毫秒）。两次并发
/// 调用会各自建一个订阅，而 `_bleBytesStream` 只记得后写入的那个 —— 前一个从此**没有
/// 任何引用能取消它**，只能等 BLE 真正断开时被 `cancelWhenDisconnected` 收走。这就是
/// 倍率在一次连接窗口内单调爬升（6 → 14.7）、断开重连后归零的原因。
///
/// 所以不变式必须钉在**创建的那个咽喉点**上，而不是分散在各个调用方。当前的调用方：
/// `capture_provider` 经 `_initiateDeviceAudioStreaming` 的三条路（`_resetState`、
/// BLE 心跳重连、`resumeDeviceRecording`），加上 `speech_profile_provider` 独立订阅同一个
/// 特征。后者眼下**是串行安全的** —— 声纹页在 `initialise` 之前先
/// `await stopStreamDeviceRecording()`、完成后再用回调重启录音 —— 但那是页面级的时序约定，
/// 不是不变式；registry 让它变成不变式。
class LiveSubscriptionRegistry {
  LiveSubscriptionRegistry({this.label = 'subscription'});

  /// 只用于日志，方便在一堆 BLE 日志里认出是谁。
  final String label;

  final Map<String, StreamSubscription<dynamic>> _live = {};
  final Map<String, Future<void>> _tail = {};

  /// 当前活着的订阅数。**测试和线上自检都靠它** —— 正常值恒为 0 或 1。
  int get liveCount => _live.length;

  bool hasLive(String key) => _live.containsKey(key);

  /// 建一个新订阅顶掉 [key] 上原有的那个。
  ///
  /// - 同一个 [key] 上的并发调用会**排队**，不会各自建一个；
  /// - 旧订阅在 [create] 之前就被取消 —— 反过来的话两个订阅会同时活着几百毫秒，
  ///   而那几百毫秒正好就是重复帧发生的地方；
  /// - [create] 返回 null（拿不到连接、特征不存在）时不留任何记录，下次调用照常重建。
  Future<StreamSubscription<T>?> replace<T>(
    String key,
    Future<StreamSubscription<T>?> Function() create,
  ) {
    final completer = Completer<StreamSubscription<T>?>();
    final prior = _tail[key] ?? Future<void>.value();
    // 把失败也吞掉：一次创建失败不能让这个 key 上后续的创建永远排不上队。
    _tail[key] = completer.future.then((_) {}, onError: (_) {});

    prior.whenComplete(() async {
      try {
        await _cancelLocked(key);
        final sub = await create();
        if (sub != null) {
          _live[key] = sub;
        }
        if (_live.length > 1) {
          // 走到这里说明有第二个 key 在用同一个 registry —— 音频只有一台设备，
          // 所以这是个值得看一眼的信号，但不是错误。
          debugPrint('[$label] live subscriptions across keys: ${_live.length}');
        }
        completer.complete(sub);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });

    return completer.future;
  }

  /// 显式收掉 [key] 上的订阅（设备断开、停止录音）。
  Future<void> cancel(String key) {
    final completer = Completer<void>();
    final prior = _tail[key] ?? Future<void>.value();
    _tail[key] = completer.future.then((_) {}, onError: (_) {});
    prior.whenComplete(() async {
      try {
        await _cancelLocked(key);
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _cancelLocked(String key) async {
    final prev = _live.remove(key);
    if (prev == null) return;
    try {
      await prev.cancel();
    } catch (e) {
      // 订阅可能已经被 `cancelWhenDisconnected` 收走了，重复 cancel 不该炸。
      debugPrint('[$label] cancel of stale subscription for $key threw: $e');
    }
  }
}

/// BLE 音频字节流的全局唯一订阅表。
///
/// ⚠️ **必须是全局的，不能挂在 `DeviceConnection` 实例上。** `DeviceService` 每次重连
/// 都 `DeviceConnectionFactory.create(...)` 造一个**新的** connection 对象
/// （`services/devices.dart:146`/`:178`），旧对象上的字段拦不住新对象再订阅一次同一个
/// 特征 —— 而底下那条广播流是同一条。key 用 BLE 的 `remoteId`。
final LiveSubscriptionRegistry bleAudioSubscriptions = LiveSubscriptionRegistry(label: 'BLE audio');
