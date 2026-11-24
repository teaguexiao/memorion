"""Prevent cross-chapter leakage and ambiguous cross-recording attribution."""

import os
from datetime import datetime, timezone
import unittest
from unittest import mock

os.environ.setdefault('OPENROUTER_API_KEY', 'test')
os.environ.setdefault('OPENAI_API_KEY', 'test')

from utils.timeline.sources import chapter_fragments, _recording_keys
from utils.timeline import rollup
from utils.llm.prompt_registry import ResolvedPrompt


def setUpModule():
    global _grounding_patch
    _grounding_patch = mock.patch.object(rollup, 'ground_rollup', side_effect=lambda evidence, draft, resolved, **kw: draft)
    _grounding_patch.start()


def tearDownModule():
    _grounding_patch.stop()


def recording(cid, texts):
    return {'id': cid, 'started_at': datetime(2026, 10, 12, tzinfo=timezone.utc),
            'structured': {'title': 'whole recording', 'overview': 'other chapter secret'},
            'transcript_segments': [{'text': text, 'start': i * 10, 'end': i * 10 + 8,
                                     'speaker_id': 0} for i, text in enumerate(texts)]}


class ChapterSourcesTests(unittest.TestCase):
    def test_partial_single_recording_never_reuses_whole_recording_summary(self):
        convo = recording('a', ['ONLY_CHAPTER_A', 'ONLY_CHAPTER_B'])
        chapter = {'source_conversation_ids': ['a'], 'segment_refs': [{'conversation_id': 'a', 'index': 1}]}
        fragments = chapter_fragments(chapter, {'a': convo})
        self.assertTrue(fragments[0]['requires_rollup'])
        self.assertFalse(fragments[0]['covers_recording'])
        rendered = rollup.render_fragments(fragments)
        self.assertIn('ONLY_CHAPTER_B', rendered)
        self.assertNotIn('ONLY_CHAPTER_A', rendered)
        self.assertNotIn('other chapter secret', rendered)
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})):
            self.assertIsNotNone(rollup.prepare_rollup(fragments))

    def test_whole_recording_is_marked_even_when_empty_segments_are_unselected(self):
        convo = recording('a', ['first', '  ', 'last'])
        chapter = {'source_conversation_ids': ['a'], 'segment_refs': [
            {'conversation_id': 'a', 'index': i} for i in (0, 2)]}
        self.assertTrue(chapter_fragments(chapter, {'a': convo})[0]['covers_recording'])

    def test_speaker_numbers_are_scoped_to_their_recording(self):
        convos = {cid: recording(cid, [f'{cid} detail']) for cid in ('a', 'b')}
        chapter = {'source_conversation_ids': ['a', 'b'], 'segment_refs': [
            {'conversation_id': cid, 'index': 0} for cid in convos]}
        fragments = chapter_fragments(chapter, convos)
        rendered = rollup.render_fragments(fragments)
        self.assertIn(_recording_keys(convos)['a'] + ': Recording started', rendered)
        self.assertIn(_recording_keys(convos)['b'] + ': Recording started', rendered)
        identities = [next(iter(f['speaker_evidence'].values())) for f in fragments]
        self.assertNotEqual(identities[0]['source_speaker_key'], identities[1]['source_speaker_key'])

    def test_duplicate_and_invalid_references_do_not_leak_other_segments(self):
        convo = recording('a', ['included', 'excluded'])
        refs = [{'conversation_id': 'a', 'index': i} for i in (0, 0, -1, 999, True)]
        rendered = rollup.render_fragments(chapter_fragments(
            {'source_conversation_ids': ['a'], 'segment_refs': refs}, {'a': convo}))
        self.assertEqual(rendered.count('included'), 1)
        self.assertNotIn('excluded', rendered)

    def test_long_segment_keeps_identity_in_every_batch(self):
        convo = recording('a', ['BEGIN' + 'x' * 50000 + 'END'])
        convo['transcript_segments'][0]['is_user'] = True
        fragments = chapter_fragments({'source_conversation_ids': ['a'], 'segment_refs': [
            {'conversation_id': 'a', 'index': 0}]}, {'a': convo})
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})):
            request = rollup.prepare_rollup(fragments)
        self.assertGreater(len(request.batches), 1)
        self.assertTrue(all('identity=user' in p and '[[speaker:' in p for p in request.evidence_blocks))
        self.assertIn('BEGIN', request.batches[0])
        self.assertIn('END', request.batches[-1])

    def test_short_utterances_do_not_spend_budget_on_repeated_identity_metadata(self):
        convo = recording('a', ['A short statement.'] * 2700)
        fragments = chapter_fragments({'source_conversation_ids': ['a'], 'segment_refs': [
            {'conversation_id': 'a', 'index': i} for i in range(2700)]}, {'a': convo})
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})):
            request = rollup.prepare_rollup(fragments)
        self.assertEqual(sum(b.count('A short statement.') for b in request.batches), 2700)
        self.assertLessEqual(len(request.batches), rollup.MAX_CHAPTER_BATCHES)
        self.assertTrue(all(p.count('identity=unknown') == 1 for p in request.evidence_blocks))

    def test_missing_transcript_uses_complete_secondary_evidence(self):
        convo = {'id': 'a', 'structured': {'title': 'Old note', 'overview': 'x' * 2000 + 'END'}}
        rendered = rollup.render_fragments(chapter_fragments({'source_conversation_ids': ['a']}, {'a': convo}))
        self.assertIn('SUMMARY ONLY', rendered)
        self.assertIn('x' * 2000 + 'END', rendered)

    def test_unsummarized_single_recording_uses_its_transcript(self):
        convo = recording('a', ['actual source'])
        convo['structured'] = {}
        fragments = chapter_fragments({'source_conversation_ids': ['a'], 'segment_refs': [
            {'conversation_id': 'a', 'index': 0}]}, {'a': convo})
        self.assertTrue(fragments[0]['requires_rollup'])

    def test_recording_key_is_present_in_every_batch(self):
        source = {'source_label': 'R1: Recording 1, started 2026-10-12',
                  'source_text': 'x' * 50000, 'requires_rollup': True}
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})):
            request = rollup.prepare_rollup([source])
        self.assertGreater(len(request.prompts), 1)
        self.assertTrue(all(source['source_label'] in prompt for prompt in request.prompts))

    def test_batch_boundary_keeps_the_following_answer_as_context(self):
        with mock.patch.object(rollup, 'get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key, fallback.content, {})), \
             mock.patch.object(rollup, '_source_batches', return_value=['Can we renew?', 'Yes, renew for three years.']):
            request = rollup.prepare_rollup([{'overview': 'question'}, {'overview': 'answer'}])
        self.assertIn('Yes, renew for three years.', request.prompts[0])
        self.assertIn('Can we renew?', request.prompts[1])
        self.assertEqual(request.batches, ['Can we renew?', 'Yes, renew for three years.'])


class BatchResultTests(unittest.TestCase):
    def resolved(self, key, fallback):
        return ResolvedPrompt(key=key, content=fallback.content, config={})

    def test_all_batch_results_survive_without_a_lossy_reduce_call(self):
        llm = mock.Mock()
        def summarize(prompt, **kwargs):
            return rollup.ChapterRollup(title='topic', overview=prompt.split('<fragments>')[1].split('</fragments>')[0])
        llm.with_structured_output.return_value.invoke.side_effect = summarize
        sources = [{'title': 'first', 'overview': 'START' + 'x' * 50000 + 'END'},
                   {'title': 'second', 'overview': 'LAST_SOURCE'}]
        with mock.patch.object(rollup, 'get_prompt', side_effect=self.resolved), \
             mock.patch.object(rollup, 'resolve_llm', return_value=llm):
            request = rollup.prepare_rollup(sources)
            result = rollup.run_rollup(request)
        self.assertEqual(llm.with_structured_output.return_value.invoke.call_count, len(request.batches))
        for detail in ('START', 'END', 'LAST_SOURCE'):
            self.assertIn(detail, result['overview'])
        self.assertTrue(result['rollup'])

    def test_failure_keeps_all_sources_and_is_marked_failed(self):
        llm = mock.Mock()
        llm.with_structured_output.side_effect = RuntimeError('provider unavailable')
        with mock.patch.object(rollup, 'get_prompt', side_effect=self.resolved), \
             mock.patch.object(rollup, 'resolve_llm', return_value=llm):
            result = rollup.summarize_chapter([{'overview': 'FIRST'}, {'overview': 'LAST'}])
        self.assertEqual(result['rollup'], 'failed')
        self.assertIn('FIRST', result['overview'])
        self.assertIn('LAST', result['overview'])

    def test_grounding_failure_does_not_publish_an_unverified_draft(self):
        llm = mock.Mock()
        llm.with_structured_output.return_value.invoke.return_value = rollup.ChapterRollup(title='draft', overview='unverified')
        with mock.patch.object(rollup, 'get_prompt', side_effect=self.resolved), \
             mock.patch.object(rollup, 'resolve_llm', return_value=llm), \
             mock.patch.object(rollup, 'ground_rollup', side_effect=RuntimeError('review failed')):
            result = rollup.summarize_chapter([{'overview': 'FIRST'}, {'overview': 'LAST'}])
        self.assertEqual(result['rollup'], 'failed')
        self.assertNotIn('unverified', result['overview'])
        self.assertIn('LAST', result['overview'])


if __name__ == '__main__':
    unittest.main()
