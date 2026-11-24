"""洞察卡的证据清洗与深读层（两层门控）不变式。

背景：2026-08-13 审计生产账本（Teague，82 条）时发现四类缺陷，它们的共同点是
**模型填的字段被当成了真值**：

  1. `conversation_id` 里躺着字面量「未知」（139 条原话证据里 5 条），而 App 只判
     `isNotEmpty` → 点进一个不存在的对话。
  2. `evidence.quote` 里放的是对话摘要（"讨论AI硬件团队与云资源及产品合作。"——
     第三人称书面语，是我们自己生成的 overview），不是用户原话。
  3. 一条 `skeptic_reason` 存成了 ANSI 转义 + 乱码。裁决本身解析正常所以没出卡，
     但 reason 是事后复盘唯一的审计线索。
  4. 数字张冠李戴：body 说「下午 4 点的沟通次数高达 43 次」，而它自己的 stat 写的是
     「周一 43 次」——`weekday_counts` 的数被当成了 `hour_counts` 的数。
  5. 怀疑者的 `revised_body` 被无条件采纳（同日又逮到两张卡）：它不打算改写时填的
     是评语而不是 null（"这段话可以保持现有表述…"），打算收紧措辞时又可能断在句子
     中间（"…你其实经常停下来问一句"）。两种都会成为用户唯一会读的那段正文。

前三类现在由 `_sanitize_evidence` / `_clean` 在**落库前**挡住（prompt 里也写了禁令，
但禁令挡不住概率，所以真值以代码为准）；第 4 类是语义问题，只能在 skeptic prompt
里加口径检查，这里断言那条规则还在 prompt 文本里没被后来的编辑弄丢。

同时钉住深读层（`depth`）的两条设计约束：
  - 它与主裁决**相互独立**：depth 被 drop 照样出卡，depth 动人也救不了假结论。
  - 它必须一路透传到 API 出口。这是本仓库反复踩的「两个各自正确的函数没接起来」
    ——单测清洗函数逮不到 router 忘了带这个字段。
"""

import ast
import os
import sys
import types
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)


def _stub_heavy_deps() -> None:
    """把 Firestore / LLM 两个模块换成空壳再 import 被测模块。

    被测的全是纯函数，但 `utils.insights.engine` 在模块级 import 了这两个。真 import
    会踩两个与本测试无关的坑：`database._client` 在 import 期就按 `.env` 的
    `GOOGLE_APPLICATION_CREDENTIALS` 落盘凭证（那个值是退役 EC2 的 Linux 路径，
    在 macOS 上 mkdir 直接 OSError），`utils.llm.clients` 则要建 LLM 客户端。
    """
    for name in ('database.developer_data', 'utils.llm.insight_engine'):
        if name in sys.modules:
            continue
        module = types.ModuleType(name)
        module.__getattr__ = lambda attr: (lambda *a, **kw: None)  # type: ignore[attr-defined]
        sys.modules[name] = module


_stub_heavy_deps()

from utils.insights.engine import (  # noqa: E402
    _BOGUS_IDS,
    _clean,
    _clean_depth,
    _clean_prose,
    _pick_revised,
    _sanitize_evidence,
)

REAL_CID = '3f9a1c2e-7b4d-4a11-9c8e-1d2f3a4b5c6d'
OTHER_CID = 'aa11bb22-cc33-4d44-8e55-ff66aa77bb88'

QUOTES = [
    {
        'text': '肯定不能打录音卡、录音笔这种标签，那个品类天花板太低了',
        'date': '2026-08-01',
        'weekday': '周六',
        'time': '14:30',
        'conversation_id': REAL_CID,
        'category': 'work',
    },
    {
        'text': '我还是觉得要先把合规这块想清楚，不然后面推不动',
        'date': '2026-08-04',
        'weekday': '周二',
        'time': '10:12',
        'conversation_id': OTHER_CID,
        'category': 'work',
    },
]

DIGEST = [
    {
        'date': '2026-08-05',
        'weekday': '周三',
        'time': '09:00',
        'title': 'AI硬件团队协作',
        'overview': '讨论AI硬件团队与云资源及产品合作。',
        'category': 'work',
        'conversation_id': OTHER_CID,
    },
]


