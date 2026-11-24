"""
日历同意状态存在服务端，且撤回不会被「存量推断」翻回来。

## 这个测试为什么存在

同意原先只存在 App 的 `shared_preferences` 里，而它和系统日历权限的存活范围**不
一致**：iOS 权限记在系统侧（TCC），跨 App 更新保留；本地同意跟着 App 沙盒走，删除
重装即丢，退出登录也会被 `clearUserPreferences()` 清掉。

于是用户看到的症状是「每装一次新 TestFlight，授权页的 iOS 日历都要重开一次，而同一页
的提醒事项不用」——因为提醒事项开关只读系统权限，日历开关是 `系统权限 ∧ 本地同意`。
看起来像 iOS 单独忘了日历权限，其实是本地状态丢了，而服务器上此前同步的日程都还在
（开关显示「关」而数据仍在，这本身也与「关掉就删」的承诺不符）。

## 四条被钉住的不变式

1. **明确记录永远压过推断**。尤其 `granted=False` 时不许因为「还留着同步记录」被推断
   成已同意——那会让撤回自己失效。
2. **缺记录 + 有同步记录 ⇒ 已同意**（存量推断）。客户端的同意闸门在所有同步路径之前
   且 `force` 也绕不过，所以「服务端存着日程」证明用户当初同意过。少了这条推断，本次
   改动会让所有存量用户再被问一次。
3. **撤回后 sync 必须被挡**（409）。否则下次启动会静默把刚删掉的日程重新传上来。
4. **删数据失败时不许记下撤回**。先记撤回再删失败，会同时造成两件坏事：告诉用户数据
   已删（其实还在），以及让 409 闸门挡住重试时的重新同步。

Run:
    cd backend && python3 tests/test_calendar_consent_server_side.py
"""

import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

# 必须先导：它作为 import 副作用把 Firestore/Redis 的 fake 装进 sys.modules。
# 见 test_admin_key_neutralized.py 里关于「不能带 tests. 前缀」的说明。
import test_bound_api_keys  # noqa: E402,F401

from fastapi import HTTPException  # noqa: E402

import routers.calendar as cal  # noqa: E402
from models.calendar_event import CalendarConsentRequest, CalendarSyncRequest  # noqa: E402

DEV = 'dev_test'
UID = 'user_test'
CTX = (DEV, UID)


class ResolveConsentTest(unittest.TestCase):
    """`resolve_calendar_consent` —— 明确记录 vs 存量推断。"""

    def _resolve(self, consent, sync_state):
        with mock.patch.object(cal.dev_db, 'get_calendar_consent', return_value=consent), \
             mock.patch.object(cal.dev_db, 'get_calendar_sync_state', return_value=sync_state):
            return cal.resolve_calendar_consent(DEV, UID)

    def test_explicit_grant_wins(self):
        self.assertTrue(self._resolve({'granted': True}, None))

    def test_explicit_refusal_beats_leftover_sync_state(self):
        """撤回后即使同步记录还没清干净，也必须是「未同意」。

        这是本测试最重要的一条：推断规则若压过明确记录，撤回就形同虚设。
        """
        stale = {'synced_at': datetime.now(timezone.utc), 'event_count': 12}
        self.assertFalse(self._resolve({'granted': False}, stale))

    def test_missing_record_with_synced_events_infers_consent(self):
        """存量用户：没有 consent 字段，但同步过 —— 推断为已同意。"""
        state = {'synced_at': datetime.now(timezone.utc), 'event_count': 3}
        self.assertTrue(self._resolve(None, state))

    def test_missing_record_with_event_count_only_infers_consent(self):
        """只有 event_count（synced_at 那次写失败）同样算同意过。"""
        self.assertTrue(self._resolve(None, {'event_count': 1}))

    def test_missing_record_and_never_synced_is_not_consent(self):
        self.assertFalse(self._resolve(None, None))
        self.assertFalse(self._resolve(None, {}))

    def test_zero_events_synced_still_counts(self):
        """同步过但当时日历是空的：`synced_at` 在，仍然是同意过。

        空 events 是有意义的信号（「这段时间我没日程」），不是「没同步过」。
        """
        self.assertTrue(self._resolve(None, {'synced_at': datetime.now(timezone.utc), 'event_count': 0}))


