"""App 首页链路上的重端点不许在 event loop 上跑同步 I/O。

存在的理由（2026-08-12 修）：生产的 `Dockerfile` 是 `uvicorn main:app` **不带
`--workers`**，也就是每个 ECS 任务一个进程一个 event loop，而 `api-rest` 只有两个任务。
这三个端点当时都是 `async def`，函数体却整段是阻塞调用（Firestore 读、以及多秒的 LLM
流水线），于是一个慢请求会冻住落在同一任务上的**所有**其它请求：

* `POST /v1/conversations/process` p50 10.3s / max 36.3s
* `GET /v1/timeline/{date}/chapters` p50 356ms 但 p90 3.7s / max 18.3s
* `GET /v1/conversations` 平常 90ms，却量到过 1.2s 和 33.4s

（`api_logs_daily`，2026-08-08..12。33.4s 那次自己什么都没做，纯粹是排在别人后面。）
用户看到的症状是「首页下拉刷新经常很久、没有响应」——下拉刷新恰好同时打这三类请求。

修法有两种，判据是**函数体里有没有真的 await**：

* 没有（`list_conversations` / `get_day_chapters`）→ 改成 **sync `def`**，FastAPI 自己
  把它丢进 threadpool。这是最省事也最不容易写错的形态。
* 有（`process_conversation` 的 loser 要 `asyncio.sleep` 轮询）→ 只能留在 `async def`，
  把每个阻塞调用用 **`run_in_threadpool`** 转发出去。

⚠️ **失败形态是静默的**：把 `def` 改回 `async def`（比如为了新加一个 await）不会有任何
报错、任何测试变红、任何日志异常，只会让别人的请求开始变慢——而慢的是**别的端点**，
所以排查时根本不会看向这里。同理，`run_in_threadpool` 前忘了 `await` 会返回 coroutine，
那反而是响眼的 500，不需要测试来管；这里仍然一并钉住，因为顺手。

第二轮（同日，同一个判据）又改了 11 个重端点，全部是零 await → sync `def`：两个分钟级
的上传链路（`/v1/sync-local-files`、`/v1/conversations/upload-audio`）、`/v1/daily-summary`
的 LLM+配图、`/v1/conversations/search` 的 embedding+Pinecone、`/v1/timeline/{date}`
的逐章 LLM rollup，以及六个走 GCS 的签名/列举/删除。

⚠️ **`/v1/conversations/search` 是「静态扫描会看漏」的那一类。** 它的函数体只有一行
`dev_db.search_conversations(...)`，按「体积」看像个轻端点，但那一个调用里面是一次
Vertex AI embedding 加一次 Pinecone 查询。判端点重不重要跟着调用链往下看一层，别只看
handler 自己有多长。

⚠️ **收 `UploadFile` 的 handler 有个额外前提**，见 `UPLOAD_FILE_HANDLERS`：读上传内容必须
走 `file.file`（底层 spooled temp file）+ `shutil.copyfileobj`。改成 `await file.read()`
就必须退回 `async def`，那时整条分钟级流水线又回到 event loop 上。

⚠️ **全仓库还剩 92 个 `async def` 且体内零 await 的 handler，仍未整改**（AST 扫 `routers/`
可复现这个数；改之前是 106）。判据仍是「这个端点重不重」——多秒 LLM、大查询、或在首页
链路上才值得动。剩下那些多是单次 Firestore 读写的轻端点，同样的毛病但影响有限。要继续
扩大范围时，把端点加进 `SYNC_HANDLERS` / `THREADPOOL_HANDLERS` 即可。

用 AST 而不是 import：这些 router 依赖 opuslib / deepgram 等原生包，本地 venv 常装不
全，import 断言会退化成环境问题而不是回归信号。同一个理由见
`test_summarizer_user_label.py`。

Run:
    cd backend && python3 tests/test_home_endpoints_off_event_loop.py
"""

import ast
import os
import sys
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

