"""日记要说出「这件事对我是什么」：背景来自用户确认过的事实（2026-11-05）。

#156 之后日记只剩挑出来的瞬间，可每个瞬间都写成「我说……对方说……」，用户说是流水账，没深度也没感情。
同一份证据重放下来：只给背景、不改写法，模型一句背景都没用上；要求写「它对我是什么」，模型写得出来，
可是核对那一遍又把它们删了（「想到自己的硬件项目，这话有点扎心」，背景里明明记着这份担心）。

这里钉住四件事：
- 选哪些背景：只要确认过的，最新的在前，有总量上限；
- 写作和核对两遍都看到同一份背景；
- 规则：背景不算当天发生的事，每个瞬间要写它对我是什么、原话不逐句复述，核对认背景里记着的担心；
- 生产调用点真的把背景传了下去。

Run: cd backend && python3 -m pytest tests/test_daily_journal_background.py
"""
import ast
import os
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import utils.llm.prompt_registry as prompt_registry  # noqa: E402
from utils.llm import daily_journal_identity as identity  # noqa: E402
from utils.llm import daily_summary  # noqa: E402

BACKEND = Path(__file__).resolve().parents[1]


def _offline_get_prompt(key, fallback, label='production'):
    return prompt_registry.ResolvedPrompt(key=key, content=fallback.content, config={}, is_fallback=True)


class _FakeLLM:
    def __init__(self, *replies):
        self.replies = list(replies)
        self.prompts = []

    def invoke(self, prompt):
        self.prompts.append(prompt)
        return types.SimpleNamespace(content=self.replies.pop(0))


class SelectionTests(unittest.TestCase):
    def test_confirmed_facts_newest_first_and_nothing_else(self):
        records = [
            {'content': '你在硬件项目上投入超过500天。', 'user_review': True, 'created_at': '2026-09-01'},
            {'content': '你每天的工作主要是销售GPU和token。', 'user_review': True, 'created_at': '2026-09-09'},
            {'content': '我是小草的爸爸', 'manually_added': True, 'created_at': '2026-10-28'},
            {'content': '你喜欢吃菠萝。'},                                       # 未审阅
            {'content': '你讨厌开车。', 'user_review': False},                    # 被否掉
            {'content': '你住在宝山。', 'user_review': True, 'deleted': True},
        ]
        self.assertEqual(identity.select_background_facts(records), [
            '我是小草的爸爸', '你每天的工作主要是销售GPU和token。', '你在硬件项目上投入超过500天。'])

    def test_repeats_dropped_and_the_budget_holds(self):
        records = [{'content': f'你的第{i}个爱好是第{i}种运动。' * 5, 'user_review': True,
                    'created_at': f'2026-09-{i % 28 + 1:02d}'} for i in range(400)]
        records.append({'content': '  你的第1个爱好是第1种运动。' * 5, 'user_review': True, 'created_at': '2026-01-01'})
        facts = identity.select_background_facts(records)
        self.assertLessEqual(sum(map(len, facts)), identity.MAX_BACKGROUND_CHARS)
        self.assertEqual(len(facts), len(set(facts)))
        self.assertGreater(len(facts), 10)

    def test_unreadable_facts_write_the_entry_without_them(self):
        with mock.patch.object(identity, 'get_confirmed_facts', side_effect=RuntimeError('firestore down')):
            self.assertEqual(identity.get_confirmed_background_facts('dev', 'uid'), [])


