"""日记里「谁是谁」只认用户确认过的事实（`utils/llm/daily_journal_identity.py`）。

2026-10-28 发现：一个用户手动写过「我只有一个儿子，叫小草」，日记却大半天用「她」称呼小草；配图在
10-25、10-27 两天把「我」画成了女性。原因是两条链路都没读用户确认过的事实：写作规则是「转写里用
他/她就跟着用」，可中文的他/她同音，是语音识别随手挑的字；配图只读最新 100 条事实，身份类的老事实
排不进去，也没有任何一条说「我是爸爸」。

这里钉住三件事：选哪些事实（只要确认过的、说「谁是谁」的，用户亲手写的优先）；它们同时到达写作和
核对两遍（核对看不到，就会把写作写对的「他」当成无依据改回去）；生产调用点真的把它们传了下去。

Run: cd backend && python3 tests/test_daily_journal_identity.py
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
    def test_only_confirmed_facts_about_who_people_are(self):
        records = [
            {'content': '我只有一个儿子，叫小草', 'manually_added': True, 'user_review': True},
            {'content': '你的妻子是一名产品经理。', 'user_review': True},
            # 被用户否掉的身份恰恰常是错的那个：父亲被提取成「你有一个丈夫」。
            {'content': '你有一个丈夫。', 'user_review': False},
            {'content': '你是萌萌和小草的爸爸。'},                          # 未审阅：同样是猜测
            {'content': '我是小草的妈妈', 'manually_added': True, 'user_review': False},  # 手写后又否掉
            {'content': '你的儿子叫小明。', 'user_review': True, 'deleted': True},
            {'content': '你喜欢吃菠萝。', 'user_review': True},              # 确认过，但不说谁是谁
            {'content': '你的AI伴侣应用改版后打开率提高了。', 'user_review': True},  # 产品名，不是伴侣
            {'content': 'Your daughter Mia starts school in September.', 'user_review': True},
        ]
        self.assertEqual(identity.select_identity_facts(records), [
            '我只有一个儿子，叫小草',
            '你的妻子是一名产品经理。',
            'Your daughter Mia starts school in September.',
        ])

    def test_user_written_facts_win_then_newest_first(self):
        records = [
            {'content': '你的孩子名叫小草。', 'user_review': True, 'created_at': '2026-08-15'},
            {'content': '你的儿子正在上一年级。', 'user_review': True, 'created_at': '2026-08-30'},
            {'content': '肖元一是我儿子，小名是小宝', 'manually_added': True, 'created_at': '2026-08-19'},
        ]
        self.assertEqual(identity.select_identity_facts(records), [
            '肖元一是我儿子，小名是小宝', '你的儿子正在上一年级。', '你的孩子名叫小草。'])

    def test_whitespace_is_normalized_and_repeats_dropped(self):
        records = [{'content': '  我是  小草的爸爸 \n', 'manually_added': True},
                   {'content': '我是 小草的爸爸', 'user_review': True}]
        self.assertEqual(identity.select_identity_facts(records), ['我是 小草的爸爸'])

    def test_caps_bound_what_reaches_the_prompt(self):
        records = [{'content': f'你的儿子第{i}个朋友叫小明{i}。', 'user_review': True} for i in range(100)]
        facts = identity.select_identity_facts(records)
        self.assertEqual(len(facts), identity.MAX_IDENTITY_FACTS)
        self.assertLessEqual(sum(map(len, facts)), identity.MAX_IDENTITY_CHARS)

    def test_unreadable_facts_write_the_entry_without_them(self):
        with mock.patch.object(identity, 'get_confirmed_facts', side_effect=RuntimeError('firestore down')):
            self.assertEqual(identity.get_confirmed_identity_facts('dev', 'uid'), [])

    def test_reads_every_confirmed_fact_not_only_the_newest_hundred(self):
        database = types.SimpleNamespace(get_memories=mock.Mock(return_value=[]))
        with mock.patch.dict(sys.modules, {'database': types.SimpleNamespace(developer_data=database)}):
            identity.get_confirmed_identity_facts('dev', 'uid')
        database.get_memories.assert_called_once_with(
            developer_id='dev', external_user_id='uid', limit=identity.CONFIRMED_FACTS_LIMIT, status='confirmed')
        self.assertGreater(identity.CONFIRMED_FACTS_LIMIT, 100)


class JournalPromptTests(unittest.TestCase):
    FACTS = ['我只有一个儿子，叫小草', '你的妻子是一名产品经理。']

    def test_both_passes_see_the_same_facts(self):
        llm = _FakeLLM('小草问我一辈子要过多少年。', '小草问我一辈子要过多少年。')
        with mock.patch.object(prompt_registry, 'get_prompt', _offline_get_prompt):
            daily_summary.generate_daily_journal(llm, 'Teague', 'Conversation #1\nUser: 你好', 'zh',
                                                 identity_facts=self.FACTS)
        block = '<confirmed_facts>\n- 我只有一个儿子，叫小草\n- 你的妻子是一名产品经理。\n</confirmed_facts>'
        self.assertEqual(2, len(llm.prompts))
        for prompt in llm.prompts:
            self.assertIn(block, prompt)
            self.assertLess(prompt.index('<confirmed_facts>'), prompt.index('<notes>'))

    def test_no_facts_is_said_explicitly(self):
        with mock.patch.object(prompt_registry, 'get_prompt', _offline_get_prompt):
            prompt = daily_summary.build_daily_summary_prompt('Teague', 'Conversation #1', 'zh')
        self.assertIn('<confirmed_facts>\nNo confirmed facts about who people are.\n</confirmed_facts>', prompt)
        self.assertNotIn('{{', prompt)

    def test_chinese_pronouns_are_not_evidence_and_facts_override_them(self):
        writer, check = daily_summary._JOURNAL_TEMPLATE, daily_summary._JOURNAL_GROUNDING_TEMPLATE
        self.assertIn('In Chinese transcripts 他 and 她 sound the same', writer)
        self.assertIn('my confirmed facts override them', writer)
        self.assertIn('only my confirmed facts establish those', writer)
        self.assertIn('In Chinese transcripts 他/她 alone never do', check)
        self.assertIn('A pronoun that contradicts the confirmed facts is wrong: fix it', check)
        # 旧口径「转写用了他/她就照用」正是错误的来源。
        self.assertNotIn('only if the notes do for that same person', writer)
        self.assertNotIn('keep it only if the notes use it for that same person', check)

    def test_facts_are_identity_never_events(self):
        self.assertIn('nothing in them happened today unless the notes show it', daily_summary._JOURNAL_TEMPLATE)
        self.assertIn('never events, feelings or which Speaker N someone is', daily_summary._JOURNAL_GROUNDING_TEMPLATE)

    def test_prompts_carry_no_one_users_people(self):
        # 写进 prompt 的例子会被当成每个用户的事实。
        for template in (daily_summary._JOURNAL_TEMPLATE, daily_summary._JOURNAL_GROUNDING_TEMPLATE):
            for name in ('小草', '肖元一', '小宝', 'Teague', 'Leslie'):
                self.assertNotIn(name, template)


class CallSiteTests(unittest.TestCase):
    def test_production_writer_passes_the_users_identity_facts(self):
        tree = ast.parse((BACKEND / 'routers/developer_daily_summary.py').read_text())
        fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == '_generate_developer_summary')
        call = next(n for n in ast.walk(fn) if isinstance(n, ast.Call) and getattr(n.func, 'id', None) == 'generate_daily_journal')
        passed = next((k.value for k in call.keywords if k.arg == 'identity_facts'), None)
        self.assertIsInstance(passed, ast.Name, 'generate_daily_journal 没收到 identity_facts')
        assigned = [n for n in ast.walk(fn) if isinstance(n, ast.Assign)
                    and any(getattr(t, 'id', None) == passed.id for t in n.targets)]
        self.assertTrue(any(getattr(a.value.func, 'id', None) == 'get_confirmed_identity_facts' for a in assigned
                            if isinstance(a.value, ast.Call)), 'identity_facts 不是从用户确认过的事实里取的')


if __name__ == '__main__':
    unittest.main(verbosity=2)
