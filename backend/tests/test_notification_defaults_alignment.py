"""通知偏好的两条默认值不变式：跨语言对齐 + 默认静默区间不许盖住任何推送。

存在的理由（2026-08-12）：

**一、两边默认值必须一致，但没人能同时改到。** 服务端闸门（`utils/notification_gate.py`）
读的是 Firestore 里同步上来的偏好，而**存量用户绝大多数没有这条记录** —— 156 个用户里
只有 2 个写过 `notification_preferences`。没记录时服务端落
`NOTIFICATION_PREFERENCES_DEFAULTS`，App 落 `SharedPreferencesUtil` 的 `?? x`。两份默认值
一分叉，症状是**设置页显示「关」而服务端在推**（或反过来），而且只影响没动过开关的用户 ——
开发者自己的账号往往早就写过记录，本地怎么点都复现不出来。原先这条约束只是
`developer_data.py:226` 的一句注释。

**二、默认静默起点不能压在某条推送的整点上。** `_in_quiet_hours` 的跨午夜分支是
`now_minutes >= start`（**闭区间**），而每日一刻恰好在用户本地 22:00 **整点**推。
默认起点曾是 22:00 → `1320 >= 1320` → 谁第一个打开静默时段开关，他的每日一刻就永久
收不到，且日志只有一行 `blocked by quiet hours`，看起来完全正常。当时线上 0 人开启这个
开关，所以这个雷埋了没炸。2026-08-12 把默认起点挪到 23:00。

⚠️ 这里刻意从 Modal cron 文件里**抽出**推送时间来喂判定，而不是把 22:00 写死在测试里。
挪推送时间的人不会想到来改这个测试；让测试自己去读那个数字，改推送时间才会真的触发它。

用正则读 Dart 源码而不是解析：只需要 `?? <默认值>` 这一个形态，正则足够，且不引入
额外依赖。扫描器自身有自检（见 `test_scanner_actually_found_things`）—— 抽到 0 个默认值
时全部断言都会真空通过，那是本仓库反复踩过的假绿灯。
"""

import os
import re
import sys
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.dirname(BACKEND_DIR)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

PREFERENCES_DART = os.path.join(REPO_DIR, 'app', 'lib', 'backend', 'preferences.dart')
NOTIFICATION_PREFS_DART = os.path.join(REPO_DIR, 'app', 'lib', 'utils', 'notification_prefs.dart')

# 后端 snake_case ↔ App camelCase 的字段映射。这份表就是 App
# `NotificationPrefs.syncToServer()` 实际上传的字段面。
PREF_KEY_TO_DART_GETTER = {
    'daily_moment': 'notifDailyMoment',
    'task_reminder': 'notifTaskReminder',
    'pause_reminder': 'notifPauseReminder',
    'milestone': 'notifMilestone',
    'quiet_hours_enabled': 'quietHoursEnabled',
    'quiet_hours_start_minutes': 'quietHoursStartMinutes',
    'quiet_hours_end_minutes': 'quietHoursEndMinutes',
}


def _read(rel_path_from_repo: str) -> str:
    with open(os.path.join(REPO_DIR, rel_path_from_repo), 'r', encoding='utf-8') as f:
        return f.read()


def _dart_defaults() -> dict:
    """从 preferences.dart 抽 `get <name> => getX('...') ?? <默认值>;` 的默认值。

    支持 `true` / `false` / `22 * 60` / `480` 四种右值形态。抽不到的 getter 直接
    不进结果，由 test_scanner_actually_found_things 兜住。
    """
    src = _read(os.path.relpath(PREFERENCES_DART, REPO_DIR))
    found = {}
    for pref_key, getter in PREF_KEY_TO_DART_GETTER.items():
        # get notifMilestone => getBool('notifMilestone') ?? true;
        m = re.search(
            r'get\s+' + re.escape(getter) + r'\s*=>\s*get\w+\([^)]*\)\s*\?\?\s*([^;]+);',
            src,
        )
        if not m:
            continue
        raw = m.group(1).strip()
        if raw == 'true':
            found[pref_key] = True
        elif raw == 'false':
            found[pref_key] = False
        else:
            # 数值：允许 `23 * 60` 这类算式，但只允许数字和 * 号，不 eval 任意代码
            expr = raw.split('//')[0].strip()
            if re.fullmatch(r'[\d\s*]+', expr):
                found[pref_key] = eval(expr)  # noqa: S307 — 形态已被上面的正则限死
    return found


