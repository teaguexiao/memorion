import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/live_subscription_registry.dart';

import 'helpers/source_stripper.dart';

/// 钉住「一台设备最多一个活着的 BLE 音频订阅」。
///
/// 这条不变式破掉的代价见 `live_subscription_registry.dart` 的类注释：同一帧音频被发给
/// 服务器 N 遍 → 服务端音频时长按 N 倍膨胀 → 语音被复印成 10ms 粒度的卡碟 → Soniox
/// **合法地**返回 0 段 → App 里一条对话都没有，而全链路零错误日志。
///
/// ⚠️ 单测 registry 本身不够，所以第三组是**接线断言**：registry 正确、连接层没用它，
/// 是本仓库反复踩的「两个各自正确的函数没接起来」。
void main() {
  group('LiveSubscriptionRegistry 行为', () {
    test('并发 replace 之后只剩一个订阅，一次事件只送达一次', () async {
      // 模拟 flutter_blue_plus 那条广播流：一条流、多个 listener，每个都会收到。
      final controller = StreamController<List<int>>.broadcast();
      addTearDown(controller.close);
      final registry = LiveSubscriptionRegistry(label: 'test');

      var delivered = 0;
      Future<StreamSubscription<List<int>>?> create(int delayMs) async {
        // 真实链路里这里是 ensureConnection / requestMtu / setNotifyValue，几百毫秒。
        // 正是这个 await 窗口让两次并发调用各自建出一个订阅。
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        return controller.stream.listen((_) => delivered++);
      }

      // 五次并发，故意让创建耗时长短交错，模拟乱序完成。
      await Future.wait<void>([
        for (var i = 0; i < 5; i++) registry.replace('dev-1', () => create((5 - i) * 4)),
      ]);

      expect(registry.liveCount, 1, reason: 'registry 里应当只剩一个音频订阅');

      controller.add([1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(delivered, 1, reason: '一包音频只该触发一次回调；N 次就是往服务器发了 N 份');
    });

    test('控制组：不经过 registry 时同样的并发会留下 5 个订阅、送达 5 次', () async {
      // 这一组存在的唯一理由是证明上一组**能失败** —— 否则「只送达一次」可能只是因为
      // 广播流不会多送，那样上面那条断言就是同义反复。
      final controller = StreamController<List<int>>.broadcast();
      addTearDown(controller.close);

      var delivered = 0;
      final subs = await Future.wait<StreamSubscription<List<int>>>([
        for (var i = 0; i < 5; i++)
          Future<StreamSubscription<List<int>>>.delayed(
            Duration(milliseconds: (5 - i) * 4),
            () => controller.stream.listen((_) => delivered++),
          ),
      ]);
      addTearDown(() => Future.wait(subs.map((s) => s.cancel())));

      controller.add([1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(delivered, 5, reason: '广播流会给每个 listener 各送一份 —— 这就是重复帧的来源');
    });

    test('旧订阅在新订阅建立之前就被取消，不存在两者同时活着的窗口', () async {
      final controller = StreamController<List<int>>.broadcast();
      addTearDown(controller.close);
      final registry = LiveSubscriptionRegistry(label: 'test');

      var firstDeliveries = 0;
      var secondDeliveries = 0;
      await registry.replace('dev-1', () async => controller.stream.listen((_) => firstDeliveries++));

      // 在「新订阅还没建好」的中途发一包音频：旧订阅必须已经死了。
      final pending = registry.replace('dev-1', () async {
        controller.add([9]);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return controller.stream.listen((_) => secondDeliveries++);
      });
      await pending;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(firstDeliveries, 0, reason: '旧订阅应在 create 之前被取消');
      expect(secondDeliveries, 0, reason: '那一包发生在新订阅建立之前，谁都不该收到');

      controller.add([1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(secondDeliveries, 1);
      expect(firstDeliveries, 0);
      expect(registry.liveCount, 1);
    });

    test('create 返回 null（拿不到连接）不留记录，也不堵住后续调用', () async {
      final controller = StreamController<List<int>>.broadcast();
      addTearDown(controller.close);
      final registry = LiveSubscriptionRegistry(label: 'test');

      expect(await registry.replace<List<int>>('dev-1', () async => null), isNull);
      expect(registry.liveCount, 0);

      // create 抛异常也不能让这个 key 上后续的 replace 永远排不上队。
      await expectLater(
        registry.replace<List<int>>('dev-1', () async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );

      var delivered = 0;
      final sub = await registry.replace('dev-1', () async => controller.stream.listen((_) => delivered++));
      expect(sub, isNotNull);
      controller.add([1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(delivered, 1);
    });

    test('cancel 之后 liveCount 归零', () async {
      final controller = StreamController<List<int>>.broadcast();
      addTearDown(controller.close);
      final registry = LiveSubscriptionRegistry(label: 'test');
      await registry.replace('dev-1', () async => controller.stream.listen((_) {}));
      expect(registry.hasLive('dev-1'), isTrue);
      await registry.cancel('dev-1');
      expect(registry.liveCount, 0);
      expect(registry.hasLive('dev-1'), isFalse);
    });
  });

  group('接线：BLE 音频订阅必须走 registry', () {
    late String connection;
    late String captureProvider;

    setUpAll(() {
      connection = stripCommentsAndStrings(
        File('lib/services/devices/memorion_connection.dart').readAsStringSync(),
      );
      captureProvider = stripCommentsAndStrings(
        File('lib/providers/capture_provider.dart').readAsStringSync(),
      );
    });

    test('performGetBleAudioBytesListener 经过 bleAudioSubscriptions.replace', () {
      final body = functionBody(connection, 'performGetBleAudioBytesListener');
      expect(body, isNotNull, reason: '找不到 performGetBleAudioBytesListener —— 改名了就把这个测试一起改');
      expect(
        body!.contains('bleAudioSubscriptions.replace'),
        isTrue,
        reason: '音频订阅必须过 registry，否则各个调用方并发时会留下多个活着的 listener',
      );
    });

    test('音频特征用 onValueReceived，不用 lastValueStream', () {
      // lastValueStream 在被 listen 那一刻会重放缓存的 lastValue，对数据流来说是白插一帧。
      final audioSub = functionBody(connection, '_subscribeAudioBytes');
      expect(audioSub, isNotNull);
      expect(audioSub!.contains('onValueReceived'), isTrue);
      expect(
        audioSub.contains('lastValueStream'),
        isFalse,
        reason: '音频不该用 lastValueStream（订阅即重放一帧旧音频）',
      );
    });

    test('电量 / 充电状态刻意保留 lastValueStream', () {
      // 判据是「订阅时重放当前值有没有意义」：电量有（否则 UI 要等下一次通知才知道），
      // 音频没有。把这条也钉住，免得下次有人「统一风格」把电量也改掉。
      expect(
        functionBody(connection, 'performGetBleBatteryLevelListener')!.contains('lastValueStream'),
        isTrue,
        reason: '电量订阅需要立刻拿到当前值，lastValueStream 是对的',
      );
    });

    test('streamAudioToWs 里的 cancel 是 await 的', () {
      final body = functionBody(captureProvider, 'streamAudioToWs');
      expect(body, isNotNull);
      expect(
        body!.contains('await _bleBytesStream?.cancel()'),
        isTrue,
        reason: '不 await 的话 cancel 与「记住新订阅」之间的窗口会漏掉一个无法取消的订阅',
      );
    });
  });
}
