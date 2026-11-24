"""Cache only identical inference dependencies; no external requests in this suite."""

import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from utils.llm.clients import create_openrouter_llm
from utils.llm.prompt_registry import ResolvedPrompt
from utils.llm import prompt_registry
from utils.timeline import rollup, store
from utils.timeline.summary_dependencies import digest, model_identity
from test_timeline_store import StoreTestBase, DayDb, convo, DEV, UID, DAY, _local_prompt


class DependencyTests(unittest.TestCase):
    def setUp(self):
        prompt_registry._override_client.cache_clear()
        self.addCleanup(prompt_registry._override_client.cache_clear)
        self.prompt_patch = patch.object(rollup, 'get_prompt', side_effect=_local_prompt)
        self.prompt_patch.start()
        self.addCleanup(self.prompt_patch.stop)

    def test_credentials_and_global_version_are_not_model_inputs(self):
        client = create_openrouter_llm('openai/gpt-6.1-sol')
        before = digest(model_identity(client))
        client.metadata = {'model_config_version': 'unrelated-image-update'}
        self.assertEqual(before, digest(model_identity(client)))
        identity = json.dumps(model_identity(client))
        self.assertNotIn('api_key', identity)
        self.assertNotIn('model_config_version', identity)
        self.assertIn('reasoning_effort', identity)

    def test_changed_inference_parameters_and_model_invalidate(self):
        baseline = digest(model_identity(create_openrouter_llm('openai/gpt-6.1-sol')))
        for model, options in [('openai/gpt-6.1-sol', {'reasoning_effort': 'medium'}),
                               ('openai/gpt-6.1-sol', {'max_tokens': 2000}),
                               ('anthropic/claude-sonnet-5.5', {})]:
            with self.subTest(model=model, options=options):
                self.assertNotEqual(baseline, digest(model_identity(create_openrouter_llm(model, **options))))

    def test_prompt_content_and_config_override_invalidate(self):
        before = rollup.resolve_summary_dependencies().fingerprint
        for content_suffix, config in [('Changed rule', {}), ('', {'model_id': 'anthropic/claude-sonnet-5.5'}),
                                        ('', {'model_id': 'openai/gpt-6.1-sol', 'reasoning_effort': 'medium'})]:
            def changed(key, fallback):
                result = _local_prompt(key, fallback)
                if key == 'timeline.chapter_grounding':
                    result.content += content_suffix
                    result.config = config
                return result
            with patch.object(rollup, 'get_prompt', side_effect=changed):
                self.assertNotEqual(before, rollup.resolve_summary_dependencies().fingerprint)

    def test_bad_template_is_resolved_before_fingerprinting(self):
        def broken(key, fallback):
            return ResolvedPrompt(key, '{{unknown_variable}}', {}, version=7, fallback_content=fallback.content)
        with patch.object(rollup, 'get_prompt', side_effect=broken):
            deps = rollup.resolve_summary_dependencies()
        self.assertTrue(deps.resolved.is_fallback)
        self.assertTrue(deps.grounding.is_fallback)
        before = deps.fingerprint
        request = rollup.prepare_rollup([{'source_text': 'Budget 37.', 'requires_rollup': True}], dependencies=deps)
        self.assertEqual(before, request.dependencies.fingerprint)

    def test_identical_registry_and_fallback_content_reuses_fingerprint(self):
        original = rollup.resolve_summary_dependencies()
        changed = copy.copy(original)
        changed.resolved = copy.deepcopy(original.resolved)
        changed.resolved.version = 17
        changed.resolved.label = 'production'
        changed.resolved.is_fallback = False
        self.assertEqual(original.fingerprint, changed.fingerprint)

    def test_provider_enum_and_typed_safety_settings_are_serializable(self):
        from google.genai.types import HarmCategory, HarmBlockThreshold, SafetySetting
        setting = SafetySetting(category=HarmCategory.HARM_CATEGORY_HATE_SPEECH,
                                threshold=HarmBlockThreshold.BLOCK_ONLY_HIGH)
        first = digest({'safety_settings': [setting]})
        self.assertEqual(first, digest({'safety_settings': [setting.model_dump(mode='json')]}))

    def test_pinned_model_reuses_client_but_changed_settings_get_a_new_one(self):
        default = object()
        resolved = ResolvedPrompt('test', 'body', {'model_id': 'openai/gpt-6.1-sol'})
        first = prompt_registry.resolve_llm(resolved, default)
        self.assertIs(first, prompt_registry.resolve_llm(resolved, default))
        resolved.config['reasoning_effort'] = 'medium'
        self.assertIsNot(first, prompt_registry.resolve_llm(resolved, default))

    def test_failed_override_construction_is_not_cached(self):
        default = object()
        resolved = ResolvedPrompt('test', 'body', {'model_id': 'openai/gpt-6.1-sol'})
        with patch('utils.llm.clients.create_model_llm', side_effect=[RuntimeError('unavailable'), 'recovered']):
            self.assertIs(default, prompt_registry.resolve_llm(resolved, default))
            self.assertEqual('recovered', prompt_registry.resolve_llm(resolved, default))

    def test_one_snapshot_survives_registry_change_during_day(self):
        deps = rollup.resolve_summary_dependencies()
        with patch.object(rollup, 'get_prompt', side_effect=AssertionError('must use the snapshot')):
            request = rollup.prepare_rollup([{'source_text': 'Budget 37.', 'requires_rollup': True}], dependencies=deps)
            self.assertEqual(deps.fingerprint, request.dependencies.fingerprint)


