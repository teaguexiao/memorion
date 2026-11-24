"""实时录音链路必须提取记忆。

存在的理由：`extract_memories_from_segments` / `new_memories_extractor` 各自都是对的，
但从 2026-03 App 自建录音链路上线到 2026-08-08，**没有任何一条实时路径调用它们** ——
生产上 `source='app'` 的 2900+ 条录音自动记忆产出为 0（历史上那些带 conversation_id
的记忆全部来自 Omi 迁移数据）。这类「两个正确的函数没接起来」的缺陷单测不到函数本身，
只能靠断言调用点存在。

用 AST 而不是 import：这两个 router 依赖 opuslib / deepgram 等原生包，本地 venv 常常
装不全，import 断言会变成环境问题而不是回归信号。
"""

import ast
import os
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


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


def _function_node(rel_path: str, func_name: str) -> ast.FunctionDef:
    tree = ast.parse(_read(rel_path))
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            return node
    raise AssertionError(f"{rel_path} 里找不到函数 {func_name}")


class TestRealtimeMemoryExtraction(unittest.TestCase):
    def test_shared_extractor_exists_with_expected_signature(self):
        """两条实时路径手里只有 dict segments，没有 Conversation 对象，所以需要这个入口。"""
        node = _function_node('utils/conversations/process_conversation.py', 'extract_memories_from_segments')
        self.assertEqual(
            [a.arg for a in node.args.args],
            ['developer_id', 'external_user_id', 'conversation_id', 'segments'],
        )

    def test_shared_extractor_writes_memory_with_conversation_id(self):
        """记忆必须带 conversation_id，否则「这条记忆来自哪次对话」就断了。"""
        body = _function_source('utils/conversations/process_conversation.py', 'extract_memories_from_segments')
        self.assertIn('dev_db.create_memory(', body)
        self.assertIn('"conversation_id": conversation_id', body)
        self.assertIn('new_memories_extractor(', body)

    def test_extractor_fails_closed_without_user_attribution(self):
        """声纹没有认出佩戴者时宁可不记，不能从全屋人的话里猜一个“你”。"""
        body = _function_source('utils/llm/memories.py', 'new_memories_extractor')
        self.assertIn('evidence_segments = _user_attributed_segments(segments)', body)
        self.assertIn('if not evidence_segments:', body)
        self.assertLess(
            body.index('if not evidence_segments:'),
            body.index('get_prompt_memories(uid)'),
            "无本人语音必须在取画像上下文和调用 LLM 之前直接返回",
        )

    def test_extractor_never_sends_other_speakers_to_profile_llm(self):
        """同场他人的第一人称陈述不能进入画像抽取 prompt。"""
        helper = _function_source('utils/llm/memories.py', '_user_attributed_segments')
        self.assertIn('if segment.is_user', helper)

        body = _function_source('utils/llm/memories.py', 'new_memories_extractor')
        self.assertIn(
            'TranscriptSegment.segments_as_string(evidence_segments, user_name=user_name)',
            body,
        )
        self.assertNotIn('segments_as_string(segments,', body)

    def test_listen_auto_process_extracts_memories(self):
        """静音切分 / WS 断开兜底建出的对话也要长记忆。"""
        body = _function_source('routers/developer_listen.py', '_auto_process_conversation')
        self.assertIn('extract_memories_from_segments', body)

    def test_app_process_endpoint_extracts_memories(self):
        """POST /v1/conversations/process 是 App 主动处理的路径，同样要长记忆。

        调用点在 `_identify_speakers_then_emit_eir` 里 —— 这条路径把提取挂在声纹之后
        （见 test_extraction_runs_after_voiceprint_*），不在 `_do_process_conversation`。
        """
        body = _function_source('routers/developer_conversations.py', '_identify_speakers_then_emit_eir')
        self.assertIn('extract_memories_from_segments', body)

    def test_extraction_runs_after_voiceprint_on_listen_path(self):
        """提取必须挂在声纹线程末尾，不能自己起线程跟它并发。

        2026-08-15 之前两者是并发的：提取几乎总是先跑完，于是喂给 prompt 的 transcript
        里 `is_user` 全是 False，佩戴者被标成匿名的 "Speaker N"，提取 prompt 无从判断
        一件事是谁的。旧注释还断言过「提取只读段落文本，不需要 is_user」—— 那是错的，
        `segments_as_string(..., user_name=...)` 正是靠 is_user 决定哪些行标真名。
        """
        outer = _function_source('routers/developer_listen.py', '_auto_process_conversation')
        self.assertNotIn(
            '_extract_memories_background', outer,
            "旧的并发线程不能回来"
        )
        sp = _function_source('routers/developer_listen.py', '_speech_profile_matching_background')
        self.assertIn('_extract_memories_after_voiceprint(revisited)', sp)
        self.assertGreater(
            sp.index('_extract_memories_after_voiceprint(revisited)'),
            sp.index('identify_developer_speakers('),
            "提取必须排在声纹匹配之后",
        )

    def test_extraction_survives_voiceprint_failure_on_listen_path(self):
        """声纹挂了不能连带丢掉记忆 —— 调用必须在 finally 里。"""
        node = _function_node('routers/developer_listen.py', '_speech_profile_matching_background')
        tries = [s for s in node.body if isinstance(s, ast.Try)]
        self.assertEqual(len(tries), 1, "函数体应当有一个 try")
        finalbody = ast.dump(ast.Module(body=tries[0].finalbody, type_ignores=[]))
        self.assertIn('_extract_memories_after_voiceprint', finalbody,
                      "提取必须在 finally 里，否则声纹异常时不会执行")

    def test_extraction_runs_after_voiceprint_on_app_process_path(self):
        """POST /process 那条路径同样：请求路径上不许再起提取线程。"""
        req = _function_source('routers/developer_conversations.py', '_do_process_conversation')
        self.assertNotIn('extract_memories_from_segments', req)
        sp = _function_source('routers/developer_conversations.py', '_identify_speakers_then_emit_eir')
        self.assertGreater(
            sp.index('extract_memories_from_segments'),
            sp.index('identify_developer_speakers('),
            "提取必须排在声纹匹配之后",
        )

    def test_skips_memories_for_discarded(self):
        """被判为媒体播放 / 无意义的对话不该污染用户画像。

        守卫读的是 **revisit 之后** 的 discarded：被声纹翻案救回来的对话反而应该长记忆。
        """
        inner = _function_source('routers/developer_listen.py', '_extract_memories_after_voiceprint')
        self.assertIn("if conv.get('discarded'):", inner)
        self.assertLess(
            inner.index("if conv.get('discarded'):"),
            inner.index('extract_memories_from_segments'),
            "守卫必须在提取之前",
        )
        sp = _function_source('routers/developer_conversations.py', '_identify_speakers_then_emit_eir')
        self.assertIn("if not conversation.get('discarded'):", sp)
        self.assertLess(
            sp.index("if not conversation.get('discarded'):"),
            sp.index('extract_memories_from_segments'),
            "守卫必须在提取之前",
        )

    def test_memory_extraction_never_blocks_conversation(self):
        """提取失败不能让对话处理挂掉 —— 整个函数体包在 try/except 里。"""
        node = _function_node('utils/conversations/process_conversation.py', 'extract_memories_from_segments')
        # 跳过 docstring，函数体的实质语句应当是单个 Try
        stmts = [s for s in node.body if not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
        self.assertEqual(len(stmts), 1, "函数体应当只有一个 try 块")
        self.assertIsInstance(stmts[0], ast.Try)

    def test_prompt_data_prefers_developer_path_user_name(self):
        """记忆正文里要出现用户真名。

        `database.auth.get_user_name` 查的是 Firebase display_name，而 App 改名写的是
        developer 路径的 `name` 字段 —— 只查 Firebase 会退化成 'The User'，实测记忆会
        写成 "The User has a young daughter..."。
        """
        body = _function_source('utils/llms/memory.py', 'get_prompt_data')
        self.assertIn('dev_db.get_user_name(developer_id, uid)', body)
        # Firebase 回退要保留（它提供 'The User' 默认值，提取 prompt 依赖这个措辞）
        self.assertIn('get_user_name(uid)', body)


if __name__ == '__main__':
    unittest.main(verbosity=2)
