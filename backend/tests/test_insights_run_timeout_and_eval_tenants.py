"""洞察 cron 的两条不变式：外层预算不能小于内层，评测租户不许进用户名单。

存在的理由（2026-08-18 查 OpenRouter 账单查出来的两件事）：

**一、`/v1/insights/run` 的 cap 曾小于它自己的内部预算。**
提名的 prompt 带 60 天的全量原话与对话摘要（实测最活跃用户 114k 字符 ≈ 57k tokens），
2026-08-14 深读段扩成三段 400-600 字之后一轮要 200s 以上；而 POST 不在
`methods_timeout` 里，走 `HTTP_DEFAULT_TIMEOUT` 的 120s ⇒ 数据最多的 4 个用户 + 1 个评测
租户**每天准时**被砍成 504（8/14 起连续 5 天，`response_time_ms` 精确落在 120001~120059）。

失败形态是这条不变式值得钉住的原因：`asyncio.wait_for` 只停止 await，`asyncio.to_thread`
里的引擎照样跑完、`released_at` 由引擎自己写进 Firestore ⇒ **卡片照样出现、钱照样花**，
只有 HTTP 那层是 504。真正丢的是推送——`_send_insight_push` 排在那个被取消的 `await`
之后，而卡已经吃掉了 5 天疲劳窗口、下一轮 `released_topics` 还会拦掉它。所以两头都要钉：
服务端 cap 要大过内部预算，**客户端 timeout 也要不小于服务端 cap**（客户端早退一样丢推送）。

**二、评测语料租户跟真实用户一样每天被扫。**
`evaluation/chat-agent/golden_corpus.py` 的 `provision` 把 `time_zone` 写进租户文档，而两个
cron 的用户发现只按 `time_zone` 过滤 ⇒ `lme-golden-en-001` 每天各跑一整轮完整 LLM（它就在
那 5 个跑满 120s 的会话里）。判据在两个独立的 Modal runtime 里各有一份拷贝，必须一致。

用 AST 读源码 + exec 纯函数，不 import：`modal/*.py` 在模块级就执行 `App(...)` 与
`Secret.from_name(...)`，import 断言会退化成「本地有没有 Modal 凭证」而不是回归信号。
"""

import ast
import os
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 生产实测的一轮耗时。cap 必须明显大过它，而不是刚好压线：prompt 随用户对话数线性
# 增长，压线等于把「以后会变慢」写成定时炸弹。
#
# ⚠️ **这个数字曾经是推断出来的，而推断值差了一倍多。** 第一版按「504 时刻与卡片落库
# 时刻之差」估成 200s；cap 放开之后实测是 **468s**。CloudWatch 显示这 466s 几乎全在**单次 nominate**
# 上，而那一轮的 `judge` 一次都没跑（唯一那条提名被账本去重拦掉）——也就是说提名条数
# 一多只会更慢。要更新这个值，用 api_logs_daily 里真实的 `response_time_ms`，别再推断。
OBSERVED_RUN_SECONDS = 468

CRON_FILES = (
    'modal/memorion_insight_engine.py',
    'modal/memorion_daily_summary.py',
)


def _read(rel_path: str) -> str:
    with open(os.path.join(BACKEND_DIR, rel_path), encoding='utf-8') as f:
        return f.read()


def _function_source(rel_path: str, func_name: str) -> str:
    src = _read(rel_path)
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == func_name:
            return ast.get_source_segment(src, node)
    raise AssertionError(f'{rel_path} 里找不到函数 {func_name}')


def _call_linenos(rel_path: str, func_name: str) -> dict:
    """`func_name` 体内每个被调用者（按属性名/函数名）出现的行号。

    ⚠️ **必须走 AST，不能用 `src.find('xxx')`。** 这个仓库反复踩过：注释里提到某个函数名，
    字符串扫描就把注释的位置当成代码位置。本文件第一版就是这么红的 —— 疲劳窗口闸门的
    注释里写着「必须排在 `collect_user_quotes` 之前」，于是 `find` 找到注释、断言反过来了。
    """
    src = _read(rel_path)
    tree = ast.parse(src)
    out = {}
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) or node.name != func_name:
            continue
        for sub in ast.walk(node):
            if not isinstance(sub, ast.Call):
                continue
            fn = sub.func
            name = fn.attr if isinstance(fn, ast.Attribute) else getattr(fn, 'id', None)
            if name:
                out.setdefault(name, []).append(sub.lineno)
        return out
    raise AssertionError(f'{rel_path} 里找不到函数 {func_name}')


