"""Source-grounded chapter summaries: no truncation, bounded batches, complete fallback."""

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")

from utils.timeline import rollup  # noqa: E402
from utils.llm.prompt_registry import ResolvedPrompt
from utils.timeline.rollup import (  # noqa: E402
    DEFAULT_EMOJI,
    MAX_FRAGMENT_BLOCK_CHARS,
    MAX_TITLE_CHARS,
    ChapterRollup,
    render_fragments,
    sanitize_emoji,
    summarize_chapter,
)


def frag(title, overview='', observation=''):
    return {'title': title, 'overview': overview, 'first_person_observation': observation, 'emoji': '🧠'}


def setUpModule():
    global _grounding_patch
    # Provider-facing factual review has its own request/JSON contract tests.
    _grounding_patch = mock.patch.object(rollup, 'ground_rollup', side_effect=lambda evidence, draft, resolved, **kw: draft)
    _grounding_patch.start()


def tearDownModule():
    _grounding_patch.stop()


class RenderSourceTests(unittest.TestCase):
    def test_many_fragments_keep_all_details_including_the_tail(self):
        fragments = [frag(f'title{i}', 'o' * 2000 + f' DETAIL_{i}') for i in range(20)]
        rendered = render_fragments(fragments)
        for i in range(20):
            self.assertIn(f'DETAIL_{i}', rendered)
        self.assertIn('o' * 2000, rendered)

    def test_oversized_input_is_batched_without_losing_any_text(self):
        rendered = render_fragments([frag('big', 'x' * 100000 + ' LAST_DETAIL'), frag('small', 'y')])
        batches = rollup._source_batches(rendered)
        self.assertGreater(len(batches), 1)
        self.assertTrue(all(len(batch) <= MAX_FRAGMENT_BLOCK_CHARS for batch in batches))
        self.assertEqual(''.join(batches), rendered)

    def test_transcript_wins_over_a_misleading_previous_summary(self):
        rendered = render_fragments([dict(frag('Old conclusion', 'Budget 73, launch approved'),
                                         source_text='Budget 37. No launch approved.')])
        self.assertIn('Budget 37', rendered)
        self.assertNotIn('73', rendered)
        self.assertNotIn('Old conclusion', rendered)



class SingleFragmentTests(unittest.TestCase):
    def test_single_fragment_reuses_without_llm(self):
        """单条独占一章:复用原 structured,LLM 一次都不调。"""
        with mock.patch.object(rollup, 'get_prompt') as gp, mock.patch.object(rollup, 'resolve_llm') as rl:
            out = summarize_chapter([frag('Solo', 'the whole overview', 'nice one')])
            gp.assert_not_called()
            rl.assert_not_called()
        self.assertEqual(out['title'], 'Solo')
        self.assertEqual(out['overview'], 'the whole overview')
        self.assertFalse(out['rollup'])

    def test_empty_input_returns_none(self):
        self.assertIsNone(summarize_chapter([]))
        self.assertIsNone(summarize_chapter([{'title': '', 'overview': ''}]))


class RollupTests(unittest.TestCase):
    def _mock_llm(self, result):
        structured = mock.Mock()
        structured.invoke.return_value = result
        llm = mock.Mock()
        llm.with_structured_output.return_value = structured
        return llm

    def test_multi_fragment_calls_llm_and_returns_rollup(self):
        """多条:调一次 LLM,返回归纳结果,rollup=True。"""
        result = ChapterRollup(title='上午的客户沟通与模型调试', overview='merged', emoji='💼', first_person_observation='')
        llm = self._mock_llm(result)
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})), \
             mock.patch.object(rollup, 'resolve_llm', return_value=llm):
            out = summarize_chapter([frag('A', 'oa'), frag('B', 'ob')], language_hint='用中文')
        self.assertEqual(out['title'], '上午的客户沟通与模型调试')
        self.assertTrue(out['rollup'])
        llm.with_structured_output.assert_called_once_with(ChapterRollup)

    def test_llm_failure_degrades_to_first_fragment(self):
        """LLM 抛异常 → 兜底成第一条碎片的摘要,标 rollup='failed',不能整章没标题。"""
        llm = mock.Mock()
        llm.with_structured_output.side_effect = RuntimeError('boom')
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})), \
             mock.patch.object(rollup, 'resolve_llm', return_value=llm):
            out = summarize_chapter([frag('First', 'first overview'), frag('Second', 'second')])
        self.assertEqual(out['title'], 'First')
        self.assertEqual(out['rollup'], 'failed')

    def test_empty_title_from_llm_degrades(self):
        """LLM 返回空标题也算失败,兜底到第一条。"""
        llm = self._mock_llm(ChapterRollup(title='   ', overview='x'))
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})), \
             mock.patch.object(rollup, 'resolve_llm', return_value=llm):
            out = summarize_chapter([frag('First', 'fo'), frag('Second', 'so')])
        self.assertEqual(out['title'], 'First')
        self.assertEqual(out['rollup'], 'failed')


