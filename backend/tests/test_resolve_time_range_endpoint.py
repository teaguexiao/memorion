"""
POST /v1/user/resolve-time-range —— 把相对时间表达式解析成绝对区间。

这个端点是为了让外部客户端（CLI / MCP）能拿到和 chat agent **同一套**时间解析
结果：MCP 的 `resolve_time_range` 工具直接调它，而不是在客户端本地猜日期——跑
MCP 的机器不一定在用户所在时区。

⚠️ 这里钉住的核心事实是**时区字段有两个**，两个写入方不同：

- `time_zone` —— `POST /v1/users/fcm-token` 写的（App 启动随 FCM token 上报）。
  chat agent（`utils/retrieval/graph.py`）、对话处理、通知都读这个。
- `timezone` —— `PATCH /v1/user/timezone` 写的（用户在设置里手选）。

本端点必须**优先 `time_zone`**，否则同一句「上周」在 MCP 里和在 App 的 chat 里
会解析成不同区间，而这种不一致是静默的：两边各自都返回一个看起来合理的区间。

Run:
    cd backend && python3 tests/test_resolve_time_range_endpoint.py
"""

import os
import sys
import unittest
from datetime import datetime, timezone as dt_timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

# 必须先导这个：它作为 import 副作用把 Firestore/Redis 的 fake 装进 sys.modules，
# 否则 database._client 会去读 .env 里那个服务器侧的凭据路径（/home/ubuntu/...），
# 本地直接 OSError。
#
# ⚠️ 必须写 `import test_bound_api_keys`，不能写 `import tests.test_bound_api_keys`。
# `tests/` 没有 `__init__.py`，pytest 把它载成顶层模块名 `test_bound_api_keys`；带
# `tests.` 前缀会**再载一份独立的模块对象**，那份的 import 副作用把 `redis_db.r` 重新
# 指向第二个 FakeRedis 实例，于是同一批 pytest 里 test_bound_api_keys 自己的断言看到
# 的是空字典。单独跑两个文件都过、合跑才炸。
import test_bound_api_keys  # noqa: E402,F401

from fastapi import HTTPException  # noqa: E402

import routers.developer_users as ru  # noqa: E402


DEV = "dev-1"
UID = "user-1"


class ResolveUserTimezoneTests(unittest.TestCase):
    """时区解析：time_zone 优先，timezone 回退，都没有则 UTC。"""

    def test_prefers_time_zone_the_chat_agent_reads(self):
        with mock.patch.object(ru.dev_db, "get_user_time_zone", return_value="Asia/Shanghai"), \
             mock.patch.object(ru.dev_db, "get_user_timezone", return_value="America/New_York"):
            self.assertEqual(ru._resolve_user_timezone(DEV, UID), "Asia/Shanghai")

    def test_falls_back_to_settings_timezone(self):
        with mock.patch.object(ru.dev_db, "get_user_time_zone", return_value=None), \
             mock.patch.object(ru.dev_db, "get_user_timezone", return_value="America/New_York"):
            self.assertEqual(ru._resolve_user_timezone(DEV, UID), "America/New_York")

    def test_defaults_to_utc_when_neither_is_set(self):
        with mock.patch.object(ru.dev_db, "get_user_time_zone", return_value=None), \
             mock.patch.object(ru.dev_db, "get_user_timezone", return_value=None):
            self.assertEqual(ru._resolve_user_timezone(DEV, UID), "UTC")

    def test_firestore_failure_does_not_break_the_endpoint(self):
        """时区读失败只该降级成 UTC，不该让整个请求 500。"""
        with mock.patch.object(ru.dev_db, "get_user_time_zone", side_effect=RuntimeError("boom")), \
             mock.patch.object(ru.dev_db, "get_user_timezone", side_effect=RuntimeError("boom")):
            self.assertEqual(ru._resolve_user_timezone(DEV, UID), "UTC")