class SyncGateTest(unittest.TestCase):
    """`POST /v1/calendar/sync` 的同意闸门与补记。"""

    def _request(self):
        now = datetime.now(timezone.utc)
        return CalendarSyncRequest(window_start=now - timedelta(days=1), window_end=now + timedelta(days=1), events=[])

    def test_explicit_refusal_blocks_sync(self):
        with mock.patch.object(cal.dev_db, 'get_calendar_consent', return_value={'granted': False}), \
             mock.patch.object(cal.dev_db, 'replace_calendar_events') as replace:
            with self.assertRaises(HTTPException) as ctx:
                cal.sync_calendar_events(self._request(), ctx=CTX)
        self.assertEqual(ctx.exception.status_code, 409)
        replace.assert_not_called()

    def test_missing_consent_is_allowed_and_backfilled(self):
        """老 App（本地闸门）不带 consent 端点，不能被拒；成功后要补记。

        补记是存量用户「重装后开关自动恢复」的来源：下一次读 sync-state 就有明确
        记录，不必再依赖推断。
        """
        with mock.patch.object(cal.dev_db, 'get_calendar_consent', return_value=None), \
             mock.patch.object(cal.dev_db, 'replace_calendar_events', return_value={'written': 0, 'deleted': 0}), \
             mock.patch.object(cal.dev_db, 'set_calendar_sync_state'), \
             mock.patch.object(cal.dev_db, 'set_calendar_consent') as set_consent:
            cal.sync_calendar_events(self._request(), ctx=CTX)
        set_consent.assert_called_once_with(DEV, UID, True)

    def test_existing_grant_is_not_rewritten(self):
        """已有明确同意就别重写，否则每次同步都在刷 granted_at，撤回历史失真。"""
        with mock.patch.object(cal.dev_db, 'get_calendar_consent', return_value={'granted': True}), \
             mock.patch.object(cal.dev_db, 'replace_calendar_events', return_value={'written': 0, 'deleted': 0}), \
             mock.patch.object(cal.dev_db, 'set_calendar_sync_state'), \
             mock.patch.object(cal.dev_db, 'set_calendar_consent') as set_consent:
            cal.sync_calendar_events(self._request(), ctx=CTX)
        set_consent.assert_not_called()


class ConsentEndpointTest(unittest.TestCase):
    """`POST /v1/calendar/consent` —— 撤回与删数据是一次操作。"""

    def test_grant_records_consent_without_deleting(self):
        with mock.patch.object(cal.dev_db, 'set_calendar_consent',
                               return_value={'granted': True, 'updated_at': datetime.now(timezone.utc)}), \
             mock.patch.object(cal.dev_db, 'delete_all_calendar_events') as delete:
            resp = cal.set_calendar_consent(CalendarConsentRequest(granted=True), ctx=CTX)
        self.assertTrue(resp.granted)
        self.assertEqual(resp.deleted_events, 0)
        delete.assert_not_called()

    def test_withdrawal_erases_events_in_the_same_call(self):
        with mock.patch.object(cal.dev_db, 'delete_all_calendar_events', return_value=7) as delete, \
             mock.patch.object(cal.dev_db, 'set_calendar_consent',
                               return_value={'granted': False, 'updated_at': datetime.now(timezone.utc)}) as set_consent:
            resp = cal.set_calendar_consent(CalendarConsentRequest(granted=False), ctx=CTX)
        self.assertFalse(resp.granted)
        self.assertEqual(resp.deleted_events, 7)
        delete.assert_called_once()
        set_consent.assert_called_once_with(DEV, UID, False)

    def test_failed_erase_does_not_record_withdrawal(self):
        """删不掉就别记撤回 —— 见文件头不变式 4。"""
        with mock.patch.object(cal.dev_db, 'delete_all_calendar_events', side_effect=RuntimeError('boom')), \
             mock.patch.object(cal.dev_db, 'set_calendar_consent') as set_consent:
            with self.assertRaises(HTTPException) as ctx:
                cal.set_calendar_consent(CalendarConsentRequest(granted=False), ctx=CTX)
        self.assertEqual(ctx.exception.status_code, 500)
        set_consent.assert_not_called()

    def test_delete_events_endpoint_also_records_withdrawal(self):
        """`DELETE /v1/calendar/events` 的语义就是撤回，必须一起记下。

        不记的话，下一次同步会通过闸门把日程重新传上来，而
        `resolve_calendar_consent` 也会继续从空的同步状态推断。
        """
        with mock.patch.object(cal.dev_db, 'delete_all_calendar_events', return_value=4), \
             mock.patch.object(cal.dev_db, 'set_calendar_consent') as set_consent:
            resp = cal.delete_calendar_events(ctx=CTX)
        self.assertEqual(resp.deleted, 4)
        set_consent.assert_called_once_with(DEV, UID, False)


