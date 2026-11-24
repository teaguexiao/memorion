"""WS 兜底路径判 discard 时，必须仍然建出对话。

存在的理由：`is_user` 只由声纹匹配产出，而声纹跑在**对话建出来之后**的后台线程里。
所以 `_auto_process_conversation` 一旦在 discard 判定处 `return`，这条路径的 discard
就变成**不可恢复**的——没有对话 → 声纹不跑 → `_revisit_user_dependent_verdicts`
永远没有机会翻案 → transcript 压根没落库。

当声纹误标导致 `is_user` 全为 False 时，discard prompt 可能误判为媒体播放。

对比路径 2（`POST /v1/conversations/process`）一直是对的：先建对话，再把判定交给
`finish_conversation(discarded=...)`。App 本来就会过滤掉 discarded，所以误判的代价
是「多一条隐藏记录」而不是「录音没了」。

用 AST 而不是 import：`developer_listen` 依赖 opuslib / deepgram 等原生包，本地 venv
常装不全，import 断言会退化成环境问题而不是回归信号（同
`test_realtime_memory_extraction.py`）。
"""

import ast
import os
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _read(rel_path: str) -> str:
    with open(os.path.join(BACKEND_DIR, rel_path), encoding='utf-8') as f:
        return f.read()


def _function_node(rel_path: str, func_name: str) -> ast.FunctionDef:
    tree = ast.parse(_read(rel_path))
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            return node
    raise AssertionError(f"{rel_path} 里找不到函数 {func_name}")


def _function_source(rel_path: str, func_name: str) -> str:
    src = _read(rel_path)
    node = _function_node(rel_path, func_name)
    return ast.get_source_segment(src, node)


LISTEN = 'routers/developer_listen.py'
AUTO_PROCESS = '_auto_process_conversation'


