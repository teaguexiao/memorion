"""事实与待办判重的不变式。

这里钉住的东西，每一条都对应一次实测走过的弯路（2026-08-17，生产数据）：

一、**判重必须是独立的一次调用。** 提取 prompt 早就写着 "Anything already known …
including rephrasings"，摘要 prompt 早就写着 "Merge duplicates"，两条都不生效——证据是
三条「孩子喜欢宝可梦卡牌」来自三条不同对话、串行写入、间隔 3 分钟，而每次提取都重查
Firestore，上下文里必然已有前一条。所以调用点存在本身就是不变式。

二、**两个写入点都必须接上。** 事实写入有两条路径（实时录音 / reprocess+上传+SD卡），
段来源不同、从不互相调用。这个模块的历史里漏接调用点已经害过一次：实时链路整条漏掉记忆
提取，`source='app'` 的 2900+ 条录音产出 0 条记忆，而单测全绿。

三、**两道门的高度必须不对称。** 判错 duplicate 只丢一条新候选，判错 supersedes 会软删
一条更丰富的真事实。只靠 prompt 的那一版在 141 条里判出 9 条 supersedes，其中 4 条是净
信息损失（`#139` 25 字取代 `#97` 37 字；`#74` 后端架构改动取代 `#38` 儿童硬件众筹计划）。

四、**待办不能跨对话判重，也不能靠向量护栏。** 跨对话（7 天窗口）丢 39 条只有 10/36 命中
金标，其余是误杀；而待办真重复对余弦 min 0.798 / median 0.873，误杀对 0.849~0.905，两个
分布完全重叠——文本模板化正是向量最无力的情形。所以待办改成组内判重 + 逐对复核。

五、**逐对复核必须 fail-closed。** 分组那一步系统性地把「同一话题下的多个条目」压成一
条；换成逐对提问后同一个模型对 15 个误杀对 15/15 判 TWO。复核挂掉时若 fail-open，等于把
这道唯一有效的防线让开。

真实产出的验证不在这里（要真调 LLM 和 embedding，CI 跑不了也花钱），在
`scripts/eval_dedupe_goldens.py`。
"""

import ast
import os
import sys
import unittest
from unittest import mock

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 必须在 import utils.* 之前：从 tests/ 直接跑时 sys.path[0] 是 tests/，少了这行
# 下面的 import 会以 "No module named 'utils'" 失败，然后被 skipIf 吞成绿灯。
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

_IMPORT_ERROR = None
try:
    from utils.llm import deduplication as dedupe
except Exception as e:  # pragma: no cover
    _IMPORT_ERROR = e


def _read(rel_path: str) -> str:
    with open(os.path.join(BACKEND_DIR, rel_path), 'r', encoding='utf-8') as f:
        return f.read()


def _function_source(rel_path: str, func_name: str) -> str:
    src = _read(rel_path)
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            return ast.get_source_segment(src, node)
    raise AssertionError(f"{rel_path} 里找不到函数 {func_name}")


# ─── 调用点：判重是独立一步，且每条写入路径都接上了 ───


