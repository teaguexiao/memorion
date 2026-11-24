"""Factual review uses the configured text/JSON client, not Sol tool calls."""

import os
import unittest
from unittest import mock

os.environ.setdefault('OPENROUTER_API_KEY', 'test')
os.environ.setdefault('OPENAI_API_KEY', 'test')

from langchain_core.messages import AIMessage
from botocore.config import Config
from utils.llm.clients import create_bedrock_llm
from utils.timeline import rollup
from utils.llm.model_config import MODEL_CONFIG
from utils.llm.prompt_registry import ResolvedPrompt


class GroundingTests(unittest.TestCase):
    def test_long_bedrock_review_has_isolated_transport_and_closes_it(self):
        shared_runtime = mock.Mock()
        shared_runtime.meta.config = Config(read_timeout=60, retries={'total_max_attempts': 5})
        client = create_bedrock_llm('global.openai.gpt-6.1-sol', client=shared_runtime,
            bedrock_client=mock.Mock(), max_tokens=16384, reasoning_effort='low')
        original_fields = client.additional_model_request_fields.copy()
        draft = rollup.ChapterRollup(title='draft', overview='Original evidence')
        for fails in (False, True):
            with self.subTest(fails=fails):
                isolated_runtime = mock.Mock()
                def invoke(copied, prompt, **kwargs):
                    self.assertIsNot(copied, client)
                    self.assertIs(copied.client, isolated_runtime)
                    self.assertEqual(copied.max_tokens, 16384)
                    self.assertEqual(copied.additional_model_request_fields, original_fields)
                    self.assertEqual(copied.client.meta.config.read_timeout, 240)
                    self.assertEqual(copied.client.meta.config.retries['total_max_attempts'], 1)
                    if fails:
                        raise TimeoutError('bounded request failed')
                    return AIMessage(content=draft.model_dump_json())
                def create_runtime(**kwargs):
                    isolated_runtime.meta.config = kwargs['config']
                    return isolated_runtime
                with mock.patch('langchain_aws.chat_models.bedrock_converse.create_aws_client',
                                side_effect=create_runtime), mock.patch.object(type(client), 'invoke', invoke):
                    if fails:
                        with self.assertRaises(TimeoutError):
                            rollup.ground_rollup('evidence', draft, None, llm=client, prompt='review')
                    else:
                        self.assertEqual(rollup.ground_rollup('evidence', draft, None, llm=client, prompt='review'), draft)
                self.assertIs(client.client, shared_runtime)
                self.assertEqual(shared_runtime.meta.config.read_timeout, 60)
                self.assertEqual(shared_runtime.meta.config.retries['total_max_attempts'], 5)
                shared_runtime.close.assert_not_called()
                isolated_runtime.close.assert_called_once()

    def test_reviewed_json_replaces_the_draft_and_sees_original_evidence(self):
        draft = rollup.ChapterRollup(title='draft', overview='Budget 73, launch approved')
        corrected = rollup.ChapterRollup(title='corrected', overview='Budget 37. No launch approval.')
        client = mock.Mock()
        client.invoke.return_value = AIMessage(content=corrected.model_dump_json())
        resolved = ResolvedPrompt(key='timeline.chapter_grounding', content=rollup._GROUNDING_TEMPLATE.content, config={})
        with mock.patch.object(rollup, 'resolve_llm', return_value=client):
            result = rollup.ground_rollup('Budget 37. No launch approved.', draft, resolved)
        self.assertEqual(result, corrected)
        prompt = client.invoke.call_args.args[0]
        self.assertIn('Budget 37. No launch approved.', prompt)
        self.assertIn('Budget 73, launch approved', prompt)
        client.with_structured_output.assert_not_called()

    def test_both_model_roles_are_configured(self):
        self.assertEqual(rollup.llm_mini.model_id,
                         MODEL_CONFIG['providers']['bedrock'][MODEL_CONFIG['chapter_rollup']['generation_tier']])
        self.assertEqual(rollup.llm_grounding.model_id,
                         MODEL_CONFIG['providers']['bedrock'][MODEL_CONFIG['chapter_rollup']['grounding_tier']])


if __name__ == '__main__':
    unittest.main()
