"""一段录音只能产出一条对话（除了静音切分刻意的多段）。

2026-08-08 生产事故：session f0e5e8a0 产出了两条对话（43929118 与 3244256e，相差 5 秒、
同为 50 段 808 字、标题不同）。root cause 三条：

1. Redis 锁只在 POST /v1/conversations/process 端点内，**WS 的静音 flush 完全不参与**
   —— POST 在写 dedup marker 之前要先跑几秒 LLM，这个窗口里 flush 就建了第二条。
2. `auto_processed_conversation_id` 一个字段承担了两个互斥语义：既当「本 session 已处理
   过、别再建」，又要允许静音切分**重复**建（长录音要切成多段）。日志实测
   "Session already processed, skipping flush" 近一天出现 **0 次** —— 这个检查从未生效。
3. 读 marker → 判断 → 建对话之间没有原子性。

用 AST 而不是 import：这两个 router 依赖 opuslib / deepgram 等原生包，本地 venv 常常
装不全，import 断言会退化成环境问题而不是回归信号。
"""

import ast
import os
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

LISTEN = 'routers/developer_listen.py'
CONVERSATIONS = 'routers/developer_conversations.py'


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


class TestSharedLockKey(unittest.TestCase):
    def test_lock_key_is_defined_once_and_shared(self):
        """三条路径必须用同一把锁 —— 各自拼字符串迟早会写歪。"""
        conv_src = _read(CONVERSATIONS)
        self.assertIn('def listen_session_lock_key(', conv_src)

        # POST /process 用它
        post_src = _function_source(CONVERSATIONS, 'process_conversation')
        self.assertIn('listen_session_lock_key(', post_src)

        # listen 的两条路径也用它，而不是自己拼 f-string
        listen_src = _read(LISTEN)
        self.assertIn('listen_session_lock_key', listen_src)
        self.assertNotIn('f"process_conversation:', listen_src)
        self.assertNotIn("f'process_conversation:", listen_src)

    def test_no_other_module_hand_rolls_the_key(self):
        """除了定义处，不该再有第二处手写这个 key 前缀。"""
        conv_src = _read(CONVERSATIONS)
        # 只允许出现在 listen_session_lock_key 的函数体里
        key_fn = _function_source(CONVERSATIONS, 'listen_session_lock_key')
        self.assertIn('process_conversation:', key_fn)
        self.assertEqual(
            conv_src.count('"process_conversation:'),
            key_fn.count('"process_conversation:'),
            '除了 listen_session_lock_key 内部，不应再手写这个前缀',
        )


class TestSilenceFlushSerialization(unittest.TestCase):
    def test_flush_takes_the_shared_lock(self):
        body = _function_source(LISTEN, '_flush_conversation')
        self.assertIn('redis_db.acquire_lock(lock_key', body)
        self.assertIn('redis_db.release_lock(lock_key)', body)

    def test_flush_rechecks_marker_under_the_lock(self):
        """读-判-建必须在锁内闭环，否则原子性缺口还在。"""
        body = _function_source(LISTEN, '_flush_conversation')
        i_acquire = body.index('acquire_lock')
        i_recheck = body.index("get('app_processed_conversation_id')")
        i_create = body.index('_auto_process_conversation(')
        self.assertLess(i_acquire, i_recheck, '复查必须在拿到锁之后')
        self.assertLess(i_recheck, i_create, '建对话必须在复查之后')

    def test_flush_does_not_bail_on_its_own_marker(self):
        """静音切分是刻意要重复触发的（长录音切多段），不能被 auto_processed 挡住。

        这正是缺陷 2：把自己的 marker 当成「别再建」，结果要么长录音只出一段，要么
        （实测）这个检查从未生效。
        """
        body = _function_source(LISTEN, '_flush_conversation')
        # 只看代码，不看 docstring —— docstring 里正解释着这个决定
        code = body[body.index('nonlocal '):]
        self.assertNotIn('auto_processed_conversation_id', code)

    def test_flush_returns_segments_when_lock_is_busy(self):
        """拿不到锁时 segments 要放回缓冲区，不能丢 —— 正确性不依赖客户端重发。"""
        body = _function_source(LISTEN, '_flush_conversation')
        self.assertIn('current_segments[:0] = segments_to_process', body)
        # 插回队首会让 id→index 映射整体错位，必须重建
        self.assertIn('current_segments_index = {', body)

    def test_flush_runs_off_the_event_loop(self):
        """锁获取 + LLM 是阻塞的，跑在事件循环上会卡住 WebSocket 读取。"""
        body = _function_source(LISTEN, '_flush_conversation')
        self.assertIn('asyncio.to_thread(', body)