class TestListenDiscardStillCreatesConversation(unittest.TestCase):
    def test_discard_verdict_does_not_return_early(self):
        """判定为 discard 不能直接 return —— 这正是丢录音的那行代码。

        断言方式刻意选「discard 判定与 create_conversation 之间没有裸 return」，而不是
        字符串比对某句注释：注释会改，控制流才是缺陷本身。
        """
        node = _function_node(LISTEN, AUTO_PROCESS)
        src = _read(LISTEN)

        call_line = None
        for sub in ast.walk(node):
            if (
                isinstance(sub, ast.Call)
                and getattr(sub.func, 'id', None) == 'should_discard_conversation'
            ):
                call_line = sub.lineno
                break
        self.assertIsNotNone(call_line, '找不到 should_discard_conversation 调用')

        create_line = None
        for sub in ast.walk(node):
            if isinstance(sub, ast.Call):
                func = sub.func
                if isinstance(func, ast.Attribute) and func.attr == 'create_conversation':
                    create_line = sub.lineno
                    break
        self.assertIsNotNone(create_line, '找不到 dev_db.create_conversation 调用')
        self.assertLess(call_line, create_line, 'discard 判定应当发生在建对话之前')

        # 这两行之间任何一个 return 都会让 discard 重新变成「不建对话」。
        offenders = [
            sub.lineno
            for sub in ast.walk(node)
            if isinstance(sub, ast.Return) and call_line <= sub.lineno < create_line
        ]
        self.assertEqual(
            offenders,
            [],
            "discard 判定与 create_conversation 之间不能有 return："
            f"第 {offenders} 行会让被误判的录音永久丢失（声纹线程跑在建对话之后，"
            "没有对话就永远无法翻案）。改成 finish_conversation(discarded=...)，"
            f"参见 {LISTEN}:{call_line} 附近的注释。\n"
            f"上下文：\n" + '\n'.join(src.splitlines()[call_line - 1:create_line])
        )

    def test_verdict_is_passed_to_finish_conversation(self):
        """判定必须落到 finish_conversation(discarded=...)，否则误判会变成「可见」。"""
        node = _function_node(LISTEN, AUTO_PROCESS)
        for sub in ast.walk(node):
            if isinstance(sub, ast.Call):
                func = sub.func
                if isinstance(func, ast.Attribute) and func.attr == 'finish_conversation':
                    kwargs = {kw.arg for kw in sub.keywords}
                    self.assertIn(
                        'discarded',
                        kwargs,
                        'finish_conversation 必须显式传 discarded，否则被判 media 的对话会照常显示',
                    )
                    return
        self.fail('找不到 dev_db.finish_conversation 调用')

    def test_speech_profile_thread_is_not_gated_on_verdict(self):
        """声纹线程不能被 discard 守卫圈住 —— 它是唯一的翻案机会。"""
        body = _function_source(LISTEN, AUTO_PROCESS)
        start = body.index('def _speech_profile_matching_background')
        guard = 'if not should_discard:'
        # 守卫可以出现在记忆提取处，但不能出现在声纹线程之前并把它包进去。
        self.assertIn('_revisit_user_dependent_verdicts', body[start:],
                      '声纹线程必须调用 _revisit_user_dependent_verdicts 来翻案')
        thread_start = body.index('threading.Thread(target=_speech_profile_matching_background)')
        preceding_guard = body.rfind(guard, 0, start)
        if preceding_guard != -1:
            # 若守卫在声纹线程定义之前出现，确认线程启动语句没有被缩进进该守卫块。
            line = body[:thread_start].splitlines()[-1] if body[:thread_start].splitlines() else ''
            self.assertFalse(
                line.startswith('        ') and preceding_guard > body.index('def _extract_memories_background'),
                '声纹线程不能放在 should_discard 守卫内',
            )

    def test_discarded_conversation_withholds_subtitle(self):
        """discarded 时不写 observation/highlights，和路径 2 保持一致。"""
        node = _function_node(LISTEN, AUTO_PROCESS)
        src = _read(LISTEN)
        for sub in ast.walk(node):
            if isinstance(sub, ast.Call):
                func = sub.func
                if isinstance(func, ast.Attribute) and func.attr == 'finish_conversation':
                    by_kw = {kw.arg: ast.get_source_segment(src, kw.value) for kw in sub.keywords}
                    for field in ('first_person_observation', 'highlights'):
                        self.assertIn(field, by_kw)
                        self.assertIn(
                            'should_discard', by_kw[field],
                            f'{field} 应当在 discarded 时置空（形如 None if should_discard else ...）',
                        )
                    return
        self.fail('找不到 dev_db.finish_conversation 调用')

    def test_memory_extraction_is_gated_on_verdict(self):
        """被判 media 的对话不该污染用户画像（与路径 2 同形）。

        ⚠️ 这个测试原本断言的是源码字面量 ``if not should_discard:``，而守卫后来搬进了
        ``_extract_memories_after_voiceprint`` 并改成读 revisit 之后的 ``discarded``
        —— 行为不但没坏，还严格变好了（被误判成媒体播放、后来被声纹翻案的对话现在也能
        产出记忆）。于是这个测试从「守卫在不在」变成了「守卫长什么样」，红了很久而且红
        得毫无信息量。判据改成守卫必须存在、且必须挡在提取调用之前，不再关心它写在哪个
        函数里、读的是哪个变量名。
        """
        body = _function_source(LISTEN, AUTO_PROCESS)
        extractor = body.split('def _extract_memories_after_voiceprint')
        self.assertEqual(len(extractor), 2, '找不到声纹后的记忆提取函数')
        head = extractor[1]
        call = 'extract_memories_from_segments('
        self.assertIn(call, head)
        guard_zone = head[: head.index(call)]
        self.assertRegex(
            guard_zone, r"if\s+(not\s+should_discard|conv\.get\('discarded'\))",
            '记忆提取必须挡在 discard 判定之后',
        )
        self.assertIn('return', guard_zone, '守卫必须真的早退，不能只是记一行日志')


if __name__ == '__main__':
    unittest.main(verbosity=2)
