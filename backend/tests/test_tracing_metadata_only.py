"""生产 trace 只记元数据，且两个调用点都接上了。

存在的理由有两条，都不是「测一个函数」：

**① 「不记用户内容」是个不变式，不是一次实现。** 决定见 `evaluation/TRACING.md` §0：
生产只记工具名、入参的**键**、耗时、token 数、命中数，**不记提问原文、不记记忆内容**。
这条约束的破坏方式是**加字段**——将来谁给某个工具加一个参数、或者顺手想「把 query 截 80
字存下来好排查」，就漏了。所以这里喂进带哨兵串的入参和返回值，断言**没有任何 span 属性
值包含哨兵**。`_tool_attributes` 只读 `kwargs.keys()`（allowlist by construction），这个
测试是那句话的证据。

**② 两个调用点都必须接。** `execute_graph_chat`（离线 eval 用）和
`execute_graph_chat_stream`（生产 `/v2/messages` 用）是两条独立代码路径，只接一条会让
线上与离线的轨迹形状不同——那正好毁掉「同一个 seam」的意义，而且**不会有任何报错**。
用 AST 断言调用点存在，跟 `test_realtime_memory_extraction.py` 同一个理由：这类「两个
正确的东西没接起来」的缺陷测不到函数本身。
"""

import ast
import os
import re
import sys
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