class DayDependencyTests(StoreTestBase):
    def setUp(self):
        super().setUp()
        self.db = DayDb([convo('a', 0), convo('b', 5)])

    def run_day(self):
        return store.recompute_day(self.db, self.redis, DEV, UID, DAY)

    def test_global_version_change_keeps_result_and_makes_zero_calls(self):
        original = self.run_day()['document']
        before = self.rollup.calls
        with patch.object(store, 'MODEL_CONFIG_VERSION', 'new-image-model-only'):
            result = self.run_day()
        self.assertEqual(result['status'], 'unchanged')
        self.assertEqual(original, result['document'])
        self.assertEqual(self.rollup.calls, before)

    def test_actual_model_parameter_change_recomputes_once(self):
        self.run_day()
        before = self.rollup.calls
        changed = create_openrouter_llm('openai/gpt-6.1-sol', reasoning_effort='medium')
        with patch.object(rollup, 'llm_grounding', changed):
            self.assertEqual(self.run_day()['status'], 'computed')
            self.assertEqual(self.rollup.calls, before + 1)
            self.assertEqual(self.run_day()['status'], 'unchanged')
            self.assertEqual(self.rollup.calls, before + 1)

    def test_prompt_only_change_reaches_chapter_despite_unchanged_transcript(self):
        self.run_day()
        before = self.rollup.calls
        def revised(key, fallback):
            p = _local_prompt(key, fallback)
            if key == 'timeline.chapter_grounding':
                p.content += '\nKeep each deadline.'
                p.version = 2
            return p
        with patch.object(rollup, 'get_prompt', side_effect=revised):
            self.assertEqual(self.run_day()['status'], 'computed')
            self.assertEqual(self.rollup.calls, before + 1)
            self.assertEqual(self.run_day()['status'], 'unchanged')

    def test_timezone_participates_in_day_identity(self):
        before = store.compute_fingerprint(self.db.convos, 'models', 'UTC')
        after = store.compute_fingerprint(self.db.convos, 'models', 'Asia/Shanghai')
        self.assertNotEqual(before, after)

    def test_invalid_timezone_is_stored_as_utc_and_then_hits(self):
        self.db.tz_name = 'Definitely/Not_A_Timezone'
        first = self.run_day()
        self.assertEqual(first['document']['timezone'], 'UTC')
        before = self.rollup.calls
        self.assertEqual(self.run_day()['status'], 'unchanged')
        self.assertEqual(self.rollup.calls, before)

    def test_legacy_cache_is_lazily_rebuilt_then_reused(self):
        original = self.run_day()['document']
        legacy = copy.deepcopy(original)
        legacy.pop('summary_fingerprint')
        legacy['fingerprint'] = 'old-global-config-fingerprint'
        for chapter in legacy['chapters']:
            chapter['rollup_key'] = 'r2-source-segments:2026-10-13.3:3:1:old-digest'
        self.db.store_timeline_day(DEV, UID, DAY.isoformat(), legacy)
        before = self.rollup.calls
        self.assertEqual(self.run_day()['status'], 'computed')
        self.assertEqual(self.rollup.calls, before + 1)
        self.assertEqual(self.run_day()['status'], 'unchanged')
        self.assertEqual(self.rollup.calls, before + 1)


if __name__ == '__main__':
    unittest.main()