class TestFactDedupeIsWired(unittest.TestCase):
    """三个事实写入点都必须走判重。漏一个的后果见模块 docstring 第二条。

    ⚠️ `_extract_memories` 只以 `threading.Thread(target=...)` 的形式被调用（SD 卡同步
    走它），所以 grep `_extract_memories(` 找不到调用者、看起来像死代码 —— 接判重时就
    是这么漏掉的。这条测试存在的一半理由就是别再漏第二次。
    """

    WRITE_PATHS = (
        '_extract_memories',              # SD 卡同步（routers/sync.py → process_conversation）
        '_extract_memories_developer',    # reprocess / 音频上传
        'extract_memories_from_segments', # 实时录音
    )

    def test_all_fact_write_paths_dedupe(self):
        for func in self.WRITE_PATHS:
            body = _function_source('utils/conversations/process_conversation.py', func)
            self.assertIn(
                '_dedupe_against_stored_facts(', body,
                f"{func} 没有走判重——它是三条独立的写入路径之一，漏掉就是残缺的功能",
            )

    def test_scanner_actually_found_the_functions(self):
        """防止「函数改名了 ⇒ 上面那条断言变成同义反复」。"""
        self.assertEqual(len(self.WRITE_PATHS), 3)
        for func in self.WRITE_PATHS:
            self.assertTrue(_function_source('utils/conversations/process_conversation.py', func))

    def test_thread_launched_path_is_still_reachable(self):
        """`_extract_memories` 是通过线程启动的。哪天它真的没人调了，这条会提醒去掉
        上面那个 WRITE_PATHS 条目，而不是留一条永远为真的断言。"""
        src = _read('utils/conversations/process_conversation.py')
        self.assertIn('target=_extract_memories,', src)

    def test_superseded_facts_are_retired_after_the_new_ones_land(self):
        """顺序不能反：先软删旧的、写新的时失败，用户那条记忆就凭空消失了。"""
        # 两种写法：create_memory 逐条写，save_memories_batch 批量写。
        writers = ('dev_db.create_memory(', 'dev_db.save_memories_batch(')
        for func in self.WRITE_PATHS:
            body = _function_source('utils/conversations/process_conversation.py', func)
            self.assertIn('_retire_superseded_facts(', body)
            write_at = min(body.index(w) for w in writers if w in body)
            self.assertLess(
                write_at,
                body.index('_retire_superseded_facts('),
                f"{func}：软删旧事实必须排在写入新事实之后",
            )

    def test_retirement_is_a_soft_delete(self):
        """必须软删（可整批翻回来），不能用 delete_memory 的硬删。"""
        body = _function_source('utils/conversations/process_conversation.py', '_retire_superseded_facts')
        self.assertIn('soft_delete_memories(', body)
        self.assertNotIn('delete_memory(', body)


class TestActionItemDedupeIsWired(unittest.TestCase):
    """待办判重的两条路径：listen（写库后回写）和 reprocess/上传/SD卡（就地改内存）。"""

    def test_listen_path_dedupes_after_the_gate(self):
        body = _function_source('routers/developer_conversations.py', '_identify_speakers_then_emit_eir')
        self.assertIn('_apply_action_item_dedupe(', body)
        self.assertLess(
            body.index('_apply_action_item_gate('),
            body.index('_apply_action_item_dedupe('),
            "判重必须排在门禁之后：被门禁清空的对话没有待办可判，早跑就是白花一次 LLM 调用",
        )

    def test_reprocess_path_dedupes(self):
        src = _read('utils/conversations/process_conversation.py')
        self.assertGreaterEqual(
            src.count('dedupe_action_items_in_place('), 3,
            "两个调用点 + 一个定义；少了就是某条路径没接上",
        )

    def test_listen_path_uses_the_batch_remove(self):
        """按下标逐个删会漂移：删掉第 1 条之后原来的第 3 条变成第 2 条。"""
        body = _function_source('routers/developer_conversations.py', '_apply_action_item_dedupe')
        self.assertIn('remove_action_items(', body)
        self.assertNotIn('delete_action_item(', body)


# ─── 不对称：两道门的高度 ───


@unittest.skipIf(_IMPORT_ERROR, f"import 失败: {_IMPORT_ERROR}")
class TestAsymmetricThresholds(unittest.TestCase):
    def test_supersede_gate_is_stricter_than_duplicate_gate(self):
        """删已有事实比丢新候选危险，所以门槛必须更高。见模块 docstring 第三条。"""
        self.assertGreater(dedupe._SUPERSEDE_MIN_COSINE, dedupe._DUPLICATE_MIN_COSINE)

    def test_supersede_gate_clears_the_observed_misjudgements(self):
        """实测那批净信息损失的取代，余弦最高 0.891（`#139`×`#84`）——门槛必须在它之上。"""
        self.assertGreater(dedupe._SUPERSEDE_MIN_COSINE, 0.891)

    def test_duplicate_gate_admits_real_restatements(self):
        """真重复对余弦下界 0.851，门槛不能高过它，否则这层判重整个失效。"""
        self.assertLessEqual(dedupe._DUPLICATE_MIN_COSINE, 0.851)


# ─── 降级行为 ───