def _literal_dict_assign(rel_path: str, name: str) -> dict:
    """取出模块级 `name = {...}` 的字面量，值形如 os.environ.get('X', default) 时取 default。

    取默认值那一支是对的：生产上并没有设这些环境变量（`.env.template` 和两个 task
    definition 里都没有），所以默认值就是生效值。
    """
    src = _read(rel_path)
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        if name not in [t.id for t in node.targets if isinstance(t, ast.Name)]:
            continue
        assert isinstance(node.value, ast.Dict), f"{name} 应当是字面量 dict"
        result = {}
        for key, value in zip(node.value.keys, node.value.values):
            assert isinstance(key, ast.Constant), "路径必须是字面量字符串"
            default = value.args[-1] if isinstance(value, ast.Call) and value.args else value
            result[key.value] = float(eval(compile(ast.Expression(default), '<ast>', 'eval')))
        return result
    raise AssertionError(f"{rel_path} 里找不到 {name} 赋值")


def _int_kwarg_of_call(rel_path: str, func_name: str, callee_attr: str, kwarg: str) -> list:
    """收集 `func_name` 里对 `*.callee_attr(...)` 的调用所传的 `kwarg` 数值。"""
    src = _read(rel_path)
    tree = ast.parse(src)
    found = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) or node.name != func_name:
            continue
        for sub in ast.walk(node):
            if not isinstance(sub, ast.Call):
                continue
            fn = sub.func
            if not (isinstance(fn, ast.Attribute) and fn.attr == callee_attr):
                continue
            for kw in sub.keywords:
                if kw.arg == kwarg:
                    found.append(float(eval(compile(ast.Expression(kw.value), '<ast>', 'eval'))))
    return found


def _load_eval_tenant_judge(rel_path: str):
    """把 `EVAL_TENANT_UID_PREFIXES` 和 `is_eval_tenant` 从源码里取出来跑真身。

    exec 真实函数体而不是在测试里重写一遍 startswith —— 后者会退化成同义反复，
    把判据换成别的语义（比如 `in` 或正则）时照样全绿。
    """
    src = _read(rel_path)
    tree = ast.parse(src)
    pieces = []
    prefixes = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and 'EVAL_TENANT_UID_PREFIXES' in [
            t.id for t in node.targets if isinstance(t, ast.Name)
        ]:
            prefixes = ast.literal_eval(node.value)
            pieces.append(ast.get_source_segment(src, node))
        elif isinstance(node, ast.FunctionDef) and node.name == 'is_eval_tenant':
            pieces.append(ast.get_source_segment(src, node))
    assert prefixes is not None, f"{rel_path} 里找不到 EVAL_TENANT_UID_PREFIXES"
    assert len(pieces) == 2, f"{rel_path} 里 EVAL_TENANT_UID_PREFIXES / is_eval_tenant 缺一个"
    ns = {}
    exec('\n'.join(pieces), ns)
    return prefixes, ns['is_eval_tenant']


