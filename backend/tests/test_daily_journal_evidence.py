"""Long-day selection preserves attribution and rejects invented evidence."""
import json
import unittest
from unittest.mock import patch
from utils.llm import daily_journal_evidence as evidence
from utils.llm.prompt_registry import ResolvedPrompt

HEADER = 'Conversation #1\nSpeaker attribution: Only User-labelled turns belong to the diary writer.\nTranscript (verbatim speech):\n'

class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.resolver = patch('utils.llm.prompt_registry.get_prompt', side_effect=lambda key, fallback: ResolvedPrompt(key=key, content=fallback.content, config={}, is_fallback=True))
        self.resolver.start()
        self.addCleanup(self.resolver.stop)

    def test_short_source_bypasses_selection(self):
        self.assertEqual('short', evidence.prepare_daily_journal_evidence(None, 'short', lambda *_: self.fail()))

    def test_parts_keep_all_turns_header_and_tail(self):
        turns = [f'Speaker 1: {n} ' + '内容' * 60 for n in range(180)]
        parts = evidence._source_parts(HEADER + '\n\n'.join(turns))
        self.assertGreater(len(parts), 1)
        for turn in turns:
            self.assertTrue(any(turn in source for source, _ in parts))
        self.assertTrue(all('Conversation #1' in source and 'Speaker attribution:' in source for source, _ in parts))

    def test_selected_ids_must_reference_original_turns(self):
        source = HEADER + 'User: 只提议，没有答应。\n\nSpeaker 1: 我答应周五完成。'
        for turn_id in ['T9999', 2]:
            invoke = lambda *_: json.dumps({'threads':[{'turn_ids':[turn_id]}]})
            with self.assertRaises(ValueError): evidence._select_part(None, source, invoke)

    def test_an_empty_thread_is_skipped_not_fatal(self):
        # 2026-11-03：模型在几个正常话题之外多返回了一个空话题，整天每次重试都失败。
        source = HEADER + 'User: 我不想去北京。\n\nSpeaker 1: 无关话题。'
        invoke = lambda *_: json.dumps({'threads': [{'turn_ids': []}, {'turn_ids': ['T0001']}]})
        result = evidence._select_part(None, source, invoke)
        self.assertIn('我不想去北京', result)
        self.assertNotIn('无关话题', result)
        for malformed in [{'turn_ids': 'T0001'}, {'turn_ids': None}]:
            with self.assertRaises(ValueError):
                evidence._select_part(None, source, lambda *_: json.dumps({'threads': [malformed]}))

    def test_only_original_turns_not_model_paraphrase_become_evidence(self):
        source = HEADER + 'User: 只提议，没有答应。\n\nSpeaker 1: 我答应周五完成。'
        invoke = lambda *_: json.dumps({'threads':[{'topic':'用户答应了', 'details':['我保证完成'], 'turn_ids':['T0001', 'T0002']}]})
        result = evidence._select_part(None, source, invoke)
        self.assertIn('User: 只提议，没有答应。', result)
        self.assertIn('Speaker 1: 我答应周五完成。', result)
        self.assertNotIn('用户答应了', result)
        self.assertNotIn('我保证完成', result)

    def test_original_order_and_omitted_gap_are_explicit(self):
        source = HEADER + 'User: 我不想去北京。\n\nSpeaker 1: 无关话题。\n\nSpeaker 2: 我答应周五完成。'
        invoke = lambda *_: json.dumps({'threads':[{'turn_ids':['T0003', 'T0001']}]})
        result = evidence._select_part(None, source, invoke)
        self.assertLess(result.index('我不想去北京'), result.index('我答应周五完成'))
        self.assertIn('[gap]', result)
        self.assertNotIn('无关话题', result)

    def test_selection_retries_once_and_retains_only_valid_original_ids(self):
        with patch.object(evidence, '_DIRECT_SOURCE_CHARS', 1), patch.object(evidence, '_source_parts', return_value=[('a',True)]), patch.object(evidence, '_select_part', side_effect=[ValueError('invalid ID'), 'User: 原话。']) as select:
            result = evidence.prepare_daily_journal_evidence(None, 'long', None)
        self.assertEqual('User: 原话。', result)
        self.assertEqual(2, select.call_count)

    def test_empty_selection_with_writer_speech_is_invalid(self):
        source = HEADER + 'User: 有三个重要选项。'
        with self.assertRaises(ValueError):
            evidence._select_part(None, source, lambda *_: '{"threads": []}')

    def test_repeated_empty_writer_selection_retains_original_part(self):
        for speech in ('嗯，好。', '只有一个孩子，不戴眼镜。'):
            source = HEADER + 'User: ' + speech
            with patch.object(evidence, '_DIRECT_SOURCE_CHARS', len(source) + 1), patch.object(evidence, '_source_parts', return_value=[(source, True)]):
                calls = []
                def invoke(*args):
                    calls.append(args)
                    return '{"threads": []}'
                result = evidence.prepare_daily_journal_evidence(None, 'x' * (len(source) + 2), invoke)
            self.assertEqual(source, result)
            self.assertEqual(2, len(calls))

    def test_repeated_invalid_ids_still_fail(self):
        source = HEADER + 'User: 原话。'
        with patch.object(evidence, '_DIRECT_SOURCE_CHARS', len(source) + 1), patch.object(evidence, '_source_parts', return_value=[(source, True)]):
            with self.assertRaises(ValueError):
                evidence.prepare_daily_journal_evidence(None, 'x' * (len(source) + 2), lambda *_: '{"threads": [{"turn_ids": ["T9999"]}]}')

    def test_empty_selection_for_background_only_part_is_allowed(self):
        source = HEADER + 'Speaker 1: 仙界神晶的电视剧剧情。'
        self.assertEqual('', evidence._select_part(None, source, lambda *_: '{"threads": []}'))

    def test_selection_seed_matches_embedded_fallback(self):
        from pathlib import Path
        entries = json.loads((Path(__file__).resolve().parents[1] / 'scripts/benchmark/seed_prompts/daily_summary.json').read_text())
        seed = next(entry for entry in entries if entry['key'] == 'daily_summary.journal_evidence_v1')
        self.assertEqual(evidence._SELECTION_PROMPT, seed['content'])

    def test_budget_admits_the_measured_chatty_day_and_still_fails_closed_beyond_it(self):
        # 2026-10-28: a 123k-character party day selected 102,226 characters of verbatim turns.
        def prepare(size):
            with patch.object(evidence, '_DIRECT_SOURCE_CHARS', 1), patch.object(evidence, '_source_parts', return_value=[('a', True)]), patch.object(evidence, '_select_part', side_effect=lambda llm, src, invoke, share=None: 'User: ' + 'x' * size):
                return evidence.prepare_daily_journal_evidence(None, 'long', None)
        self.assertGreater(len(prepare(102226)), 102226)
        with self.assertRaises(ValueError):
            prepare(evidence._MAX_EVIDENCE_CHARS + 1)

    def test_all_parts_are_processed_in_source_order(self):
        with patch.object(evidence, '_DIRECT_SOURCE_CHARS', 1), patch.object(evidence, '_source_parts', return_value=[('a',True),('b',True)]), patch.object(evidence, '_select_part', side_effect=lambda llm,src,invoke,share=None:'Speaker 1: '+src):
            self.assertEqual('Speaker 1: a\n\n---------------------\n\nSpeaker 1: b', evidence.prepare_daily_journal_evidence(None, 'long', None))

    def test_an_over_budget_day_is_reselected_under_a_share_instead_of_failing(self):
        # 2026-11-05: 10-30 (~9 hours recorded) failed on every run; the diary keeps a few moments.
        calls = []

        def select(llm, src, invoke, share=None):
            calls.append(share)
            # A model that keeps roughly the share it is asked for, as a fraction of the part.
            return 'User: ' + 'x' * (200 if share is None else int(len(src) * share))
        parts = [('p%d' % i + 'y' * 99, True) for i in range(10)]          # 1,030 source chars
        with patch.object(evidence, '_DIRECT_SOURCE_CHARS', 500), patch.object(evidence, '_MAX_EVIDENCE_CHARS', 1000), \
                patch.object(evidence, '_source_parts', return_value=parts), patch.object(evidence, '_select_part', side_effect=select):
            result = evidence.prepare_daily_journal_evidence(None, 'x' * 1030, None)
        self.assertLessEqual(len(result), 1000)
        self.assertEqual(calls[:10], [None] * 10, 'the first pass is the normal selection')
        self.assertEqual(len(calls), 30, 'one normal pass and two tightened passes over all parts')
        self.assertAlmostEqual(calls[10], 1000 * evidence._TIGHTEN_TARGET / sum(len(p) for p, _ in parts), places=6)
        self.assertLess(calls[20], calls[10], 'a pass that is still over budget tightens further')

    def test_a_day_that_fits_is_never_tightened(self):
        shares = []
        with patch.object(evidence, '_DIRECT_SOURCE_CHARS', 1), patch.object(evidence, '_source_parts', return_value=[('a', True)]), \
                patch.object(evidence, '_select_part', side_effect=lambda llm, src, invoke, share=None: shares.append(share) or 'User: ok'):
            evidence.prepare_daily_journal_evidence(None, 'long', None)
        self.assertEqual(shares, [None])

    def test_the_share_reaches_the_selection_prompt(self):
        prompts = []
        source = HEADER + 'User: 我不想去北京。\n\nSpeaker 1: 无关话题。'

        def invoke(llm, prompt):
            prompts.append(prompt)
            return json.dumps({'threads': [{'turn_ids': ['T0001']}]})
        evidence._select_part(None, source, invoke)
        evidence._select_part(None, source, invoke, share=0.25)
        self.assertNotIn('too long to keep everything', prompts[0])
        self.assertIn('select at most about 25% of the original turns', prompts[1])
        self.assertLess(prompts[1].index('</source>'), prompts[1].index('too long to keep everything'))

if __name__ == '__main__': unittest.main()
