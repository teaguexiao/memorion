import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/providers/recording_source_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/source_stripper.dart';

/// 钉住「取消录音源三选一」这次改动的四条不变式（2026-08-19，设计文档 §3.2）。
///
/// 为什么这四条值得测：前三条是纯逻辑，最后一条是**接线** —— 而这个仓库反复栽在
/// 「两个函数各自正确、但没接起来」上（实时链路整条漏掉记忆提取、待办门禁跑在声纹之前
/// 都是这个形状）。`consumeForcePhoneOnce` 漏调的症状尤其安静：开关一直亮着，用户以为
/// 自己每次都要手动关，或者更糟 —— 他忘了它开着，之后戴着设备录音全走手机麦克风，
/// 而那正是取消持久化偏好本来要消灭的失败形态。
void main() {
  group('resolve 只看当下', () {
    test('连着设备就用设备，没连接就用手机', () {
      final p = RecordingSourceProvider();
      expect(p.resolve(bleConnected: true), RecordingSource.bleDevice);
      expect(p.resolve(bleConnected: false), RecordingSource.phone);
    });

    test('forcePhoneOnce 压过设备连接状态 —— 这就是「设备在包里」那个场景', () {
      final p = RecordingSourceProvider()..setForcePhoneOnce(true);
      expect(p.resolve(bleConnected: true), RecordingSource.phone);
    });

    test('消费之后回到看设备状态', () {
      final p = RecordingSourceProvider()..setForcePhoneOnce(true);
      p.consumeForcePhoneOnce();
      expect(p.forcePhoneOnce, isFalse);
      expect(p.resolve(bleConnected: true), RecordingSource.bleDevice);
    });
  });

  group('forcePhoneOnce 不许持久化', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('拨开关不写盘 —— 它表达的是当下的临时状态，不是偏好', () async {
      RecordingSourceProvider().setForcePhoneOnce(true);
      final prefs = await SharedPreferences.getInstance();
      // 断言「一个键都没多」，而不是断言某个具体键不在：将来换个键名照样能被逮到。
      expect(prefs.getKeys(), isEmpty,
          reason: '一次性覆盖被写进了 prefs —— 那就退回了「改了忘记改回来」的老问题');
    });

    test('新实例不会从盘上捡回上次的状态', () {
      SharedPreferences.setMockInitialValues({'recordingSource': 'phone'});
      // 存量键刻意不迁移也不清理（见 preferences.dart 的注释），但**绝不能被读回来**。
      expect(RecordingSourceProvider().forcePhoneOnce, isFalse);
      expect(RecordingSourceProvider().resolve(bleConnected: true), RecordingSource.bleDevice);
    });
  });

  test('RecordingSource 只剩两个值 —— watch 不该回来', () {
    // 手表录音是在**手表上**按开始的，手机既给不了选择也无法阻止它。把它列成一个「可选
    // 来源」的实际后果是：用户点了「Apple Watch」之后什么都不会发生。
    expect(RecordingSource.values.map((e) => e.name).toSet(), {'phone', 'bleDevice'});
  });

  group('接线：启动采集之后必须消费一次性开关', () {
    late String code;

    setUpAll(() {
      final f = File('lib/pages/today_chapters/live_capture_page.dart');
      expect(f.existsSync(), isTrue, reason: '实时采集页被挪走了，这条断言要跟着改路径');
      // ⚠️ 必须剥注释：这次改动的注释里就有 `consumeForcePhoneOnce` 这几个字，不剥的话
      // 把真调用删掉照样绿，测试退化成同义反复（见 source_stripper 的类注释）。
      code = stripCommentsAndStrings(f.readAsStringSync());
    });

    test('resolve 与 consumeForcePhoneOnce 都在，缺一个就是半个功能', () {
      expect(code.contains('.resolve('), isTrue,
          reason: '实时采集页没在解析录音来源 —— 它是唯一决定走 BLE 还是手机的地方');
      expect(code.contains('consumeForcePhoneOnce()'), isTrue,
          reason: '一次性开关没被消费 —— 它会一直亮着，之后每次录音都走手机麦克风');
    });

    test('消费排在启动采集之后，而不是之前', () {
      final iStart = code.indexOf('streamRecording()');
      final iConsume = code.indexOf('consumeForcePhoneOnce()');
      expect(iStart, greaterThan(-1));
      expect(iConsume, greaterThan(iStart),
          reason: '先清开关再启动采集的话，resolve 读到的已经是被清掉的值 —— '
              '「这次用手机录」当场失效，而且失效得毫无痕迹');
    });

    test('不在 finally 里消费 —— 启动失败时开关得留着让用户重试', () {
      // 判据落在「consume 与它后面第一个 finally 的相对位置」上：consume 若被搬进
      // finally，就会排在那个 finally 之后。
      final iConsume = code.indexOf('consumeForcePhoneOnce()');
      final iFinally = code.indexOf('finally', code.indexOf('streamRecording()'));
      // ⚠️ **这一句是变异验证逼出来的，别删。** 没有它时，「调用整行被删掉」这种变异会让
      // 这条断言**假绿** —— `indexOf` 返回 -1，而 `-1 < iFinally` 恰好成立，于是最该报警
      // 的情形反而通过了。2026-08-19 实测：删掉调用后只有两条转红，这条是绿的。
      expect(iConsume, greaterThan(-1), reason: 'consumeForcePhoneOnce 的调用点不见了');
      expect(iFinally, greaterThan(-1), reason: '那段 try/finally 的结构变了，这条断言要重写');
      expect(iConsume, lessThan(iFinally),
          reason: '一次性开关在 finally 里被清掉了 —— 采集启动抛异常时用户还没录上，'
              '开关却已经没了');
    });
  });
}
