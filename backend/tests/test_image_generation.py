"""Exercise the daily illustration's Vertex request and response contract."""

import ast
import struct
import zlib
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from google.genai import types
from google.auth.credentials import AnonymousCredentials
from utils.llm import image_generation as images
from utils.llm.daily_journal_identity import CONFIRMED_FACTS_LIMIT  # noqa: E402
from utils.llm.daily_illustration_sources import IllustrationSources
from utils.llm.prompt_registry import ResolvedPrompt


SUMMARY = 'A quiet morning gardening, followed by dinner with friends.'


def response_with(*parts):
    return types.GenerateContentResponse(candidates=[
        types.Candidate(content=types.Content(parts=list(parts))),
    ])


class ImageGenerationTests(unittest.TestCase):
    def setUp(self):
        self.review_patch = mock.patch.object(images, '_review_candidate', return_value=images.IllustrationReview(issues=[]))
        self.review_mock = self.review_patch.start()
        self.addCleanup(self.review_patch.stop)
        self.prompt = ResolvedPrompt(key='test', content='Draw {{scene_sources}}; facts={{character_facts}}', config={}, version=1)
        self.prompt_patch = mock.patch.object(images, 'get_prompt', return_value=self.prompt)
        self.prompt_patch.start()
        self.sources_patch = mock.patch.object(images, 'select_daily_illustration_sources',
                                               side_effect=lambda text: IllustrationSources(events=[text]))
        self.sources_mock = self.sources_patch.start()
        self.addCleanup(self.sources_patch.stop)
        self.addCleanup(self.prompt_patch.stop)
        self.factory_patch = mock.patch.object(images, 'create_gemini_client')
        self.factory = self.factory_patch.start()
        self.addCleanup(self.factory_patch.stop)
        self.client = self.factory.return_value.__enter__.return_value
        self.bedrock_patch = mock.patch.object(images.boto3, 'client')
        self.bedrock_factory = self.bedrock_patch.start()
        self.addCleanup(self.bedrock_patch.stop)
        self.reviewer = self.bedrock_factory.return_value

    def test_registered_model_square_png_and_final_image_are_used(self):
        self.client.models.generate_content.return_value = response_with(
            types.Part(text='A warm illustration.'),
            types.Part(thought=True, inline_data=types.Blob(mime_type='image/png', data=b'draft')),
            types.Part(inline_data=types.Blob(mime_type='image/png', data=b'')),
            types.Part(inline_data=types.Blob(mime_type='audio/wav', data=b'audio')),
            types.Part.from_bytes(data=b'final-png', mime_type='image/png'),
        )
        # A registry change must reach the provider, without a business-code literal.
        with mock.patch.dict(images.MODEL_CONFIG['image_generation'], model_id='future-image-model'):
            self.assertEqual(images.generate_daily_summary_image(SUMMARY), b'final-png')
        request = self.client.models.generate_content.call_args.kwargs
        self.assertEqual(request['model'], 'future-image-model')
        self.assertEqual(request['contents'], f'Draw {json.dumps(dict(events=[SUMMARY], objects=[]))}; facts=[]')
        config = request['config'].model_dump(exclude_none=True)
        self.assertEqual(config['response_modalities'], ['IMAGE', 'TEXT'])
        self.assertEqual(config['max_output_tokens'], 4096)
        self.assertEqual(config['image_config'], {
            'aspect_ratio': '1:1', 'image_size': '1K', 'output_mime_type': 'image/png',
        })
        self.assertNotIn('thinking_config', config)  # Use the image model's supported default.
        self.factory.return_value.__exit__.assert_called_once()

    def test_image_provider_receives_confirmed_identity_constraints(self):
        facts = ['I have exactly one child.', 'I do not wear glasses.']
        self.client.models.generate_content.return_value = response_with(
            types.Part.from_bytes(data=b'png', mime_type='image/png'))
        self.assertEqual(images.generate_daily_summary_image(SUMMARY, character_facts=facts), b'png')
        self.assertIn(json.dumps(facts), self.client.models.generate_content.call_args.kwargs['contents'])

    def test_source_selection_failure_never_sends_raw_diary_to_image_provider(self):
        self.sources_mock.side_effect = ValueError('No grounded sources')
        self.assertIsNone(images.generate_daily_summary_image(SUMMARY))
        self.factory.assert_not_called()

    def test_global_client_does_not_inherit_regional_environment(self):
        # Temporarily restore the real factory to inspect SDK construction only.
        self.factory_patch.stop()
        with mock.patch.dict('os.environ', GOOGLE_CLOUD_LOCATION='us-central1'), \
                mock.patch.object(images.genai, 'Client') as sdk:
            images.create_gemini_client()
        sdk.assert_called_once_with(vertexai=True, project=images.GOOGLE_CLOUD_PROJECT, location='global',
                                    http_options=types.HttpOptions(timeout=90_000,
                                        retry_options=types.HttpRetryOptions(attempts=1)))

    def test_installed_sdk_client_supports_context_manager(self):
        # Exercise the real pinned SDK without an inference call or credentials.
        with images.genai.Client(vertexai=True, project='test', location='global',
                                 credentials=AnonymousCredentials()) as client:
            self.assertIsInstance(client, images.genai.Client)

    def test_complete_diary_and_identity_facts_reach_registry_prompt(self):
        summary = '日' * 1800 + '我只有一个孩子，我不戴眼镜。'
        facts = ['I have exactly one child.', 'I do not wear glasses.']
        prompt = images.build_daily_summary_image_prompt(summary, 'zh', character_facts=facts)
        self.assertIn(summary, prompt)
        self.sources_mock.assert_called_once_with(summary)
        self.assertIn(json.dumps(facts, ensure_ascii=False), prompt)
        images.get_prompt.assert_called_once_with(images.DAILY_ILLUSTRATION_PROMPT_KEY,
                                                   fallback=images._DAILY_ILLUSTRATION)

    def test_fallback_is_available_for_new_registry_key_and_seed_matches(self):
        fallback = ResolvedPrompt(key='test', content=images._DAILY_ILLUSTRATION.content,
                                  config={}, is_fallback=True)
        with mock.patch.object(images, 'get_prompt', return_value=fallback):
            prompt = images.build_daily_summary_image_prompt(SUMMARY)
        self.assertNotIn('{{', prompt)
        self.assertIn('ONE IMAGE, ADAPTIVE REGIONS', prompt)
        records = json.loads((Path(__file__).resolve().parents[1] /
                              'scripts/benchmark/seed_prompts/misc.json').read_text())
        record = next(r for r in records if r['key'] == images.DAILY_ILLUSTRATION_PROMPT_KEY)
        self.assertEqual(record['content'], images._DAILY_ILLUSTRATION.content)
        review = next(r for r in records if r['key'] == 'image_generation.daily_illustration_review_v1')
        self.assertEqual(review['content'], images._REVIEW.content)

    def test_confirmed_facts_are_scoped_and_rejected_facts_never_reach_image(self):
        records = [
            {'content': 'I have one child.', 'user_review': True},
            {'content': 'I do not wear glasses.', 'manually_added': True},
            {'content': 'I have two children.'},
            {'content': 'I wear glasses.', 'manually_added': True, 'user_review': False},
            {'content': 'Deleted fact', 'user_review': True, 'deleted': True},
            {'content': ' ', 'user_review': True},
            {'content': None, 'user_review': True},
        ]
        database = SimpleNamespace(get_memories=mock.Mock(return_value=records))
        with mock.patch.dict(sys.modules, {'database': SimpleNamespace(developer_data=database)}):
            facts = images.get_daily_illustration_facts('tenant-A', 'user-A')
        self.assertEqual(facts, ['I have one child.', 'I do not wear glasses.'])
        database.get_memories.assert_called_once_with(developer_id='tenant-A',
                                                     external_user_id='user-A', limit=CONFIRMED_FACTS_LIMIT,
                                                     status='confirmed')

    def test_identity_facts_older_than_the_newest_hundred_still_reach_the_image(self):
        # 只读最新 100 条时，一个用户的「你的妻子……」比第 100 新的事实早了九个月，配图从没见过它；
        # 这一天又没有任何事实说「我是爸爸」，于是「我」被画成了女性（2026-10-25、10-27）。
        records = [{'content': f'你喜欢第{i}种水果。', 'user_review': True} for i in range(150)]
        records.append({'content': '我是小草的爸爸', 'manually_added': True})
        records.append({'content': '你的妻子是一名产品经理。', 'user_review': True})
        database = SimpleNamespace(get_memories=mock.Mock(return_value=records))
        with mock.patch.dict(sys.modules, {'database': SimpleNamespace(developer_data=database)}):
            facts = images.get_daily_illustration_facts('tenant-A', 'user-A')
        self.assertEqual(facts[:2], ['我是小草的爸爸', '你的妻子是一名产品经理。'])
        self.assertEqual(len(facts), images.DAILY_ILLUSTRATION_FACTS_LIMIT)
        self.assertEqual(len(facts), len(set(facts)))

    def test_gender_comes_only_from_confirmed_facts_in_drawing_and_review(self):
        # 生成和质检必须同口径：只改生成，质检照样放行一个画成女性的「爸爸」。
        self.assertIn('Gender comes only from the confirmed facts', images._DAILY_ILLUSTRATION.content)
        self.assertIn('Chinese 他/她 sound the same', images._DAILY_ILLUSTRATION.content)
        self.assertIn('a narrator confirmed as a father is never drawn as a woman', images._REVIEW.content)

    def test_facts_lookup_failure_uses_unknown_appearance_instead_of_failing_diary(self):
        database = SimpleNamespace(get_memories=mock.Mock(side_effect=RuntimeError('offline')))
        with mock.patch.dict(sys.modules, {'database': SimpleNamespace(developer_data=database)}):
            self.assertEqual(images.get_daily_illustration_facts('tenant-A', 'user-A'), [])

    def test_short_or_blank_input_does_not_call_provider(self):
        for summary in (None, '', '   ', 'short'):
            with self.subTest(summary=summary):
                self.assertIsNone(images.generate_daily_summary_image(summary))
        self.factory.assert_not_called()

    def test_empty_blocked_text_only_and_wrong_format_return_none(self):
        for response in (
            types.GenerateContentResponse(),
            types.GenerateContentResponse(candidates=[types.Candidate(finish_reason='SAFETY')]),
            response_with(types.Part(text='Unable to generate an image.')),
            response_with(types.Part.from_bytes(data=b'jpeg', mime_type='image/jpeg')),
            response_with(types.Part(thought=True, inline_data=types.Blob(mime_type='image/png', data=b'draft'))),
        ):
            with self.subTest(response=response):
                self.client.models.generate_content.return_value = response
                self.assertIsNone(images.generate_daily_summary_image(SUMMARY))

    def test_provider_error_returns_none_and_closes_client(self):
        self.client.models.generate_content.side_effect = RuntimeError('synthetic provider failure')
        self.assertIsNone(images.generate_daily_summary_image(SUMMARY))
        self.factory.return_value.__exit__.assert_called_once()

    def test_client_initialization_error_is_optional_image_failure(self):
        self.factory.side_effect = RuntimeError('synthetic credential failure')
        self.assertIsNone(images.generate_daily_summary_image(SUMMARY))

    def test_retry_recovers_then_stops(self):
        with mock.patch.object(images, '_generate_candidate', side_effect=[None, b'png']) as generate:
            self.assertEqual(images.generate_daily_summary_image_with_retry(SUMMARY, 'zh'), b'png')
        self.assertEqual(generate.call_count, 2)
        self.sources_mock.assert_called_once_with(SUMMARY)
        self.review_mock.assert_called_once()

    def test_character_constraints_are_preserved_on_every_retry(self):
        facts = ['I have exactly one child.', 'I do not wear glasses.']
        with mock.patch.object(images, '_generate_candidate', side_effect=[None, b'png']) as generate:
            self.assertEqual(images.generate_daily_summary_image_with_retry(
                SUMMARY, 'zh', character_facts=facts), b'png')
        self.assertEqual(generate.call_count, 2)
        for call in generate.call_args_list:
            self.assertIn(json.dumps(facts), call.args[1])
        self.sources_mock.assert_called_once_with(SUMMARY)

    def test_two_entries_draw_their_pictures_one_at_a_time(self):
        # The journal worker writes two entries at once; their pictures must not overlap.
        import threading
        drawing, overlap, first_started = [], [], threading.Event()
        release_first = threading.Event()

        def candidate(*args, **kwargs):
            overlap.append(len(drawing))
            drawing.append(1)
            if not first_started.is_set():
                first_started.set()
                release_first.wait(5)
            drawing.pop()
            return b'png'

        with mock.patch.object(images, '_generate_candidate', side_effect=candidate):
            first = threading.Thread(target=images.generate_daily_summary_image_with_retry, args=(SUMMARY,))
            first.start()
            self.assertTrue(first_started.wait(5))
            second = threading.Thread(target=images.generate_daily_summary_image_with_retry, args=(SUMMARY,))
            second.start()
            second.join(0.2)
            self.assertTrue(second.is_alive(), 'the second picture started while the first was drawing')
            release_first.set()
            first.join(5)
            second.join(5)
        self.assertEqual([0, 0], overlap)

    def test_picture_that_waits_too_long_is_omitted(self):
        import threading
        results = []
        with mock.patch.object(images, '_ILLUSTRATION_WAIT_SECONDS', 0.05), \
                mock.patch.object(images, '_generate_candidate', return_value=b'png') as generate:
            self.assertTrue(images._ILLUSTRATION_SLOT.acquire(timeout=1))
            waiting = threading.Thread(target=lambda: results.append(
                images.generate_daily_summary_image_with_retry(SUMMARY)))
            try:
                waiting.start()
                waiting.join(2)
                self.assertFalse(waiting.is_alive(), 'waited for the slot without its limit')
            finally:
                images._ILLUSTRATION_SLOT.release()
                waiting.join(5)
            self.assertEqual([None], results)
            generate.assert_not_called()
            self.assertEqual(b'png', images.generate_daily_summary_image_with_retry(SUMMARY))

    def test_retry_exhaustion_is_bounded_to_three_attempts(self):
        with mock.patch.object(images, '_generate_candidate', return_value=None) as generate:
            self.assertIsNone(images.generate_daily_summary_image_with_retry(SUMMARY))
        self.assertEqual(generate.call_count, 3)

    def test_rejected_candidate_is_edited_then_reviewed_before_return(self):
        self.review_mock.side_effect = [images.IllustrationReview(issues=['Blank bottom wedge']),
                                        images.IllustrationReview(issues=[])]
        with mock.patch.object(images, '_generate_candidate', side_effect=[b'bad', b'fixed']) as generate:
            self.assertEqual(images.generate_daily_summary_image_with_retry(SUMMARY), b'fixed')
        self.assertEqual(generate.call_args_list[1].args[2:], (b'bad', ['Blank bottom wedge']))
        self.assertEqual(self.review_mock.call_count, 2)
        self.sources_mock.assert_called_once_with(SUMMARY)

    def test_all_visually_rejected_candidates_are_omitted_and_budget_is_capped(self):
        self.review_mock.return_value = images.IllustrationReview(issues=['Extra child'])
        with mock.patch.object(images, '_generate_candidate', return_value=b'bad') as generate:
            self.assertIsNone(images.generate_daily_summary_image_with_retry(SUMMARY, max_retries=99))
        self.assertEqual(generate.call_count, 3)

    def test_review_outage_never_returns_unreviewed_candidate(self):
        self.review_mock.side_effect = RuntimeError('review unavailable')
        with mock.patch.object(images, '_generate_candidate', return_value=b'unreviewed') as generate:
            self.assertIsNone(images.generate_daily_summary_image_with_retry(SUMMARY))
        generate.assert_called_once()

    def test_review_requires_explicit_valid_result_and_sees_actual_image(self):
        self.review_patch.stop()
        self.prompt_patch.stop()
        resolved = ResolvedPrompt(key='review', content=images._REVIEW.content, config={})
        self.prompt_patch = mock.patch.object(images, 'get_prompt', return_value=resolved)
        self.prompt_patch.start()
        self.addCleanup(self.prompt_patch.stop)
        for payload in ('', '{}', '{"issues": null}', '{"issues": "pass"}'):
            self.reviewer.converse.return_value = {'output': {'message': {'content': [{'text': payload}]}}}
            with self.subTest(payload=payload), self.assertRaises(Exception):
                images._review_candidate(self.client, b'png', 'Specification')
        self.reviewer.converse.return_value = {'output': {'message': {'content': [{'text': '{"issues": []}'}]}}}
        result = images._review_candidate(self.client, b'png', 'Specification')
        self.assertEqual(result.issues, [])
        request = self.reviewer.converse.call_args.kwargs
        self.assertEqual(request['messages'][0]['content'][1]['image']['source']['bytes'], b'png')
        self.assertEqual(request['modelId'], images.MODEL_CONFIG['image_generation_review']['model_id'])
        self.assertEqual(request['inferenceConfig'], {'maxTokens': 2048})
        options = self.bedrock_factory.call_args.kwargs
        self.assertEqual(options['region_name'], 'us-west-2')
        self.assertEqual(options['config'].read_timeout, 45)
        self.assertEqual(options['config'].connect_timeout, 5)
        self.assertEqual(options['config'].retries, {'total_max_attempts': 1})
        self.reviewer.close.assert_called()

    def test_review_uses_structured_submission(self):
        self.review_patch.stop()
        images.get_prompt.return_value = ResolvedPrompt(key='review', content=images._REVIEW.content, config={})
        self.reviewer.converse.return_value = {'output': {'message': {'content': [
            {'text': 'Visible bottom margin found.'},
            {'toolUse': {'name': 'submit_review', 'input': {'issues': ['Blank bottom margin']}}}]}}}
        result = images._review_candidate(self.client, b'png', 'facts')
        self.assertEqual(result.issues, ['Blank bottom margin'])
        request = self.reviewer.converse.call_args.kwargs
        self.assertEqual(request['toolConfig']['toolChoice'], {'auto': {}})
        self.reviewer.converse.return_value['output']['message']['content'][1]['toolUse']['input'] = {}
        with self.assertRaises(ValueError):
            images._review_candidate(self.client, b'png', 'facts')

    def test_edit_request_contains_candidate_and_grounded_specification(self):
        self.client.models.generate_content.return_value = response_with(
            types.Part.from_bytes(data=b'edited', mime_type='image/png'))
        self.assertEqual(images._generate_candidate(self.client, 'Grounded facts', b'original',
                                                   ['Paint bottom floor']), b'edited')
        request = self.client.models.generate_content.call_args.kwargs
        self.assertEqual(request['contents'][1].inline_data.data, b'original')
        self.assertIn('Grounded facts', request['contents'][0].text)
        self.assertIn('Paint bottom floor', request['contents'][0].text)

    def test_multi_event_guide_covers_canvas_and_contains_no_portrait(self):
        marker = 'SELECTED DIARY EVIDENCE (JSON; event clauses and object topic phrases):\n'
        self.assertIsNone(images._layout_reference(marker + json.dumps({'events': ['one']})))
        for count in (2, 3):
            prompt = marker + json.dumps({'events': ['event'] * count, 'objects': []})
            guide = images._layout_reference(prompt)
            self.assertTrue(guide.startswith(b'\x89PNG\r\n\x1a\n'))
            offset, compressed = 8, b''
            while offset < len(guide):
                length = struct.unpack('!I', guide[offset:offset + 4])[0]
                kind, data = guide[offset + 4:offset + 8], guide[offset + 8:offset + 8 + length]
                self.assertEqual(struct.unpack('!I', guide[offset + 8 + length:offset + 12 + length])[0],
                                 zlib.crc32(kind + data))
                if kind == b'IDAT':
                    compressed += data
                offset += 12 + length
            raw = zlib.decompress(compressed)
            self.assertEqual(len(raw), 256 * (1 + 256 * 3))
            colors = set()
            for row in range(256):
                scanline = raw[row * 769:(row + 1) * 769]
                self.assertEqual(scanline[0], 0)
                colors.update(tuple(scanline[i:i + 3]) for i in range(1, 769, 3))
            self.assertEqual(len(colors), count + 1)  # Only region fills + fine stroke.
            self.assertNotIn((255, 255, 255), colors)
            self.client.models.generate_content.return_value = response_with(
                types.Part.from_bytes(data=b'png', mime_type='image/png'))
            images._generate_candidate(self.client, prompt)
            contents = self.client.models.generate_content.call_args.kwargs['contents']
            self.assertEqual(contents[-1].inline_data.data, guide)
            self.assertIn('supplies no people', contents[-2].text)

    def test_review_uses_grounded_data_without_generator_typography_rules(self):
        self.review_patch.stop()
        facts, evidence = ['Exactly one child; no glasses'], {'events': [SUMMARY], 'objects': []}
        prompt = images._DAILY_ILLUSTRATION.content.replace('{{character_facts}}', json.dumps(facts))
        prompt = prompt.replace('{{scene_sources}}', json.dumps(evidence))
        images.get_prompt.return_value = ResolvedPrompt(key='review', content=images._REVIEW.content, config={})
        self.reviewer.converse.return_value = {'output': {'message': {'content': [{'text': '{"issues": []}'}]}}}
        images._review_candidate(self.client, b'png', prompt)
        review_prompt = self.reviewer.converse.call_args.kwargs['messages'][0]['content'][0]['text']
        self.assertIn(json.dumps(facts), review_prompt)
        self.assertIn(json.dumps(evidence), review_prompt)
        self.assertNotIn('no letter-like glyphs', review_prompt)

    def test_generation_reserves_review_time_and_caps_request_timeout(self):
        with mock.patch.object(images.time, 'monotonic', side_effect=[0, 170, 195, 200]), \
                mock.patch.object(images, '_generate_candidate', return_value=b'png') as generate:
            self.assertEqual(images.generate_daily_summary_image_with_retry(SUMMARY), b'png')
        self.assertEqual(generate.call_args.kwargs['timeout_ms'], 25_000)
        self.assertEqual(self.review_mock.call_args.kwargs['timeout_ms'], 45_000)

    def test_insufficient_budget_does_not_start_unreviewable_candidate(self):
        with mock.patch.object(images.time, 'monotonic', side_effect=[0, 196]), \
                mock.patch.object(images, '_generate_candidate') as generate:
            self.assertIsNone(images.generate_daily_summary_image_with_retry(SUMMARY))
        generate.assert_not_called()

    def test_expired_review_never_returns_candidate(self):
        with mock.patch.object(images.time, 'monotonic', side_effect=[0, 1, 230, 241]), \
                mock.patch.object(images, '_generate_candidate', return_value=b'png'):
            self.assertIsNone(images.generate_daily_summary_image_with_retry(SUMMARY))
        self.assertEqual(self.review_mock.call_args.kwargs['timeout_ms'], 10_000)

    def test_throttling_does_not_immediately_retry(self):
        error = RuntimeError('provider capacity')
        error.code = 429
        with mock.patch.object(images, '_generate_candidate', side_effect=error) as generate:
            self.assertIsNone(images.generate_daily_summary_image_with_retry(SUMMARY))
        generate.assert_called_once()

    def test_review_registry_cannot_drop_specification_and_request_is_bounded(self):
        self.review_patch.stop()
        images.get_prompt.return_value = ResolvedPrompt(key='review', content='Inspect image.', config={})
        self.reviewer.converse.return_value = {'output': {'message': {'content': [{'text': '{"issues": []}'}]}}}
        with mock.patch.dict(images.MODEL_CONFIG['image_generation_review'], model_id='review-alias'), \
                mock.patch.dict(images.MODEL_CONFIG['replacements'], {'review-alias': 'review-model'}):
            images._review_candidate(self.client, b'png', 'Exactly one child; no glasses', timeout_ms=2500)
        request = self.reviewer.converse.call_args.kwargs
        self.assertIn('Exactly one child; no glasses', request['messages'][0]['content'][0]['text'])
        self.assertEqual(request['modelId'], 'review-model')
        options = self.bedrock_factory.call_args.kwargs['config']
        self.assertEqual(options.read_timeout, 2.5)
        self.assertEqual(options.connect_timeout, 2.5)

    def test_cron_queues_the_image_budget_instead_of_waiting_for_it(self):
        # The text and the bounded image pipeline run in the journal worker (`defer`); the
        # cron's request only covers the API's checks and the enqueue.
        source = Path(__file__).resolve().parents[1] / 'modal/memorion_daily_summary.py'
        tree = ast.parse(source.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                        and node.name == 'call_daily_summary_api')
        requests = mock.Mock()
        requests.post.return_value.status_code = 200
        requests.post.return_value.json.return_value = {'image_url': 'https://fixture/image.png'}
        namespace = {'os': os, 'requests': requests}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), 'exec'), namespace)
        result = namespace['call_daily_summary_api']('fixture-user', '2026-10-23', 'fixture-key')
        self.assertEqual(result['status'], 'success')
        request = requests.post.call_args.kwargs
        self.assertLessEqual(request['timeout'], 120)
        self.assertEqual(request['json'], {'date': '2026-10-23', 'include_image': True, 'force_regenerate': False,
                                           'defer': True})
        for node in tree.body:
            if isinstance(node, ast.AsyncFunctionDef) and node.name in (
                    'daily_summary_cronjob', 'manual_summary_trigger', 'manual_summary_for_user'):
                decorator = next(d for d in node.decorator_list if isinstance(d, ast.Call))
                cap = next(k.value.value for k in decorator.keywords if k.arg == 'timeout')
                self.assertGreater(cap, request['timeout'])
                if node.name != 'manual_summary_for_user':
                    self.assertGreaterEqual((cap // request['timeout']) * 5, 25)


class UploadedPictureUrlTests(unittest.TestCase):
    """A redrawn picture must get a new URL: the App keeps pictures on disk by URL for 60 days."""

    def _storage(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            'storage_under_test', Path(__file__).resolve().parents[1] / 'utils/other/storage.py')
        module = importlib.util.module_from_spec(spec)
        with mock.patch('google.cloud.storage.Client'):
            spec.loader.exec_module(module)
        module.daily_summary_images_bucket = 'daily-bucket'
        return module

    def _upload(self, storage, generation):
        blob = SimpleNamespace(generation=None)
        blob.upload_from_string = lambda data, content_type: setattr(blob, 'generation', generation)
        storage.storage_client = SimpleNamespace(bucket=lambda name: SimpleNamespace(blob=lambda path: blob))
        return storage.upload_daily_summary_image(b'png', 'dev_d_u', '2026-10-27')

    def test_each_upload_of_a_days_picture_has_its_own_url(self):
        storage = self._storage()
        first, second = self._upload(storage, 111), self._upload(storage, 222)
        base = 'https://storage.googleapis.com/daily-bucket/dev_d_u/2026-10-27_summary.png'
        self.assertEqual((first, second), (base + '?v=111', base + '?v=222'))

    def test_missing_generation_keeps_the_plain_url(self):
        self.assertEqual(self._upload(self._storage(), None),
                         'https://storage.googleapis.com/daily-bucket/dev_d_u/2026-10-27_summary.png')


if __name__ == '__main__':
    unittest.main()