# 体内没有 await 的重端点 → 必须是 sync def，让 FastAPI 用它的 threadpool 跑。
SYNC_HANDLERS = (
    # 第一轮（首页链路）
    ('routers/developer_conversations.py', 'list_conversations'),
    ('routers/timeline.py', 'get_day_chapters'),
    # 第二轮：分钟级的上传链路。这两个是全 API 最长的请求，收益也最大。
    ('routers/sync.py', 'sync_local_files'),
    ('routers/audio_upload.py', 'upload_audio_for_conversation'),
    # 第二轮：多秒 LLM
    ('routers/developer_daily_summary.py', 'create_daily_summary'),
    ('routers/timeline.py', 'get_timeline_shadow'),
    # 第二轮：embedding + Pinecone。函数体只有一行，重量在调用链下一层。
    ('routers/developer_conversations.py', 'search_conversations'),
    # 第二轮：GCS 签名 / 列举 / 删除
    ('routers/developer_conversations.py', 'get_conversation_audio_url'),
    ('routers/developer_images.py', 'get_image_url'),
    ('routers/developer_images.py', 'delete_image'),
    ('routers/developer_people.py', 'delete_person'),
    ('routers/developer_people.py', 'delete_person_speech_sample'),
    ('routers/developer_speech_profile.py', 'get_speech_profile'),
    ('routers/developer_speech_profile.py', 'delete_speech_profile'),
    ('routers/developer_speech_profile.py', 'list_samples'),
    ('routers/developer_speech_profile.py', 'delete_sample'),
)

# 收 UploadFile 的 sync handler：读上传内容只许走 `file.file`（底层 spooled temp file）。
# `await file.read()` 会强迫它们退回 async def，把分钟级流水线放回 event loop 上。
UPLOAD_FILE_HANDLERS = (
    ('routers/sync.py', 'sync_local_files', 'retrieve_file_paths'),
    ('routers/audio_upload.py', 'upload_audio_for_conversation', None),
)

# 必须留在 async def 的重端点 → 每个阻塞调用都要过 run_in_threadpool。
# 值是「不许在 event loop 上直接调」的函数名。
THREADPOOL_HANDLERS = {
    ('routers/developer_conversations.py', 'process_conversation'): {
        '_do_process_conversation',      # create + 多秒 LLM + finish
        '_lookup_processed_conversation',  # Firestore 读，轮询循环里每 0.5s 一次
    },
}


def _parse(rel_path: str) -> ast.Module:
    with open(os.path.join(BACKEND_DIR, rel_path), encoding='utf-8') as f:
        return ast.parse(f.read())


def _find_function(rel_path: str, func_name: str):
    for node in ast.walk(_parse(rel_path)):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == func_name:
            return node
    raise AssertionError(f"{rel_path} 里找不到函数 {func_name}")


def _is_route(node) -> bool:
    """挂了 @router.<method>(...) 的才是端点。"""
    return any('router' in ast.unparse(d) for d in node.decorator_list)


def _awaits(node) -> int:
    return sum(1 for n in ast.walk(node) if isinstance(n, (ast.Await, ast.AsyncWith, ast.AsyncFor)))


def _direct_calls(node) -> set:
    """函数体里被直接调用（即在当前线程执行）的名字。

    `run_in_threadpool(f, ...)` 里的 `f` 是**参数**而不是 `Call.func`，所以不会被算进
    来——这正是本测试要区分的两种形态。
    """
    return {
        n.func.id
        for n in ast.walk(node)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
    }


def _copyfileobj_sources(node) -> set:
    """`shutil.copyfileobj(<src>, ...)` 里 `<src>` 的源码文本。

    要的是判断它是不是 `xxx.file`——UploadFile 的同步句柄。`await file.read()` 才是那个
    会把 handler 拖回 async def 的形态。
    """
    sources = set()
    for n in ast.walk(node):
        if not isinstance(n, ast.Call):
            continue
        name = ast.unparse(n.func)
        if name.endswith('copyfileobj') and n.args:
            sources.add(ast.unparse(n.args[0]))
    return sources


def _threadpool_dispatched(node) -> set:
    """被 run_in_threadpool 转发出去的名字（第一个位置参数）。"""
    dispatched = set()
    for n in ast.walk(node):
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'run_in_threadpool':
            if n.args and isinstance(n.args[0], ast.Name):
                dispatched.add(n.args[0].id)
    return dispatched