class TestDisconnectFallbackSerialization(unittest.TestCase):
    def test_finally_fallback_takes_the_shared_lock(self):
        src = _read(LISTEN)
        self.assertIn('def _locked_finalize()', src)
        self.assertIn('redis_db.acquire_lock(final_lock_key', src)
        self.assertIn('redis_db.release_lock(final_lock_key)', src)

    def test_finally_fallback_bails_unconditionally_only_on_the_app_marker(self):
        """🚨 让路的判据是 `app_processed_conversation_id`，不是「有没有 marker」。

        这一条 2026-08-22 翻过来过：以前两个 marker 都无条件让路，而那个早退还排在
        `if not remaining_segments` **之前**，于是「切分过至少一次的长会话」在收尾时把尾巴
        （最后一次切分之后说的话）整段丢掉。客户端改成不再每 120s 自己拆会话之后，长命
        session 成了常态，这条路径每天都会走到，而且不报错。

        两个 marker 语义不同（见 CLAUDE.md）：`app_processed_conversation_id` = App 整体
        接管了本 session，它提交的是自己那份完整段落列表，我们再建一条就是重复内容；
        `auto_processed_conversation_id` = **某一批**已被静音切分归档，与尾巴不相交。
        """
        body = _function_source(LISTEN, '_blocking_conversation_id')
        # 只看代码，不看 docstring —— docstring 里正解释着这个决定
        code = body[body.index('session_doc = '):]

        self.assertIn("get('app_processed_conversation_id')", code)
        self.assertIn("get('auto_processed_conversation_id')", code)

        i_app = code.index("get('app_processed_conversation_id')")
        i_auto = code.index("get('auto_processed_conversation_id')")
        self.assertLess(i_app, i_auto, 'app marker 必须先判：它是无条件让路的那个')

        # auto marker 必须与「没有尾巴」合取，否则尾巴又会被丢掉。
        self.assertIn('not remaining_segments', code,
                      'auto marker 又变成无条件让路了 —— 长会话的尾巴会被整段丢掉')
        self.assertLess(i_auto, code.index('not remaining_segments'),
                        '`not remaining_segments` 必须挂在 auto marker 那一支上')
        # app marker 那一支绝不能被 remaining_segments 影响。
        app_branch = code[i_app:i_auto]
        self.assertNotIn('remaining_segments', app_branch,
                         'app marker 变成有条件让路了 —— App 提交过的内容会被重复建一条')

    def test_finally_fallback_snapshot_happens_after_flush_task_is_cancelled(self):
        """上一条的安全性前提：快照 `current_segments` 时不能还有在飞的 flush。

        允许「auto marker 存在时继续归档尾巴」成立，靠的是 `remaining_segments` 与任何
        已切分批次**必然不相交** —— `_flush_conversation` 取批次时会同步清空
        `current_segments`，而 finally 在快照之前已经 `await` 过切分 task 的取消。少了那个
        await，flush 和 finalize 可能各持同一批段落，两条路径都建对话 ⇒ 2026-08-08 那种
        重复对话又会出现，而且这次没有 marker 检查兜着。
        """
        src = _read(LISTEN)

        # ⚠️ 不能直接 `src.index('conversation_creation_task.cancel()')`：`_reset_conversation_timer`
        # 里也有一份**同样的** cancel + await（每来新段落就重排定时器），而且排在前面。第一版
        # 就是这么写的，变异验证时逮到了 —— 把 finally 里的 await 整段删掉，断言命中的仍是
        # `_reset_conversation_timer` 里那一对，测试照样绿。所以先把那个函数整段抠掉。
        reset_src = _function_source(LISTEN, '_reset_conversation_timer')
        i_snapshot = src.index('remaining_segments = deepcopy(current_segments)')
        head = src[:i_snapshot].replace(reset_src, '')

        self.assertIn('conversation_creation_task.cancel()', head,
                      '快照前没有取消切分 task —— flush 可能与 finalize 各持同一批段落')
        self.assertIn('await conversation_creation_task', head,
                      '只 cancel() 没 await —— task 可能正跑在 _flush_conversation 中间，'
                      '此刻快照到的段落会被两条路径各建一条对话')

    def test_tail_conversation_span_is_its_own_duration_not_the_session_axis(self):
        """尾巴对话的时长必须是尾巴自己的，不能是「距 session 起点」的偏移。

        这条是上面那个「auto marker 存在时仍归档尾巴」的必要条件，值得单独钉住 —— 一次
        code review 正是在这里推错了，结论是「录了 5 小时的会话，尾巴对话的 finished_at 会
        落在 5 小时后（且在未来）」。

        它不成立，因为 `_auto_process_conversation` **开头**就按 `min_start` 重新归零了一次
        （`timestamp_offset` 那一层只在整个 session 的第一段上算，段落进到这里时带的确实是
        session 轴偏移，但这里会再减掉 min_start）。实测：尾巴 17880~18000 → 归一化成
        0~120 → `speech_span = 120` → `finished_at = started_at + 120s`。

        所以真正要守的是**顺序**：归零必须排在 `speech_span` 之前。反过来的话尾巴对话会拿到
        一个巨大的时长和一个未来的结束时间，而且不报错。
        """
        body = _function_source(LISTEN, '_auto_process_conversation')

        # ⚠️ 这个函数里有**两个** speech_span，只有后一个依赖归零：
        #   :401 `max(end) - min(start)`（差值，天然不受 session 轴偏移影响，用于时长下限
        #        与 discard 判定）
        #   :602 `max(end)`（假定段落已 0 起，`finished_at` 用的是它）
        # 所以要锚定行首精确定位后者。顺带：搜 `finished_at = started_at + timedelta(` 会被
        # `discard_finished_at = started_at + timedelta(` 撞上（前者是后者的后缀），第一版就
        # 这么错了，断言比较的是两个不相干的位置。
        i_apply = body.index('segments = conversation_segments(segments)')
        i_span = body.index('\n    speech_span = max(')
        i_finished = body.index('\n    finished_at = started_at + timedelta(')

        self.assertLess(i_apply, i_span,
                        '归零必须排在 speech_span = max(end) 之前 —— 否则尾巴对话的时长会变成'
                        '「距 session 起点」的偏移（5 小时会话的 2 分钟尾巴会写成 5 小时，'
                        '且 finished_at 落在未来）')
        self.assertLess(i_span, i_finished, 'finished_at 依赖 speech_span')

        self.assertIn("s['original_start']", body, '归零时必须保留原始时间坐标')

    def test_finally_fallback_waits_instead_of_bailing_on_busy_lock(self):
        """这是全链路唯一给对话挂音频的地方，拿不到锁就返回会让音频永久孤立。

        （flush 传 audio_path=None，POST /process 根本看不到音频。）锁被占用意味着
        持锁方还在跑 LLM、marker 还没写 —— 此刻返回既读不到 conversation_id 也不能
        建对话，音频就没处挂了。所以要轮询等：marker 和锁哪个先到都能收尾。
        """
        body = _function_source(LISTEN, '_locked_finalize')
        self.assertIn('while True:', body)
        self.assertIn('time.sleep(', body)
        self.assertIn('FINALIZE_LOCK_WAIT_SECONDS', body)
        # 每轮都要重读 marker，而不是只在拿到锁之后读
        i_loop = body.index('while True:')
        i_marker = body.index('_blocking_conversation_id()')
        i_acquire = body.index('redis_db.acquire_lock')
        self.assertLess(i_loop, i_marker, 'marker 必须在轮询循环内重读')
        self.assertLess(i_marker, i_acquire, '先看 marker 再抢锁：有 marker 就只需挂音频')

    def test_finally_fallback_links_audio_whenever_a_conversation_exists(self):
        """读到 marker 就必须挂音频 —— 否则录音详情页没有音频可播。"""
        body = _function_source(LISTEN, '_locked_finalize')
        # 锁内锁外两处 marker 命中都要走 _link_audio
        self.assertEqual(body.count('_link_audio('), 2)
        self.assertIn('_link_audio(existing)', body)
        self.assertIn('_link_audio(existing_conv_id)', body)
        # 只有真拿到锁才建对话
        i_guard = body.index('if not acquired:')
        i_create = body.index('_auto_process_conversation(')
        self.assertLess(i_guard, i_create)
        self.assertIn('if acquired:', body)


if __name__ == '__main__':
    unittest.main(verbosity=2)