class FieldBleedTests(unittest.TestCase):
    """`llm_mini` 会把邻近字段漏进 emoji / title —— 真跑时 8 章里 3 章中招。

    这不是防御性编程：`emoji` 直接原样渲染在 App 首页卡片上，收到一整段 overview
    就是肉眼可见的坏显示，而 `response_model` 拦不住（类型确实是 str）。
    实测到的三个坏值：`);`、`{\"180加30等于多少`、以及整段正文。
    """

    def test_prose_and_junk_emoji_fall_back(self):
        for bad in (');', '{"180加30等于多少', '模块可以去掉。随后话题转向声纹识别技术，你指出当前准确率',
                    '', '   ', None, 123, 'ok'):
            with self.subTest(value=bad):
                self.assertEqual(sanitize_emoji(bad), DEFAULT_EMOJI)

    def test_real_emoji_survives(self):
        """含 ZWJ 的家庭 emoji 与变体选择符都不能被误杀。"""
        for good in ('🧠', '🃏', '📊', '👨‍👩‍👧‍👦', '⚠️', '🚄'):
            with self.subTest(value=good):
                self.assertEqual(sanitize_emoji(good), good)

    def test_llm_emoji_is_sanitized_in_rollup(self):
        llm = mock.Mock()
        structured = mock.Mock()
        structured.invoke.return_value = ChapterRollup(title='正常标题', overview='o', emoji=');')
        llm.with_structured_output.return_value = structured
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})), \
             mock.patch.object(rollup, 'resolve_llm', return_value=llm):
            out = summarize_chapter([frag('A', 'oa'), frag('B', 'ob')])
        self.assertEqual(out['emoji'], DEFAULT_EMOJI)
        self.assertEqual(out['title'], '正常标题')

    def test_reused_fragment_emoji_is_sanitized(self):
        """复用单碎片时也要过滤 —— 碎片自己的 emoji 也是 LLM 生成的。"""
        out = summarize_chapter([frag('Solo', 'o') | {'emoji': 'not an emoji at all'}])
        self.assertEqual(out['emoji'], DEFAULT_EMOJI)

    def test_paragraph_title_degrades_to_fragment_title(self):
        """title 长成一整段 = overview 漏进来了 → 兜底成第一条碎片的标题。"""
        llm = mock.Mock()
        structured = mock.Mock()
        structured.invoke.return_value = ChapterRollup(
            title='正' * (MAX_TITLE_CHARS + 1), overview='o', emoji='🧠')
        llm.with_structured_output.return_value = structured
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})), \
             mock.patch.object(rollup, 'resolve_llm', return_value=llm):
            out = summarize_chapter([frag('First', 'fo'), frag('Second', 'so')])
        self.assertEqual(out['title'], 'First')
        self.assertEqual(out['rollup'], 'failed')

    def test_normal_length_title_passes(self):
        llm = mock.Mock()
        structured = mock.Mock()
        structured.invoke.return_value = ChapterRollup(
            title='Agent开发生命周期中的评估体系建设', overview='o', emoji='🔍')
        llm.with_structured_output.return_value = structured
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})), \
             mock.patch.object(rollup, 'resolve_llm', return_value=llm):
            out = summarize_chapter([frag('A', 'oa'), frag('B', 'ob')])
        self.assertEqual(out['title'], 'Agent开发生命周期中的评估体系建设')
        self.assertTrue(out['rollup'])


