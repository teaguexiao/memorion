"""`memorion-daily-summary` cron 的早上补写轮与用户时区规则（2026-10-27）。

- 补写轮在 CATCH_UP_LOCAL_TIME 问「昨天」并带 `catch_up=True`（后端据此不推送）；
- 晚上那一轮出错不能连累补写轮；
- 用户发现两个时区字段都查，按 `effective_time_zone` 归时区，且这条规则与后端
  `get_user_effective_timezone` 一致 —— 两边不一致时，一天里有一段落在两篇日志之间。

⚠️ 函数是从源码 AST 抽出来执行的，不是 import：在 backend/ 下 `import modal` 解析到的是
`backend/modal/` 这个目录本身（没有 `__init__.py` 的命名空间包），不是 pip 的 modal。

Run: cd backend && python3 tests/test_daily_summary_cron_catch_up.py
"""

import ast
import asyncio
import concurrent.futures
import os
import sys
import types
import unittest
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from typing import List, Optional
from unittest import mock
from zoneinfo import ZoneInfo, available_timezones

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))
CRON = BACKEND / 'modal' / 'memorion_daily_summary.py'

try:
    import pytz  # noqa: F401  (the Modal image installs it; local test envs may not)
    PYTZ_SHIM = {}
except ImportError:
    PYTZ_SHIM = {'pytz': types.SimpleNamespace(timezone=ZoneInfo, utc=timezone.utc,
                                               all_timezones=sorted(available_timezones()))}


def _load(*names, **namespace):
    """Exec the named top-level functions/assignments of the cron source, decorators stripped."""
    src = CRON.read_text()
    body, found = [], set()
    for node in ast.parse(src).body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in names:
            node.decorator_list = []
            body.append(node)
            found.add(node.name)
        elif isinstance(node, ast.Assign):
            targets = {t.id for t in node.targets if isinstance(t, ast.Name)} & set(names)
            if targets:
                body.append(node)
                found |= targets
    assert found == set(names), f'cron 源码里找不到：{set(names) - found}'
    ns = {'asyncio': asyncio, 'concurrent': concurrent, 'datetime': datetime, 'List': List, 'Optional': Optional,
          'os': os, **namespace}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(CRON), 'exec'), ns)
    return ns


class FixedDatetime(datetime):
    """2026-10-25 22:00 UTC = 2026-10-26 06:00 in Shanghai: the catch-up hour there."""

    @classmethod
    def now(cls, tz=None):
        moment = datetime(2026, 10, 25, 22, 0, tzinfo=timezone.utc)
        return moment.astimezone(tz) if tz else moment


class CatchUpPassTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.dict(sys.modules, PYTZ_SHIM)
        patch.start()
        self.addCleanup(patch.stop)

    def test_catch_up_asks_for_yesterday_with_the_flag_and_evening_for_today(self):
        calls = []

        def call_api(uid, date_str, api_key, catch_up=False):
            calls.append((uid, date_str, catch_up))
            return {'status': 'success'}

        ns = _load('get_today_date_for_timezone', 'get_yesterday_date_for_timezone', 'process_daily_summaries',
                   datetime=FixedDatetime, call_daily_summary_api=call_api)
        users = [{'uid': 'u', 'timezone': 'Asia/Shanghai'}]
        asyncio.run(ns['process_daily_summaries'](users, 'key', catch_up=True))
        asyncio.run(ns['process_daily_summaries'](users, 'key'))
        self.assertEqual([('u', '2026-10-25', True), ('u', '2026-10-26', False)], calls)

    def test_catch_up_pass_runs_at_its_local_hour_with_the_flag(self):
        hours, passes = [], []

        async def users_in(timezones):
            return [{'uid': 'u', 'timezone': timezones[0], 'collection': 'developer_data'}]

        async def process(users, api_key, catch_up=False):
            passes.append(catch_up)
            return {'success': len(users)}

        ns = _load('CATCH_UP_LOCAL_TIME', 'send_catch_up_summaries',
                   get_timezones_at_time=lambda t: hours.append(t) or ['Asia/Shanghai'],
                   get_users_in_timezones=users_in, process_daily_summaries=process)
        result = asyncio.run(ns['send_catch_up_summaries']('key'))
        self.assertEqual([ns['CATCH_UP_LOCAL_TIME']], hours)
        self.assertEqual([True], passes)
        self.assertEqual(1, result['users_found'])

    def _cronjob(self, evening, catch_up, zones_at=lambda target: ['Asia/Shanghai']):
        return _load('CATCH_UP_LOCAL_TIME', 'daily_summary_cronjob', initialize_firebase=lambda: True,
                     _get_api_key=lambda: 'key', get_timezones_at_time=zones_at,
                     send_daily_summary=evening, send_catch_up_summaries=catch_up)['daily_summary_cronjob']

    def test_failing_evening_pass_does_not_cost_the_catch_up_its_run(self):
        ran = []

        async def evening(api_key):
            raise RuntimeError('firestore down')

        async def catch_up(api_key, timezones=None):
            ran.append(api_key)
            return {'users_found': 1, 'results': {}}

        result = asyncio.run(self._cronjob(evening, catch_up)())
        self.assertEqual(['key'], ran)
        self.assertEqual('error', result['status'])
        self.assertEqual({'users_found': 1, 'results': {}}, result['catch_up'])

    def test_catch_up_zones_are_taken_before_the_evening_pass_uses_up_the_minute(self):
        # The real `get_timezones_at_time` matches the current minute only. The evening pass
        # runs for minutes, so zones looked up after it are those at 06:0X: nobody.
        catch_up_time = _load('CATCH_UP_LOCAL_TIME')['CATCH_UP_LOCAL_TIME']
        clock = {'minute': 0}
        got = []

        def zones_at(target):
            return ['Asia/Shanghai'] if target == catch_up_time and clock['minute'] == 0 else []

        async def evening(api_key):
            clock['minute'] = 7
            return {'users_found': 3, 'results': {}}

        async def catch_up(api_key, timezones=None):
            got.append(timezones if timezones is not None else zones_at(catch_up_time))
            return {'users_found': len(got[-1]), 'results': {}}

        asyncio.run(self._cronjob(evening, catch_up, zones_at)())
        self.assertEqual([['Asia/Shanghai']], got)

    def test_payload_carries_catch_up_only_when_asked(self):
        requests = mock.Mock()
        requests.post.return_value.status_code = 200
        requests.post.return_value.json.return_value = {}
        ns = _load('call_daily_summary_api', requests=requests)
        ns['call_daily_summary_api']('u', '2026-10-25', 'key', catch_up=True)
        self.assertEqual({'date': '2026-10-25', 'include_image': True, 'force_regenerate': False, 'defer': True,
                          'catch_up': True},
                         requests.post.call_args.kwargs['json'])
        ns['call_daily_summary_api']('u', '2026-10-25', 'key')
        self.assertNotIn('catch_up', requests.post.call_args.kwargs['json'])

    def test_queued_day_is_reported_as_queued(self):
        # 202: the journal worker writes it (and sends the evening push); the cron is done.
        requests = mock.Mock()
        requests.post.return_value.status_code = 202
        requests.post.return_value.json.return_value = {'status': 'queued', 'job_id': 'b7e0a35c-0000', 'job_status': 'queued'}
        ns = _load('call_daily_summary_api', requests=requests)
        result = ns['call_daily_summary_api']('u', '2026-10-25', 'key')
        self.assertEqual('queued', result['status'])
        self.assertTrue(requests.post.call_args.kwargs['json']['defer'])


