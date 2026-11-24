"""日记 prompt 与清洗的不变式。

journal（第一人称散文）是默认格式；legacy（五段报告）是存量与回滚形态，下面以
`test_finalize_daily_summary_text_*` 开头、没写 journal 的几条全是 legacy 的老断言，
原样保留——它们证明换格式没有打坏旧日记。

Run: cd backend && python3 tests/test_daily_summary_formatting.py
"""

import json
import os
import re
import sys
import unittest
from pathlib import Path
from unittest import mock


sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import utils.llm.prompt_registry as prompt_registry
from utils.llm import daily_summary
from utils.llm.daily_summary import (
    build_daily_summary_prompt,
    extract_daily_summary_body,
    finalize_daily_summary_text,
)
from utils.locales import (
    get_localized_daily_summary_header,
    get_localized_daily_summary_title,
)

SEED = Path(__file__).resolve().parents[1] / 'scripts' / 'benchmark' / 'seed_prompts' / 'daily_summary.json'
_MARKDOWN_RESIDUE = re.compile(r'\*\*|^\s*#|^\s*>|^\s*(?:[-*•]|\d+[.)])\s', re.MULTILINE)


def _offline_get_prompt(calls):
    """Stand-in for the registry: records the key, always serves the fallback.

    Keeps the test off the network and lets it assert *which* key is resolved."""

    def _get_prompt(key, fallback, label='production'):
        calls.append(key)
        return prompt_registry.ResolvedPrompt(
            key=key, content=fallback.content, config=dict(fallback.config), label=label, is_fallback=True)

    return _get_prompt


def _build(language_code='zh', calls=None):
    calls = [] if calls is None else calls
    with mock.patch.object(prompt_registry, 'get_prompt', _offline_get_prompt(calls)):
        return build_daily_summary_prompt(
            user_name='Teague',
            conversation_history='Conversation #1\nShipped an important fix.',
            language_code=language_code,
        )