class SyncHandlerTests(unittest.TestCase):
    def test_heavy_handlers_are_sync_def(self):
        for rel_path, name in SYNC_HANDLERS:
            with self.subTest(handler=name):
                fn = _find_function(rel_path, name)
                self.assertTrue(_is_route(fn), f'{name} 不再是端点了，这条断言已经失去意义')
                self.assertIsInstance(
                    fn, ast.FunctionDef,
                    f'{name} 又变成 async def 了：它体内全是阻塞调用，会冻住同一任务上的所有请求',
                )

    def test_sync_def_stays_justified(self):
        """sync def 的前提是「体内没有 await」——有了 await 就该改用 threadpool 转发。

        这条不是重复上一条：将来给它们加 await 的人会先撞到语法错误（sync def 里不能
        await），于是很可能顺手把 def 改回 async def，把上一条的失败形态解释成「测试
        过时了」。这里把正确的替代形态写出来。
        """
        for rel_path, name in SYNC_HANDLERS:
            with self.subTest(handler=name):
                fn = _find_function(rel_path, name)
                self.assertEqual(
                    _awaits(fn), 0,
                    f'{name} 里出现了 await：请保留 async def，但把阻塞调用交给 run_in_threadpool',
                )


class UploadFileHandlerTests(unittest.TestCase):
    """收 `UploadFile` 的 handler 能不能是 sync `def`，取决于它怎么读上传内容。

    这两个是全 API 最长的请求（解码 + VAD + STT + LLM，分钟级），所以「别在 event loop
    上跑」的收益最大；但它们也是**唯一**有额外前提的：`UploadFile` 既有 async 的
    `await file.read()`，也有同步的 `file.file`（底层 spooled temp file）。用了前者就
    必须是 `async def`，那时整条流水线又回到 loop 上。

    ⚠️ 这条不能靠上面的「零 await」断言代管。那条的报错信息给的建议是「留 async def +
    run_in_threadpool」——对这两个 handler 是错的方向，正确的修法是把读法换回 `.file`。
    """

    def test_uploads_are_read_synchronously(self):
        for rel_path, name, helper in UPLOAD_FILE_HANDLERS:
            with self.subTest(handler=name):
                nodes = [_find_function(rel_path, name)]
                if helper:
                    nodes.append(_find_function(rel_path, helper))

                for fn in nodes:
                    self.assertEqual(
                        _awaits(fn), 0,
                        f'{fn.name} 里出现了 await：如果是 `await file.read()`，请改回 '
                        f'`shutil.copyfileobj(file.file, ...)`——否则 {name} 只能退回 '
                        f'async def，分钟级的流水线又回到 event loop 上',
                    )

                sources = set().union(*(_copyfileobj_sources(fn) for fn in nodes))
                self.assertTrue(
                    sources, f'{name} 及其 helper 里找不到 copyfileobj —— 读法换了？这条断言已失效'
                )
                self.assertTrue(
                    all(src.endswith('.file') for src in sources),
                    f'{name} 的上传读取源不是 `.file`：{sorted(sources)}',
                )


class ThreadpoolHandlerTests(unittest.TestCase):
    def test_blocking_calls_go_through_threadpool(self):
        for (rel_path, name), blocking in THREADPOOL_HANDLERS.items():
            with self.subTest(handler=name):
                fn = _find_function(rel_path, name)
                self.assertTrue(_is_route(fn), f'{name} 不再是端点了，这条断言已经失去意义')
                self.assertIsInstance(
                    fn, ast.AsyncFunctionDef,
                    f'{name} 需要 await（锁等待轮询），改成 sync def 会让 asyncio.sleep 失效',
                )

                offenders = _direct_calls(fn) & blocking
                self.assertEqual(
                    offenders, set(),
                    f'{name} 在 event loop 上直接调了 {sorted(offenders)}：'
                    f'p50 10.3s 的流水线会冻住同一任务上的所有请求，请用 run_in_threadpool 转发',
                )
                self.assertEqual(
                    blocking - _threadpool_dispatched(fn), set(),
                    f'{name} 里这些阻塞调用既没直接调、也没进 threadpool——被删了还是改名了？',
                )

    def test_threadpool_calls_are_awaited(self):
        """run_in_threadpool 忘了 await 会返回 coroutine（500），顺手一起钉住。"""
        for rel_path, name in THREADPOOL_HANDLERS:
            with self.subTest(handler=name):
                fn = _find_function(rel_path, name)
                total = sum(
                    1 for n in ast.walk(fn)
                    if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
                    and n.func.id == 'run_in_threadpool'
                )
                awaited = sum(
                    1 for n in ast.walk(fn)
                    if isinstance(n, ast.Await) and isinstance(n.value, ast.Call)
                    and isinstance(n.value.func, ast.Name) and n.value.func.id == 'run_in_threadpool'
                )
                self.assertEqual(total, awaited, f'{name} 里有没被 await 的 run_in_threadpool')