@unittest.skipIf(_IMPORT_ERROR, f"import 失败: {_IMPORT_ERROR}")
class TestFactDedupeDegradation(unittest.TestCase):
    EXISTING = [{'id': 'm1', 'content': '你住在上海宝山。'}]

    def _with_verdict(self, verdict, sims):
        """把 LLM 与 embedding 都换成固定答案，只测判决逻辑。"""
        payload = f'{{"verdicts":[{{"candidate":"C1","verdict":"{verdict}","existing":["E1"]}}]}}'
        return mock.patch.object(
            dedupe, 'get_prompt',
            return_value=mock.Mock(
                content='x', config={}, render=mock.Mock(return_value='p'),
            ),
        ), mock.patch.object(
            dedupe, 'resolve_llm',
            return_value=mock.Mock(invoke=mock.Mock(return_value=payload)),
        ), mock.patch.object(dedupe, '_pair_similarities', return_value=sims)

    def _run(self, verdict, sims, candidate='你在上海宝山住。'):
        p1, p2, p3 = self._with_verdict(verdict, sims)
        with p1, p2, p3:
            return dedupe.resolve_fact_duplicates([candidate], self.EXISTING)

    def test_duplicate_above_gate_is_dropped(self):
        r = self._run('duplicate', {0: 0.97})
        self.assertEqual(r.kept_indexes, [])
        self.assertEqual(r.superseded_ids, [])

    def test_duplicate_below_gate_is_kept(self):
        r = self._run('duplicate', {0: 0.70})
        self.assertEqual(r.kept_indexes, [0])

    def test_supersedes_above_gate_retires_the_old_fact(self):
        r = self._run('supersedes', {0: 0.95})
        self.assertEqual(r.kept_indexes, [0])
        self.assertEqual(r.superseded_ids, ['m1'])

    def test_supersedes_just_below_gate_keeps_both(self):
        """0.903 是实测里一个**正确**的取代，仍被拦下——这是刻意选的保守方向：
        宁可让用户多看到一条相似的事实，也不要静默删掉他真实的记忆。"""
        r = self._run('supersedes', {0: 0.903})
        self.assertEqual(r.kept_indexes, [0])
        self.assertEqual(r.superseded_ids, [])

    def test_no_vector_check_still_drops_duplicates(self):
        """embedding 挂掉时 duplicate 照旧生效——它只丢新候选，不动已有数据。"""
        r = self._run('duplicate', None)
        self.assertEqual(r.kept_indexes, [])

    def test_no_vector_check_never_retires_anything(self):
        """没有复核就不许删已有事实。"""
        r = self._run('supersedes', None)
        self.assertEqual(r.kept_indexes, [0])
        self.assertEqual(r.superseded_ids, [])

    def test_verdict_without_a_target_keeps_the_candidate(self):
        """「说是重复但指不出重复了哪一条」更像是没答完整，不足以丢掉一条事实。"""
        payload = '{"verdicts":[{"candidate":"C1","verdict":"duplicate","existing":[]}]}'
        with mock.patch.object(
            dedupe, 'get_prompt',
            return_value=mock.Mock(content='x', config={}, render=mock.Mock(return_value='p')),
        ), mock.patch.object(
            dedupe, 'resolve_llm',
            return_value=mock.Mock(invoke=mock.Mock(return_value=payload)),
        ):
            r = dedupe.resolve_fact_duplicates(['随便一条'], self.EXISTING)
        self.assertEqual(r.kept_indexes, [0])

    def test_llm_failure_keeps_every_candidate(self):
        """fail-open：判重是质量改进，不是安全门禁。丢掉真事实的代价更高。"""
        with mock.patch.object(dedupe, 'get_prompt', side_effect=RuntimeError('boom')):
            r = dedupe.resolve_fact_duplicates(['a', 'b'], self.EXISTING)
        self.assertEqual(r.kept_indexes, [0, 1])
        self.assertEqual(r.superseded_ids, [])

    def test_no_existing_facts_keeps_everything_without_calling_the_llm(self):
        with mock.patch.object(dedupe, 'get_prompt', side_effect=AssertionError('不该调用')):
            r = dedupe.resolve_fact_duplicates(['a'], [])
        self.assertEqual(r.kept_indexes, [0])


