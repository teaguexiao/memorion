"""喂给摘要器的 transcript 必须把佩戴者标成字面量 `User`，不是他的显示名。

存在的理由（2026-08-12 修）：五个建 transcript 的地方都把 `is_user=True` 的段落标成
`dev_db.get_user_name()` 查出来的显示名（"Teague"），理由写的是「让摘要里出现真名」。
但摘要 prompt 把 `User` 这个字面量硬编码在三处（`utils/llm/conversation_processing.py`
:390 / :419 / :585），其中 **:419 是一个否定判据**：

    The "User" label never appears in the transcript (only "Speaker N" labels)
    — this strongly suggests the user was not speaking, just listening to media

换成显示名之后，**只要佩戴者说过话，这个分支就恒为真**：摘要从别人的视角写，
甚至整条对话被判成媒体播放丢掉。离线评测里这条缺陷是可测的——修完之后同一份语料
（28 条不变）上 `report_no_record(no_record)` 从 4 降到 1、`memory_search` 调用
78→91、带引用的题 33→39，见 `evaluation/chat-agent/GOLDEN-RESULTS.md` 结论十二。

⚠️ **判据是「prompt 知不知道这个名字」，不是「哪个链路更重要」。** 记忆提取
**要**拿到真名，而且必须保持原样：画像抽取现在只接收 `is_user=True` 的段落，
这些段落仍要渲染成 `Teague: ...`，让 prompt 能把证据和画像主人绑定。写成字面量
`User` 会让输出退化成 "The User has ..."。所以这份测试同时钉两个方向——摘要侧
不许有显示名，记忆侧不许没有。

用 AST 而不是 import：这两个 router 依赖 opuslib / deepgram 等原生包，本地 venv 常
装不全，import 断言会退化成环境问题而不是回归信号。同一个理由见
`test_realtime_memory_extraction.py`。
"""

import ast
import os
import sys
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

# 摘要家族：这几个函数的 prompt 都以字面量 `User` 认佩戴者
SUMMARIZER_CALLS = {
    'get_transcript_structure',
    'get_reprocess_transcript_structure',
    'should_discard_conversation',
}

# 只扫生产代码。scripts/ 和 maintenance/ 里的一次性脚本不上生产链路，
# 但如果哪天有脚本要回填摘要，它同样该守这条规则——那时把目录加进来。
SCAN_DIRS = ('routers', 'utils')


def _read(rel_path: str) -> str:
    with open(os.path.join(BACKEND_DIR, rel_path), encoding='utf-8') as f:
        return f.read()


def _function_source(rel_path: str, func_name: str) -> str:
    src = _read(rel_path)
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == func_name:
            return ast.get_source_segment(src, node)
    raise AssertionError(f"{rel_path} 里找不到函数 {func_name}")


def _called_names(node: ast.AST) -> set:
    names = set()
    for child in ast.walk(node):
        if isinstance(child, ast.Call):
            func = child.func
            if isinstance(func, ast.Attribute):
                names.add(func.attr)
            elif isinstance(func, ast.Name):
                names.add(func.id)
    return names


def _summarizer_callers():
    """返回 [(rel_path, func_name, 该函数里出现过的调用名集合)]。"""
    found = []
    for base in SCAN_DIRS:
        for dirpath, _, filenames in os.walk(os.path.join(BACKEND_DIR, base)):
            for filename in filenames:
                if not filename.endswith('.py'):
                    continue
                abs_path = os.path.join(dirpath, filename)
                rel_path = os.path.relpath(abs_path, BACKEND_DIR)
                try:
                    tree = ast.parse(_read(rel_path))
                except SyntaxError:  # pragma: no cover
                    continue
                for node in ast.walk(tree):
                    if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        continue
                    names = _called_names(node)
                    if names & SUMMARIZER_CALLS:
                        found.append((rel_path, node.name, names))
    return found