class JournalPromptTests(unittest.TestCase):
    def test_resolves_the_journal_key_not_the_legacy_one(self):
        # 🚨 注册表里 `daily_summary` 的 production 仍是五段 prompt，且注册表压过 fallback。
        # 退回旧 key 等于改了 fallback 却照样出五段报告——而且看不出来。
        calls = []
        _build(calls=calls)
        self.assertEqual(['daily_summary.journal_detailed_v1'], calls)

    def test_prompt_is_a_diary_not_a_five_section_report(self):
        prompt = _build('zh')
        self.assertIn('first person', prompt)
        self.assertIn('### 明天记得', prompt, 'tomorrow heading must be localized')
        self.assertIn('Respond in Chinese', prompt)
        self.assertIn('Shipped an important fix.', prompt)
        for legacy in ['今日亮点', '关键跟进事项', '今日决定', '新的收获', '可以改进的地方', 'five']:
            self.assertNotIn(legacy, prompt)
        self.assertNotIn('{{', prompt)

    def test_prompt_forbids_fabricated_quotes_and_clock_times(self):
        # 输入只有 overview、没有转录原文，时间戳是 UTC：这两条是「编」的主要来源。
        prompt = _build('en')
        self.assertIn('exact contiguous words from a transcript speaker turn', prompt)
        self.assertIn('only words inside quotation marks in summary notes', prompt)
        self.assertIn('timestamps are UTC', prompt)
        self.assertIn('### For tomorrow', prompt)
        self.assertIn('Write the entire response in English.', prompt)

    def test_prompt_guards_the_round1_failure_modes(self):
        # 2026-10 真实生成的第一版：按对话顺序逐条复述（718 字）、清单式罗列、套话开头，
        # 外加四类没有依据的断言（替人给结局、默认性别、从时间戳推时段、把玩笑话当真）。
        # 每条断言对应 prompt 里的一条规则；规则被删 / 改弱时这里会红。
        t = daily_summary._JOURNAL_TEMPLATE
        for rule in [
            "Choose, don't cover",                          # 取舍，而不是覆盖
            'Do not walk through the day conversation by conversation or follow the clock',
            'Never list',                                   # 装备 / 体测项 / 菜单
            'No fixed paragraph maximum',
            'Hours of recording never justify a longer entry',
            'Do not open with a framing formula',           # 「今天最清楚的一段是」
            'No summary of the day as a whole, no moral or lesson',
            'Stop where the notes stop.',                   # 「最后也没等到」「never got an answer」
            "Don't write morning, noon, lunch",             # 「Lunch was loud」
            'use he/she (他/她) for a person only when my confirmed facts',  # 老师的 she
            "Don't turn them into literal facts",           # 叽叽喳喳 → chirping noise
            'Negative and mixed feelings are allowed',
            "Don't add feeling words the notes don't support",
            'drop the compliment',                          # 观察者写的「耐心」「温和」
            # 第二轮真实生成：把「当时在等 / 在提醒」延伸到写日记的此刻
            # （「理由到现在我也没听到」「the homework is still sitting there」），
            # 外加编动作（waved it off）和替人判动机（puzzled he didn't have one）。
            'A record that stops is not evidence that nothing followed',
            'No invented gestures, reactions or motives.',
            "Don't judge someone's reasons",
            "don't add words someone didn't use",           # "a real reason"
            'silently reread your draft against the notes',
            # 第二轮两种语言都零加粗零引语：「通常嵌进句子」把版式锚点全压没了。
            'set it on its own line starting with "> "',
            'bold the one short phrase worth landing on',
            # 第三轮英文：「nobody left」（输入只说被卡片留住）、给转述加引号当开头、写成 5 段。
            'Keep the scope the notes give.',
            'Never put quotation marks around a paraphrase',
            'No fixed paragraph maximum',
            # 第四轮：「something still open」「end … on something still unresolved」这两条正向
            # 要求逼模型造悬念（「那张卡到底掉没掉，我没看到」），已删；同时钉住归属 / 心态≠动作 / 标点。
            "Don't write what I didn't see, hear or know",
            "when they don't say who did something, I don't assign it to anyone",
            "don't turn a state of mind",
            'full-width ，。：“” in Chinese',
        ]:
            self.assertIn(rule, t)
        for removed in ['unresolved', 'still open']:
            self.assertNotIn(removed, t, '正向要求「未解决的收尾」会逼模型编造未知状态')

    def test_prompt_chooses_moments_instead_of_covering_the_day(self):
        # 2026-10-24（#123）把第一轮修掉的「按对话顺序逐条复述」原样请了回来：「清点全部话题、
        # 每个都写进去、按录音顺序排」+ 一遍专门补话题的复核。一天写成 2700~5200 字的会议纪要
        # 加逐句复述，用户原话「流水账，没有任何温度和感情」。这里钉住挑选的判据（先按感受挑、
        # 工作只留记得的一两点），并禁止覆盖式要求回来。
        t = daily_summary._JOURNAL_TEMPLATE
        for rule in [
            'pick by feeling first',
            'Never the agenda, the minutes',
            'Give each chosen moment room to be felt',      # 要更多细节，就给挑出来的瞬间多留篇幅
            'not with a quotation or a "> " line',          # 第二版 4 篇里 3 篇用引语开头
        ]:
            self.assertIn(rule, t)
        for coverage in ['Include each substantive thread', 'inventory', 'Do not choose just a couple of highlights',
                         'Arrange events in their recorded order', 'Restore any omitted']:
            self.assertNotIn(coverage, t, '覆盖式要求会把日记写回流水账')

    def test_feelings_come_from_the_words_in_a_transcript(self):
        # 输入是逐字转录：旧规则「notes 描述了反应才许写感受」在逐字稿上等于永远不写感受。
        # 判据换成「话本身带出的感受」，且说出口的感受必须进日记。
        t = daily_summary._JOURNAL_TEMPLATE
        self.assertIn('When I said how I felt', t)
        self.assertIn('When my own words in a moment carry a feeling', t)
        self.assertIn('never bigger than the words show', t)
        self.assertNotIn('or the notes describe a reaction', t)

    def test_chinese_pronoun_fallback_never_treats_a_person_as_an_object(self):
        # 「otherwise use … they」在中文里被译成「它」：2026-10-28 实测一篇日记通篇用「它」称呼孩子。
        self.assertIn('never call a person 它', daily_summary._JOURNAL_TEMPLATE)
        self.assertIn('never 它 for a person', daily_summary._JOURNAL_GROUNDING_TEMPLATE)

    def test_anti_extension_reminder_sits_after_the_notes(self):
        # 长输入之后模型最容易忘掉中段的规则；结尾那句提醒必须真在 notes 后面。
        prompt = _build('zh')
        notes_at = prompt.index('Shipped an important fix.')
        self.assertGreater(prompt.index('Reminder: stop where the notes stop'), notes_at)

    def test_prompt_carries_no_fixed_sample_day(self):
        # 生产 prompt 里不许固化某一天的内容当示例——模型会把它当成模板往每一天上套。
        t = daily_summary._JOURNAL_TEMPLATE
        for leaked in ['剪头发', '绿豆', '体测', '游乐', 'haircut', 'mung bean', 'fitness test', 'Tesla']:
            self.assertNotIn(leaked, t)

    def test_seed_entry_is_byte_identical_to_code_fallback(self):
        # seed 脚本把 JSON 写成 v1 + production。两者一致 ⇒ seed 前后线上行为相同。
        entry = next(e for e in json.loads(SEED.read_text()) if e['key'] == 'daily_summary.journal_detailed_v1')
        self.assertEqual(daily_summary._JOURNAL_TEMPLATE, entry['content'])

    def test_legacy_five_section_prompt_still_renders_under_the_new_key(self):
        # 回滚路径：把旧五段 prompt promote 到 daily_summary.journal 下。render 缺变量会
        # 静默降级回 journal fallback（回滚无声失败），所以旧变量必须继续传。
        legacy = ('### {{header}}\n### {{followups_title}}\n### {{decisions_title}}\n'
                  '### {{learning_title}}\n### {{improvement_title}}\n{{user_name}}{{memories_clause}}'
                  '{{language_instruction}}{{conversation_history}}')

        def _registry(key, fallback, label='production'):
            return prompt_registry.ResolvedPrompt(key=key, content=legacy, config={}, version=7,
                                                  fallback_content=fallback.content)

        with mock.patch.object(prompt_registry, 'get_prompt', _registry):
            prompt = build_daily_summary_prompt('Teague', 'ctx', 'zh')
        self.assertTrue(prompt.startswith('### 今日亮点\n### 关键跟进事项'))


