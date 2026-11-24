/// bound key 被顶掉后的自愈（2026-08-12）。
///
/// 现场：一台设备连续 401 了 111 次、横跨 19 小时。根因是 `/v1/auth/app-token` 换发时
/// **硬删除**该用户此前的 key，所以在第二台设备（或模拟器）上登录同一账号，会把第一台
/// 手里那把从服务端抹掉；而 `ensureBoundApiKey()` 只在本地没有 bound key 时才换发，
/// 于是那台设备永远不会自愈——录音、人物、时间线全挂，只有用户手动登出重登才能恢复。
///
/// 这里钉的三条都是「不这么写就会把可自愈的故障放大」的形态：
///
/// 1. **单飞**。换发会撤销上一把，所以并发换发会互相撤销：最后只有一把有效，其余请求
///    拿着刚被顶掉的新 key 继续 401。冷启动并发十几个请求必然撞上。
/// 2. **失败要落冷却**，否则每个失败请求都额外打一次换发，请求量翻倍。
/// 3. **换发抛异常也算失败**，不能让异常穿出去——调用方是在 401 分支里 await 它。
///
/// Run:
///     cd app && flutter test test/api_key_recovery_test.dart
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/api_key_recovery.dart';

void main() {
  /// 可控时钟。真实 DateTime.now() 没法在测试里跨过冷却窗口。
  late DateTime now;
  DateTime clock() => now;

  setUp(() => now = DateTime(2026, 8, 12, 10, 0, 0));

  ApiKeyRecovery build(Future<bool> Function() exchange) =>
      ApiKeyRecovery(exchange: exchange, clock: clock);

  group('单飞', () {
    test('并发的 401 只换发一次，且都拿到同一个结果', () async {
      final gate = Completer<bool>();
      final recovery = build(() => gate.future);

      final calls = List.generate(8, (_) => recovery.recover());
      gate.complete(true);
      final results = await Future.wait(calls);

      expect(recovery.exchangeAttempts, 1,
          reason: '并发换发会互相撤销 key，第 2..N 个请求会拿着刚被顶掉的新 key 继续 401');
      expect(results, everyElement(isTrue));
    });

    test('前一次换发结束后，in-flight 标记要清掉', () async {
      // 不清的话之后所有 401 都搭上一辆已经到站的车，永远换不到新 key。
      var attempts = 0;
      final recovery = build(() async {
        attempts++;
        return false; // 失败，避免走成功冷却那条分支
      });

      expect(await recovery.recover(), isFalse);
      now = now.add(const Duration(seconds: 61)); // 越过失败冷却
      expect(await recovery.recover(), isFalse);

      expect(attempts, 2);
    });
  });

  group('失败冷却', () {
    test('冷却窗口内不再换发，直接返回 false', () async {
      final recovery = build(() async => false);

      expect(await recovery.recover(), isFalse);
      now = now.add(const Duration(seconds: 59));
      expect(await recovery.recover(), isFalse);

      expect(recovery.exchangeAttempts, 1, reason: '换发失败时每个 401 都再打一次 = 请求量翻倍');
    });

    test('冷却过期后可以再试', () async {
      final recovery = build(() async => false);

      await recovery.recover();
      now = now.add(const Duration(seconds: 61));
      await recovery.recover();

      expect(recovery.exchangeAttempts, 2, reason: '冷却是节流，不是永久放弃');
    });

    test('换发抛异常等同失败：不外泄、并落冷却', () async {
      final recovery = build(() async => throw Exception('boom'));

      expect(await recovery.recover(), isFalse);
      expect(await recovery.recover(), isFalse);

      expect(recovery.exchangeAttempts, 1);
    });
  });

  group('成功冷却', () {
    test('刚换到新 key 时返回 true 但不再换发', () async {
      final recovery = build(() async => true);

      expect(await recovery.recover(), isTrue);
      now = now.add(const Duration(seconds: 29));
      expect(await recovery.recover(), isTrue,
          reason: '本地那把已经是最新的了，调用方应该直接重试');

      expect(recovery.exchangeAttempts, 1);
    });

    test('成功冷却是节流不是终态：过期后还能再换（例如又被另一台设备顶掉）', () async {
      var succeed = false;
      final recovery = build(() async => succeed);

      expect(await recovery.recover(), isFalse); // 落失败冷却
      now = now.add(const Duration(seconds: 61));
      succeed = true;
      expect(await recovery.recover(), isTrue);

      now = now.add(const Duration(seconds: 31));
      expect(await recovery.recover(), isTrue);
      expect(recovery.exchangeAttempts, 3);
    });
  });
}