@unittest.skipIf(_IMPORT_ERROR, f"import 失败: {_IMPORT_ERROR}")
class TestActionItemDedupeDegradation(unittest.TestCase):
    ITEMS = ['给孩子报名下周六的游泳课', '下周六的游泳课要给孩子报上名', '周日陪孩子去公园']

    def _grouped(self, confirm):
        payload = '{"groups":[{"keep":"C2","drop":["C1"]}]}'
        return (
            mock.patch.object(
                dedupe, 'get_prompt',
                return_value=mock.Mock(content='x', config={}, render=mock.Mock(return_value='p')),
            ),
            mock.patch.object(
                dedupe, 'resolve_llm',
                return_value=mock.Mock(invoke=mock.Mock(return_value=payload)),
            ),
            mock.patch.object(dedupe, '_confirm_same_commitment', return_value=confirm),
        )

    def test_confirmed_pair_is_dropped(self):
        p1, p2, p3 = self._grouped(True)
        with p1, p2, p3:
            self.assertEqual(dedupe.resolve_action_item_duplicates(self.ITEMS), [0])

    def test_unconfirmed_pair_is_kept(self):
        """复核否掉就不删——这是唯一挡住「按话题聚合」的防线。"""
        p1, p2, p3 = self._grouped(False)
        with p1, p2, p3:
            self.assertEqual(dedupe.resolve_action_item_duplicates(self.ITEMS), [])

    def test_pair_check_failure_keeps_both(self):
        """fail-closed：复核挂掉时当作「不是同一件事」。"""
        with mock.patch.object(dedupe, 'get_prompt', side_effect=RuntimeError('boom')):
            self.assertFalse(dedupe._confirm_same_commitment('a', 'b'))

    def test_pair_check_prefers_two_when_the_answer_is_muddled(self):
        """模型回一整句时，只要里面出现 TWO 就保留——保留是安全方向。"""
        for answer in ('TWO', 'two', 'The answer is TWO because…', 'ONE or TWO? TWO.'):
            with mock.patch.object(
                dedupe, 'get_prompt',
                return_value=mock.Mock(content='x', config={}, render=mock.Mock(return_value='p')),
            ), mock.patch.object(
                dedupe, 'resolve_llm',
                return_value=mock.Mock(invoke=mock.Mock(return_value=answer)),
            ):
                self.assertFalse(dedupe._confirm_same_commitment('a', 'b'), answer)

    def test_unparseable_pair_check_keeps_both(self):
        with mock.patch.object(
            dedupe, 'get_prompt',
            return_value=mock.Mock(content='x', config={}, render=mock.Mock(return_value='p')),
        ), mock.patch.object(
            dedupe, 'resolve_llm',
            return_value=mock.Mock(invoke=mock.Mock(return_value='maybe?')),
        ):
            self.assertFalse(dedupe._confirm_same_commitment('a', 'b'))

    def test_single_item_never_calls_the_llm(self):
        with mock.patch.object(dedupe, 'get_prompt', side_effect=AssertionError('不该调用')):
            self.assertEqual(dedupe.resolve_action_item_duplicates(['只有一条']), [])

    def test_never_drops_every_item(self):
        """把一条对话的待办丢空 ⇒ 全留更安全。

        单个分组丢不空（keep 自己被排除），能丢空的是**互相矛盾的两个分组**：
        「留 C1 丢 C2」和「留 C2 丢 C1」同时出现，两条都进 drop。
        """
        payload = '{"groups":[{"keep":"C1","drop":["C2"]},{"keep":"C2","drop":["C1"]}]}'
        with mock.patch.object(
            dedupe, 'get_prompt',
            return_value=mock.Mock(content='x', config={}, render=mock.Mock(return_value='p')),
        ), mock.patch.object(
            dedupe, 'resolve_llm',
            return_value=mock.Mock(invoke=mock.Mock(return_value=payload)),
        ), mock.patch.object(dedupe, '_confirm_same_commitment', return_value=True):
            self.assertEqual(dedupe.resolve_action_item_duplicates(['a', 'b']), [])

    def test_signature_takes_no_history(self):
        """待办刻意**不**跨对话判重——跨对话贡献 5/18 收益却带来几乎全部误杀。
        参数没有 existing 不是漏了，是结论；别顺手加回来。"""
        import inspect

        params = list(inspect.signature(dedupe.resolve_action_item_duplicates).parameters)
        self.assertEqual(params, ['candidate_descriptions'])


if __name__ == '__main__':
    unittest.main()