class SanitizeEvidenceTest(unittest.TestCase):
    def test_quote_present_in_pool_is_kept(self):
        kept, dropped = _sanitize_evidence(
            [{'quote': QUOTES[0]['text'], 'conversation_id': REAL_CID, 'date': '2026-08-01'}],
            QUOTES, DIGEST,
        )
        self.assertEqual(dropped, [])
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0]['conversation_id'], REAL_CID)

    def test_fabricated_quote_is_dropped(self):
        """原话池里没有的句子不算证据——模型可以复述摘要，但不能凭空造引号里的话。"""
        kept, dropped = _sanitize_evidence(
            [{'quote': '我这辈子最怕的就是让家里人失望', 'conversation_id': REAL_CID}],
            QUOTES, DIGEST,
        )
        self.assertEqual(kept, [])
        self.assertEqual(len(dropped), 1)
        self.assertTrue(dropped[0].startswith('quote_not_in_transcript'))

    def test_digest_leaked_into_quote_is_labelled(self):
        """把 overview 当原话引用要能被认出来，且丢弃原因要区分于凭空编造。"""
        kept, dropped = _sanitize_evidence(
            [{'quote': '讨论AI硬件团队与云资源及产品合作。', 'conversation_id': OTHER_CID}],
            QUOTES, DIGEST,
        )
        self.assertEqual(kept, [])
        self.assertEqual(len(dropped), 1)
        self.assertTrue(dropped[0].startswith('digest_leaked_into_quote'), dropped)

    def test_partial_quote_still_matches(self):
        """模型常只引一句话的片段，或反过来把上下文一起带上——都不该判成伪造。"""
        kept, _ = _sanitize_evidence(
            [{'quote': '录音笔这种标签，那个品类天花板太低了'}], QUOTES, DIGEST,
        )
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0]['conversation_id'], REAL_CID)

    def test_punctuation_only_difference_still_matches(self):
        """补个句号、改全角半角是无害微调，逐字比对会把它误判成伪造。"""
        kept, dropped = _sanitize_evidence(
            [{'quote': '我还是觉得要先把合规这块想清楚, 不然后面推不动。'}], QUOTES, DIGEST,
        )
        self.assertEqual(dropped, [])
        self.assertEqual(len(kept), 1)

    def test_bogus_conversation_id_is_cleared(self):
        for bogus in ('未知', 'unknown', 'N/A', 'none'):
            with self.subTest(bogus=bogus):
                kept, _ = _sanitize_evidence(
                    [{'stat': '周五 67 段 / 周日 5 段', 'conversation_id': bogus}], QUOTES, DIGEST,
                )
                self.assertEqual(len(kept), 1)
                self.assertIsNone(kept[0]['conversation_id'])

    def test_unknown_conversation_id_is_cleared(self):
        """不在本轮取数范围里的 id 一律置空——它可能是模型自己拼的 UUID。"""
        kept, _ = _sanitize_evidence(
            [{'stat': '深夜 12 段', 'conversation_id': 'ffffffff-0000-0000-0000-000000000000'}],
            QUOTES, DIGEST,
        )
        self.assertIsNone(kept[0]['conversation_id'])

    def test_mismatched_conversation_id_is_overwritten_not_just_validated(self):
        """引对了话但配错了对话 id：校验会放过（id 真实存在），覆盖才能修掉。

        这是把 `_sanitize_evidence` 写成"以池里为准"而不是"校验后保留"的理由。
        """
        kept, dropped = _sanitize_evidence(
            [{'quote': QUOTES[0]['text'], 'conversation_id': OTHER_CID, 'date': '2026-07-01'}],
            QUOTES, DIGEST,
        )
        self.assertEqual(dropped, [])
        self.assertEqual(kept[0]['conversation_id'], REAL_CID)
        self.assertEqual(kept[0]['date'], '2026-08-01')

    def test_stat_only_evidence_survives_without_quote_check(self):
        """统计型洞察本来就没有原话，不能被原话核对连坐毙掉。"""
        kept, dropped = _sanitize_evidence(
            [{'stat': '周五 67 段 / 周日 5 段'}], QUOTES, DIGEST,
        )
        self.assertEqual(dropped, [])
        self.assertEqual(len(kept), 1)
        self.assertIsNone(kept[0]['quote'])

    def test_empty_evidence_item_is_skipped(self):
        kept, _ = _sanitize_evidence([{}, None, {'date': '2026-08-01'}], QUOTES, DIGEST)
        self.assertEqual(kept, [])