class PromptTests(unittest.TestCase):
    BACKGROUND = ['你在硬件项目上投入超过500天，担心进展慢、缺乏差异化。', '你的儿子在上一年级。']

    def test_both_passes_see_the_same_background_before_the_notes(self):
        llm = _FakeLLM('我说创业公司都差不多，想到自己的项目，有点扎心。', '我说创业公司都差不多，想到自己的项目，有点扎心。')
        with mock.patch.object(prompt_registry, 'get_prompt', _offline_get_prompt):
            daily_summary.generate_daily_journal(llm, 'Teague', 'Conversation #1\nUser: 大家做的东西都很像。', 'zh',
                                                 background_facts=self.BACKGROUND)
        block = ('<background>\n- 你在硬件项目上投入超过500天，担心进展慢、缺乏差异化。\n- 你的儿子在上一年级。\n'
                 '</background>')
        self.assertEqual(2, len(llm.prompts))
        for prompt in llm.prompts:
            self.assertIn(block, prompt)
            self.assertLess(prompt.index('<background>'), prompt.index('<notes>'))
            self.assertNotIn('{{', prompt)

    def test_no_background_is_said_explicitly(self):
        with mock.patch.object(prompt_registry, 'get_prompt', _offline_get_prompt):
            writer = daily_summary.build_daily_summary_prompt('Teague', 'Conversation #1', 'zh')
            check = daily_summary.build_journal_grounding_prompt('Teague', 'Conversation #1', '草稿', 'zh')
        for prompt in (writer, check):
            self.assertIn('<background>\nNo background facts.\n</background>', prompt)
            self.assertNotIn('{{', prompt)

    def test_background_never_becomes_an_event_of_the_day(self):
        w, g = daily_summary._JOURNAL_TEMPLATE, daily_summary._JOURNAL_GROUNDING_TEMPLATE
        self.assertIn('Nothing in the background happened today.', w)
        self.assertIn('never bring in a topic the notes do not touch', w)
        self.assertIn("Don't recite my life, list facts about me", w)
        self.assertIn('Anything else drawn from the background is unsupported', g)
        self.assertIn("never as evidence of today's events", g)

    def test_each_moment_says_what_it_was_to_me_without_minutes(self):
        w = daily_summary._JOURNAL_TEMPLATE
        self.assertIn('say in a clause or a sentence what it was to me', w)
        self.assertIn('Keep at most one or two lines of what was said per moment', w)
        self.assertIn('is minutes, not a diary', w)
        self.assertIn('Never invent a feeling, opinion, worry or event to supply it', w)
        # 旧版「把来回都写进去」正是逐句复述的来源。
        self.assertNotIn('the back-and-forth and what I answered', w)

    def test_the_check_accepts_a_worry_the_background_records_and_nothing_bigger(self):
        g = daily_summary._JOURNAL_GROUNDING_TEMPLATE
        self.assertIn("A worry or care of mine that <background> records is also supported where today's moment "
                      'touches that same thing', g)
        self.assertIn('keep it as small as the background puts it', g)
        self.assertIn('ties a supported moment to something the background states about my life', g)
        self.assertIn('Remove feelings that nothing in the words or the background shows', g)

    def test_templates_still_carry_no_one_users_life(self):
        for template in (daily_summary._JOURNAL_TEMPLATE, daily_summary._JOURNAL_GROUNDING_TEMPLATE):
            for leaked in ('小草', '宝可梦', 'Pokémon', 'GPU', '硬件', 'Teague'):
                self.assertNotIn(leaked, template)


class CallSiteTests(unittest.TestCase):
    def test_production_writer_passes_the_users_background(self):
        tree = ast.parse((BACKEND / 'routers/developer_daily_summary.py').read_text())
        fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == '_generate_developer_summary')
        call = next(n for n in ast.walk(fn) if isinstance(n, ast.Call) and getattr(n.func, 'id', None) == 'generate_daily_journal')
        passed = next((k.value for k in call.keywords if k.arg == 'background_facts'), None)
        self.assertIsInstance(passed, ast.Name, 'generate_daily_journal 没收到 background_facts')
        assigned = [n for n in ast.walk(fn) if isinstance(n, ast.Assign)
                    and any(getattr(t, 'id', None) == passed.id for t in n.targets)]
        self.assertTrue(any(getattr(a.value.func, 'id', None) == 'get_confirmed_background_facts' for a in assigned
                            if isinstance(a.value, ast.Call)), 'background_facts 不是从用户确认过的事实里取的')


if __name__ == '__main__':
    unittest.main()
