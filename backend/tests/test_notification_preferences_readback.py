"""通知偏好回读（`GET /v1/users/notification-preferences`）的核心不变式。

存在的理由（2026-08-12）：偏好同步在这之前是**单向**的 —— 只有 POST，App 也不回读。
本地一清（重装 / 换机）就回到默认值，而云端仍是用户上次设的值：**设置页显示开着、
服务端其实不推**，用户无从自查。加了 GET 之后 App 在启动时回读一次。

⚠️ **这份测试真正要钉住的是 `stored_keys`，不是「GET 能不能返回偏好」。**
读出去的 `preferences` 总是全字段（缺的按 `NOTIFICATION_PREFERENCES_DEFAULTS` 补齐），
所以「用户显式设成 True」和「从没设过、默认恰好是 True」在**值上完全一样**。客户端若
只看 `preferences` 就覆盖本地，等于把**服务端此刻的默认值固化成用户设置** —— 此后两边
改默认值对这批用户永久无效，而且看起来完全正常（值合法、行为「正常」、没有任何日志）。
线上 156 个用户里只有 2 个写过这条记录，也就是说绝大多数人都会踩到。

这个缺陷形态没法靠「返回值对不对」发现，只能钉住 `stored_keys` 的语义本身：
**没存过的 key 一定不在里面**（`test_stored_keys_excludes_unset_keys`），以及端点确实
把它带出去了（`test_endpoint_returns_stored_keys`）。

Firestore 用一个假 ref 顶掉（`_get_user_ref` 是 `developer_data.py` 里唯一的用户文档
访问器），因此不连库、也不需要凭证。
"""

import os
import sys
import unittest
from unittest import mock

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

import database.developer_data as dev_db  # noqa: E402
import routers.notifications as notif_router  # noqa: E402


class _FakeDoc:
    def __init__(self, data):
        self._data = data
        self.exists = data is not None

    def to_dict(self):
        return self._data


class _FakeRef:
    def __init__(self, data):
        self._doc = _FakeDoc(data)

    def get(self):
        return self._doc


class _FakeWritableRef:
    """支持 update() 且写完能被 get() 读到 —— 写入侧测试需要真的串起写-读两半。"""

    def __init__(self, data=None):
        self.data = data
        self.updates = []

    def get(self):
        return _FakeDoc(self.data)

    def update(self, payload):
        self.updates.append(payload)
        if self.data is None:
            self.data = {}
        self.data.update(payload)


def _set_prefs(stored, preferences):
    """在「Firestore 里存着 `stored`」的前提下调 set_notification_preferences。

    返回 (函数返回值, 真正落库的 notification_preferences map)。两者刻意不同。
    """
    data = None if stored is None else {'notification_preferences': stored}
    ref = _FakeWritableRef(data)
    with mock.patch.object(dev_db, '_get_user_ref', return_value=ref), \
            mock.patch.object(dev_db, '_ensure_user_exists'):
        returned = dev_db.set_notification_preferences('dev-1', 'user-1', preferences)
    return returned, ref.data['notification_preferences']


def _detailed_with_stored(stored):
    """在「Firestore 里存着 `stored`」的前提下调 get_notification_preferences_detailed。

    stored=None 表示用户文档不存在。
    """
    data = None if stored is None else {'notification_preferences': stored}
    with mock.patch.object(dev_db, '_get_user_ref', return_value=_FakeRef(data)):
        return dev_db.get_notification_preferences_detailed('dev-1', 'user-1')