class ResolveTimeRangeEndpointTests(unittest.IsolatedAsyncioTestCase):
    async def _call(self, expr, tz_override=None, resolver=None):
        body = ru.TimeRangeRequest(expr=expr, timezone=tz_override)
        with mock.patch.object(ru.dev_db, "get_user_time_zone", return_value="Asia/Shanghai"), \
             mock.patch.object(ru.dev_db, "get_user_timezone", return_value=None), \
             mock.patch.object(ru, "retrieve_context_dates_by_question", resolver or (lambda *a: [])):
            return await ru.resolve_time_range(body, external_user_id=UID, developer_id=DEV)

    async def test_resolves_a_range_and_echoes_the_timezone_used(self):
        start = datetime(2026, 8, 3, tzinfo=dt_timezone.utc)
        end = datetime(2026, 8, 9, 23, 59, tzinfo=dt_timezone.utc)
        res = await self._call("上周", resolver=lambda *a: [start, end])
        self.assertEqual(res.start, start.isoformat())
        self.assertEqual(res.end, end.isoformat())
        self.assertEqual(res.timezone, "Asia/Shanghai")
        self.assertEqual(res.resolved_as, "上周")

    async def test_passes_the_user_timezone_to_the_resolver(self):
        """区间是在用户时区里算的——传错时区会静默算出偏一天的区间。"""
        seen = {}

        def resolver(question, tz):
            seen["tz"] = tz
            return []

        await self._call("last Wednesday", resolver=resolver)
        self.assertEqual(seen["tz"], "Asia/Shanghai")

    async def test_explicit_timezone_overrides_the_stored_one(self):
        seen = {}

        def resolver(question, tz):
            seen["tz"] = tz
            return []

        await self._call("last Wednesday", tz_override="Europe/London", resolver=resolver)
        self.assertEqual(seen["tz"], "Europe/London")

    async def test_unresolvable_expression_returns_nulls_not_an_error(self):
        """没有可解析日期是正常答案。返回 500 会让客户端以为端点坏了。"""
        res = await self._call("随便聊聊", resolver=lambda *a: [])
        self.assertIsNone(res.start)
        self.assertIsNone(res.end)
        self.assertEqual(res.timezone, "Asia/Shanghai")

    async def test_llm_failure_degrades_to_nulls(self):
        def boom(*a):
            raise RuntimeError("llm down")

        res = await self._call("上周", resolver=boom)
        self.assertIsNone(res.start)
        self.assertIsNone(res.end)

    async def test_single_datetime_is_not_treated_as_a_range(self):
        """解析器只给一个时间点时不能当区间用——end 会是 undefined 索引。"""
        res = await self._call("昨天", resolver=lambda *a: [datetime(2026, 8, 8, tzinfo=dt_timezone.utc)])
        self.assertIsNone(res.start)
        self.assertIsNone(res.end)

    async def test_blank_expression_is_rejected(self):
        body = ru.TimeRangeRequest(expr="   ")
        with self.assertRaises(HTTPException) as ctx:
            await ru.resolve_time_range(body, external_user_id=UID, developer_id=DEV)
        self.assertEqual(ctx.exception.status_code, 400)


class EndpointWiringTests(unittest.TestCase):
    def test_endpoint_is_registered(self):
        paths = {
            (tuple(sorted(r.methods)), r.path)
            for r in ru.router.routes
            if hasattr(r, "methods")
        }
        self.assertIn((("POST",), "/v1/user/resolve-time-range"), paths)

    def test_auth_matches_its_neighbours(self):
        """鉴权必须和同文件其他端点一致：漏掉 Depends 就是个开放端点。"""
        import inspect

        sig = inspect.signature(ru.resolve_time_range)
        self.assertIn("developer_id", sig.parameters)
        self.assertIn("external_user_id", sig.parameters)


if __name__ == "__main__":
    unittest.main(verbosity=2)
