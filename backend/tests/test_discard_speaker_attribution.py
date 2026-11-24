"""「没有 User 标签 ⇒ 媒体播放」这个信号，只有在声纹真的跑过之后才成立。

这个判据已经赔过两次录音，两次都是同一个形状：判定跑在声纹**之前**，此时
`is_user` 结构上必然全 False（云端 STT 从不产出它），而 prompt 把这个零信息量的事实
当成「强媒体信号」。

  * 2026-08-15，手表上传路径：13 条上传里 11 条被判 discarded，含一条 39 分钟、
    8859 字的家庭对话。当时的修法只给离线路径传了 False，理由是「实时路径可以由声纹
    翻案救回」。
  * 2026-08-22，实时 listen 路径：那个理由不成立 —— 声纹覆盖率实测约 36%，多数误判
    等不到翻案。而这条路径**压根没传过这个参数**，吃的是默认值。8 天 112 条被丢弃的
    对话、79 条金标测下来：真实对话被误丢**约 80%**（4 次测量 77/79/81/83%，波动 4pp）。
  * 同一天还发现第三个调用点 `process_conversation`（reprocess / 上传 / SD 卡同步）用的是
    「按 source 推」——那同样是「路径将来会不会有」而不是「此刻有没有」。

所以这里钉三件事：
  1. 默认值必须是 False —— 它决定「将来新增的调用点忘记传」时落到哪一侧；
  2. 现有每个调用点都必须显式传，且不许硬编码、也不许按 source 推；
  3. 那个实参在各路径**真实的 segment 形态**上要真的能求值（见 TestTheExpressionActuallyEvaluates）。

判据是「此刻**是否已经有**归属信息」，不是「这条路径将来会不会有」。所以正确的实参是
从 segments 上真实读出来的（手动实时标注过说话人时为真），不是写死的布尔。
"""

import ast
import inspect
import os
import sys
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

try:
    from utils.llm.conversation_processing import should_discard_conversation
    _IMPORT_ERROR = None
except Exception as e:  # 缺依赖时不要变成假红
    _IMPORT_ERROR = e

_CALL_SITES = (
    'routers/developer_listen.py',
    'routers/developer_conversations.py',
    'utils/conversations/process_conversation.py',
)


def _read(rel):
    with open(os.path.join(BACKEND_DIR, rel), encoding='utf-8') as f:
        return f.read()


def _discard_calls(rel):
    """返回该文件里所有 should_discard_conversation(...) 调用节点。"""
    src = _read(rel)
    out = []
    for node in ast.walk(ast.parse(src)):
        if not isinstance(node, ast.Call):
            continue
        fn = node.func
        name = fn.id if isinstance(fn, ast.Name) else getattr(fn, 'attr', None)
        if name == 'should_discard_conversation':
            out.append((node, src))
    return out


@unittest.skipIf(_IMPORT_ERROR, f"import 失败: {_IMPORT_ERROR}")
class TestDefaultIsTheSafeSide(unittest.TestCase):
    def test_default_is_false(self):
        """默认值决定「漏传」落到哪一侧，必须落在保守保留那一侧。"""
        sig = inspect.signature(should_discard_conversation)
        default = sig.parameters['speaker_attribution_available'].default
        self.assertIs(
            default, False,
            'speaker_attribution_available 的默认值必须是 False：True 会把「没人被标成 '
            'User」这个零信息量的事实当成强媒体信号，实测让约 80% 的真实对话被丢弃',
        )


class TestEveryCallSitePassesItExplicitly(unittest.TestCase):
    def test_all_call_sites_pass_the_argument(self):
        total = 0
        for rel in _CALL_SITES:
            for node, src in _discard_calls(rel):
                total += 1
                kwargs = [kw.arg for kw in node.keywords]
                with self.subTest(site=f'{rel}:{node.lineno}'):
                    self.assertIn(
                        'speaker_attribution_available', kwargs,
                        f'{rel}:{node.lineno} 没有显式声明 speaker_attribution_available；'
                        f'吃默认值正是 listen 路径赔掉录音的方式',
                    )
        self.assertGreaterEqual(
            total, 3, '扫描器没找到预期的调用点 —— 断言失去意义，先修扫描器',
        )

    def test_live_paths_derive_it_from_segments_not_a_literal(self):
        """**每一个**调用点都必须从 segments 读，不能写死、也不能从 source 推。

        写死 True 就是这个缺陷本身；写死 False 也不对 —— 用户在录音过程中手动标注过
        说话人时，`is_user` 是真实的，那时的正面证据（「用户确实参与了」）不该被扔掉。
        按 `source` 推同样不行：那是「这条路径将来会不会有归属信息」，而需要的是「此刻
        有没有」。`process_conversation` 原本按 source 推，于是 reprocess 一条声纹没认出
        人的真实对话时，又一次把零信息量的信号当证据 —— 这条路径最初被本测试豁免了。
        """
        for rel in _CALL_SITES:
            calls = _discard_calls(rel)
            self.assertTrue(calls, f'{rel} 里找不到 should_discard_conversation 调用')
            for node, src in calls:
                expr = next((ast.get_source_segment(src, kw.value) for kw in node.keywords
                             if kw.arg == 'speaker_attribution_available'), None)
                with self.subTest(site=f'{rel}:{node.lineno}'):
                    self.assertIsNotNone(expr)
                    self.assertNotIn(
                        expr.strip(), ('True', 'False'),
                        f'{rel}:{node.lineno} 把它写成了字面量 {expr!r} —— 判据是「此刻是否'
                        f'已经有归属信息」，只能从 segments 上读出来',
                    )
                    self.assertIn(
                        'is_user', expr,
                        f'{rel}:{node.lineno} 的实参没有读 is_user，无法反映真实归属状态',
                    )