class TestInsightsRunTimeoutBudget(unittest.TestCase):
    def test_insights_run_has_its_own_cap(self):
        paths = _literal_dict_assign('main.py', 'paths_timeout')
        self.assertIn(
            '/v1/insights/run', paths,
            'insights/run 必须有自己的 cap —— POST 不在 methods_timeout 里，'
            '默认 120s 低于它一轮的实测耗时',
        )

    def test_cap_exceeds_observed_run_duration(self):
        cap = _literal_dict_assign('main.py', 'paths_timeout')['/v1/insights/run']
        self.assertGreater(
            cap, OBSERVED_RUN_SECONDS * 2,
            f'cap={cap}s 对实测的 {OBSERVED_RUN_SECONDS}s 一轮没有留出余量 —— '
            'prompt 随用户对话数线性增长，压线就是等着它再次结构性失败',
        )

    def test_cap_is_actually_an_override_not_the_default(self):
        """cap 等于默认值时这条 entry 没有任何作用，而它看起来是「已经修了」。"""
        cap = _literal_dict_assign('main.py', 'paths_timeout')['/v1/insights/run']
        src = _read('utils/other/timeout.py')
        tree = ast.parse(src)
        defaults = []
        for node in ast.walk(tree):
            # self._get_timeout_from_env("HTTP_DEFAULT_TIMEOUT", default=2 * 60)
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)):
                continue
            if node.func.attr != '_get_timeout_from_env':
                continue
            named = {kw.arg: kw.value for kw in node.keywords}
            # 默认值可以是 `default=` 关键字，也可以是最后一个位置参数
            expr = named.get('default') or (node.args[-1] if len(node.args) > 1 else None)
            if expr is None:
                continue
            defaults.append(float(eval(compile(ast.Expression(expr), '<ast>', 'eval'))))
        self.assertTrue(defaults, 'timeout.py 里读不到 HTTP_DEFAULT_TIMEOUT 的默认值')
        self.assertGreater(cap, max(defaults))

    def test_cron_client_timeout_is_not_below_server_cap(self):
        """客户端早退和服务端早退是同一个损失：那一轮的推送在 handler 末尾，发不出去。

        只剩手动触发还在同步等引擎；cron 改成排队了（见下一条）。
        """
        cap = _literal_dict_assign('main.py', 'paths_timeout')['/v1/insights/run']
        for func in ('manual_insight_for_user',):
            timeouts = _int_kwarg_of_call(
                'modal/memorion_insight_engine.py', func, 'post', 'timeout'
            )
            self.assertTrue(timeouts, f'{func} 里找不到 requests.post 的 timeout')
            for t in timeouts:
                self.assertGreaterEqual(
                    t, cap,
                    f'{func} 的 timeout={t}s 小于服务端 cap={cap}s —— '
                    '我们会先放弃，而推送要到 handler 末尾才发',
                )

    def test_cron_queues_the_run_instead_of_waiting_for_it(self):
        """2026-10-28 起 cron 带 `defer`：引擎和推送都在 journal worker 里，这个请求只管排队。

        等引擎的同步请求过了约 6 分钟就收不到响应（服务端照样跑完），cron 于是把跑完的那轮
        记成超时；而赶上部署被打断的那一轮，卡可能已释放、推送却没发。
        """
        from unittest import mock
        source = _function_source('modal/memorion_insight_engine.py', 'call_insight_run_api')
        requests = mock.Mock()
        requests.Timeout = TimeoutError
        requests.post.return_value.status_code = 202
        requests.post.return_value.json.return_value = {'status': 'queued', 'job_id': 'c3f1a2b4-0000', 'job_status': 'queued'}
        namespace = {'os': os, 'requests': requests, 'WINDOW_DAYS': 60}
        exec(source, namespace)
        self.assertEqual('queued', namespace['call_insight_run_api']('u', 'key')['status'])
        call = requests.post.call_args.kwargs
        self.assertEqual({'window_days': 60, 'dry_run': False, 'send_push': True, 'defer': True}, call['json'])
        self.assertLessEqual(call['timeout'], 120)

    @staticmethod
    def _modal_function_timeout(rel_path: str, func_name: str) -> float:
        src = _read(rel_path)
        tree = ast.parse(src)
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            if node.name != func_name:
                continue
            for dec in node.decorator_list:
                if not isinstance(dec, ast.Call):
                    continue
                for kw in dec.keywords:
                    if kw.arg == 'timeout':
                        return float(eval(compile(ast.Expression(kw.value), '<ast>', 'eval')))
        raise AssertionError(f'{rel_path}: {func_name} 上找不到 @app.function 的 timeout')

    def test_modal_function_timeout_exceeds_its_own_http_timeout(self):
        """Modal 先杀掉函数，效果跟客户端早退一样：那一轮的推送发不出去。"""
        rel = 'modal/memorion_insight_engine.py'
        http = max(_int_kwarg_of_call(rel, 'manual_insight_for_user', 'post', 'timeout'))
        self.assertGreater(self._modal_function_timeout(rel, 'manual_insight_for_user'), http)

    def test_cron_function_timeout_fits_more_than_one_concurrent_batch(self):
        """第三层预算：一小时的用户按并发分批，每批最多一个 http timeout。

        只留一批的余量等于「再多几个重度用户就被拦腰砍掉」，而那是无声的。
        """
        rel = 'modal/memorion_insight_engine.py'
        http = max(_int_kwarg_of_call(rel, 'call_insight_run_api', 'post', 'timeout'))
        cron = self._modal_function_timeout(rel, 'insight_engine_cronjob')
        # 严格大于而不是 >=：当前最坏是 2 批（4 个重度用户 / 并发 3），恰好等于 N 批
        # 就是没有余量，而这条断言存在的理由正是「压线等于等着它再次失败」。
        self.assertGreater(
            cron, http * 3,
            f'cron function timeout={cron}s 装不下 3 批以上的 {http}s —— '
            '重度用户一多就会被 Modal 砍掉，而被砍的那批推送同样发不出去',
        )