class MediaChapterTests(unittest.TestCase):
    """SUMMARY_POLICY 让模型对广播/噪声返回 `[Media Recording]` + 空正文，App 据此隐藏。

    以前空正文被当成失败 ⇒ 兜底成整条录音的标题 + 原始转录：一段 3 小时的航班录音
    在首页冒出三张同名的「飞往深圳，慢慢安顿下来」（2026-10-31）。
    """

    def _summarize(self, fragments, invoke):
        structured = mock.Mock()
        structured.invoke.side_effect = invoke
        llm = mock.Mock()
        llm.with_structured_output.return_value = structured
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})), \
             mock.patch.object(rollup, 'resolve_llm', return_value=llm):
            return summarize_chapter(fragments)

    def test_media_with_empty_overview_is_a_hidden_chapter_not_a_failure(self):
        for title in ('[Media Recording]', 'Media Recording', ' [media recording] '):
            with self.subTest(title=title):
                out = self._summarize([frag('飞往深圳', 'oa'), frag('B', 'ob')],
                                      lambda *a, **k: ChapterRollup(title=title, overview='', emoji='✈️'))
                self.assertEqual(out['title'], '[Media Recording]')
                self.assertEqual(out['overview'], '')
                self.assertIs(out['rollup'], True)

    def test_empty_overview_without_media_title_still_fails(self):
        out = self._summarize([frag('First', 'fo'), frag('Second', 'so')],
                              lambda *a, **k: ChapterRollup(title='机上广播', overview='  '))
        self.assertEqual(out['title'], 'First')
        self.assertEqual(out['rollup'], 'failed')

    def test_cached_media_result_is_reusable(self):
        cached = rollup._validated_rollup({'title': '[Media Recording]', 'overview': '', 'emoji': '✈️'})
        self.assertEqual(cached.title, '[Media Recording]')

    def _two_batches(self):
        size = MAX_FRAGMENT_BLOCK_CHARS - 2000
        return [dict(frag('A', 'oa'), source_text='NOISE_HEAD ' + 'n' * size),
                dict(frag('B', 'ob'), source_text='r' * size + ' REAL_TAIL')]

    def test_media_batch_is_dropped_from_a_chapter_with_real_content(self):
        media = ChapterRollup(title='[Media Recording]', overview='', emoji='✈️')
        real = ChapterRollup(title='降落前询问洗手间', overview='洗手间在机舱后部。', emoji='✈️')
        out = self._summarize(self._two_batches(),
                              lambda prompt, **k: media if 'NOISE_HEAD' in prompt else real)
        self.assertEqual(out['title'], '降落前询问洗手间')
        self.assertNotIn('Media Recording', out['overview'])
        self.assertIs(out['rollup'], True)

    def test_chapter_is_hidden_only_when_every_batch_is_media(self):
        media = ChapterRollup(title='[Media Recording]', overview='', emoji='✈️')
        out = self._summarize(self._two_batches(), lambda *a, **k: media)
        self.assertEqual(out['title'], '[Media Recording]')
        self.assertEqual(out['overview'], '')
        self.assertIs(out['rollup'], True)


class SeedParityTests(unittest.TestCase):
    def test_seed_json_matches_code_fallback(self):
        """seed json 的 content 必须与代码 fallback 一字不差。

        改了 prompt 正文却忘了同步 seed，dashboard 上跑的就不是线上那份 —— 而且
        不会有任何报错。
        """
        import json
        import os as _os

        path = _os.path.join(_os.path.dirname(__file__), '..', 'scripts', 'benchmark',
                             'seed_prompts', 'timeline.json')
        with open(path, encoding='utf-8') as fh:
            entries = json.load(fh)
        entry = next(e for e in entries if e['key'] == 'timeline.chapter_rollup')
        self.assertEqual(entry['content'], rollup._ROLLUP_TEMPLATE.content)


if __name__ == '__main__':
    unittest.main(verbosity=2)
