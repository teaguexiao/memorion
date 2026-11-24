"""Exercise the actual image helper without network or production storage."""

import asyncio
import base64
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault('OPENROUTER_API_KEY', 'test')

from langchain_core.messages import AIMessage
from utils.llm import image_description as images


class ImageDescriptionTests(unittest.IsolatedAsyncioTestCase):
    async def test_png_and_jpeg_use_configured_vertex_role_and_correct_mime(self):
        for raw, mime in ((b'\x89PNG\r\n\x1a\nfixture', 'image/png'), (b'\xff\xd8\xfffixture', 'image/jpeg')):
            encoded = base64.b64encode(raw).decode()
            client = mock.Mock()
            client.ainvoke = mock.AsyncMock(return_value=AIMessage(content=[{
                'type': 'text', 'text': '{"text":["TEST 37"],"summary":"test card"}',
            }]))
            with self.subTest(mime=mime), mock.patch.object(images, 'create_llm', return_value=client) as factory:
                result = await images.describe_image_with_gemini(encoded)
            factory.assert_called_once_with(**images.MODEL_CONFIG['image_description'])
            self.assertEqual(result.text, ['TEST 37'])
            call = client.ainvoke.call_args
            self.assertEqual(call.args[0][0].content[1]['image_url']['url'], f'data:{mime};base64,{encoded}')
            self.assertEqual(call.kwargs['response_mime_type'], 'application/json')
            self.assertEqual(call.kwargs['max_output_tokens'], 4096)

    async def test_markdown_and_legacy_non_json_fallback(self):
        for content, summary in (('```json\n{"summary":"card"}\n```', 'card'), ('plain description', 'plain description')):
            client = mock.Mock()
            client.ainvoke = mock.AsyncMock(return_value=AIMessage(content=content))
            with self.subTest(content=content), mock.patch.object(images, 'create_llm', return_value=client):
                result = await images.describe_image_with_gemini('')
            self.assertEqual(result.summary, summary)

    async def test_provider_errors_propagate_to_existing_endpoint_error_handling(self):
        client = mock.Mock()
        client.ainvoke = mock.AsyncMock(side_effect=RuntimeError('provider unavailable'))
        with mock.patch.object(images, 'create_llm', return_value=client), self.assertRaisesRegex(RuntimeError, 'unavailable'):
            await images.describe_image_with_gemini('')

    async def test_endpoint_timeout_cancels_inflight_async_request(self):
        cancelled = asyncio.Event()

        async def pending(*args, **kwargs):
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        client = mock.Mock()
        client.ainvoke = pending
        with mock.patch.object(images, 'create_llm', return_value=client), self.assertRaises(asyncio.TimeoutError):
            await asyncio.wait_for(images.describe_image_with_gemini(''), timeout=0.01)
        self.assertTrue(cancelled.is_set())


if __name__ == '__main__':
    unittest.main()
