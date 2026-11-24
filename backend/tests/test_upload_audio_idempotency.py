"""同一段录音上传两次，不许变成两条对话。

存在的理由（2026-08-15 生产事故）：一段 30 分钟的手表录音在 `upload-audio` 上被传了
**四次**，产出四条一模一样的对话和四次 Soniox 离线任务 —— 而那个额度是账号级的、与实时
转录链路共享。链条是：

1. 端点是同步的，内部预算本来就以分钟计（ffmpeg + Silero VAD + 一次最长轮询 300s 的
   Soniox 任务 + LLM 处理），实测长录音 2~4 分钟；
2. 而 POST **不在** `main.py` 的 `methods_timeout` 里，走 `HTTP_DEFAULT_TIMEOUT` 的
   120s 默认值 → 每次都在 120s 整被 `TimeoutMiddleware` 砍成 504；
3. 504 是**该重试**的（网络抖动、服务重启都长这样），客户端于是重传；
4. 而 `asyncio.wait_for` 只是停止 await，同步 `def` 的处理函数在线程池里**照样跑完**，
   转录完成、对话照写。

所以两头都要钉：**cap 必须大于端点自己的内部预算**（否则它结构上不可能成功），以及
**同一时间锚点必须幂等**（cap 只是把阈值往后挪，任何在转录落地之后发生的 504／断网都能
复现这件事，而客户端重试是对的）。

用 AST 读源码而不是 import：这个 router 依赖 opuslib / pydub 等原生包，本地 venv 常常
装不全，import 断言会退化成环境问题而不是回归信号。
"""

import ast
import os
import re
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# `soniox_transcribe_file` 自己的轮询上限。cap 至少要大过它，否则超时的是我们而不是它。
SONIOX_POLL_BUDGET_FLOOR = 300


def _read(rel_path: str) -> str:
    with open(os.path.join(BACKEND_DIR, rel_path), encoding='utf-8') as f:
        return f.read()


def _function_source(rel_path: str, func_name: str) -> str:
    src = _read(rel_path)
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            return ast.get_source_segment(src, node)
    raise AssertionError(f"{rel_path} 里找不到函数 {func_name}")


def _paths_timeout_literal() -> dict:
    """从 `main.py` 里取出 `paths_timeout` 的字面量，不 import 整个 app。"""
    src = _read('main.py')
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
            if 'paths_timeout' not in targets:
                continue
            assert isinstance(node.value, ast.Dict), "paths_timeout 应当是字面量 dict"
            result = {}
            for key, value in zip(node.value.keys, node.value.values):
                assert isinstance(key, ast.Constant), "路径必须是字面量字符串"
                # 值形如 os.environ.get('X', 10 * 60) —— 取默认值那一支，
                # 因为生产上并没有设这个环境变量（`.env.template` / task definition 里都没有）。
                if isinstance(value, ast.Call) and value.args:
                    default = value.args[-1]
                else:
                    default = value
                result[key.value] = float(eval(compile(ast.Expression(default), '<ast>', 'eval')))
            return result
    raise AssertionError("main.py 里找不到 paths_timeout 赋值")


