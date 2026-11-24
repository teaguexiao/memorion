"""Talk cleaning contract across model response formats and failures."""

import asyncio
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault('OPENROUTER_API_KEY', 'test')

from langchain_core.messages import AIMessage
from utils.llm import transcript_cleaner as cleaner


class TalkCleaningTests(unittest.IsolatedAsyncioTestCase):
    async def test_levels_formats_and_content_blocks_preserve_cleaning_contract(self):
        for level in ('light', 'standard', 'aggressive'):
            for output_format in ('paragraph', 'bullets', 'raw'):
                with self.subTest(level=level, output_format=output_format):
                    client = mock.Mock()
                    client.ainvoke = mock.AsyncMock(return_value=AIMessage(content=[
                        {'type': 'text', 'text': '```json\n{"text":"预算是370元。","changes":["去掉重复"]}\n```'},
                    ]))
                    with mock.patch.object(cleaner, '_get_llm_client', return_value=client), \
                            mock.patch.object(cleaner, '_fetch_production_prompt', return_value=None):
                        result = await cleaner.clean_transcript('嗯，预算是370元。', level, output_format)
                    self.assertEqual(result, {'text': '预算是370元。', 'changes': ['去掉重复']})
                    messages = client.ainvoke.call_args.args[0]
                    self.assertEqual([m.type for m in messages], ['system', 'human'])
                    self.assertIn('预算是370元', messages[1].content)

    async def test_plain_text_and_failure_keep_existing_fallback(self):
        client = mock.Mock()
        client.ainvoke = mock.AsyncMock(side_effect=[AIMessage(content='Clean text.'), RuntimeError('provider down')])
        with mock.patch.object(cleaner, '_get_llm_client', return_value=client), \
                mock.patch.object(cleaner, '_fetch_production_prompt', return_value=None):
            self.assertEqual(await cleaner.clean_transcript('Original'), {'text': 'Clean text.', 'changes': []})
            self.assertEqual(await cleaner.clean_transcript('Original'), {'text': 'Original', 'changes': []})

    async def test_empty_input_and_cancellation_do_not_fake_a_success(self):
        with mock.patch.object(cleaner, '_get_llm_client') as get_client:
            self.assertEqual(await cleaner.clean_transcript('  '), {'text': '', 'changes': []})
            get_client.assert_not_called()
        client = mock.Mock()
        client.ainvoke = mock.AsyncMock(side_effect=asyncio.CancelledError)
        with mock.patch.object(cleaner, '_get_llm_client', return_value=client), \
                mock.patch.object(cleaner, '_fetch_production_prompt', return_value=None):
            with self.assertRaises(asyncio.CancelledError):
                await cleaner.clean_transcript('Original')

    async def test_empty_or_reasoning_only_response_preserves_original_transcript(self):
        for content in ('', [], [{'type': 'reasoning', 'reasoning': 'hidden'}]):
            with self.subTest(content=content):
                client = mock.Mock()
                client.ainvoke = mock.AsyncMock(return_value=AIMessage(content=content))
                with mock.patch.object(cleaner, '_get_llm_client', return_value=client), \
                        mock.patch.object(cleaner, '_fetch_production_prompt', return_value=None):
                    self.assertEqual(await cleaner.clean_transcript('Original'), {'text': 'Original', 'changes': []})


if __name__ == '__main__':
    unittest.main()
