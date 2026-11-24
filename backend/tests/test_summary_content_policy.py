"""Regression coverage for long meeting evidence and content-aware presentation."""
import os
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault('OPENAI_API_KEY', 'test')
from models.conversation import Structured
from utils.llm import conversation_processing as cp
from utils.llm.prompt_registry import ResolvedPrompt
from utils.summary_policy import CONTENT_RETENTION_POLICY, SUMMARY_POLICY, apply_summary_policy
from utils.conversation_visibility import conversation_is_hidden
from utils.timeline.chaptering import collect_segment_refs, segment_day_into_chapters
from utils.timeline import rollup


def local_prompt(key, fallback):
    return ResolvedPrompt(key, fallback.content, fallback.config, is_fallback=True,
                          fallback_content=fallback.content)


class EvidenceTests(unittest.TestCase):
    def test_substantive_sharing_is_kept_even_if_legacy_media_flags_disagree(self):
        llm = Mock()
        llm.invoke.return_value = '{"discard":true,"is_media":true,"content_kind":"substantive_sharing"}'
        with patch.object(cp, 'get_prompt', side_effect=local_prompt), \
             patch.object(cp, 'resolve_llm', return_value=llm):
            self.assertFalse(cp.should_discard_conversation(' '.join(f'word{i}' for i in range(100))))

    def test_irrelevant_background_is_discarded_without_requiring_media(self):
        llm = Mock()
        llm.invoke.return_value = '{"discard":true,"is_media":false,"content_kind":"irrelevant_background"}'
        with patch.object(cp, 'get_prompt', side_effect=local_prompt), \
             patch.object(cp, 'resolve_llm', return_value=llm):
            self.assertTrue(cp.should_discard_conversation(' '.join(f'word{i}' for i in range(100))))

    def test_value_policy_overrides_registered_playback_rule_in_system_message(self):
        llm = Mock()
        llm.invoke.return_value = '{"discard":true,"is_media":true,"content_kind":"passive_entertainment"}'
        old = ResolvedPrompt('conversation.discard', 'Discard all recorded talks.\n{{full_context}}', {})
        with patch.object(cp, 'get_prompt', return_value=old), \
             patch.object(cp, 'resolve_llm', return_value=llm):
            self.assertTrue(cp.should_discard_conversation(' '.join(f'word{i}' for i in range(100))))
        system, evidence = llm.invoke.call_args.args[0]
        self.assertTrue(system.content.endswith(CONTENT_RETENTION_POLICY))
        self.assertNotIn(CONTENT_RETENTION_POLICY, evidence.content)

    def test_explicit_keep_wins_even_when_background_media_is_detected(self):
        llm = Mock(); llm.invoke.return_value = '{"discard":false,"is_media":true}'
        with patch.object(cp, 'get_prompt', side_effect=local_prompt), \
             patch.object(cp, 'resolve_llm', return_value=llm):
            self.assertFalse(cp.should_discard_conversation(' '.join(f'word{i}' for i in range(100))))

    def test_blank_lines_do_not_erase_the_middle_of_a_meeting(self):
        lines = ['Speaker 1: hello'] + [f'Speaker 2: project budget item {i}' for i in range(746)] + ['Speaker 1: bye']
        batches = cp._discard_transcript_batches('\n\n'.join(lines))
        self.assertEqual('\n'.join(batches), '\n'.join(lines))
        self.assertIn('project budget item 373', batches[0])

    def test_all_evidence_survives_bounded_batches_including_one_huge_line(self):
        text = '\n'.join(['a' * 17, 'b' * 400, 'final decision'])
        batches = cp._discard_transcript_batches(text, max_chars=80)
        self.assertTrue(all(len(batch) <= 80 for batch in batches))
        self.assertEqual(''.join(batches).replace('\n', ''), text.replace('\n', ''))
        self.assertIn('final decision', batches[-1])

    def test_any_substantive_part_prevents_discard_of_the_whole_capture(self):
        llm = Mock()
        llm.invoke.side_effect = ['{"discard":true,"is_media":true}', '{"discard":false,"is_media":false}']
        with patch.object(cp, 'get_prompt', side_effect=local_prompt), \
             patch.object(cp, 'resolve_llm', return_value=llm), \
             patch.object(cp, '_discard_transcript_batches', return_value=['broadcast opening', 'substantive project decision']):
            self.assertFalse(cp.should_discard_conversation(' '.join(f'word{i}' for i in range(100))))
        self.assertEqual(llm.invoke.call_count, 2)
        self.assertIn('substantive project decision', llm.invoke.call_args.args[0][1].content)
        self.assertIn('never infer that omitted context was meaningless',
                      llm.invoke.call_args.args[0][0].content)

    def test_all_media_parts_remain_discarded(self):
        llm = Mock(); llm.invoke.return_value = '{"discard":true,"is_media":true}'
        with patch.object(cp, 'get_prompt', side_effect=local_prompt), \
             patch.object(cp, 'resolve_llm', return_value=llm), \
             patch.object(cp, '_discard_transcript_batches', return_value=['broadcast one', 'broadcast two']):
            self.assertTrue(cp.should_discard_conversation(' '.join(f'word{i}' for i in range(100))))
        self.assertEqual(llm.invoke.call_count, 2)


