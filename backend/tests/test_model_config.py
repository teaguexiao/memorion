"""Regression checks for versioned model migrations and real request shapes."""

import ast
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault('OPENROUTER_API_KEY', 'test')
os.environ.setdefault('OPENAI_API_KEY', 'test')

from pydantic import BaseModel
from utils.llm import clients, model_config, prompt_registry


class Answer(BaseModel):
    answer: str


class ModelConfigValidationTests(unittest.TestCase):
    def load_changed(self, change):
        config = copy.deepcopy(model_config.MODEL_CONFIG)
        change(config)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'models.json'
            path.write_text(json.dumps(config))
            return model_config.load_model_config(path)

    def test_version_is_required(self):
        with self.assertRaisesRegex(ValueError, 'version'):
            self.load_changed(lambda config: config.pop('version'))

    def test_unknown_schema_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'schema_version'):
            self.load_changed(lambda config: config.update(schema_version=2))

    def test_missing_tier_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            self.load_changed(lambda config: config['providers']['openrouter'].pop('mini'))

    def test_summary_route_is_validated(self):
        for field in ('provider', 'model_tier'):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'conversation_summary'):
                self.load_changed(lambda config: config['conversation_summary'].update({field: 'typo'}))

    def test_image_route_requires_valid_gemini_tier(self):
        for change in ({'provider': 'openrouter'}, {'model_tier': 'typo'}):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'image_description'):
                self.load_changed(lambda config: config['image_description'].update(change))

    def test_invalid_thinking_level_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'thinking_level'):
            self.load_changed(lambda config: config['model_parameters'].update({
                'gemini-3.8-flash': {'thinking_level': 'minimal'},
            }))

    def test_image_review_requires_registered_bedrock_model_and_region(self):
        for route in ({}, None, {'model_id': '', 'location': 'global'},
                      {'provider': 'gemini', 'model_id': 'reviewer', 'region': 'us-east-1'},
                      {'provider': 'bedrock', 'model_id': 'unknown', 'region': 'us-east-1'},
                      {'provider': 'bedrock', 'model_id': 'global.anthropic.claude-sonnet-5-5', 'region': 'unknown'}):
            with self.subTest(route=route), self.assertRaisesRegex(ValueError, 'image_generation_review'):
                self.load_changed(lambda config: config.update(image_generation_review=route))

    def test_image_generation_requires_model_and_global_endpoint(self):
        invalid_routes = ({}, None, {'model_id': '', 'location': 'global'},
                          {'model_id': None, 'location': 'global'},
                          {'model_id': 'gemini-3.1-flash-lite-image', 'location': 'us-central1'},
                          {'model_id': 'image-model', 'location': 'global', 'api_key': 'forbidden'})
        for route in invalid_routes:
            with self.subTest(route=route), self.assertRaisesRegex(ValueError, 'image_generation'):
                self.load_changed(lambda config: config.update(image_generation=route))

    def test_cleaner_default_requires_a_registered_model_id(self):
        for invalid in ('', None, 'gemini-unknown', 'google/gemini-unknown'):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, 'transcript_cleaner'):
                self.load_changed(lambda config: config['transcript_cleaner'].update(model_id=invalid))

    def test_model_routes_reject_unknown_targets(self):
        with self.assertRaisesRegex(ValueError, 'model_routes'):
            self.load_changed(lambda config: config['model_routes'].update({
                'google/gemini-3.8-flash': 'gemini-unknown',
            }))

    def test_cyclic_migration_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Cyclic'):
            self.load_changed(lambda config: config.update(replacements={'a': 'b', 'b': 'a'}))

    def test_model_config_cannot_override_credentials_or_endpoint(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported model parameters'):
            self.load_changed(lambda config: config['model_parameters'].update({'example': {'base_url': 'wrong'}}))


class ModelRoutingTests(unittest.TestCase):
    def test_summary_role_overrides_container_provider(self):
        route = model_config.MODEL_CONFIG['conversation_summary']
        expected = model_config.model_map(route['provider'])[route['model_tier']]
        for container_provider in ('openrouter', 'gemini'):
            with self.subTest(provider=container_provider), mock.patch.object(clients, 'LLM_PROVIDER', container_provider):
                client = clients.create_llm(**route)
                self.assertEqual(client.model_id, expected)
                self.assertEqual(client.metadata['model_config_version'], model_config.MODEL_CONFIG_VERSION)

    def test_initial_and_reprocessed_summaries_use_the_configured_role(self):
        from datetime import datetime, timezone
        from langchain_core.messages import AIMessage
        from utils.llm import conversation_processing as cp
        response_client = mock.Mock()
        response_client.invoke.return_value = AIMessage(content='{"title":"test","overview":"test"}')

        def fallback(key, fallback):
            return prompt_registry.ResolvedPrompt(key=key, content=fallback.content, config={})

        with mock.patch.object(cp, 'get_prompt', side_effect=fallback), \
                mock.patch.object(cp, 'resolve_llm', return_value=response_client) as resolver:
            for method in (cp.get_transcript_structure, cp.get_reprocess_transcript_structure):
                extra = {'title': ''} if method is cp.get_reprocess_transcript_structure else {}
                method('User: hello', datetime(2026, 10, 13, tzinfo=timezone.utc), 'en', 'UTC', **extra)
                self.assertIs(resolver.call_args.args[1], cp.llm_summary)

    def test_all_old_default_routes_are_replaced(self):
        for provider in ('openrouter', 'bedrock', 'gemini'):
            for model in model_config.model_map(provider).values():
                self.assertNotIn('haiku', model)
                self.assertNotIn('gpt-4.1', model)

    def test_gemini_migrates_without_changing_other_provider_tiers(self):
        self.assertEqual(set(clients.GEMINI_MODELS.values()), {'gemini-3.8-flash'})
        self.assertEqual(clients.OPENROUTER_MODELS['medium'], 'anthropic/claude-sonnet-5.5')
        self.assertEqual(clients.BEDROCK_MODELS['medium_experiment'], 'global.openai.gpt-6.1-sol')

    def test_sonnet_migration_preserves_structured_output_and_bounds_reservation(self):
        client = clients.create_openrouter_llm('anthropic/claude-sonnet-5', temperature=0.8)
        self.assertEqual(client.model_name, 'anthropic/claude-sonnet-5.5')
        self.assertEqual(client.max_tokens, 16384)
        self.assertIsNone(client.temperature)
        # The OpenRouter path uses JSON schema, not unsupported forced tool choice.
        bound = client.with_structured_output(Answer).first
        self.assertEqual(bound.kwargs['response_format'], Answer)
        self.assertNotIn('tool_choice', bound.kwargs)

    def test_bedrock_sonnet_structured_output_never_forces_tool_choice(self):
        client = clients.create_llm('medium', provider='bedrock')
        self.assertEqual(client.model_id, 'global.anthropic.claude-sonnet-5-5')
        self.assertEqual(list(client.supports_tool_choice_values), ['auto'])
        bound = client.with_structured_output(Answer).first
        self.assertIsNone(bound.kwargs.get('tool_choice'))
        self.assertEqual(client.max_tokens, 16384)

    def test_route_reads_configuration_instead_of_a_business_code_literal(self):
        with mock.patch.dict(model_config.MODEL_CONFIG['providers']['openrouter'], mini='test/future-model'):
            self.assertEqual(model_config.model_map('openrouter')['mini'], 'test/future-model')

    def test_parameters_are_copied_not_mutated_by_caller(self):
        model = clients.BEDROCK_MODELS['mini']
        params = model_config.model_parameters(model)
        params['additional_model_request_fields']['reasoning']['effort'] = 'high'
        self.assertEqual(model_config.model_parameters(model)['additional_model_request_fields']['reasoning']['effort'], 'none')

    def test_luna_tool_call_payload_disables_reasoning_and_sampling(self):
        client = clients.create_openrouter_llm('anthropic/claude-haiku-4.5', temperature=0.8)
        bound = client.bind_tools([Answer], tool_choice='Answer')
        payload = client._get_request_payload('Answer yes', **bound.kwargs)
        self.assertEqual(payload['model'], 'openai/gpt-6-luna')
        self.assertEqual(payload['reasoning_effort'], 'none')
        self.assertNotIn('temperature', payload)
        self.assertIn('tools', payload)
        self.assertEqual(client.metadata['model_config_version'], model_config.MODEL_CONFIG_VERSION)

    def test_sol_plain_completion_payload_uses_supported_reasoning(self):
        client = clients.create_openrouter_llm('openai/gpt-4.1', temperature=0.3, max_tokens=8192)
        payload = client._get_request_payload('Write a summary')
        self.assertEqual(payload['model'], 'openai/gpt-6.1-sol')
        self.assertEqual(payload['reasoning_effort'], 'low')
        self.assertNotIn('temperature', payload)
        self.assertEqual(payload.get('max_completion_tokens', payload.get('max_tokens')), 8192)

    def test_persona_stream_keeps_streaming_without_unsupported_temperature(self):
        with mock.patch.object(clients, 'LLM_PROVIDER', 'openrouter'):
            client = clients.create_llm('persona_mini', streaming=True, temperature=0.8)
        self.assertFalse(client.disable_streaming)
        self.assertEqual(client.model_id, 'global.openai.gpt-6-luna')
        self.assertIsNone(client.temperature)

    def test_bedrock_uses_configured_luna_tool_capabilities(self):
        with mock.patch.object(clients, 'LLM_PROVIDER', 'bedrock'), \
             mock.patch.object(clients, 'ConfiguredChatBedrockConverse') as constructor:
            clients.create_llm('mini', temperature=0.8)
        kwargs = constructor.call_args.kwargs
        self.assertEqual(kwargs['model'], 'global.openai.gpt-6-luna')
        self.assertEqual(kwargs['additional_model_request_fields'], {'reasoning': {'effort': 'none'}})
        self.assertIn('tool', kwargs['supports_tool_choice_values'])
        self.assertNotIn('temperature', kwargs)

    def test_gemini_uses_thinking_level_instead_of_sampling(self):
        with mock.patch.object(clients, 'LLM_PROVIDER', 'gemini'), \
             mock.patch.object(clients, 'ConfiguredChatGoogleGenerativeAI') as constructor:
            clients.create_llm('mini', streaming=True, temperature=0.8)
        self.assertEqual(constructor.call_args.kwargs['model'], 'gemini-3.8-flash')
        self.assertEqual(constructor.call_args.kwargs['thinking_level'], 'low')
        self.assertNotIn('temperature', constructor.call_args.kwargs)
        self.assertTrue(constructor.call_args.kwargs['vertexai'])
        self.assertEqual(constructor.call_args.kwargs['location'], 'global')

    def test_gemini_sdk_defaults_and_invoke_overrides_are_removed_from_wire_payload(self):
        from google.auth.credentials import AnonymousCredentials
        from langchain_core.messages import HumanMessage

        client = clients.ConfiguredChatGoogleGenerativeAI(
            model='gemini-3.8-flash', project='test', location='global', vertexai=True,
            credentials=AnonymousCredentials(), thinking_level='low',
        )
        bound = client.bind_tools([Answer])
        for options in ({}, {'temperature': 0.2, 'top_p': 0.8, 'top_k': 10}, bound.kwargs):
            with self.subTest(options=options):
                request = client._prepare_request([HumanMessage(content='Say yes')], **options)
                config = request['config'].model_dump(exclude_none=True)
                for key in ('temperature', 'top_p', 'top_k', 'candidate_count'):
                    self.assertNotIn(key, config)
                self.assertEqual(config['thinking_config']['thinking_level'].lower(), 'low')
                if options is bound.kwargs:
                    self.assertIn('tools', config)

    def test_older_gemini_request_keeps_supported_sampling(self):
        from google.auth.credentials import AnonymousCredentials
        from langchain_core.messages import HumanMessage

        client = clients.ConfiguredChatGoogleGenerativeAI(
            model='gemini-2.5-flash', project='test', vertexai=True,
            credentials=AnonymousCredentials(), temperature=0.2,
        )
        config = client._prepare_request([HumanMessage(content='Say yes')])['config']
        self.assertEqual(config.temperature, 0.2)


class RegistryMigrationTests(unittest.TestCase):
    def setUp(self):
        from utils.llm import transcript_cleaner
        transcript_cleaner._create_cleaner_client.cache_clear()
        prompt_registry._override_client.cache_clear()

    def tearDown(self):
        self.setUp()

    def test_unpinned_prompt_preserves_provider_specific_default(self):
        default = object()
        resolved = prompt_registry.ResolvedPrompt(key='test', content='test', config={})
        self.assertIs(prompt_registry.resolve_llm(resolved, default), default)

    def test_old_pinned_model_follows_migration_and_keeps_prompt_options(self):
        resolved = prompt_registry.ResolvedPrompt(
            key='test', content='test', version=7,
            config={'model_id': 'openai/gpt-4.1', 'temperature': 0.7, 'max_tokens': 8192, 'reasoning_effort': 'medium'},
        )
        client = prompt_registry.resolve_llm(resolved, object())
        self.assertEqual(client.model_id, 'global.openai.gpt-6.1-sol')
        self.assertEqual(client.additional_model_request_fields['reasoning']['effort'], 'medium')
        self.assertEqual(client.max_tokens, 8192)
        self.assertIsNone(client.temperature)

    def test_unrelated_pinned_model_is_not_migrated(self):
        resolved = prompt_registry.ResolvedPrompt(
            key='test', content='test', config={'model_id': 'openai/gpt-4o-mini', 'temperature': 0.3},
        )
        client = prompt_registry.resolve_llm(resolved, object())
        self.assertEqual(client.model_name, 'openai/gpt-4o-mini')
        self.assertEqual(client.temperature, 0.3)

    def test_transcript_cleaner_cannot_restore_old_pinned_model(self):
        from utils.llm import transcript_cleaner

        with mock.patch.object(transcript_cleaner, '_fetch_production_model', return_value='anthropic/claude-haiku-4.5'):
            client = transcript_cleaner._get_llm_client()
        self.assertEqual(client.model_id, 'global.openai.gpt-6-luna')
        self.assertEqual(client.max_tokens, 4096)
        self.assertIsNone(client.temperature)

    def test_cleaner_old_selection_and_outage_fallback_both_use_new_flash(self):
        from google.auth.credentials import AnonymousCredentials
        from langchain_core.messages import HumanMessage
        from utils.llm import transcript_cleaner

        constructor = clients.ConfiguredChatGoogleGenerativeAI
        for selected in ('google/gemini-2.5-flash', 'google/gemini-3.8-flash', 'gemini-3.8-flash', None):
            with self.subTest(selected=selected), mock.patch.object(
                transcript_cleaner, '_fetch_production_model', return_value=selected,
            ), mock.patch.object(clients, 'ConfiguredChatGoogleGenerativeAI', side_effect=lambda **kwargs:
                                 constructor(credentials=AnonymousCredentials(), **kwargs)), \
                    mock.patch.object(clients, 'create_openrouter_llm') as openrouter:
                client = transcript_cleaner._get_llm_client()
                request = client._prepare_request([HumanMessage(content='Clean this transcript')])
                payload = request['config'].model_dump(exclude_none=True)
                self.assertEqual(client.model, 'gemini-3.8-flash')
                self.assertTrue(client.client.vertexai)
                self.assertEqual(client.project, clients.GOOGLE_CLOUD_PROJECT)
                self.assertEqual(client.location, 'global')
                self.assertEqual(payload['thinking_config']['thinking_level'].lower(), 'low')
                self.assertEqual(payload['max_output_tokens'], 4096)
                for key in ('temperature', 'top_p', 'top_k', 'candidate_count'):
                    self.assertNotIn(key, payload)
                openrouter.assert_not_called()

    def test_gemini_registry_pin_routes_to_vertex_and_explicit_comparison_keeps_openrouter(self):
        from google.auth.credentials import AnonymousCredentials
        from langchain_core.messages import HumanMessage

        resolved = prompt_registry.ResolvedPrompt(
            key='test', content='test', config={'model_id': 'google/gemini-2.5-flash',
                                             'reasoning_effort': 'medium', 'max_tokens': 2048},
        )
        constructor = clients.ConfiguredChatGoogleGenerativeAI
        with mock.patch.object(clients, 'ConfiguredChatGoogleGenerativeAI', side_effect=lambda **kwargs:
                               constructor(credentials=AnonymousCredentials(), **kwargs)):
            client = prompt_registry.resolve_llm(resolved, object())
        self.assertEqual(client.model, 'gemini-3.8-flash')
        payload = client._prepare_request([HumanMessage(content='Say yes')])['config'].model_dump(exclude_none=True)
        self.assertEqual(payload['thinking_config']['thinking_level'].lower(), 'medium')
        self.assertEqual(payload['max_output_tokens'], 2048)
        self.assertNotIn('reasoning_effort', payload)
        client = clients.create_model_llm('google/gemini-2.5-flash', provider='gemini',
                                          credentials=AnonymousCredentials())
        self.assertEqual(client.model, 'gemini-3.8-flash')
        self.assertTrue(client.client.vertexai)
        comparison = clients.create_model_llm('google/gemini-2.5-flash', provider='openrouter')
        self.assertEqual(comparison.model_name, 'google/gemini-3.8-flash')

    def test_gemini_legacy_reasoning_extremes_use_supported_vertex_levels(self):
        from google.auth.credentials import AnonymousCredentials
        from langchain_core.messages import HumanMessage

        for effort, level in (('none', 'low'), ('minimal', 'low'), ('xhigh', 'high'), ('max', 'high')):
            with self.subTest(effort=effort):
                client = clients.create_gemini_llm('gemini-3.8-flash', reasoning_effort=effort,
                                                  credentials=AnonymousCredentials())
                request = client._prepare_request([HumanMessage(content='Say yes')])['config']
                self.assertEqual(request.thinking_config.thinking_level.value.lower(), level)
        with self.assertRaisesRegex(ValueError, 'Unsupported Gemini effort'):
            clients.create_gemini_llm('gemini-3.8-flash', reasoning_effort='typo')

    def test_cleaner_reuses_canonical_client_and_switches_when_dashboard_model_changes(self):
        from utils.llm import transcript_cleaner

        vertex, bedrock = object(), object()
        with mock.patch.object(transcript_cleaner, '_fetch_production_model', side_effect=[
            'google/gemini-2.5-flash', 'gemini-3.8-flash', None, 'anthropic/claude-haiku-4.5',
        ]), mock.patch.object(transcript_cleaner, 'create_model_llm', side_effect=[vertex, bedrock]) as factory:
            for _ in range(3):
                self.assertIs(transcript_cleaner._get_llm_client(), vertex)
            self.assertIs(transcript_cleaner._get_llm_client(), bedrock)
        self.assertEqual(factory.call_args_list, [
            mock.call('gemini-3.8-flash', temperature=0.3, max_tokens=4096),
            mock.call('global.openai.gpt-6-luna', temperature=0.3, max_tokens=4096),
        ])


class BenchmarkModelCompatibilityTests(unittest.TestCase):
    def call_payload(self, model_id, **options):
        # Exercise the standalone runner's actual REST helper without Modal,
        # database access, or a network request.
        path = Path(__file__).resolve().parents[1] / 'modal' / 'benchmark_runner.py'
        tree = ast.parse(path.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                        and node.name == 'call_openrouter')
        namespace = dict(globals(), _MODEL_CONFIG=model_config.MODEL_CONFIG,
                         OPENROUTER_URL='https://openrouter.ai/api/v1/chat/completions')
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), 'exec'), namespace)
        response = mock.Mock(status_code=200)
        response.json.return_value = {'choices': [{'message': {'content': 'ok'}}]}
        with mock.patch('httpx.post', return_value=response) as post:
            namespace['call_openrouter'](model_id, [{'role': 'user', 'content': 'test'}], **options)
        return post.call_args.kwargs['json']

    def test_fallback_judge_uses_configured_reasoning_and_omits_temperature(self):
        judge = model_config.MODEL_CONFIG['benchmark_default_judges'][1]['model_id']
        payload = self.call_payload(judge, temperature=0.0, max_tokens=2048)
        self.assertEqual(payload['model'], clients.OPENROUTER_MODELS['mini'])
        self.assertEqual(payload['reasoning_effort'], 'none')
        self.assertNotIn('temperature', payload)
        self.assertEqual(payload['max_tokens'], 2048)

    def test_explicit_historical_comparison_keeps_original_model_and_sampling(self):
        payload = self.call_payload('anthropic/claude-haiku-4.5', temperature=0.0)
        self.assertEqual(payload['model'], 'anthropic/claude-haiku-4.5')
        self.assertEqual(payload['temperature'], 0.0)
        self.assertNotIn('reasoning_effort', payload)


if __name__ == '__main__':
    unittest.main()
