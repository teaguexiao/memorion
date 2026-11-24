"""Evidence selection must fail safely without passing unfiltered diary text to images."""
from pathlib import Path
import sys
import unittest
from unittest import mock
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from utils.llm import daily_illustration_sources as sources
from utils.llm.prompt_registry import ResolvedPrompt


class IllustrationSourceTests(unittest.TestCase):
    def test_exact_sources_are_preserved(self):
        diary = '我带女儿去公园踢球。朋友说他周末想带两个孩子出去玩。'
        selected = sources.IllustrationSources(events=['我带女儿去公园踢球。'])
        self.assertEqual(sources.validate_illustration_sources(selected, diary), selected)

    def test_empty_and_invented_sources_fail_closed(self):
        diary = '今天聊了代码。'
        for selected in (sources.IllustrationSources(),
                         sources.IllustrationSources(events=['我在书桌写代码。']),
                         sources.IllustrationSources(objects=['']),
                         sources.IllustrationSources(objects=[' 代码'])):
            with self.subTest(selected=selected), self.assertRaises(ValueError):
                sources.validate_illustration_sources(selected, diary)

    def test_topic_only_selection_does_not_return_disclaimed_outing(self):
        diary = '今天聊了代码。朋友说他周末想带两个孩子去公园。'
        llm = mock.Mock()
        llm.with_structured_output.return_value.invoke.return_value = sources.IllustrationSources(objects=['代码'])
        resolved = ResolvedPrompt(key='test', content=sources._SCENE_SELECTION.content, config={})
        with mock.patch.dict(sys.modules, {'utils.llm.clients': SimpleNamespace(llm_mini=llm)}), \
                mock.patch.object(sources, 'get_prompt', return_value=resolved), \
                mock.patch.object(sources, 'resolve_llm', return_value=llm):
            selected = sources.select_daily_illustration_sources(diary)
        self.assertEqual(selected.model_dump(), {'events': [], 'objects': ['代码']})
        request = llm.with_structured_output.return_value.invoke.call_args.args[0]
        self.assertIn(diary, request)
        self.assertIn('plans, future activities', request)

    def test_selector_error_propagates_without_raw_source_fallback(self):
        llm = mock.Mock()
        llm.with_structured_output.return_value.invoke.side_effect = RuntimeError('selection failed')
        resolved = ResolvedPrompt(key='test', content=sources._SCENE_SELECTION.content, config={})
        with mock.patch.dict(sys.modules, {'utils.llm.clients': SimpleNamespace(llm_mini=llm)}), \
                mock.patch.object(sources, 'get_prompt', return_value=resolved), \
                mock.patch.object(sources, 'resolve_llm', return_value=llm), \
                self.assertRaises(RuntimeError):
            sources.select_daily_illustration_sources('今天聊了代码。')


if __name__ == '__main__':
    unittest.main()