class SyncStateResponseTest(unittest.TestCase):
    """`GET /v1/calendar/sync-state` 要把同意状态一起带回去。"""

    def test_consent_is_included(self):
        state = {'synced_at': datetime.now(timezone.utc), 'event_count': 5}
        with mock.patch.object(cal.dev_db, 'get_calendar_sync_state', return_value=state), \
             mock.patch.object(cal.dev_db, 'get_calendar_consent', return_value={'granted': True}):
            resp = cal.get_calendar_sync_state(ctx=CTX)
        self.assertTrue(resp.consent_granted)
        self.assertEqual(resp.event_count, 5)

    def test_no_state_at_all_is_not_consent(self):
        with mock.patch.object(cal.dev_db, 'get_calendar_sync_state', return_value=None), \
             mock.patch.object(cal.dev_db, 'get_calendar_consent', return_value=None):
            resp = cal.get_calendar_sync_state(ctx=CTX)
        self.assertFalse(resp.consent_granted)
        self.assertIsNone(resp.synced_at)

    def test_revoked_user_reports_not_consented(self):
        """撤回后再读：开关必须是关的，哪怕同步状态字段没被清干净。"""
        with mock.patch.object(cal.dev_db, 'get_calendar_sync_state',
                               return_value={'event_count': 9, 'synced_at': datetime.now(timezone.utc)}), \
             mock.patch.object(cal.dev_db, 'get_calendar_consent', return_value={'granted': False}):
            resp = cal.get_calendar_sync_state(ctx=CTX)
        self.assertFalse(resp.consent_granted)


class ClientGateInvariantTest(unittest.TestCase):
    """存量推断的前提：客户端闸门不可绕过。

    `resolve_calendar_consent` 把「服务端存着日程」当成「用户同意过」的证据，这只在
    客户端的同意检查确实拦在所有同步路径之前、且 `force` 绕不过时才成立。这里直接读
    Dart 源码钉住那个前提——它一旦被改成「force 可跳过」，推断就会静默变成错的。
    """

    GATE_FILE = os.path.join(os.path.dirname(__file__), '..', '..', 'app', 'lib', 'services', 'calendar_sync_service.dart')

    def test_consent_gate_precedes_upload_and_ignores_force(self):
        if not os.path.exists(self.GATE_FILE):
            self.skipTest('app/ 不在此 checkout 中')
        source = open(self.GATE_FILE, encoding='utf-8').read()

        gate = source.find('calendarAiConsentGranted')
        upload = source.find('syncCalendarEvents(')
        self.assertNotEqual(gate, -1, '同意闸门不见了')
        self.assertNotEqual(upload, -1, '找不到上传调用')
        self.assertLess(gate, upload, '同意闸门必须在上传之前')

        # force 只允许绕过节流与指纹，绝不允许绕过同意。
        gate_line_start = source.rfind('\n', 0, gate)
        gate_stmt = source[gate_line_start:source.find('\n', gate) + 1]
        self.assertNotIn('force', gate_stmt, 'force 不得出现在同意闸门的条件里')


if __name__ == '__main__':
    unittest.main(verbosity=2)
