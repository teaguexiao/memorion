"""提名退化时必须重试——2026-08-19 那次事故的另一半。

那天生产推出去的是一张 08-02 的空壳卡（`tech-discussion-frequency`，body 32 字、无
depth），而**排序本身是对的**：同一轮新提名的三条 depth 都有 400~445 字，按
`worth × freshness` 重放，新卡 68.0 分压得过老货折后的 54.3。真正失效的是
`pick_next` 跑的时候**池子里只有老货**——这一路 nominate 返回了 0 条可用提名。

所以修复是两处，缺一个都不够：
  - 这里：重试解决「池子为什么是空的」。
  - `valve.eligible` 的 depth 硬门槛：解决「池子空了会发出什么」（见
    tests/test_insight_sampling_and_freshness.py 的 `TestDepthIsRequiredToRelease`）。

⚠️ **退化是静默的，所以重试判据不能是「有没有抛异常」。** `with_structured_output`
返回的是一个合法的 `{"nominations": []}`——没有异常、没有 safety 拦截，全链路只有一行
warning。这跟 flash-lite 让事实抽取归零那次是同一个形态（合法的空 + finish_reason=STOP）。

⚠️ **重试上限是 2 而不是「多试几次总没错」。** 约束来自服务端 20 分钟 cap 与实测 466s
的单次提名（见 test_insights_run_timeout_and_eval_tenants.py）：越过 cap 时
`asyncio.wait_for` 只停 await，引擎照样跑完并自己写 `released_at` ⇒ 卡落库了、5 天疲劳
窗口烧掉了，只有推送丢了。那比「今天空手」严格更糟。
"""

import os
import sys
import types
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)


def _stub_llm_clients() -> None:
    """`utils.llm.clients` 在 import 期就建 LLM 客户端（要凭证）。

    被测的是重试的控制流，客户端由每个用例自己注入假的。
    """
    name = 'utils.llm.clients'
    if name not in sys.modules:
        module = types.ModuleType(name)
        module.llm_medium_insight = object()
        sys.modules[name] = module


def _drop_insight_engine_stub() -> None:
    """⚠️ 同目录的 test_insight_evidence_and_depth.py 会把 `utils.llm.insight_engine`
    整个换成空壳（它只需要 `utils.insights.engine` 能 import 成功）。

    那个文件按字母序排在本文件之前，于是全量跑时我们 import 到的是那个空壳——它的
    `__getattr__` 对任何属性都返回一个 `lambda: None`，所以 `nominate(...)` 恒为 None、
    七条断言全红，而**单独跑本文件时全绿**。这类"只在一起跑时红"的假信号很费时间，
    所以这里主动把空壳摘掉、让真模块加载。

    ⚠️ **判据必须直接查 `__dict__`，不能用 `hasattr` 也不能用 `getattr(..., None)`。**
    模块的 `__getattr__` 只在正常查找失败后才触发，而空壳的 `__dict__` 里没有
    `__file__` ⇒ 连 `__file__` 都会走到那个 catch-all lambda 上、返回一个函数对象。
    于是"getattr 是不是 None"这个判据恒为假，摘除静默失效、七条断言照旧全红。
    """
    stub = sys.modules.get('utils.llm.insight_engine')
    if stub is not None and '__file__' not in vars(stub):
        del sys.modules['utils.llm.insight_engine']


_stub_llm_clients()
_drop_insight_engine_stub()

from utils.llm import insight_engine as ie  # noqa: E402


class _FakeStructured:
    def __init__(self, outcome):
        self._outcome = outcome

    def invoke(self, _prompt):
        if isinstance(self._outcome, Exception):
            raise self._outcome
        return self._outcome


class _FakeLLM:
    """按脚本逐次返回不同结果，并记下真实调用次数。"""

    def __init__(self, outcomes):
        self._outcomes = list(outcomes)
        self.calls = 0

    def with_structured_output(self, _model):
        outcome = self._outcomes[min(self.calls, len(self._outcomes) - 1)]
        self.calls += 1
        return _FakeStructured(outcome)


class _Batch:
    def __init__(self, nominations):
        self.nominations = [_Nom(n) for n in nominations]


class _Nom:
    def __init__(self, data):
        self._data = data

    def model_dump(self):
        return dict(self._data)