class TestUploadAudioTimeoutBudget(unittest.TestCase):
    def test_soniox_poll_budget_is_still_what_we_assumed(self):
        """下面那条断言的地板值来自这里；它变了，cap 也得跟着变。"""
        src = _read('utils/stt/pre_recorded.py')
        match = re.search(r'max_wait_seconds\s*[:=]\s*(?:int\s*=\s*)?(\d+)', src)
        self.assertIsNotNone(match, "pre_recorded.py 里找不到 max_wait_seconds")
        self.assertGreaterEqual(
            SONIOX_POLL_BUDGET_FLOOR,
            int(match.group(1)),
            "Soniox 的轮询上限涨了，`main.py` 的 paths_timeout 要一起抬高",
        )

    def test_upload_audio_cap_exceeds_its_own_internal_budget(self):
        """cap 低于端点内部预算 = 长录音结构上不可能成功，而失败形态是 504（看起来像网络）。"""
        paths = _paths_timeout_literal()
        cap = paths.get('/v1/conversations/upload-audio')
        self.assertIsNotNone(cap, "upload-audio 必须有自己的 cap，POST 不在 methods_timeout 里")
        self.assertGreater(
            cap,
            SONIOX_POLL_BUDGET_FLOOR,
            f"cap={cap}s 不大于 Soniox 自己的 {SONIOX_POLL_BUDGET_FLOOR}s 轮询预算 —— "
            "转录还没超时，我们先把请求砍了，而客户端会一直重试",
        )

    def test_middleware_resolves_path_override_before_method_and_default(self):
        """路径覆盖必须压过 method 覆盖和默认值，且按前缀匹配。

        `_timeout_for` 是纯函数，可以直接构造实例状态来跑 —— 不需要起 app。
        """
        import sys

        sys.path.insert(0, BACKEND_DIR)
        from utils.other.timeout import TimeoutMiddleware

        class _URL:
            def __init__(self, path):
                self.path = path

        class _Req:
            def __init__(self, path, method='POST'):
                self.url = _URL(path)
                self.method = method

        mw = TimeoutMiddleware.__new__(TimeoutMiddleware)
        mw.default_timeout = 120.0
        mw.methods_timeout = {'GET': 30.0}
        mw.paths_timeout = TimeoutMiddleware._parse_paths_timeout({'/v1/conversations/upload-audio': 600})

        self.assertEqual(mw._timeout_for(_Req('/v1/conversations/upload-audio')), 600.0)
        # 前缀匹配：多一个斜杠不许静默掉回默认值 —— 那正好是这个参数要修的那个 bug。
        self.assertEqual(mw._timeout_for(_Req('/v1/conversations/upload-audio/')), 600.0)
        self.assertEqual(mw._timeout_for(_Req('/v1/conversations/process')), 120.0)
        self.assertEqual(mw._timeout_for(_Req('/health_check', 'GET')), 30.0)


class TestUploadAudioIdempotency(unittest.TestCase):
    def setUp(self):
        self.endpoint = _function_source('routers/audio_upload.py', 'upload_audio_for_conversation')

    def test_dedup_lookup_runs_before_anything_expensive(self):
        """幂等检查必须在转码/VAD/Soniox 之前，否则额度已经烧掉了才发现是重复。"""
        dedup_at = self.endpoint.find('get_conversation_id_by_source_started_at')
        self.assertGreater(dedup_at, -1, "端点没有按 (uid, source, started_at) 查重")
        for expensive in ('_convert_upload_audio', '_transcribe_and_finish'):
            at = self.endpoint.find(expensive)
            self.assertGreater(at, -1, f"端点里找不到 {expensive}，这个测试的假设过期了")
            self.assertLess(dedup_at, at, f"查重必须排在 {expensive} 之前")

    def test_in_flight_upload_answers_409_not_200(self):
        """在飞状态下什么都还没落库，绝不能回 200 —— 客户端会据此删掉唯一的那份文件。"""
        self.assertIn('acquire_lock', self.endpoint)
        self.assertIn('409', self.endpoint)
        self.assertIn('release_lock', self.endpoint)

    def test_lock_is_released_on_every_exit(self):
        """release 必须在 finally 里：被拒的上传（VAD 判无人说话）不能把锚点锁死 15 分钟。"""
        node = None
        tree = ast.parse(_read('routers/audio_upload.py'))
        for candidate in ast.walk(tree):
            if isinstance(candidate, ast.FunctionDef) and candidate.name == 'upload_audio_for_conversation':
                node = candidate
                break
        self.assertIsNotNone(node)
        released_in_finally = False
        for inner in ast.walk(node):
            if not isinstance(inner, ast.Try):
                continue
            for stmt in inner.finalbody:
                if 'release_lock' in (ast.get_source_segment(_read('routers/audio_upload.py'), stmt) or ''):
                    released_in_finally = True
        self.assertTrue(released_in_finally, "release_lock 不在任何 finally 块里")

    def test_existing_response_decompresses_segments(self):
        """复用已存对话时必须走 `get_conversation`。

        长对话的 `transcript_segments` 是 zlib 压缩存的，裸读 `to_dict()` 拿到的是
        **bytes** —— 客户端会收到一个看起来完全正常、transcript 是乱码的 200。
        """
        body = _function_source('routers/audio_upload.py', '_existing_upload_response')
        self.assertIn('developer_data_db.get_conversation(', body)
        self.assertNotIn('to_dict()', body)


if __name__ == '__main__':
    unittest.main(verbosity=2)