class TestSummarizerUserLabel(unittest.TestCase):
    def test_default_label_is_the_literal_user(self):
        """机制本身：不传 `user_name` 时 `segments_as_string` 回落到字面量 `User`。

        这是「摘要侧不传名字」之所以够用的原因——不需要额外传 `user_name="User"`。
        """
        from models.transcript_segment import TranscriptSegment

        segments = [
            TranscriptSegment(id='1', text='hello', speaker_id=0, is_user=True, start=0.0, end=1.0),
            TranscriptSegment(id='2', text='hi', speaker_id=1, is_user=False, start=1.0, end=2.0),
        ]
        rendered = TranscriptSegment.segments_as_string(segments)
        self.assertIn('User: hello', rendered)
        self.assertNotIn('Speaker 0', rendered)
        # 反向对照：显示名确实会盖掉标签（这就是缺陷的形状）
        self.assertIn('Teague: hello', TranscriptSegment.segments_as_string(segments, user_name='Teague'))

    def test_no_summarizer_caller_resolves_a_display_name(self):
        """核心不变式：任何调摘要家族的函数都不许查用户显示名。

        这条比逐点断言强——它对**将来新增**的调用点也成立。真出现合法例外（比如
        某个链路要把名字用在别处），在这里显式豁免并写下理由，别直接删断言。
        """
        offenders = [
            f"{path}:{func}"
            for path, func, names in _summarizer_callers()
            if 'get_user_name' in names
        ]
        self.assertEqual(
            offenders, [],
            "这些函数把摘要 transcript 里的 `User` 换成了显示名，会翻转 "
            "conversation_processing.py:419 的媒体判定：" + ', '.join(offenders),
        )

    def test_all_five_known_sites_are_covered(self):
        """把「扫到了几个调用点」钉住，防止扫描器本身失效。

        上一条不变式如果因为 AST 匹配写错而扫到 0 个函数，它会**恒过**。
        """
        callers = {(path, func) for path, func, _ in _summarizer_callers()}
        for expected in [
            ('routers/developer_listen.py', '_auto_process_conversation'),
            ('routers/developer_conversations.py', '_do_process_conversation'),
            ('routers/developer_conversations.py', '_revisit_user_dependent_verdicts'),
            ('utils/conversations/process_conversation.py', '_get_structured'),
        ]:
            self.assertIn(expected, callers, f"扫描器漏了 {expected}——不变式会变成恒过")

    def test_listen_builds_both_transcripts_with_the_literal(self):
        """`_auto_process_conversation` 建两遍 transcript：初次 + speaker→People 映射后重建。

        重建那一遍包在 `except Exception` 里，所以它引用一个已删除的变量时是**静默**的
        （只打一行「mapping failed」，People 名字从此不再进摘要）。必须两处都断言。
        """
        body = _function_source('routers/developer_listen.py', '_auto_process_conversation')
        self.assertIn('speaker_label = "User"', body)
        self.assertIn('label = "User"', body)
        self.assertNotIn('owner_name', body)

    def test_app_process_endpoint_builds_transcript_with_the_literal(self):
        body = _function_source('routers/developer_conversations.py', '_do_process_conversation')
        self.assertIn('speaker_label = "User"', body)
        self.assertNotIn('owner_name', body)

    def test_discard_restore_regenerates_with_the_literal(self):
        """声纹翻案后补 first_person_observation 的那次重出摘要，同样要用字面量。"""
        body = _function_source('routers/developer_conversations.py', '_revisit_user_dependent_verdicts')
        self.assertIn("'User' if seg.get('is_user')", body)
        self.assertNotIn('owner_name', body)

    def test_get_structured_does_not_thread_a_name_into_the_transcript(self):
        """`_get_structured` 是批量链路（reprocess / 音频上传 / SD 卡同步）的入口。

        它不该再有 `user_name` 参数——留着一个「必须永远传 None」的参数，
        下一个人只会把它接回去。
        """
        src = _read('utils/conversations/process_conversation.py')
        node = next(
            n for n in ast.walk(ast.parse(src))
            if isinstance(n, ast.FunctionDef) and n.name == '_get_structured'
        )
        self.assertNotIn(
            'user_name', [a.arg for a in node.args.args],
            "`_get_structured` 不该再接受 user_name——它只会被接回 get_transcript()",
        )
        body = ast.get_source_segment(src, node)
        self.assertIn('conversation.get_transcript(False, people=people)', body)

    def test_memory_extraction_still_gets_the_real_name(self):
        """反方向：记忆提取**必须**拿到真名，不能被这次修改顺手清掉。

        它的 prompt 插值 `{user_name}`，并用这个名字标记已经通过 `is_user` 门禁的
        本人证据。记忆正文写成 "The User has a young daughter" 就是这里断了。
        """
        body = _function_source('utils/llm/memories.py', 'new_memories_extractor')
        self.assertIn('get_prompt_memories(uid)', body)
        self.assertIn('user_name=user_name', body)

    def test_summarizer_prompt_still_matches_on_the_literal(self):
        """把「为什么必须是 User」这个前提本身钉住。

        如果哪天摘要 prompt 改成认真名了，这条会红——那时该做的是**一起**改标签，
        而不是把上面的断言删掉。
        """
        src = _read('utils/llm/conversation_processing.py')
        self.assertIn("""The user (labeled 'User')""", src)
        self.assertIn('The "User" label never appears in the transcript', src)


if __name__ == '__main__':
    unittest.main(verbosity=2)