class CleanTextTest(unittest.TestCase):
    def test_ansi_and_control_chars_are_stripped(self):
        """生产上真出现过的形态：skeptic_reason 存成了终端控制码 + 乱码。"""
        dirty = '\x1a \x1b[0004m统计型洞察\x1b[33.86m \x1b[| 20m9W.D.*<-5m'
        cleaned = _clean(dirty)
        self.assertNotIn('\x1b', cleaned)
        self.assertNotIn('\x1a', cleaned)
        self.assertIn('统计型洞察', cleaned)

    def test_clean_collapses_whitespace(self):
        self.assertEqual(_clean('  a\n\n\n   b  '), 'a b')

    def test_clean_prose_keeps_paragraph_breaks(self):
        """depth 是给人读的散文，_clean 会把它压成一行——那个呼吸感是内容的一部分。"""
        out = _clean_prose('第一段。\n\n\n\n第二段。   \n')
        self.assertEqual(out, '第一段。\n\n第二段。')

    def test_clean_prose_strips_control_chars_too(self):
        self.assertNotIn('\x1b', _clean_prose('温度\x1b[31m还在'))


class PickRevisedTest(unittest.TestCase):
    """怀疑者的改写稿要过一道合理性检查才能顶掉提名者原文。

    两条形态都是 2026-08-13 真跑时从生产账本里逮到的（各一张卡）：怀疑者不打算
    改写时填的是评语而不是 null；打算收紧措辞时又可能断在句子中间。两种都会
    直接成为用户唯一会读的那段正文。
    """

    ORIGINAL = '讲技术方案的时候，你经常停下来问一句"我这么理解对吗"，像是随时准备承认自己也可能想错。'

    def test_meta_comment_falls_back_to_original(self):
        """真实形态：released 卡的正文变成了「这段话可以保持现有表述…」。"""
        for meta in (
            '这段话可以保持现有表述，因其内容与复现型证据相符，措辞已较为克制。',
            '建议保留原表述，证据充分。',
            '该洞察属于统计型，无需修改。',
        ):
            with self.subTest(meta=meta):
                self.assertEqual(
                    _pick_revised(meta, self.ORIGINAL, require_sentence_end=True), self.ORIGINAL)

    def test_truncated_revision_falls_back_to_original(self):
        """真实形态：'…你其实经常停下来问一句' —— 没有句末标点就落库了。"""
        self.assertEqual(
            _pick_revised('讲技术方案或细节的时候，你其实经常停下来问一句',
                          self.ORIGINAL, require_sentence_end=True),
            self.ORIGINAL,
        )

    def test_too_short_revision_falls_back(self):
        self.assertEqual(_pick_revised('你会自我确认。', self.ORIGINAL, require_sentence_end=True),
                         self.ORIGINAL)

    def test_genuine_revision_is_adopted(self):
        """收紧措辞是怀疑者的正当职责，不能因为变短就一律拒掉。"""
        tightened = '讲技术细节的时候，你经常停下来确认一句自己的理解对不对——不是不确定，更像是不愿假装全知。'
        self.assertEqual(
            _pick_revised(tightened, self.ORIGINAL, require_sentence_end=True), tightened)

    def test_headline_needs_no_sentence_end(self):
        """标题本来就不带句号，套用正文判据会把所有改写标题都拒掉。"""
        self.assertEqual(
            _pick_revised('你总在专家身份里悄悄确认自己', '原标题', require_sentence_end=False),
            '你总在专家身份里悄悄确认自己',
        )

    def test_empty_revision_falls_back(self):
        for empty in (None, '', '   ', '\n'):
            with self.subTest(empty=empty):
                self.assertEqual(
                    _pick_revised(empty, self.ORIGINAL, require_sentence_end=True), self.ORIGINAL)

    def test_multi_paragraph_depth_revision_survives(self):
        """深读段是多段散文，判定只看清洗后的结尾，不该被换行绊倒。"""
        prose = '你好像总在替别人兜着。\n\n我不确定这是习惯，还是别的什么。'
        self.assertEqual(_pick_revised(prose, '原文。', require_sentence_end=True), prose)


