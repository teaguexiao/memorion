import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 钉住「每日一刻只有一条通知」以及那条遗留清理不许被删。
///
/// 背景（2026-08-12）：晚上会收到两条内容重复的提醒 ——
/// - 本地 **21:00**「今天过得怎么样？来看看记小宝为你整理的今日日记吧。」
///   （`NotificationPrefs` 里当时的 `applyDailyMomentSchedule`，`repeats: true` 排定）
/// - 服务端 **22:00** 的 `daily_moment` FCM 推送（带真实日记摘要 + `moment_id`）
///
/// 本地那条已删除：当天日记要到 22:00 才由服务端生成（21:00 点进去看到的是昨天）；它跟
/// 22:00 那条说的是同一件事；它的 payload 没有 `moment_id`，
/// `NotificationDeepLink.fromPayload` 只能落 `homeShell` —— 用户报的「点推送进首页而不是
/// 每日一刻的页面」有一半是它。
///
/// ⚠️ 这份测试的重点不是「代码删干净了」，而是**那次 cancel 还在**。本地通知的排期存在
/// 系统侧、不随 App 升级消失，启动时也没有任何 `cancelAllSchedules` 兜底。把清理一起删掉
/// 的话，已装 App 的用户会一直收到 21:00 那条，而新装用户不会 —— 「只有老用户复现」。
///
/// 为什么是源码断言：清理直接打 `NotificationService.instance` 这个静态单例（底层是
/// awesome_notifications 的平台通道），纯单测里没有注入点；而缺陷形态是「少调了一次」
/// 或「多排了一条」，看返回值都看不出来。同款理由见
/// `notification_remote_tap_wiring_test.dart`。
void main() {
  String src(String path) => File(path).readAsStringSync();

  /// 抽出遗留清理函数的函数体。抽不到就直接 fail，而不是返回空串 ——
  /// 空串会让下面的 isFalse 断言真空通过。
  String legacyCleanupBody() {
    final s = src('lib/utils/notification_prefs.dart');
    const sig = 'clearRetiredLocalNotifications() async {';
    final start = s.indexOf(sig);
    expect(start, greaterThan(-1),
        reason: 'clearRetiredLocalNotifications 不见了或改名了。'
            '如果是想彻底删掉这次遗留清理，先确认所有活跃用户都升过 >= 2026-08-12 的版本，'
            '否则老用户会一直收到本地 21:00 那条重复提醒');
    var depth = 0;
    final open = s.indexOf('{', start);
    for (var i = open; i < s.length; i++) {
      if (s[i] == '{') depth++;
      if (s[i] == '}') {
        depth--;
        if (depth == 0) return s.substring(open + 1, i);
      }
    }
    fail('没能配平 clearRetiredLocalNotifications 的花括号');
  }

  test('遗留清理只撤销、不排定任何本地提醒', () {
    final body = legacyCleanupBody();
    expect(body.contains('clearNotification(id)') && body.contains('1001'), isTrue,
        reason: '必须真的 cancel：存量排期是 repeats:true，不主动撤会一直响到卸载重装');
    expect(body.contains('showNotification'), isFalse,
        reason: '别把本地 21:00 提醒排回来 —— 服务端 22:00 推送已覆盖同一件事，'
            '且那条带 moment_id 能直达日记详情，本地这条只能回首页');
    expect(body.contains('NotificationCalendar'), isFalse,
        reason: '同上：这个函数不该排任何定时通知');
  });

  test('遗留清理仍然在启动时被调用', () {
    // 这是清掉存量排期的唯一时机（设置页与切语言的调用都已随功能删除）。
    expect(src('lib/main.dart').contains('NotificationPrefs.clearRetiredLocalNotifications()'),
        isTrue,
        reason: '启动时不调用，存量用户手机上的 21:00 重复排期永远撤不掉');
  });

  test('App 端不再有「每日一刻」本地排期的入口', () {
    // 每日一刻从此是纯服务端推送。留着一个叫 applyDailyMomentSchedule 的函数，
    // 下一个人很容易顺手把 showNotification 加回去。
    final lib = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
    final offenders = lib.where((f) => f.readAsStringSync().contains('applyDailyMomentSchedule')).map((f) => f.path);
    expect(offenders, isEmpty,
        reason: '每日一刻已是纯服务端推送（本地 22:00），不该再有本地排期函数');
  });

  test('设置页不再向用户承诺 21:00', () {
    final s = src('lib/pages/today_chapters/notification_settings_page.dart');
    // 只查面向用户的 revampText 文案行，注释里提 21:00 是允许的（记录停用原因）。
    final userFacingLines = s
        .split('\n')
        .where((l) => l.contains('revampText(') && !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
        .toList();
    expect(userFacingLines, isNotEmpty, reason: '一行 revampText 都没抽到，正则跟不上了');
    expect(userFacingLines.where((l) => l.contains('21:00')), isEmpty,
        reason: '每日一刻现在是服务端 22:00 推送，文案里的 21:00 会变成假承诺');
  });
}