# 哨兵串：分别扮演「用户提问原文」「记忆正文」「异常里带出来的入参」。
SENTINELS = (
    "MY-PRIVATE-QUESTION-ABOUT-DIVORCE",
    "MEMORY-BODY-USER-TAKES-SERTRALINE",
    "EXCEPTION-LEAKED-ARGUMENT-VALUE",
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
    raise AssertionError(f"{rel_path} 里找不到函数 {func_name}")


class _FakeSpan:
    def __init__(self, name):
        self.name = name
        self.attributes = {}
        self.status = None

    def set_attribute(self, key, value):
        self.attributes[key] = value

    def set_status(self, status):
        self.status = status

    def end(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class _FakeTracer:
    """tracer 替身。**故意**要求 record_exception=False / set_status_on_exception=False。

    这不是模仿 SDK，是把约束前移。真 SDK 这两个参数默认 True，而 `record_exception`
    会往 span 上挂一个带 `exception.message` 和 `exception.stacktrace` 的 event——
    实测里那条 message 就是用户提问原文（`ValueError(f"invalid query: {query}")`）。
    当前的 JSON exporter 不序列化 event，所以今天它到不了 CloudWatch；但那是
    **exporter** 的性质，而 tracing.py 明确写着「换 exporter 就行，别的都不用动」——
    换成 OTLP 后 event 是会发出去的。所以这里在替身上强制断言，让漏掉参数在没装
    SDK 的环境里也立刻失败。
    """

    def __init__(self):
        self.spans = []

    def _new(self, name):
        span = _FakeSpan(name)
        self.spans.append(span)
        return span

    def start_as_current_span(self, name, **kwargs):
        assert kwargs.get('record_exception') is False, (
            f"{name}: 必须传 record_exception=False，否则 SDK 会把异常信息"
            f"（常含用户提问原文）挂成 span event")
        assert kwargs.get('set_status_on_exception') is False, (
            f"{name}: 必须传 set_status_on_exception=False，状态由 _mark_error 显式设")
        return self._new(name)

    def start_span(self, name, **kwargs):
        # LLM span 手工 start/end，不经过 with，SDK 不会自动记异常。
        return self._new(name)


class _FakeTool:
    """langchain 工具对象的最小形状：name + func（`instrument_tools` 只用这两个）。"""

    def __init__(self, name, func):
        self.name = name
        self.func = func


class TestMetadataOnly(unittest.TestCase):
    def setUp(self):
        from utils.observability import tracing

        self.tracing = tracing
        self.tracer = _FakeTracer()
        self._saved = dict(tracing._state)
        tracing._state.update({"ready": True, "attempted": True, "tracer": self.tracer})

    def tearDown(self):
        self.tracing._state.clear()
        self.tracing._state.update(self._saved)

    def _all_attr_values(self):
        values = []
        for span in self.tracer.spans:
            for key, value in span.attributes.items():
                values.append(str(key))
                values.append(str(value))
        return values

    def assert_no_sentinels(self):
        blob = "\n".join(self._all_attr_values())
        for sentinel in SENTINELS:
            self.assertNotIn(
                sentinel, blob,
                f"span 属性里出现了 {sentinel}——生产 trace 只许记元数据（TRACING.md §0）")

    def test_tool_span_records_keys_not_values(self):
        def memory_search(query=None, limit=None):
            return [{"overview": SENTINELS[1]}, {"overview": "another"}]

        tools = self.tracing.instrument_tools([_FakeTool("memory_search", memory_search)])
        out = tools[0].func(query=SENTINELS[0], limit=5)

        self.assertEqual(len(out), 2)
        span = self.tracer.spans[0]
        self.assertEqual(span.name, "tool.memory_search")
        # 键要记下来——「模型到底设了哪些参数」正是这个字段回答的问题。
        self.assertEqual(span.attributes["memorion.tool.arg_keys"], "limit,query")
        # 命中数要记下来：「搜了但没搜到」和「压根没搜」是两回事，只有它能分开。
        self.assertEqual(span.attributes["memorion.tool.hit_count"], 2)
        self.assertTrue(span.attributes["memorion.tool.ok"])
        self.assert_no_sentinels()

    def test_positional_args_do_not_leak(self):
        """位置参数没有键可记，所以只能记个数——不能退化成把值 str() 下来。"""
        def people_lookup(name):
            return {"ok": False, "people": []}

        tools = self.tracing.instrument_tools([_FakeTool("people_lookup", people_lookup)])
        tools[0].func(SENTINELS[0])

        span = self.tracer.spans[0]
        self.assertEqual(span.attributes["memorion.tool.arg_keys"], "")
        self.assertEqual(span.attributes["memorion.tool.arg_count"], 1)
        # 「没查到人」和「工具报错」是两件事：调用成功(ok=True)，业务结果为空
        # (result_ok=False)。合成一个字段会把前者读成后者。
        self.assertTrue(span.attributes["memorion.tool.ok"])
        self.assertFalse(span.attributes["memorion.tool.result_ok"])
        self.assert_no_sentinels()

    def test_exception_records_type_only(self):
        """异常信息常常把入参原文带出来（"invalid query: <用户提问>"），只许记类型。"""
        class BadQuery(ValueError):
            pass

        def memory_search(query=None):
            raise BadQuery(f"invalid query: {SENTINELS[2]}")

        tools = self.tracing.instrument_tools([_FakeTool("memory_search", memory_search)])
        with self.assertRaises(BadQuery):
            tools[0].func(query=SENTINELS[0])

        span = self.tracer.spans[0]
        self.assertEqual(span.attributes["exception.type"], "BadQuery")
        self.assertFalse(span.attributes["memorion.tool.ok"])
        # 类型记了，message 不许记——它带着 SENTINELS[2]。
        self.assertNotIn("exception.message", span.attributes)
        self.assert_no_sentinels()

    def test_turn_span_exception_records_type_only(self):
        """turn span 同理：agent 抛出的异常常把提问原文带在 message 里。"""
        with self.assertRaises(RuntimeError):
            with self.tracing.turn_span("chat.turn", **{"enduser.id": "u1"}) as span:
                span.set_attribute("memorion.history_turns", 2)
                raise RuntimeError(f"agent failed on: {SENTINELS[0]}")

        span = self.tracer.spans[0]
        self.assertEqual(span.attributes["exception.type"], "RuntimeError")
        self.assertNotIn("exception.message", span.attributes)
        self.assert_no_sentinels()

    def test_llm_span_records_tokens_not_text(self):
        """prompt / completion 全文一律不进 span，token 数进。"""
        handler = self.tracing._LlmSpanCallback()
        handler.on_chat_model_start(
            {"kwargs": {"model": "anthropic/claude-sonnet-5"}},
            [[{"role": "user", "content": SENTINELS[0]}]],
            run_id="r1",
            invocation_params={"model": "anthropic/claude-sonnet-5"},
        )

        class _Msg:
            usage_metadata = {"input_tokens": 12000, "output_tokens": 300,
                              "input_token_details": {"cache_read": 11000}}

        class _Gen:
            message = _Msg()
            generation_info = {"finish_reason": "stop"}
            text = SENTINELS[1]

        class _Response:
            llm_output = {"token_usage": {"prompt_tokens": 12000, "completion_tokens": 300}}
            generations = [[_Gen()]]

        handler.on_llm_end(_Response(), run_id="r1")

        span = self.tracer.spans[0]
        self.assertEqual(span.name, "llm.anthropic/claude-sonnet-5")
        self.assertEqual(span.attributes["gen_ai.usage.input_tokens"], 12000)
        self.assertEqual(span.attributes["gen_ai.usage.output_tokens"], 300)
        # 缓存命中数：graph._to_lc_messages 打了两个 cache_control 断点，在此之前
        # 没有任何生产侧读数能说它们到底有没有命中。
        self.assertEqual(span.attributes["gen_ai.usage.cache_read_input_tokens"], 11000)
        self.assertEqual(span.attributes["gen_ai.response.finish_reasons"], "stop")
        self.assert_no_sentinels()

    def test_unwrappable_tool_fails_loudly(self):
        """包不上必须炸。工具表没被包 = trace 里一次工具调用都没有，
        而那读起来像「模型没调工具」——是会被当成结论的（golden_run.py:132 同一个坑）。"""
        class _NoFunc:
            name = "memory_search"
            func = None

        with self.assertRaises(RuntimeError):
            self.tracing.instrument_tools([_NoFunc()])


class TestDisabledIsNoOp(unittest.TestCase):
    """关掉时必须是彻底的 no-op：工具对象原样返回、callbacks 为空。

    这条不是洁癖：eval harness 自己会包一层 ToolTap，而 `instrument_tools` 若在关闭
    状态下仍然重写 `.func`，离线轨迹的形状就被生产代码改变了。
    """

    def setUp(self):
        from utils.observability import tracing

        self.tracing = tracing
        self._saved = dict(tracing._state)
        tracing._state.update({"ready": False, "attempted": True, "tracer": None})

    def tearDown(self):
        self.tracing._state.clear()
        self.tracing._state.update(self._saved)

    def test_tools_returned_untouched(self):
        def fn():
            return "x"

        tool = _FakeTool("memory_search", fn)
        out = self.tracing.instrument_tools([tool])
        self.assertIs(out[0], tool)
        self.assertIs(out[0].func, fn)

    def test_no_callbacks(self):
        self.assertEqual(self.tracing.llm_callbacks(), [])

    def test_turn_span_still_usable(self):
        with self.tracing.turn_span("chat.turn", **{"enduser.id": "u1"}) as span:
            span.set_attribute("memorion.citations", 3)  # 不该炸


class TestBothCallSitesWired(unittest.TestCase):
    """离线的同步路径和生产的流式路径都要接上，只接一条不会报错但会静默分叉。"""

    def test_sync_path(self):
        src = _function_source('utils/retrieval/graph.py', 'execute_graph_chat')
        self.assertIn('turn_span(', src)
        self.assertIn('config=_agent_config()', src)

    def test_stream_path(self):
        src = _function_source('utils/retrieval/graph.py', 'execute_graph_chat_stream')
        self.assertIn('turn_span(', src)
        self.assertIn('config=_agent_config()', src)

    def test_tools_instrumented_at_the_single_build_point(self):
        """两条路径共用 _build_agent，所以工具包装只需要一处——但那一处必须在。"""
        src = _function_source('utils/retrieval/graph.py', '_build_agent')
        self.assertIn('instrument_tools(make_agent_tools(', src)

    def test_startup_initialises_tracing(self):
        self.assertIn('init_tracing()', _read('main.py'))


class TestKwargsOnlyReadForKeys(unittest.TestCase):
    """`_tool_attributes` 在**结构上**只读 `kwargs.keys()`。

    上面的哨兵测试证明**当前**这几个字段是干净的；它证明不了「将来加一个字段时不会
    顺手把值存下来」——那才是这条约束的真实破坏方式。所以这里直接看 AST：函数体里
    不许出现 `kwargs[...]`、`kwargs.values()`、`kwargs.items()`。少了这一条，
    `str(v)[:200]`（eval harness 里正是这么写的，那份结果文件因此必须 gitignore）
    照抄进来时，所有哨兵测试仍然全绿——因为哨兵串只覆盖它们知道的那几个键。
    """

    FORBIDDEN_ATTRS = ('values', 'items', 'get', 'pop')

    def test_only_keys_is_read_off_kwargs(self):
        src = _read('utils/observability/tracing.py')
        tree = ast.parse(src)
        func = next(n for n in ast.walk(tree)
                    if isinstance(n, ast.FunctionDef) and n.name == '_tool_attributes')

        offending = []
        for node in ast.walk(func):
            # kwargs[...] —— 取值
            if isinstance(node, ast.Subscript) and _names_kwargs(node.value):
                offending.append(f"line {node.lineno}: kwargs[...]")
            # kwargs.values() / .items() / .get() / .pop() —— 也是取值
            if isinstance(node, ast.Attribute) and _names_kwargs(node.value):
                if node.attr in self.FORBIDDEN_ATTRS:
                    offending.append(f"line {node.lineno}: kwargs.{node.attr}")
                elif node.attr != 'keys':
                    offending.append(f"line {node.lineno}: kwargs.{node.attr}（只许 .keys()）")

        self.assertEqual(offending, [],
                         "_tool_attributes 读了 kwargs 的值——元数据-only 是靠"
                         "「只读 .keys()」在结构上保证的，别开取值的旁路；"
                         "真需要某个值，加 (tool, param) 白名单并在这里补测试")


class TestFinishReasonNotDoubled(unittest.TestCase):
    """流式下 `finish_reason` 是拼接出来的，得还原。

    实测值来自 2026-08-12 生产 span：`"tool_callstool_calls"`、`"stopstop"`。成因是
    langchain 聚合 streamed chunk 用 `merge_dicts`，同名 str 键相加而不是覆盖。
    症状**不是缺值而是有一个变形的值**，所以按值分组的查询会静默分裂成好几组。
    """

    CASES = [
        ('tool_callstool_calls', 'tool_calls'),
        ('stopstop', 'stop'),
        ('stopstopstop', 'stop'),
        ('stop', 'stop'),
        ('tool_calls', 'tool_calls'),
        ('length', 'length'),
        ('content_filter', 'content_filter'),
    ]

    def setUp(self):
        from utils.observability import tracing
        self.tracing = tracing

    def test_repeated_values_collapse(self):
        for raw, want in self.CASES:
            self.assertEqual(self.tracing._undouble(raw), want, f"{raw!r}")

    def test_enum_members_are_not_self_repetitions(self):
        """反过来钉一遍：还原逻辑不会误伤枚举里的任何一个合法取值。

        这条在于 `_undouble` 是通用的「整数次重复」检测——如果将来某个 provider 出现一个
        本身就是重复串的 finish_reason，这里会先红。
        """
        for member in ('stop', 'length', 'tool_calls', 'content_filter', 'function_call'):
            self.assertEqual(self.tracing._undouble(member), member)

    def test_call_site_uses_it(self):
        src = _read('utils/observability/tracing.py')
        self.assertRegex(src, r'finish_reasons"\]\s*=\s*_undouble\(',
                         '取消了还原就会重新写进一个不可聚合的值')


class TestChatRouterDoesNotLogQuestionText(unittest.TestCase):
    """`/v2/messages` 入口不许把提问原文写进日志。

    🚨 span 那一侧的元数据-only 口径，被入口上方一行 `print('send_message', data.text, uid)`
    整个绕过了——2026-08-12 在 `/ecs/memorion-api-rest` 里实测到整句中文提问。**只护住
    span 等于没护住**，两处是同一条约束，所以这条测试放在这个文件里而不是 chat 的测试里。

    ⚠️ 读源码而不是 import：`routers/developer_chat.py` 会连带拉起凭证与 Firestore client。
    """

    def test_no_print_of_message_text(self):
        src = _read('routers/developer_chat.py')
        offending = [f"line {i}: {ln.strip()}" for i, ln in enumerate(src.splitlines(), 1)
                     if re.match(r'\s*print\(', ln) and 'data.text' in ln]
        self.assertEqual(offending, [],
                         "把提问原文 print 出来了；只记 len(data.text) 与 uid")

    def test_logs_length_instead(self):
        src = _read('routers/developer_chat.py')
        self.assertRegex(src, r'logger\.info\(\s*"send_message uid=%s chars=%d',
                         '连长度都不记就没法回答「请求到了吗」——保留计数，去掉内容')


def _names_kwargs(node) -> bool:
    """`kwargs` 本身，或 `(kwargs or {})` 这种包装。"""
    if isinstance(node, ast.Name):
        return node.id == 'kwargs'
    if isinstance(node, ast.BoolOp):
        return any(_names_kwargs(v) for v in node.values)
    return False


if __name__ == '__main__':
    unittest.main(verbosity=2)