def _good(topic='acknowledgment-before-probe', worth=68):
    return {'topic_key': topic, 'worth': worth, 'confidence': 75,
            'headline': 'h', 'body': 'b', 'depth': 'd' * 600}


class NominateRetryTest(unittest.TestCase):
    def setUp(self):
        self._orig_get_prompt = ie.get_prompt
        self._orig_resolve = ie.resolve_llm
        # render() 只要能吐出字符串就行，本测试不碰 prompt 内容
        ie.get_prompt = lambda key, fallback=None: types.SimpleNamespace(
            render=lambda **kw: 'prompt', is_fallback=True, version=0)

    def tearDown(self):
        ie.get_prompt = self._orig_get_prompt
        ie.resolve_llm = self._orig_resolve

    def _run(self, outcomes):
        llm = _FakeLLM(outcomes)
        ie.resolve_llm = lambda resolved, default: llm
        out = ie.nominate(fact_sheet={}, quotes=[], digest=[], known_topics={}, companion_days=1)
        return out, llm

    def test_empty_batch_is_retried(self):
        """核心形态：第一次合法地返回 0 条，第二次才出货。"""
        out, llm = self._run([_Batch([]), _Batch([_good()])])
        self.assertEqual(llm.calls, 2, '返回空批次时没有重试 —— 08-19 就是这么发出空壳卡的')
        self.assertEqual([n['topic_key'] for n in out], ['acknowledgment-before-probe'])

    def test_all_degenerate_counts_as_empty(self):
        """`worth=0` / `topic_key` 太短都进不了排期，一批全是这个等于什么都没提名。"""
        junk = _Batch([{'topic_key': 'ab', 'worth': 0}, {'topic_key': '', 'worth': 90}])
        out, llm = self._run([junk, _Batch([_good()])])
        self.assertEqual(llm.calls, 2)
        self.assertEqual(len(out), 1)

    def test_a_healthy_batch_is_not_retried(self):
        """能用就立刻返回：一次提名要几百秒、约 $0.40，不许为了"更多选择"再烧一轮。"""
        out, llm = self._run([_Batch([_good()])])
        self.assertEqual(llm.calls, 1)
        self.assertEqual(len(out), 1)

    def test_degenerate_items_are_kept_not_filtered(self):
        """判据只决定"要不要重试"，不许拿它当过滤器。

        模型偶尔会给一条真提名打 worth 0（prompt 就要求「他早就知道的事」压低分）。
        滤掉它，账本里就没有这条记录，下一轮会把同一件事重新提名一遍——而提名才是
        整条链路最贵的一步。
        """
        mixed = _Batch([_good(), {'topic_key': 'known-already', 'worth': 0, 'headline': 'h'}])
        out, llm = self._run([mixed])
        self.assertEqual(llm.calls, 1)
        self.assertEqual(len(out), 2, 'worth=0 的那条被滤掉了 —— 它该进账本防重复提名')

    def test_exception_is_retried_too(self):
        out, llm = self._run([RuntimeError('502 upstream'), _Batch([_good()])])
        self.assertEqual(llm.calls, 2)
        self.assertEqual(len(out), 1)

    def test_gives_up_at_the_cap_instead_of_looping(self):
        """一直退化时必须收手，别把 20 分钟的 cap 撞穿（撞穿会丢推送 + 烧掉疲劳窗口）。"""
        out, llm = self._run([_Batch([])])
        self.assertEqual(out, [])
        self.assertEqual(llm.calls, ie._NOMINATE_ATTEMPTS)
        self.assertLessEqual(
            ie._NOMINATE_ATTEMPTS, 2,
            '实测单次提名 466s、服务端 cap 20 分钟 —— 3 次就会越过 cap',
        )

    def test_client_construction_failure_returns_empty_not_raises(self):
        """契约是"失败返回空列表"：这里漏一个异常会把整轮 run 掀掉。"""
        def _boom(resolved, default):
            raise RuntimeError('no credentials')

        ie.resolve_llm = _boom
        self.assertEqual(
            ie.nominate(fact_sheet={}, quotes=[], digest=[], known_topics={}, companion_days=1),
            [],
        )


if __name__ == '__main__':
    unittest.main(verbosity=2)