def _dart_sync_keys() -> set:
    """从 notification_prefs.dart 抽 App 上报/回读认得的服务端字段名。

    即 `_serverBoolKeys` ∪ `_serverMinuteKeys`（`allServerKeys` 就是这两个的并集）。
    在 Dart 侧断言「上行认得的 == 下行认得的」是同义反复（两边用的是同一对集合），
    真判据只能跨语言比 —— 所以放在这里。
    """
    src = _read(os.path.relpath(NOTIFICATION_PREFS_DART, REPO_DIR))
    keys = set()
    for name in ('_serverBoolKeys', '_serverMinuteKeys'):
        m = re.search(
            r'Set<String>\s+' + re.escape(name) + r'\s*=\s*\{(.*?)\}',
            src,
            re.DOTALL,
        )
        if m:
            keys |= set(re.findall(r"'([a-z_]+)'", m.group(1)))
    return keys


def _server_push_local_hours() -> dict:
    """服务端推送各自在用户本地的触发整点，从 Modal cron 源码里抽出来。

    返回 {推送名: (小时, 分钟)}。抽不到的不进结果，由扫描器自检兜住。
    """
    hours = {}

    # memorion_daily_summary.py:  target_time = "22:00"
    m = re.search(
        r'target_time\s*=\s*[\'"](\d{1,2}):(\d{2})[\'"]',
        _read('backend/modal/memorion_daily_summary.py'),
    )
    if m:
        hours['daily_moment'] = (int(m.group(1)), int(m.group(2)))

    # memorion_insight_engine.py:  TARGET_LOCAL_HOUR = 10
    m = re.search(
        r'^TARGET_LOCAL_HOUR\s*=\s*(\d{1,2})',
        _read('backend/modal/memorion_insight_engine.py'),
        re.MULTILINE,
    )
    if m:
        hours['milestone'] = (int(m.group(1)), 0)

    return hours