class NotificationPreferencesReadbackTest(unittest.TestCase):
    def test_stored_keys_excludes_unset_keys(self):
        """只设过一个 key 时，stored_keys 只有那一个 —— 这是整个回读设计的核心。

        注意断言的是**只设过 daily_moment**，而 `preferences['task_reminder']` 此刻也是
        True（默认值）。两者在值上不可区分，所以 stored_keys 是客户端唯一的判据。
        """
        prefs, stored_keys = _detailed_with_stored({'daily_moment': False})

        self.assertEqual(stored_keys, ['daily_moment'])
        self.assertFalse(prefs['daily_moment'], '用户设过的值必须生效')
        self.assertTrue(
            prefs['task_reminder'],
            '没设过的 key 仍按默认补齐 —— 这正是不能只看 preferences 的原因',
        )

    def test_stored_keys_empty_when_user_never_synced(self):
        """从没同步过（文档不存在 / 没有这个字段）→ stored_keys 为空，客户端一个字段都不该覆盖。"""
        for stored in (None, {}, {'daily_moment': None}):
            with self.subTest(stored=stored):
                prefs, stored_keys = _detailed_with_stored(stored)
                self.assertEqual(stored_keys, [])
                self.assertEqual(
                    prefs, dev_db.NOTIFICATION_PREFERENCES_DEFAULTS,
                    '没有记录时必须落全套默认值（默认放行）',
                )

    def test_stored_keys_covers_every_known_pref(self):
        """全部设过时，stored_keys 覆盖所有已知 key —— 防止漏掉某个 key 永远同步不下来。

        这条也是「新增一个偏好字段」时的守卫：字段加进 DEFAULTS 但收集逻辑漏了它，
        症状是那个开关在新设备上永远显示默认值，而云端明明有值。
        """
        all_set = {k: v for k, v in dev_db.NOTIFICATION_PREFERENCES_DEFAULTS.items()}
        prefs, stored_keys = _detailed_with_stored(all_set)

        self.assertEqual(
            sorted(stored_keys), sorted(dev_db.NOTIFICATION_PREFERENCES_DEFAULTS.keys()),
        )
        self.assertEqual(prefs, all_set)

    def test_unknown_stored_keys_are_not_leaked(self):
        """Firestore 里的陌生字段既不进 preferences 也不进 stored_keys。

        存量数据里可能有别的键（改名遗留、手改数据），带出去会让老版本 App 拿到
        它不认识的字段。
        """
        prefs, stored_keys = _detailed_with_stored({'daily_moment': True, 'legacy_switch': True})

        self.assertNotIn('legacy_switch', prefs)
        self.assertNotIn('legacy_switch', stored_keys)

    def test_get_notification_preferences_stays_consistent(self):
        """推送闸门用的那个薄封装必须与 detailed 的第一个返回值完全一致。

        闸门（`utils/notification_gate.py`）只关心最终值。两个函数各算一遍的话，
        「GET 显示的」和「实际执行的」会分叉 —— 而这正是这次要修的病。
        """
        stored = {'daily_moment': False, 'quiet_hours_enabled': True}
        data = {'notification_preferences': stored}
        with mock.patch.object(dev_db, '_get_user_ref', return_value=_FakeRef(data)):
            plain = dev_db.get_notification_preferences('dev-1', 'user-1')
            detailed, _ = dev_db.get_notification_preferences_detailed('dev-1', 'user-1')
        self.assertEqual(plain, detailed)

    def test_no_developer_id_falls_back_to_defaults(self):
        """拿不到 developer_id 时不碰 Firestore，返回默认值 + 空 stored_keys。"""
        prefs, stored_keys = dev_db.get_notification_preferences_detailed('', 'user-1')
        self.assertEqual(prefs, dev_db.NOTIFICATION_PREFERENCES_DEFAULTS)
        self.assertEqual(stored_keys, [])

    def test_endpoint_returns_stored_keys(self):
        """端点必须把 stored_keys 带出去 —— 少了它客户端就只能猜。"""
        with mock.patch.object(
            notif_router.dev_db,
            'get_notification_preferences_detailed',
            return_value=({'daily_moment': False}, ['daily_moment']),
        ):
            body = notif_router.read_notification_preferences(ctx=('dev-1', 'user-1'))

        self.assertEqual(body['status'], 'Ok')
        self.assertEqual(body['preferences'], {'daily_moment': False})
        self.assertEqual(body['stored_keys'], ['daily_moment'])

    def test_write_persists_only_stored_and_incoming_keys(self):
        """⚠️ 落库的 map 不许被补齐成全字段 —— 这是回读那层防护的存亡线。

        `set_notification_preferences` 曾拿 `get_notification_preferences()`（补齐默认后的
        全字段）当基线整份写回：用户动一个开关，七个字段全落库，`stored_keys` 立刻退化成
        全集，此后回读会把**当时的**默认值当成用户设置覆盖回本地。App 侧改成增量上报只治了
        上行那一半，这里不治就等于没治 —— 两个函数各自都对、接起来才错，两边的单测都发现不了。

        实测代价：线上 2 个写过记录的用户 `quiet_hours_start_minutes` 全被钉在 1320（22:00
        的旧默认），而 22:00 恰好是每日一刻的推送点 —— 谁一开静默就永久收不到它。
        """
        _, stored = _set_prefs(None, {'milestone': False})

        self.assertEqual(
            stored, {'milestone': False},
            '只传了一个字段，落库就必须只有这一个；补齐默认值等于把它固化成用户设置',
        )

    def test_write_preserves_previously_stored_keys(self):
        """既有的用户设置不能被这次写入抹掉（合并语义仍然成立）。

        Ted 显式关掉过 `pause_reminder` —— 这类真实意图和「固化的默认 True」必须区分开，
        不能因为收窄落库范围就把它一起丢了。
        """
        _, stored = _set_prefs({'pause_reminder': False}, {'milestone': False})

        self.assertEqual(stored, {'pause_reminder': False, 'milestone': False})

    def test_write_response_still_returns_full_prefs(self):
        """响应体仍是补齐默认的全字段 —— 落库范围收窄不改变 POST 的对外契约。"""
        returned, stored = _set_prefs(None, {'milestone': False})

        expected = dict(dev_db.NOTIFICATION_PREFERENCES_DEFAULTS)
        expected['milestone'] = False
        self.assertEqual(returned, expected)
        self.assertNotEqual(returned, stored, '返回全字段、落库只存设过的，两者刻意不同')

    def test_write_then_read_keeps_stored_keys_minimal(self):
        """写完立刻回读：stored_keys 只含用户真设过的那个 key。

        这条把写和读串起来 —— 单看任何一边都是绿的，退化只在接缝处显形。
        """
        ref = _FakeWritableRef(None)
        with mock.patch.object(dev_db, '_get_user_ref', return_value=ref), \
                mock.patch.object(dev_db, '_ensure_user_exists'):
            dev_db.set_notification_preferences('dev-1', 'user-1', {'milestone': False})
            prefs, stored_keys = dev_db.get_notification_preferences_detailed('dev-1', 'user-1')

        self.assertEqual(stored_keys, ['milestone'])
        self.assertTrue(
            prefs['quiet_hours_start_minutes'] == dev_db.NOTIFICATION_PREFERENCES_DEFAULTS[
                'quiet_hours_start_minutes'
            ],
            '没设过的静默起点必须仍是「跟随默认」，不能被这次写入钉住',
        )

    def test_write_ignores_unknown_incoming_keys(self):
        """传入的陌生字段不落库（Pydantic 之外的第二道闸）。"""
        _, stored = _set_prefs(None, {'milestone': False, 'not_a_pref': True})

        self.assertEqual(stored, {'milestone': False})

    def test_get_and_post_share_the_same_auth_dependency(self):
        """GET 与 POST 必须同款鉴权，否则回读会成为一个能读任意用户偏好的口子。

        比对的是 Depends 里那个 callable 本身，而不是函数名字符串 —— 改名/换实现都跟得上。
        """
        import inspect

        def dep_of(fn):
            sig = inspect.signature(fn)
            deps = [p.default.dependency for p in sig.parameters.values()
                    if hasattr(p.default, 'dependency')]
            self.assertEqual(len(deps), 1, f'{fn.__name__} 应恰好有一个鉴权依赖')
            return deps[0]

        self.assertIs(
            dep_of(notif_router.read_notification_preferences),
            dep_of(notif_router.save_notification_preferences),
        )


if __name__ == '__main__':
    unittest.main(verbosity=2)
