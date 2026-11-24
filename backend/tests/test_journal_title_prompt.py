"""日记标题 prompt（`daily_summary.journal_title`）的不变式。

旧 prompt（`daily_summary.emotion_title`）要求「意象化、只写情绪与画面、不复述具体事项」，
示例是「风筝下的温暖午后」这一类 ⇒ 模型给每一天都套上温暖 / 疲惫，再配一个正文里没有
的画面、天气或时段。新 prompt 要求标题来自正文里的真实细节，或正文已写明的情绪。

Run: cd backend && python3 tests/test_journal_title_prompt.py
"""

import importlib.util
import json
import os
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Load an isolated copy so the lightweight client stub cannot leak to other tests.
import utils.llm.prompt_registry as prompt_registry  # noqa: E402

_module_spec = importlib.util.spec_from_file_location(
    'journal_title_under_test', Path(__file__).resolve().parents[1] / 'utils' / 'llm' / 'emotion_title.py'
)
emotion_title = importlib.util.module_from_spec(_module_spec)
with mock.patch.dict(sys.modules, {'utils.llm.clients': types.SimpleNamespace(llm_mini=object())}):
    _module_spec.loader.exec_module(emotion_title)

SEED = Path(__file__).resolve().parents[1] / 'scripts' / 'benchmark' / 'seed_prompts' / 'daily_summary.json'


class _FakeLLM:
    def __init__(self, title, prompts):
        self._title = title
        self._prompts = prompts

    def with_structured_output(self, schema):
        self._schema = schema
        return self

    def invoke(self, prompt):
        self._prompts.append(prompt)
        return self._schema(title=self._title)


def _generate(title, summary='我把那张卡片放回了盒子里。', language_code='zh', registry_content=None):
    keys, prompts = [], []

    def _get_prompt(key, fallback, label='production'):
        keys.append(key)
        if registry_content is None:
            return prompt_registry.ResolvedPrompt(key=key, content=fallback.content, config={}, is_fallback=True)
        return prompt_registry.ResolvedPrompt(key=key, content=registry_content, config={}, version=3,
                                              fallback_content=fallback.content)

    with mock.patch.object(emotion_title, 'get_prompt', _get_prompt), \
            mock.patch.object(emotion_title, 'resolve_llm', lambda resolved, default: _FakeLLM(title, prompts)):
        result = emotion_title.generate_emotion_title(summary, language_code)
    return result, keys, prompts


class JournalTitlePromptTests(unittest.TestCase):
    def test_resolves_the_new_key(self):
        # 🚨 旧 key 在注册表里仍指着「意象化」版本，注册表压过 fallback。
        _, keys, _ = _generate('放回盒子的卡片')
        self.assertEqual(['daily_summary.journal_title'], keys)

    def test_seed_entry_is_byte_identical_to_code_fallback(self):
        entries = {e['key']: e for e in json.loads(SEED.read_text())}
        self.assertEqual(emotion_title._JOURNAL_TITLE_TEMPLATE.content, entries['daily_summary.journal_title']['content'])

    def test_prompt_and_schema_no_longer_ask_for_imagery(self):
        # schema 的 description 也会发给模型，必须与 prompt 同口径。
        template = emotion_title._JOURNAL_TITLE_TEMPLATE.content
        schema_desc = emotion_title.EmotionTitleLLMOutput.model_fields['title'].description
        for text in (template, schema_desc):
            self.assertNotIn('意象', text)
            self.assertNotIn('画面', text)
        self.assertIn('one concrete thing in the entry', template)
        self.assertIn('No scenery, weather, light, season or time of day', template)
        self.assertIn('Do not reach for a default mood', template)
        self.assertIn('concrete', schema_desc)

    def test_prompt_carries_no_example_titles(self):
        # 示例标题会被当成模板套用——旧版的三个示例就是「温暖午后」式标题的来源。
        template = emotion_title._JOURNAL_TITLE_TEMPLATE.content
        for leaked in ['风筝', '午后', '礼物', '周三', '绿豆']:
            self.assertNotIn(leaked, template)

    def test_language_instruction_reaches_the_prompt(self):
        _, _, prompts = _generate('A Title', language_code='en')
        self.assertIn('- Write the title in English.', prompts[0])
        _, _, prompts = _generate('标题', language_code='zh')
        self.assertIn('Respond in Chinese', prompts[0])
        self.assertIn('我把那张卡片放回了盒子里。', prompts[0])

    def test_wrapping_quotes_and_trailing_punctuation_are_stripped(self):
        self.assertEqual(_generate('「放回盒子的卡片」。')[0], '放回盒子的卡片')
        self.assertEqual(_generate('"One more try."')[0], 'One more try')

    def test_empty_entry_skips_the_llm(self):
        result, keys, _ = _generate('不该被调用', summary='  ')
        self.assertIsNone(result)
        self.assertEqual([], keys)

    def test_old_prompt_promoted_under_new_key_still_renders(self):
        # 回滚路径：变量没变，旧 prompt promote 到新 key 下能直接渲染，而不是静默降级。
        old = '旧版标题 prompt {{language_hint}}\n<summary>{{summary_text}}</summary>'
        _, _, prompts = _generate('标题', registry_content=old)
        self.assertTrue(prompts[0].startswith('旧版标题 prompt - Respond in Chinese'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
