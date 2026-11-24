import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/calendar.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 日历同意的真相源在服务端，本地只是缓存。
///
/// ## 这个测试钉住的 bug
///
/// 用户报的症状是「每装一个新 TestFlight，授权设置里的 iOS 日历都要重新打开一次，
/// 而同一页的提醒事项不用」。根因不在 iOS：两个开关读的东西不一样——
///
/// - 提醒事项 = `系统权限`
/// - 日历 = `系统权限 ∧ 同意`
///
/// 系统权限（EventKit/TCC）按 bundle id 记在系统侧，跨 App 更新与重装都保留；而同意
/// 原先只存在 `shared_preferences` 里，跟着 App 沙盒走，删除重装即丢，登出也会被
/// `clearUserPreferences()` 清掉。丢的是本地那一半，于是日历开关回到「关」，看起来像
/// iOS 单独忘了日历权限——而服务器上此前同步的日程其实都还在。
///
/// 修法是把同意记到服务端、跟着账号走。下面三组断言分别覆盖它的三处要害。
///
/// ## 为什么有两处是「复刻判据」而不是调真实代码
///
/// 判据本身各只有一两行，但它们所在的函数都拖着不可注入的依赖：授权页的开关要真的
/// 问 EventKit，`CalendarAiConsent.refreshFromServer` 要真的发 HTTP（`makeApiCall`
/// 用的是文件级私有的共享 client）。为这两行去重构生产代码的可测试性不值得，所以这里
/// 复刻表达式并写明镜像的源位置——与 `about_me_promises_no_spinner_test.dart` 同一套
/// 做法。改动那两处时必须一起改这里。
/// 读源码做断言时先剥掉整行注释。
///
/// 不剥的话这些断言会假绿：把 `identifier: toggleId,` 注掉成
/// `// identifier: toggleId,`，行为已经没了而字符串还在，`contains` 照样通过。
/// 变异验证时实测撞到过。
String _codeOf(String path) => File(path)
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

const _authPage = 'lib/pages/today_chapters/authorization_settings_page.dart';