class TestTheExpressionActuallyEvaluates(unittest.TestCase):
    """光断言实参里出现了 `is_user` 是不够的 —— 那对**类型不匹配**结构上失明。

    第一版把 listen 那处写成了 `s.get('is_user')`，而 `discard_segments` 的元素是
    `type('Seg', (), {...})()` 造出来的**属性风格**对象，`.get` 根本不存在。后果不是
    报错退出：那一行在 `try` 里，AttributeError 被吞成「判定失败，保留」，于是丢弃判定
    整体静默失效、媒体再也不会被过滤。纯 AST 断言当时全绿。

    所以这里把实参表达式抓出来**真的求值**，喂两条路径真实的 segment 形态。
    """

    #: listen 用 `type('Seg', (), {...})()`；App process 用 Pydantic 的
    #: TranscriptSegment。两者都是属性风格 —— dict 式 `.get()` 对两者都错。
    @staticmethod
    def _attr_seg(is_user):
        return type('Seg', (), {'is_user': is_user, 'text': 'x'})()

    def _arg_expr(self, rel):
        for node, src in _discard_calls(rel):
            for kw in node.keywords:
                if kw.arg == 'speaker_attribution_available':
                    return ast.get_source_segment(src, kw.value)
        self.fail(f'{rel} 里没找到 speaker_attribution_available 实参')

    def _eval_with(self, expr, samples):
        """把 `for s in (<容器>)` 换成测试样本后求值。"""
        import re
        patched = re.sub(r'for s in \([^()]*(?:\([^()]*\))?[^()]*\)',
                         'for s in _SAMPLES', expr)
        self.assertIn('_SAMPLES', patched, f'替换容器失败: {expr!r}')
        return eval(patched, {'getattr': getattr, '_SAMPLES': samples})  # noqa: S307

    def test_live_path_expressions_work_on_attribute_style_segments(self):
        for rel in _CALL_SITES:
            expr = self._arg_expr(rel)
            with self.subTest(site=rel):
                # 有人被标成 User ⇒ 归属信息已经存在
                self.assertIs(
                    self._eval_with(expr, [self._attr_seg(False), self._attr_seg(True)]), True,
                    f'{rel}: 有 is_user 时必须为 True，否则会丢掉「用户确实参与了」这个正面证据',
                )
                # 没人被标 ⇒ 无法区分「没说话」和「声纹还没跑」⇒ 必须为 False
                self.assertIs(
                    self._eval_with(expr, [self._attr_seg(False), self._attr_seg(False)]), False,
                    f'{rel}: 无 is_user 时必须为 False，这正是那个零信息量信号要被压住的情形',
                )
                # 空列表也不能炸
                self.assertIs(self._eval_with(expr, []), False)


@unittest.skipIf(_IMPORT_ERROR, f"import 失败: {_IMPORT_ERROR}")
class TestSignalIsSuppressedWhenUnavailable(unittest.TestCase):
    """行为层：`speaker_attribution_available=False` 时，喂给模型的说话人分析必须
    **主动反驳**那条媒体信号，而不是只是沉默 —— 模板里那句断言留着不管，模型照旧照它办事。
    """

    def test_unavailable_branch_contradicts_the_prompt_bullet(self):
        src = inspect.getsource(should_discard_conversation)
        head = src.split('if not speaker_attribution_available:', 1)
        self.assertEqual(len(head), 2, '找不到 speaker_attribution_available 的分支')
        # 以下一个分支为界，而不是取固定字符数：实测这一支约 1100 字，写死 1200 只剩
        # ~100 字余量，往分支上方加两三行注释就会让断言失败，而失败信息会把人指向
        # 「分支没反驳 prompt」这个错误方向。
        branch = head[1].split('elif participation:', 1)[0]
        self.assertIn('NO information', branch,
                      '不可用分支必须明说这个信号零信息量')
        self.assertIn('MUST NOT', branch,
                      '必须明确禁止把它当媒体信号，只是不提等于放任模板里的断言生效')


if __name__ == '__main__':
    unittest.main(verbosity=2)