class PresentationTests(unittest.TestCase):
    def test_registry_is_unchanged_and_policy_precedes_evidence(self):
        original = ResolvedPrompt('conversation.structure', 'warm only\n\nContent:\n{{full_context}}', {'temperature': 0.1},
                                  fallback_content='fallback\n\nContent:\n{{full_context}}')
        result = apply_summary_policy(original, evidence_marker='{{full_context}}')
        self.assertNotIn(SUMMARY_POLICY, original.content)
        self.assertLess(result.content.index(SUMMARY_POLICY), result.content.index('Content:'))
        self.assertIn(SUMMARY_POLICY, result.fallback_content)
        self.assertEqual(result.config, original.config)

    def test_initial_and_reprocess_prompts_override_old_companion_style(self):
        llm = Mock(); llm.invoke.return_value = '{"title":"Project review","overview":"Details"}'
        def old(key, fallback):
            return ResolvedPrompt(key, 'You are NOT a meeting-notes assistant.\n\nContent:\n{{full_context}}', {})
        now = datetime.now(timezone.utc)
        with patch.object(cp, 'get_prompt', side_effect=old), patch.object(cp, 'resolve_llm', return_value=llm):
            cp.get_transcript_structure('evidence only', now, 'en', 'UTC')
            cp.get_reprocess_transcript_structure('evidence only', now, 'en', 'UTC', title='')
        for call in llm.invoke.call_args_list:
            messages = call.args[0]
            self.assertIn(SUMMARY_POLICY, messages[0].content)
            self.assertNotIn(SUMMARY_POLICY, messages[1].content)

    def test_rollup_policy_is_fingerprinted_and_survives_bad_registry_fallback(self):
        def broken(key, fallback):
            return ResolvedPrompt(key, '{{unknown_variable}}', {}, fallback_content=fallback.content)
        with patch.object(rollup, 'get_prompt', side_effect=broken):
            deps = rollup.resolve_summary_dependencies()
        self.assertIn(SUMMARY_POLICY, deps.resolved.content)
        self.assertIn(SUMMARY_POLICY, deps.grounding.content)
        before = deps.fingerprint
        deps.resolved.content += ' Changed style'
        self.assertNotEqual(before, deps.fingerprint)


class VisibilityTests(unittest.TestCase):
    def test_legacy_media_placeholder_never_becomes_a_timeline_block(self):
        now = datetime(2026, 10, 13, 8, tzinfo=timezone.utc)
        for title in ['[Media Recording]', 'Media Recording', ' [media recording] ']:
            c = {'id':'media', 'started_at':now, 'finished_at':now, 'discarded':False,
                 'structured':{'title':title}, 'transcript_segments':[{'start':0,'end':60,'text':'broadcast'}]}
            self.assertTrue(conversation_is_hidden(c))
            self.assertEqual(collect_segment_refs([c]), [])
            self.assertEqual(segment_day_into_chapters([c]), [])
            c['transcript_segments'] = []
            self.assertEqual(segment_day_into_chapters([c]), [])
        self.assertFalse(conversation_is_hidden({'structured':{'title':'Media Recording Notes'}}))


if __name__ == '__main__':
    unittest.main()