void main() {
  group('CalendarSyncState.fromJson — consent_granted 的三态', () {
    test('缺字段解析成 null，不是 false', () {
      // 这是全套改动里最容易被写错、且错了最贵的一处。App 走 TestFlight、后端走 ECS，
      // 上线顺序保证不了；把缺字段读成「未同意」会在新 App 碰上旧后端时，把**所有**
      // 用户的日历开关打成关——比它要修的 bug 严重得多。
      final state = CalendarSyncState.fromJson({'event_count': 5});
      expect(state.consentGranted, isNull);
      expect(state.eventCount, 5);
    });

    test('true / false 都如实解析', () {
      expect(CalendarSyncState.fromJson({'consent_granted': true}).consentGranted, isTrue);
      expect(CalendarSyncState.fromJson({'consent_granted': false}).consentGranted, isFalse);
    });

    test('空 JSON 不抛异常，视作没有任何状态', () {
      final state = CalendarSyncState.fromJson({});
      expect(state.consentGranted, isNull);
      expect(state.syncedAt, isNull);
      expect(state.eventCount, 0);
    });
  });

  group('本地缓存的三态', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();
    });

    test('从未决定过时 decision 是 null，而 granted 退化成 false', () {
      // 两个 getter 的分工：闸门用 `granted`（没决定就当没同意，绝不默认放行），
      // 「要不要去问服务端」用 `decision`（只有 null 才问）。
      expect(SharedPreferencesUtil().calendarAiConsentDecision, isNull);
      expect(SharedPreferencesUtil().calendarAiConsentGranted, isFalse);
    });

    test('明确的拒绝与「从未决定」可区分', () {
      SharedPreferencesUtil().calendarAiConsentGranted = false;
      expect(SharedPreferencesUtil().calendarAiConsentDecision, isFalse);
      expect(SharedPreferencesUtil().calendarAiConsentGranted, isFalse);
    });

    test('登出清掉本地决定 —— 换账号必须重新询问', () async {
      SharedPreferencesUtil().calendarAiConsentGranted = true;
      await SharedPreferencesUtil().clearUserPreferences();
      // 清掉是刻意的：同意是某个账号给的，不是这台设备给的。同一个账号重新登录时，
      // 服务端那份记录会把它恢复回来（见下面 refreshFromServer 的复刻）。
      expect(SharedPreferencesUtil().calendarAiConsentDecision, isNull);
    });
  });

  group('refreshFromServer 的判定（复刻 calendar_ai_consent_sheet.dart:63-69）', () {
    /// 镜像 `CalendarAiConsent.refreshFromServer`：
    /// ```dart
    /// final remote = state?.consentGranted;
    /// if (remote == null) return granted;
    /// _set(remote); return remote;
    /// ```
    bool resolve({required bool localCache, required bool? remote}) {
      if (remote == null) return localCache;
      return remote;
    }

    test('请求失败 / 后端没这个字段 ⇒ 保持本地缓存不动', () {
      // 两种 null 都不能当成「未同意」：网络差的时候凭空撤回用户的同意，或者在旧后端
      // 上把所有人关掉，都比开关偶尔不刷新糟糕得多。
      expect(resolve(localCache: true, remote: null), isTrue);
      expect(resolve(localCache: false, remote: null), isFalse);
    });

    test('服务端说同意过 ⇒ 恢复 —— 这正是重装后开关自己回到「开」的那一步', () {
      expect(resolve(localCache: false, remote: true), isTrue);
    });

    test('服务端说已撤回 ⇒ 关掉，哪怕本地缓存还是开的（在另一台设备上关的）', () {
      expect(resolve(localCache: true, remote: false), isFalse);
    });
  });

  group('授权页首屏不等网络', () {
    // 把同意的回读放进首屏路径，代价是弱网下整页白屏：`_loading` 期间 body 是
    // `SizedBox.shrink()`。模拟器上实测撞到过——一次 401 自愈重发就够看见白屏。
    // 这一页的两个开关本地查 EventKit 就能画出来，网络那半应该后到再刷。
    test('_loading = false 排在 refreshFromServer 之前', () {
      final code = _codeOf(_authPage);
      final paint = code.indexOf('_loading = false');
      final network = code.indexOf('CalendarAiConsent.refreshFromServer');
      expect(paint, greaterThan(-1), reason: '找不到 _loading = false');
      expect(network, greaterThan(-1), reason: '找不到服务端回读');
      expect(paint, lessThan(network), reason: '首屏渲染不得排在网络请求之后');
    });
  });

  group('撤回成功后开关必须变关', () {
    // 实测漏过的一处：`_turnCalendarOff` 撤回成功后只清了 `_calendarSyncState`，
    // 没清 `_calendarGranted`。于是服务端日程已删、同意已撤，开关却还是"开"——
    // 而 CalendarSyncService 的闸门此刻已经关闭，一条都不会传。跟这次要修的 bug
    // 是同一种骗人，方向相反。
    //
    // 根源是照抄了提醒事项那条路：提醒事项的开关就是纯系统权限，App 关不掉，所以
    // 它"只弹去设置、开关不动"是对的；日历多了同意这一半，而它刚被关掉了。
    test('deleted 分支里 _calendarGranted 与 _calendarSyncState 一起清', () {
      final code = _codeOf(_authPage);
      final start = code.indexOf('Future<void> _turnCalendarOff()');
      expect(start, greaterThan(-1), reason: '找不到 _turnCalendarOff');
      final body = code.substring(start, code.indexOf('_showRevokeDialog', start));
      expect(body, contains('_calendarGranted = false'),
          reason: '撤回成功后开关必须变关，否则显示在同步、实际闸门已关');
      expect(body, contains('_calendarSyncState = null'), reason: '状态行也要清');
    });

    test('两个开关都有 accessibilityIdentifier —— 否则 UI 测试只能靠状态行反推', () {
      // 这个 bug 之所以在 maestro 里蒙混过关，是因为当时唯一可断言的是状态行文案：
      // 撤回后状态行从「已同步 1 个日程」变成「尚未同步」，`assertNotVisible: 已同步`
      // 照样通过，而开关还开着。现在开关自己可选中。
      final code = _codeOf(_authPage);
      expect(code, contains("toggleId: 'calendar_toggle'"));
      expect(code, contains("toggleId: 'reminders_toggle'"));
      expect(code, contains('identifier: toggleId'));
    });
  });

  group('授权页开关的判定（复刻 authorization_settings_page.dart 的 _refreshStatus）', () {
    /// 镜像 `_calendarGranted = calendarGranted && consentGranted`。
    bool calendarToggle({required bool systemPermission, required bool consent}) =>
        systemPermission && consent;

    test('两半都在才是开', () {
      expect(calendarToggle(systemPermission: true, consent: true), isTrue);
    });

    test('bug 现场：系统权限还在、同意丢了 ⇒ 开关是关的', () {
      // 修复前这个组合在每次重装后必然出现，因为同意只存在本地。修复后它只在用户
      // 真的撤回过同意时出现——服务端说了才算。
      expect(calendarToggle(systemPermission: true, consent: false), isFalse);
    });

    test('同意过但用户在系统设置里收回了日历权限 ⇒ 仍然是关的', () {
      // 同意不能替代系统权限：没有权限就一条也读不到，显示成「开」是骗人。
      expect(calendarToggle(systemPermission: false, consent: true), isFalse);
    });
  });
}
