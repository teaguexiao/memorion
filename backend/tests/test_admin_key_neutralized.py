"""Regression coverage for authentication with missing or obsolete credentials."""

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

# 必须先导这个：它作为 import 副作用把 Firestore/Redis 的 fake 装进 sys.modules。
#
# ⚠️ 必须写 `import test_bound_api_keys`，不能带 `tests.` 前缀。`tests/` 没有
# `__init__.py`，pytest 把它载成顶层模块名；带前缀会**再载一份独立的模块对象**，那份
# 的 import 副作用把 `redis_db.r` 指向第二个 FakeRedis 实例，于是同一批 pytest 里
# test_bound_api_keys 自己的缓存断言看到空字典。单独跑每个文件都过、合跑才炸。
import test_bound_api_keys  # noqa: E402,F401

from fastapi import HTTPException  # noqa: E402

import utils.other.endpoints as endpoints_auth  # noqa: E402


class AdminKeyBackdoorIsGoneTests(unittest.TestCase):
    """两个鉴权依赖里都不能再有「自报 uid」的旁路，ADMIN_KEY 设成什么都一样。"""

    def _assert_backdoor_inert(self, authorization):
        """后门若还在会直接返回 uid；已删则走正常校验并抛 HTTPException。"""
        with self.assertRaises(HTTPException) as ctx:
            endpoints_auth.get_current_user_uid(
                authorization=authorization, external_user_id=None
            )
        # 401 = 格式不对/缺头，400 = 缺 external_user_id。都说明没走后门。
        self.assertIn(ctx.exception.status_code, (400, 401))

        with self.assertRaises(HTTPException) as ctx:
            endpoints_auth.get_current_user_context(
                authorization=authorization, external_user_id=None
            )
        self.assertIn(ctx.exception.status_code, (400, 401))

    def test_configured_admin_key_no_longer_grants_anything(self):
        """
        最强的那条断言：把 ADMIN_KEY 设成一个真值，再拿它当门票敲门。

        后门还在的话 `ADMIN_KEY in authorization` 为真，`split()[1]` 会把尾巴当
        uid 返回 —— 于是这两个调用不抛异常，测试失败。这也是代码被「顺手恢复」时
        唯一能立刻炸掉的形态：置空版的断言在这里是过不去的。
        """
        with mock.patch.dict(os.environ, {"ADMIN_KEY": "old-backdoor-key"}):
            for authorization in [
                "old-backdoor-keyvictim_uid",   # 后门的原始用法
                "old-backdoor-key",
                "Bearer old-backdoor-keyvictim_uid",
            ]:
                with self.subTest(authorization=authorization):
                    self._assert_backdoor_inert(authorization)

    def test_empty_admin_key_does_not_open_backdoor(self):
        """
        空串是每个字符串的子串。后门代码在时靠 `os.getenv('ADMIN_KEY') and ...`
        的 falsy 短路挡住这一点；代码删掉后这条性质变成无条件成立。留着它，是为了
        在有人重新引入任何形式的 env 门票时也能报警。
        """
        with mock.patch.dict(os.environ, {"ADMIN_KEY": ""}):
            for authorization in ["", "anything", "victim_uid", "Bearer x"]:
                with self.subTest(authorization=authorization):
                    self._assert_backdoor_inert(authorization)

    def test_unset_admin_key_does_not_open_backdoor(self):
        env = {k: v for k, v in os.environ.items() if k != "ADMIN_KEY"}
        with mock.patch.dict(os.environ, env, clear=True):
            self._assert_backdoor_inert("victim_uid")

    def test_nothing_reads_admin_key_from_the_environment(self):
        """
        行为断言只覆盖 endpoints.py 那两个函数。这条扫源码，防止别处（新 router、
        新 util）又冒出一个读 ADMIN_KEY 的分支 —— 后门的危害正在于「无日志、看不
        见」，靠人 review 发现不可靠。

        只禁**真的去读环境变量**的形态。散文里提到这个名字是有意保留的：几个文件的
        docstring 专门写着「这里要的不是 ADMIN_KEY」「不再复用 ADMIN_KEY」，那些说明
        正是防止有人再把它接回来，不该被这条测试逼着删掉。
        """
        import re
        import subprocess

        backend = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        r = subprocess.run(
            ["grep", "-rn", "ADMIN_KEY", "--include=*.py", backend],
            capture_output=True,
            text=True,
        )
        # getenv/environ 两种读法都算，引号随意。
        reads_env = re.compile(r"""(getenv|environ(\.get)?)\s*[(\[]\s*['"]ADMIN_KEY['"]""")
        offenders = [
            line
            for line in r.stdout.splitlines()
            # 本文件自己就是靠 mock.patch.dict 设这个变量来做断言的。
            if os.path.basename(__file__) not in line and reads_env.search(line)
        ]
        self.assertEqual(offenders, [], "ADMIN_KEY 又被读取了:\n" + "\n".join(offenders))