class NotificationDefaultsAlignmentTest(unittest.TestCase):
    def setUp(self):
        # import 放在测试里：developer_data 会拉起 Firestore client，import 期失败时
        # 应该报成这一个测试的错，而不是整个模块收集失败。
        import database.developer_data as dev_db

        self.server_defaults = dev_db.NOTIFICATION_PREFERENCES_DEFAULTS
        self.dart_defaults = _dart_defaults()
        self.dart_sync_keys = _dart_sync_keys()
        self.push_hours = _server_push_local_hours()

    def test_scanner_actually_found_things(self):
        """先证明扫描器没扫到空。

        正则一旦跟不上源码写法（比如 getter 改成多行、或加了 `??=`），抽到 0 个默认值，
        下面所有对齐断言都会真空通过 —— 那正是这份测试想防的那类假绿灯。
        """
        self.assertEqual(
            set(self.dart_defaults),
            set(PREF_KEY_TO_DART_GETTER),
            '没能从 preferences.dart 抽全默认值——正则跟不上源码写法了，先修这里，'
            '别删断言。缺的字段：'
            f'{sorted(set(PREF_KEY_TO_DART_GETTER) - set(self.dart_defaults))}',
        )
        self.assertEqual(
            set(self.push_hours),
            {'daily_moment', 'milestone'},
            '没能从 Modal cron 源码抽出推送时间，静默区间那条断言会变成空跑。'
            f'抽到的是：{self.push_hours}',
        )
        self.assertTrue(
            self.dart_sync_keys,
            '没能从 notification_prefs.dart 抽出 _serverBoolKeys/_serverMinuteKeys，'
            'test_sync_field_names_match 会真空通过。',
        )

    def test_sync_field_names_match(self):
        """App 上报/回读认得的字段名 == 服务端偏好字段名。

        这条只能跨语言比。在 Dart 侧断言「上行认得的 == 下行认得的」是同义反复 ——
        `allServerKeys` 就是那两个集合的并集、回读也用它们判定，往里塞个假 key 照样绿
        （变异验证实测如此）。

        对不齐的症状是**单向同步**：App 发得出但服务端不认（字段被 Pydantic 静默丢弃，
        开关看着能存、服务端永远按默认走），或服务端有但 App 不认（那个开关换台机器就丢）。
        两种都不报错。同款静默丢弃在 `stt_service` 上真发生过，用户在设置里选的转录引擎
        因此一直没生效。
        """
        self.assertEqual(
            self.dart_sync_keys,
            set(self.server_defaults),
            'App 与服务端的通知偏好字段名对不上。'
            f'App 多出来的：{sorted(self.dart_sync_keys - set(self.server_defaults))}；'
            f'服务端多出来的：{sorted(set(self.server_defaults) - self.dart_sync_keys)}',
        )

    def test_server_and_app_defaults_match(self):
        """服务端 NOTIFICATION_PREFERENCES_DEFAULTS == App SharedPreferencesUtil 默认值。

        分叉的症状是「设置页显示关、服务端在推」，只影响从没动过开关的用户，
        开发者账号复现不出来。
        """
        self.assertEqual(
            set(self.server_defaults),
            set(PREF_KEY_TO_DART_GETTER),
            '后端加了新的偏好字段，但这份测试的映射表没跟上——'
            '同时也说明 App 端很可能也没跟上。',
        )
        for key in sorted(self.server_defaults):
            self.assertEqual(
                self.dart_defaults[key],
                self.server_defaults[key],
                f'{key} 两边默认值不一致：'
                f'App({PREF_KEY_TO_DART_GETTER[key]})={self.dart_defaults[key]} '
                f'vs 后端={self.server_defaults[key]}',
            )

    def test_default_quiet_hours_do_not_swallow_any_server_push(self):
        """默认静默区间不许盖住任何服务端推送的触发时刻。

        `_in_quiet_hours` 的起点是闭区间，所以「推送整点 == 静默起点」会被拦死。
        推送时间是从 Modal cron 源码里读的：把每日一刻挪回 23:00、或把静默默认起点
        挪回 22:00，这条都会红。
        """
        from utils.notification_gate import _in_quiet_hours

        prefs = dict(self.server_defaults)
        for kind, (hour, minute) in sorted(self.push_hours.items()):
            self.assertFalse(
                _in_quiet_hours(prefs, hour * 60 + minute),
                f'{kind} 在用户本地 {hour:02d}:{minute:02d} 推送，却落在默认静默区间 '
                f'{self.server_defaults["quiet_hours_start_minutes"] // 60:02d}:00–'
                f'{self.server_defaults["quiet_hours_end_minutes"] // 60:02d}:00 内。'
                '任何打开静默时段开关的用户都会永久收不到它，而日志只有一行 '
                '`blocked by quiet hours`，看起来完全正常。',
            )

    def test_quiet_hours_start_is_still_inclusive(self):
        """把上一条依赖的前提本身钉住：起点是闭区间。

        如果哪天有人把判定改成 `now > start`（左开），上面那条就失去意义了 ——
        那时该做的是删掉这条 + 重新想清楚边界语义，而不是让它静静地失效。
        """
        from utils.notification_gate import _in_quiet_hours

        prefs = {'quiet_hours_start_minutes': 23 * 60, 'quiet_hours_end_minutes': 8 * 60}
        self.assertTrue(_in_quiet_hours(prefs, 23 * 60), '静默起点整点应当算在静默内')
        self.assertFalse(_in_quiet_hours(prefs, 23 * 60 - 1), '起点前一分钟不该被拦')
        self.assertFalse(_in_quiet_hours(prefs, 8 * 60), '结束整点不该被拦（右开）')
        self.assertTrue(_in_quiet_hours(prefs, 8 * 60 - 1), '结束前一分钟应当还在静默内')

    def test_gate_reads_defaults_instead_of_hardcoding_them(self):
        """`_in_quiet_hours` 的 fallback 必须引用 defaults，不许再写一份数字。

        这是第三处默认值。它平时不生效（`get_notification_preferences` 总会把 key 补全），
        所以写错了也不会被任何调用路径发现 —— 只在有人直接调 `_in_quiet_hours` 时才咬人。
        """
        src = _read('backend/utils/notification_gate.py')
        self.assertIn('NOTIFICATION_PREFERENCES_DEFAULTS', src)
        self.assertNotRegex(
            src,
            r'quiet_hours_(start|end)_minutes[\'"]\s*,\s*\d',
            '别在 notification_gate.py 里给静默时段另写一份默认数字，'
            '引用 dev_db.NOTIFICATION_PREFERENCES_DEFAULTS。',
        )


if __name__ == '__main__':
    unittest.main(verbosity=2)