class DepthVerdictTest(unittest.TestCase):
    DEPTH = '你好像总在替别人兜着。\n\n我不确定这是习惯还是别的什么。'

    def test_keep_is_the_default_including_unknown_values(self):
        """未知取值按 keep 处理：这一层的失败模式是"少一段散文"，不是"发出错的结论"。"""
        for verdict in ({}, {'depth_verdict': 'keep'}, {'depth_verdict': 'weird-value'}):
            with self.subTest(verdict=verdict):
                self.assertIsNotNone(_clean_depth({'depth': self.DEPTH}, verdict))

    def test_drop_removes_the_prose(self):
        self.assertIsNone(_clean_depth({'depth': self.DEPTH}, {'depth_verdict': 'drop'}))

    def test_revise_prefers_the_rewritten_version(self):
        # 替身文本刻意写足长度：短于 _MIN_BODY_LEN 的"改写稿"会被 _pick_revised
        # 判成残句退回原文，而深读段本来就是一段 150~300 字的散文
        revised = '你替别人兜着的时候，从来不说自己累——我不确定那是体面，还是一种更安静的疲惫。'
        out = _clean_depth(
            {'depth': self.DEPTH},
            {'depth_verdict': 'revise', 'revised_depth': revised},
        )
        self.assertEqual(out, revised)

    def test_revise_without_replacement_falls_back_to_original(self):
        """判了 revise 却没给改写版时不能把整段吞掉——那等于静默降级成 drop。"""
        self.assertIsNotNone(_clean_depth({'depth': self.DEPTH}, {'depth_verdict': 'revise'}))

    def test_revise_with_meta_comment_falls_back_to_original(self):
        """改写稿是评语时同样要退回原段，而不是把评语当深读段发出去。"""
        out = _clean_depth(
            {'depth': self.DEPTH},
            {'depth_verdict': 'revise', 'revised_depth': '这段话可以保持现有表述，措辞已较为克制。'},
        )
        self.assertEqual(out, self.DEPTH)

    def test_missing_depth_is_none_not_empty_string(self):
        self.assertIsNone(_clean_depth({}, {'depth_verdict': 'keep'}))


