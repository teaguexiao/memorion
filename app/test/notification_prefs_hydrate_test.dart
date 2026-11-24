import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/utils/notification_prefs.dart';

/// 钉住通知偏好回读（`GET /v1/users/notification-preferences`）的合并规则。
///
/// 背景（2026-08-12）：偏好同步此前是单向的（只 POST），重装 App / 换机后本地回到默认值、
/// 云端还是用户上次设的值 —— **设置页显示开着、服务端其实不推**，用户无从自查。
///
/// ⚠️ **回读最容易写错的一点：只覆盖服务端 `stored_keys` 里的字段。**
/// 响应里的 `preferences` 总是全字段（缺的按服务端默认补齐），所以「用户显式设成 true」和
/// 「从没设过、默认恰好是 true」在值上一模一样。无脑覆盖等于把服务端此刻的默认值**固化**成
/// 用户设置 —— 之后两边改默认值对这批用户永久无效，而且完全看不出来（值合法、行为「正常」、
/// 没有任何日志）。线上 156 个用户里只有 2 个写过这条记录。
///
/// 判定逻辑刻意抽成纯函数 `resolveServerOverrides()`：写入 SharedPreferences 那半边在纯
/// 单测里没有观察点，而所有会出错的判断都在这个函数里。后端对应
/// `backend/tests/test_notification_preferences_readback.py`。
void main() {
  Map<String, dynamic> payload(Map<String, Object?> prefs, List<String> storedKeys) =>
      {'status': 'Ok', 'preferences': prefs, 'stored_keys': storedKeys};

  group('resolveServerOverrides', () {
    test('只覆盖 stored_keys 里的字段，没设过的一个都不动', () {
      // 服务端把 task_reminder 也带回来了（默认 true），但用户只设过 daily_moment。
      final out = NotificationPrefs.resolveServerOverrides(payload(
        {'daily_moment': false, 'task_reminder': true, 'milestone': true},
        ['daily_moment'],
      ));

      expect(out, {'daily_moment': false});
      expect(out.containsKey('task_reminder'), isFalse,
          reason: '这个 true 是服务端补的默认值，不是用户的选择。'
              '写进本地就把默认值固化成了设置 —— 之后改默认值对这批用户永久无效');
    });

    test('用户从没同步过（stored_keys 为空）→ 什么都不覆盖', () {
      final out = NotificationPrefs.resolveServerOverrides(payload(
        {'daily_moment': true, 'task_reminder': true, 'quiet_hours_enabled': false},
        [],
      ));
      expect(out, isEmpty, reason: '这些全是服务端默认值，本地该保持自己的默认逻辑');
    });

    test('全部设过时全部覆盖', () {
      final full = {
        'daily_moment': false,
        'task_reminder': false,
        'pause_reminder': true,
        'milestone': false,
        'quiet_hours_enabled': true,
        'quiet_hours_start_minutes': 22 * 60 + 30,
        'quiet_hours_end_minutes': 7 * 60,
      };
      final out = NotificationPrefs.resolveServerOverrides(payload(full, full.keys.toList()));
      expect(out, full);
    });

    test('回读失败 / 响应结构不对 → 空，保持本地值', () {
      // 宁可显示旧值，也不要把设置页清成默认。
      expect(NotificationPrefs.resolveServerOverrides(null), isEmpty);
      expect(NotificationPrefs.resolveServerOverrides({}), isEmpty);
      expect(NotificationPrefs.resolveServerOverrides({'preferences': {}}), isEmpty,
          reason: '缺 stored_keys 时不能退化成「覆盖全部」');
      expect(NotificationPrefs.resolveServerOverrides({'stored_keys': ['daily_moment']}), isEmpty);
      expect(
          NotificationPrefs.resolveServerOverrides(
              {'preferences': 'oops', 'stored_keys': ['daily_moment']}),
          isEmpty);
      expect(
          NotificationPrefs.resolveServerOverrides(
              {'preferences': {'daily_moment': false}, 'stored_keys': 'daily_moment'}),
          isEmpty);
    });

    test('类型不符的值丢弃而不是强转', () {
      // JSON 里 bool/int 混淆是真会发生的（手改 Firestore、老客户端写脏数据）。
      // 强转会在 hydrate 时抛 TypeError，或者把 0/1 当成布尔写进本地。
      final out = NotificationPrefs.resolveServerOverrides(payload(
        {
          'daily_moment': 0,
          'quiet_hours_enabled': 'true',
          'quiet_hours_start_minutes': true,
          'quiet_hours_end_minutes': '480',
          'milestone': false,
        },
        [
          'daily_moment',
          'quiet_hours_enabled',
          'quiet_hours_start_minutes',
          'quiet_hours_end_minutes',
          'milestone',
        ],
      ));
      expect(out, {'milestone': false}, reason: '只有类型正确的那个该被接受');
    });

    test('分钟数越界丢弃', () {
      // 存进去不会崩，但静默判定拿它跟 `hour*60+minute`（0..1439）比，
      // 会变成「永远不在静默时段」或「永远在」，且没有任何报错。
      final out = NotificationPrefs.resolveServerOverrides(payload(
        {'quiet_hours_start_minutes': 1440, 'quiet_hours_end_minutes': -1},
        ['quiet_hours_start_minutes', 'quiet_hours_end_minutes'],
      ));
      expect(out, isEmpty);

      final edges = NotificationPrefs.resolveServerOverrides(payload(
        {'quiet_hours_start_minutes': 1439, 'quiet_hours_end_minutes': 0},
        ['quiet_hours_start_minutes', 'quiet_hours_end_minutes'],
      ));
      expect(edges, {'quiet_hours_start_minutes': 1439, 'quiet_hours_end_minutes': 0},
          reason: '合法边界值必须放过');
    });

    test('后端新增字段不会让老版本 App 写出脏数据', () {
      final out = NotificationPrefs.resolveServerOverrides(payload(
        {'daily_moment': false, 'future_switch': true},
        ['daily_moment', 'future_switch'],
      ));
      expect(out, {'daily_moment': false});
    });
  });

  group('buildSyncPayload（上行只发改动字段）', () {
    // ⚠️ 这组测试钉住的是**回读那套防护赖以成立的前提**。
    //
    // 上报若是全量的（2026-08-12 之前就是），用户随便动一个开关就把 7 个字段连同**当时的
    // 默认值**一起写进云端 → 服务端 `stored_keys` 退化成全集 → 上面 resolveServerOverrides
    // 那层「只覆盖用户设过的字段」对**除了从没同步过的人以外的所有用户**失效。
    // 两个函数各自都对，接起来才错 —— 单看任何一边的测试都发现不了。
    //
    // 这里只测 key 面（发了哪些字段），不测值：值要读 SharedPreferences，而会出错的判断
    // 全在「发哪些 key」上。

    test('只发传入的那个字段', () {
      expect(NotificationPrefs.buildSyncPayload({'milestone'}).keys, ['milestone'],
          reason: '多发字段是静默的：服务端照样返回 200，只是云端多记了一个当时的默认值');
    });

    test('拼错的 key 不发，而不是静默做一次空写', () {
      expect(NotificationPrefs.buildSyncPayload({'mileStone', 'not_a_pref'}), isEmpty);
    });

    test('静默时段三个字段是一个语义单元', () {
      // 用户开启静默开关时就接受了当前显示的起止时间；只报 enabled 会让服务端拿它自己的
      // 默认区间去判定，而那个区间未必等于用户屏幕上看到的。
      expect(NotificationPrefs.quietHoursKeys, {
        'quiet_hours_enabled',
        'quiet_hours_start_minutes',
        'quiet_hours_end_minutes',
      });
      expect(NotificationPrefs.buildSyncPayload(NotificationPrefs.quietHoursKeys).keys.toSet(),
          NotificationPrefs.quietHoursKeys);
    });

    // 注：这里刻意**没有**「上行 key 全集 == 下行认得的 key」这条测试。
    // `allServerKeys` 就是由 `_serverBoolKeys ∪ _serverMinuteKeys` 定义的，而回读也用这两个
    // 集合判定 —— 断言两者相等是同义反复，往集合里塞个假 key 它照样绿。真判据是「这个集合
    // 与后端 NOTIFICATION_PREFERENCES_DEFAULTS 的 key 一致」，跨语言，放在
    // backend/tests/test_notification_defaults_alignment.py（那边已有读 Dart 源码的设施）。

    test('设置页不再全量上报', () {
      // 源码断言：`_syncPrefs()` 无参调用就是全量上报的形态，它一回来这套防护就失效。
      final page = File('lib/pages/today_chapters/notification_settings_page.dart').readAsStringSync();
      expect(page.contains('_syncPrefs()'), isFalse,
          reason: '_syncPrefs 必须带上本次改动的 key；无参形态等于全量上报，'
              '会把当时的默认值固化进云端');
      final calls = RegExp(r'_syncPrefs\(([^)]*)\)').allMatches(page).map((m) => m.group(1)!).toList();
      expect(calls, isNotEmpty, reason: '一处 _syncPrefs 调用都没抽到，正则跟不上了');
      for (final arg in calls) {
        expect(arg.trim(), isNotEmpty, reason: '_syncPrefs 的实参不能为空');
      }
    });
  });

  group('接线', () {
    // 源码断言：hydrate 只在启动时调一次，纯单测里没有观察点，而缺陷形态是「少调了」——
    // 那样这个功能等于不存在，且表现和修复前一模一样（本地值就是本地值）。
    test('启动时调用了 hydrateFromServer', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('NotificationPrefs.hydrateFromServer()'), isTrue,
          reason: '不在启动时回读，重装/换机后设置页显示的和服务端执行的就永远不一致');
      // 必须在已登录分支里 —— 未登录时没有 uid，回读只会拿到 401。
      final authBlock = main.substring(main.indexOf('if (isAuth) {'));
      expect(authBlock.indexOf('NotificationPrefs.hydrateFromServer()'), greaterThan(-1),
          reason: 'hydrateFromServer 必须在 isAuth 分支内');
    });

    test('回读改动会撤下按旧设置排定的任务提醒', () {
      final src = File('lib/utils/notification_prefs.dart').readAsStringSync();
      const sig = 'hydrateFromServer() async {';
      final start = src.indexOf(sig);
      expect(start, greaterThan(-1), reason: 'hydrateFromServer 不见了或改名了');
      final body = src.substring(start, src.indexOf('\n  }', start));
      // 任务提醒是本地排期，按回读**之前**的开关/静默时段排的；回读关掉开关或挪动静默
      // 区间后它们照样会响。清掉后交给 applyTaskReminderSchedule 下次重排（幂等）。
      expect(body.contains('_clearScheduledTaskReminders()'), isTrue,
          reason: '回读改了 task_reminder / 静默时段却不撤旧排期，'
              '用户会在自己刚关掉的时间段里继续收到提醒');
    });
  });
}