class JournalFormattingTests(unittest.TestCase):
    def test_keeps_paragraphs_bold_anchor_quote_and_tomorrow_note(self):
        raw = """
和小林把发布时间定在了**周五**，拖了两周的事总算落地。

晚上妈妈打电话来，说的第一句是：
>   "别太晚睡"

### 明天记得
* 把发布说明发给小林
""".strip()
        self.assertEqual(
            finalize_daily_summary_text(raw, 'zh'),
            '和小林把发布时间定在了**周五**，拖了两周的事总算落地。\n\n'
            '晚上妈妈打电话来，说的第一句是：\n\n'
            '> "别太晚睡"\n\n'
            '### 明天记得\n\n'
            '- 把发布说明发给小林',
        )

    def test_journal_does_not_get_a_highlights_header_or_a_made_up_title(self):
        raw = '# 平静的一天\n\n今天只聊了一件事。\n\n### 今日亮点\n\n就是把周报交了。'
        self.assertEqual(finalize_daily_summary_text(raw, 'zh'), '今天只聊了一件事。\n\n就是把周报交了。')

    def test_colon_ended_prose_is_not_mistaken_for_a_heading(self):
        # legacy 规则把「…：」整行当标题；在散文里那是引语的前一句。
        raw = '她最后只说了一句：\n\n> 下次再说'
        self.assertEqual(finalize_daily_summary_text(raw, 'zh'), '她最后只说了一句：\n\n> 下次再说')

    def test_strips_preamble_without_eating_real_prose(self):
        self.assertEqual(finalize_daily_summary_text('好的，这是你今天的日记：\n\n下午改完了文档。', 'zh'), '下午改完了文档。')
        self.assertEqual(finalize_daily_summary_text("Here's your journal entry:\nOksana called.", 'en'), 'Oksana called.')
        self.assertEqual(finalize_daily_summary_text('Oksana called back.', 'en'), 'Oksana called back.')
        self.assertEqual(finalize_daily_summary_text('这是我第一次去提交报告。', 'zh'), '这是我第一次去提交报告。')

    def test_bold_is_capped_and_never_wraps_a_whole_line(self):
        raw = '**整句都加粗了。**\n\n**一**、**二**、**三**、**四**，还有 __五__ 和 *斜体*。'
        out = finalize_daily_summary_text(raw, 'zh')
        self.assertEqual(out, '整句都加粗了。\n\n**一**、**二**、**三**、四，还有 五 和 斜体。')

    def test_drops_transcript_dump_section(self):
        raw = '今天很短。\n\n### 今日对话\nSpeaker 0: 原文原文\n\n### 明天记得\n- 交房租'
        self.assertEqual(finalize_daily_summary_text(raw, 'zh'), '今天很短。\n\n### 明天记得\n\n- 交房租')

    def test_finalize_is_idempotent_on_journal_text(self):
        raw = '先是**一件事**。\n第二行同段。\n\n> "原话"\n\n### For tomorrow\n- Call Sam\n- Send the deck'
        once = finalize_daily_summary_text(raw, 'en')
        self.assertEqual(finalize_daily_summary_text(once, 'en'), once)

    def test_push_body_is_plain_text_without_markdown(self):
        stored = '和小林把时间定在**周五**。\n\n> 别太晚睡\n\n### 明天记得\n- 发说明'
        body = extract_daily_summary_body(stored, 'zh')
        self.assertEqual(body, '和小林把时间定在周五。\n“别太晚睡”')
        self.assertIsNone(_MARKDOWN_RESIDUE.search(body))

    def test_push_body_for_legacy_entry_drops_list_markers(self):
        legacy = '### 今日亮点\n\n- 完成了**设计评审**\n2. 见了客户\n\n### 今日决定\n\n定了方向。'
        body = extract_daily_summary_body(legacy, 'zh')
        self.assertEqual(body, '完成了设计评审\n见了客户')
        self.assertIsNone(_MARKDOWN_RESIDUE.search(body))


    def test_push_body_never_empty(self):
        self.assertEqual(extract_daily_summary_body('', 'zh'), '今日亮点')