USERS = {
    'pref-only': {'timezone': 'Asia/Shanghai', 'fcm_token': 't'},
    'device-only': {'time_zone': 'Asia/Shanghai', 'fcm_token': 't'},
    'both': {'timezone': 'Asia/Shanghai', 'time_zone': 'Asia/Shanghai', 'fcm_token': 't'},
    'moved': {'timezone': 'America/Denver', 'time_zone': 'Asia/Shanghai', 'fcm_token': 't'},
    'golden-tenant': {'time_zone': 'Asia/Shanghai'},
}


class _FakeUsers:
    def __init__(self, docs):
        self._docs = docs

    def where(self, filter):
        hits = [SimpleNamespace(id=uid, to_dict=lambda d=data: dict(d))
                for uid, data in self._docs.items() if data.get(filter.field_path) in filter.value]
        return SimpleNamespace(stream=lambda: iter(hits))

    def document(self, uid):
        return SimpleNamespace(get=lambda: SimpleNamespace(exists=False))


class _FakeFirestore:
    def collection(self, name):
        if name == 'developer_data':
            return SimpleNamespace(document=lambda dev: SimpleNamespace(collection=lambda _: _FakeUsers(USERS)))
        return _FakeUsers({})  # legacy top-level users/


class UserDiscoveryTests(unittest.TestCase):
    def _discover(self, timezones):
        firebase_admin = types.SimpleNamespace(firestore=types.SimpleNamespace(client=_FakeFirestore))
        ns = _load('DEFAULT_DEVELOPER_ID', 'EVAL_TENANT_UID_PREFIXES', 'is_eval_tenant', 'effective_time_zone',
                   'get_users_in_timezones')
        with mock.patch.dict(sys.modules, {'firebase_admin': firebase_admin}):
            users = asyncio.run(ns['get_users_in_timezones'](timezones))
        return {u['uid']: u['timezone'] for u in users}

    def test_either_field_reaches_the_user_and_the_effective_zone_decides(self):
        # `pref-only` was never found before (discovery read `time_zone` only); `moved` belongs to
        # Denver, where its preference points, not to the zone its device last reported.
        self.assertEqual({'pref-only': 'Asia/Shanghai', 'device-only': 'Asia/Shanghai', 'both': 'Asia/Shanghai'},
                         self._discover(['Asia/Shanghai']))
        self.assertEqual({'moved': 'America/Denver'}, self._discover(['America/Denver']))

    def test_rule_matches_the_backend(self):
        import database.developer_data as dev_db
        cron_rule = _load('effective_time_zone')['effective_time_zone']
        for uid, data in list(USERS.items()) + [('empty', {}), ('blank-pref', {'timezone': '', 'time_zone': 'Asia/Tokyo'})]:
            doc = SimpleNamespace(exists=True, to_dict=lambda d=data: dict(d))
            with self.subTest(uid=uid), mock.patch.object(
                    dev_db, '_get_user_ref', return_value=SimpleNamespace(get=lambda doc=doc: doc)):
                self.assertEqual(dev_db.get_user_effective_timezone('dev', uid), cron_rule(data))


if __name__ == '__main__':
    unittest.main(verbosity=2)