class NotificationEndpointTests(unittest.TestCase):
    """/v1/notification 现在用自己的 OPS_NOTIFICATION_KEY，不再复用 ADMIN_KEY。

    它是踩过「空串等于空串」那个坑的地方，所以密钥缺失的形态要一直钉着。
    """

    def _send(self, secret_key, data=None):
        import routers.notifications as notifications

        return notifications.send_notification_to_user(
            data if data is not None else {}, secret_key=secret_key
        )

    def test_missing_ops_key_refuses_every_secret(self):
        """密钥未配置时端点必须整体关闭 —— 尤其是空的 secret-key 头。"""
        for env in ({"OPS_NOTIFICATION_KEY": ""}, {}):
            for secret_key in ["", "bogus", "None"]:
                with self.subTest(env=env, secret_key=secret_key):
                    with mock.patch.dict(os.environ, env, clear=not env):
                        with self.assertRaises(HTTPException) as ctx:
                            self._send(secret_key)
                        self.assertEqual(ctx.exception.status_code, 403)

    def test_admin_key_no_longer_opens_this_endpoint(self):
        """换密钥的核心断言：拿 ADMIN_KEY 来敲门必须被拒。"""
        with mock.patch.dict(
            os.environ, {"ADMIN_KEY": "old-backdoor-key", "OPS_NOTIFICATION_KEY": "new-ops-key"}
        ):
            with self.assertRaises(HTTPException) as ctx:
                self._send("old-backdoor-key")
            self.assertEqual(ctx.exception.status_code, 403)

    def test_configured_ops_key_still_rejects_wrong_secret(self):
        with mock.patch.dict(os.environ, {"OPS_NOTIFICATION_KEY": "real-secret"}):
            with self.assertRaises(HTTPException) as ctx:
                self._send("wrong-secret")
            self.assertEqual(ctx.exception.status_code, 403)

    def test_non_ascii_secret_is_rejected_not_crashed(self):
        """compare_digest 对非 ASCII str 会抛 TypeError —— 那会把 403 变成 500。"""
        with mock.patch.dict(os.environ, {"OPS_NOTIFICATION_KEY": "real-secret"}):
            with self.assertRaises(HTTPException) as ctx:
                self._send("密钥")
            self.assertEqual(ctx.exception.status_code, 403)

    def test_configured_ops_key_lets_the_right_secret_through(self):
        """正确密钥必须过掉 403，停在后面的 `uid is required` 校验上。"""
        with mock.patch.dict(os.environ, {"OPS_NOTIFICATION_KEY": "real-secret"}):
            with self.assertRaises(HTTPException) as ctx:
                self._send("real-secret")
            self.assertEqual(ctx.exception.status_code, 400)
            self.assertIn("uid", str(ctx.exception.detail))

    def test_missing_title_or_body_is_400_not_500(self):
        """原来缺 title/body 会 KeyError 冒成 500（审计报告 L18）。"""
        with mock.patch.dict(os.environ, {"OPS_NOTIFICATION_KEY": "real-secret"}):
            for data in ({"uid": "u1"}, {"uid": "u1", "title": "t"}, {"uid": "u1", "body": "b"}):
                with self.subTest(data=data):
                    with self.assertRaises(HTTPException) as ctx:
                        self._send("real-secret", data)
                    self.assertEqual(ctx.exception.status_code, 400)


if __name__ == "__main__":
    unittest.main(verbosity=2)