class LegacyFormattingTests(unittest.TestCase):

    def test_finalize_daily_summary_text_keeps_sections_and_drops_transcript_in_chinese(self):
        raw_text = """
好的，这是根据今天对话内容生成的总结报告。

### 今日亮点（中文）

今天你把产品方向和客户反馈都收拢清楚了，推进节奏比昨天更稳。

### 关键跟进事项

1. 明天把会议纪要发出去。
2. 跟进客户的演示反馈。

### 今日对话
这里是很长的对话原文，不应该继续保留。
""".strip()

        self.assertEqual(
            finalize_daily_summary_text(raw_text, 'zh'),
            (
                '### 今日亮点\n\n'
                '今天你把产品方向和客户反馈都收拢清楚了，推进节奏比昨天更稳。\n\n'
                '### 关键跟进事项\n\n'
                '1. 明天把会议纪要发出去。\n'
                '2. 跟进客户的演示反馈。'
            ),
        )

    def test_finalize_daily_summary_text_localizes_headers_and_preserves_bullets(self):
        raw_text = """
**Daily Highlights (English)**

- You closed the design loop with the team.
- Client feedback on the demo was positive.

**Key Follow-up Items**
1. Send the notes tomorrow.
""".strip()

        self.assertEqual(
            finalize_daily_summary_text(raw_text, 'en'),
            (
                '### Daily Highlights\n\n'
                '- You closed the design loop with the team.\n'
                '- Client feedback on the demo was positive.\n\n'
                '### Key Follow-up Items\n\n'
                '1. Send the notes tomorrow.'
            ),
        )

    def test_finalize_daily_summary_text_handles_plain_header_without_markdown(self):
        raw_text = """
今日亮点

今天你把最关键的两件事推进下去了，沟通也更有结论。
""".strip()

        self.assertEqual(
            finalize_daily_summary_text(raw_text, 'zh'),
            '### 今日亮点\n\n今天你把最关键的两件事推进下去了，沟通也更有结论。',
        )

    def test_extract_daily_summary_body_returns_body_only(self):
        summary = """
### 今日亮点

今天你把关键事项都往前推进了一步，沟通也更聚焦。
""".strip()

        self.assertEqual(
            extract_daily_summary_body(summary, 'zh'),
            '今天你把关键事项都往前推进了一步，沟通也更聚焦。',
        )

    def test_push_title_matches_localized_summary_header(self):
        self.assertEqual(get_localized_daily_summary_title('zh'), '今日亮点')
        self.assertEqual(get_localized_daily_summary_title('zh-tw'), '今日亮點')
        self.assertEqual(get_localized_daily_summary_title('en'), 'Daily Highlights')
        self.assertEqual(
            get_localized_daily_summary_title('zh-CN'),
            get_localized_daily_summary_header('zh-CN'),
        )


if __name__ == '__main__':
    unittest.main(verbosity=2)