class WiringTest(unittest.TestCase):
    """接线断言：清洗函数各自正确，但没接上流程就等于没做。"""

    @staticmethod
    def _source(rel_path: str) -> str:
        with open(os.path.join(BACKEND_DIR, rel_path)) as f:
            return f.read()

    def test_engine_sanitizes_before_persisting(self):
        src = self._source('utils/insights/engine.py')
        tree = ast.parse(src)
        run = next(
            node for node in ast.walk(tree)
            if isinstance(node, ast.FunctionDef) and node.name == 'run_insight_engine'
        )
        calls = {
            node.func.id for node in ast.walk(run)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
        }
        self.assertIn('_sanitize_evidence', calls, 'run_insight_engine 必须在落库前清洗证据')
        self.assertIn('_clean_depth', calls, 'run_insight_engine 必须裁决 depth')

    def test_passed_nomination_without_verifiable_evidence_is_demoted(self):
        """怀疑者可能是照着一条伪造的原话放行的，所以清洗后零证据不能相信那次 pass。"""
        src = self._source('utils/insights/engine.py')
        self.assertIn('evidence_unverifiable', src)
        self.assertIn('not evidence', src)

    def test_depth_reaches_the_api_surface(self):
        router = self._source('routers/developer_insights.py')
        self.assertIn("'depth': row.get('depth')", router,
                      '_to_card_out 必须带上 depth，否则字段落了库但客户端永远看不到')
        self.assertIn('depth: Optional[str]', router,
                      'InsightCardOut 必须声明 depth，否则 response_model 会把它过滤掉')

    def test_stored_bogus_ids_are_scrubbed_on_read(self):
        """存量账本里已经躺着 5 条「未知」，改代码不会回填，出口必须再挡一道。"""
        router = self._source('routers/developer_insights.py')
        self.assertIn('_sanitize_stored_evidence', router)
        self.assertIn("'evidence': _sanitize_stored_evidence(", router)

    def test_skeptic_prompt_keeps_the_hard_won_rules(self):
        """这几条规则各自对应一个生产缺陷，被后来的 prompt 编辑弄丢是静默的。

        ⚠️ 这只钉住**代码 fallback**。生产实际用的是 prompt registry 的
        production label（改代码对线上无效，见 utils/llm/prompt_registry.py），
        所以改 registry 时要一并改这里，否则本地/eval 与生产读到两份不同的
        prompt——而它们长得一样，看不出来。
        """
        src = self._source('utils/llm/insight_engine.py')
        # 问题 2：「符合人类常识」曾被当成 pass 的正面理由（卡片 busy-monday-friday-pattern）
        self.assertIn('符合人类常识', src)
        self.assertIn('随便换一个陌生人来', src)
        # 问题 4 后半：weekday_counts 的数被说成 hour_counts 的数
        self.assertIn('口径', src)
        # 问题 3：摘要被当原话引用
        self.assertIn('对话的标题或概述', src)
        # 问题 6：关系复现型不该被降级成单次事件
        self.assertIn('反复回到某个人', src)
        # depth 与主裁决独立
        self.assertIn('depth_verdict', src)

    def test_depth_spec_keeps_the_permission_not_prescription_rule(self):
        """「可以给许可，不可以开处方」是 depth 能有情绪指导又不变成教练的唯一判据。

        两边都必须有，少一边就静默回到原样：只写给提名者，怀疑者会把那句许可当说教
        改掉（它的红线里本来就写着"开处方"）；只写给怀疑者，则根本没人去写那句话。

        同理钉住篇幅——2026-08-13 用户反馈"深读段太短、没有深度"（当时写的是 150-300 字，
        模型贴着下限走），改成 400-600 字后 2026-08-20 又反馈"丰富度还是不够"，实测产出
        409/445 字，同样贴着下限。同时告诉怀疑者篇幅不是它的职责，否则加长的要求会与
        "审稿人默认怀疑"撞车。

        ⚠️ **必须逐段给下限，只给总字数不成立。** 400-600 字那一版的实际形态是第一段
        铺得最开、第二三段各两三句凑够总量——而第二段（往下走一层讲代价与张力）恰恰是
        唯一真的在思考的那段。所以下面同时钉住总量和三个分段下限。

        ⚠️ 与下面 skeptic 那条同样的告警：这只钉代码 fallback，生产读 registry。
        """
        src = self._source('utils/llm/insight_engine.py')
        self.assertIn('600-900 字', src, 'depth 篇幅要求被改回去了')
        for floor in ('第一段 ≥150 字', '第二段 ≥250 字', '第三段 ≥120 字'):
            self.assertIn(floor, src, f'{floor} 没了 —— 只给总字数时模型会压缩后两段')
        self.assertIn('至少两个不同的角度', src, '第二段少了"两个角度"的展开要求')
        self.assertIn('你可以给许可，不可以开处方', src, '提名者少了许可/处方的界线')
        self.assertIn('误判成处方', src, '怀疑者少了"别把许可误判成处方"的豁免')
        self.assertIn('篇幅和深度不是你的职责', src, '怀疑者会拿篇幅当红线')
        # 结构化输出的字段说明与 prompt 是两处独立入口，模型两处都会看到
        model_src = self._source('models/insight.py')
        self.assertIn('600-900 字', model_src, 'InsightNomination.depth 的 description 没跟上')
        self.assertIn('≥250 字', model_src, '字段说明里少了第二段的下限')

    def test_nominator_prompt_forbids_inventing_conversation_ids(self):
        src = self._source('utils/llm/insight_engine.py')
        self.assertIn('conversation_id', src)
        self.assertIn('留空是正确答案', src)

    def test_bogus_id_sets_match_between_backend_and_app(self):
        """两边各挡一道，但挡的必须是同一批词，否则一边放过的另一边照样跳。"""
        app_schema = os.path.join(
            os.path.dirname(BACKEND_DIR), 'app', 'lib', 'backend', 'schema', 'insight.dart')
        if not os.path.exists(app_schema):
            self.skipTest('app/ not present in this checkout')
        with open(app_schema) as f:
            dart = f.read()
        for token in _BOGUS_IDS:
            self.assertIn(f"'{token}'", dart, f'App 侧 _bogusConversationIds 缺少 {token!r}')


if __name__ == '__main__':
    unittest.main(verbosity=2)