class TestFatigueGateRunsBeforeAnythingExpensive(unittest.TestCase):
    """疲劳窗口内今天发不了卡，那就不该先花几分钟提名。

    这条不变式的代价是实打实的：窗口 5 天 ⇒ 5 天里有 4 天的提名注定不会释放，而每轮
    实测 466 秒 + 一整轮 LLM。2026-08-18 那次 dry run 就是活证据（跑满 466s，返回
    `skipped_reason=fatigue_window`）。判断只依赖 `ledger`，而 `ledger` 早在提名之前
    就取好了，所以前移不需要多读任何数据。
    """

    ENGINE = 'utils/insights/engine.py'

    def setUp(self):
        self.calls = _call_linenos(self.ENGINE, 'run_insight_engine')

    def _first(self, name: str) -> int:
        lines = self.calls.get(name)
        self.assertTrue(lines, f'run_insight_engine 里找不到对 {name} 的调用，这个测试的假设过期了')
        return min(lines)

    def test_fatigue_gate_precedes_nomination_and_prompt_building(self):
        gate = self._first('in_fatigue_window')
        for expensive in (
            'collect_user_quotes',            # 遍历全窗口对话，实测拼出 66k 字符
            'collect_conversation_digest',    # 同上，40k 字符
            'nominate',                       # 实测 466 秒 + ~$0.6
        ):
            self.assertLess(
                gate, self._first(expensive),
                f'疲劳窗口闸门排在 {expensive} 之后 —— 窗口内那 4/5 的天数又会白跑一轮',
            )

    def test_gate_reads_the_ledger_fetched_before_it(self):
        """闸门要复用已有的 ledger，而不是自己再查一次 —— 否则省了 LLM 又添一次 Firestore。"""
        self.assertLess(
            self._first('list_insights'), self._first('in_fatigue_window'),
            'ledger 必须在闸门之前就取好',
        )
        self.assertIn(
            'in_fatigue_window(ledger',
            _function_source(self.ENGINE, 'run_insight_engine'),
            '闸门应当直接吃已有的 ledger，而不是自己再查一次',
        )


class TestEvalTenantsExcludedFromCrons(unittest.TestCase):
    # 真实 Firebase uid 的**形态**：28 位纯字母数字。2026-08-18 核过全部 155 个租户，
    # 判为真实的 84 个里没有一个带 `-` 或 `_`，所以带连字符的前缀零误伤。
    #
    # ⚠️ **这些值是照着那个形态构造的，不是线上真实 uid** —— 这里要断言的是「判据不会
    # 误伤 28 位 alnum」，用真 uid 反而是没必要地把它们钉进仓库。2026-08-19 我自己被这
    # 组样本绊过一次：拿其中一个去打生产 `insights/run`，回的是
    # `insufficient_data(days=0,convos=0)` —— 那个报错的真实含义是**这个 uid 不存在**，
    # 看起来却像「这个用户没数据」。要真实 uid 请去 Firestore 现查。
    REAL_UID_SAMPLES = (
        'aaaa1111bbbb2222cccc3333dddd',
        'Zz9Yy8Xx7Ww6Vv5Uu4Tt3Ss2Rr1Q',
        'SampleUser03OnlyForTests123',
        'SampleUser04OnlyForTests456',
    )
    # 库里还有 UUID 形态的历史 uid —— 那些可能是真实用户，判据不许把它们扫进来。
    LEGACY_UUID_SAMPLES = (
        '00000000-0000-4000-8000-000000000001',
        '00000000-0000-4000-8000-000000000002',
    )
    EVAL_UIDS = ('lme-golden-en-001', 'golden-zh-001')

    def test_judge_catches_known_eval_tenants(self):
        for rel in CRON_FILES:
            _, is_eval = _load_eval_tenant_judge(rel)
            for uid in self.EVAL_UIDS:
                self.assertTrue(is_eval(uid), f'{rel}: {uid} 应当被判为评测租户')

    def test_judge_does_not_touch_real_or_legacy_uids(self):
        for rel in CRON_FILES:
            _, is_eval = _load_eval_tenant_judge(rel)
            for uid in self.REAL_UID_SAMPLES + self.LEGACY_UUID_SAMPLES:
                self.assertFalse(is_eval(uid), f'{rel}: {uid} 被误判成评测租户')
            self.assertFalse(is_eval(''), f'{rel}: 空 uid 不该命中')
            self.assertFalse(is_eval(None), f'{rel}: None 不该抛错也不该命中')

    def test_both_crons_use_the_same_judge(self):
        """两个 cron 是各自独立的 Modal runtime，没法共享 import —— 只能靠这条钉住。"""
        seen = {rel: _load_eval_tenant_judge(rel)[0] for rel in CRON_FILES}
        values = list(seen.values())
        self.assertEqual(
            tuple(values[0]), tuple(values[1]),
            f'两个 cron 的评测租户判据不一致: {seen}',
        )

    def test_user_discovery_actually_applies_the_judge(self):
        """判据存在但没人调用，是这个仓库反复踩的「两个各自正确的函数没接起来」。"""
        for rel in CRON_FILES:
            src = _read(rel)
            tree = ast.parse(src)
            callers = set()
            for node in ast.walk(tree):
                if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    continue
                for sub in ast.walk(node):
                    if (
                        isinstance(sub, ast.Call)
                        and isinstance(sub.func, ast.Name)
                        and sub.func.id == 'is_eval_tenant'
                    ):
                        callers.add(node.name)
            self.assertIn(
                'get_users_in_timezones', callers,
                f'{rel}: 用户发现里没有调 is_eval_tenant —— 判据白写了',
            )


if __name__ == '__main__':
    unittest.main()