class ScannerSelfCheckTests(unittest.TestCase):
    """扫描器本身的自检。

    上面每条断言都是「找不到就 raise」，所以名字写错会直接报错而不是静默通过。剩下的
    风险是名单空了（有人清空常量、或把两个字典写成同一个），那样测试会全绿而什么都没查。
    """

    def test_scanner_covers_something(self):
        self.assertGreaterEqual(len(SYNC_HANDLERS), 16)
        self.assertGreaterEqual(len(THREADPOOL_HANDLERS), 1)
        self.assertGreaterEqual(len(UPLOAD_FILE_HANDLERS), 2)
        self.assertTrue(all(names for names in THREADPOOL_HANDLERS.values()))

    def test_no_duplicate_entries(self):
        """名单是手工维护的：同一个 handler 写两遍时，subTest 会各跑一次而看不出重复，
        而 `assertGreaterEqual` 的下限也就被灌水灌过去了。"""
        self.assertEqual(len(SYNC_HANDLERS), len(set(SYNC_HANDLERS)))

    def test_detects_the_pre_fix_shape(self):
        """变异验证：拿修复前的形态喂给判据，必须被认出来。

        修复前 `get_day_chapters` 是 `async def` 且体内零 await，`process_conversation`
        直接调 `_do_process_conversation`。判据要是写反了，上面所有断言都会一直是绿的。
        """
        before_sync = ast.parse(
            'async def get_day_chapters():\n'
            '    return recompute_day()\n'
        ).body[0]
        self.assertNotIsInstance(before_sync, ast.FunctionDef, '判据认不出「本该 sync 却是 async」')
        self.assertEqual(_awaits(before_sync), 0)

        before_pool = ast.parse(
            'async def process_conversation():\n'
            '    await asyncio.sleep(0.5)\n'
            '    return _do_process_conversation(data, dev)\n'
        ).body[0]
        self.assertIn('_do_process_conversation', _direct_calls(before_pool))
        self.assertEqual(_threadpool_dispatched(before_pool), set())

        after_pool = ast.parse(
            'async def process_conversation():\n'
            '    await asyncio.sleep(0.5)\n'
            '    return await run_in_threadpool(_do_process_conversation, data, dev)\n'
        ).body[0]
        self.assertNotIn('_do_process_conversation', _direct_calls(after_pool))
        self.assertEqual(_threadpool_dispatched(after_pool), {'_do_process_conversation'})

    def test_detects_async_upload_read(self):
        """变异验证：`await file.read()` 那个形态必须被认出来。

        它是唯一会正当地把这两个 handler 拖回 `async def` 的改动，所以判据要能分辨
        「同步读 `.file`」和「异步读 `.read()`」，而不只是数 await 的个数。
        """
        sync_read = ast.parse(
            'def upload():\n'
            '    with open(p, "wb") as f:\n'
            '        shutil.copyfileobj(file.file, f)\n'
        ).body[0]
        self.assertEqual(_awaits(sync_read), 0)
        self.assertEqual(_copyfileobj_sources(sync_read), {'file.file'})

        async_read = ast.parse(
            'async def upload():\n'
            '    data = await file.read()\n'
            '    open(p, "wb").write(data)\n'
        ).body[0]
        self.assertEqual(_awaits(async_read), 1, '判据认不出 await file.read()')
        self.assertEqual(_copyfileobj_sources(async_read), set(), 'copyfileobj 检查不该在这里命中')

        # 中间形态：同步读了，但读的是 `.read()` 的结果而不是 `.file` 句柄。零 await 蒙混
        # 过关，只有 `.file` 那条断言拦得住。
        wrong_handle = ast.parse(
            'def upload():\n'
            '    shutil.copyfileobj(file, f)\n'
        ).body[0]
        self.assertEqual(_awaits(wrong_handle), 0)
        self.assertFalse(all(s.endswith('.file') for s in _copyfileobj_sources(wrong_handle)))


if __name__ == '__main__':
    unittest.main(verbosity=2)
