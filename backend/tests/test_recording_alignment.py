"""Transcript → recording axis, shared by voiceprint slicing and app playback.

The transcript page seeks the player to a tapped sentence. Seeking with the
displayed segment time is wrong for every live recording: its wav is the whole
WS session with VAD silence removed, so the sentence is somewhere else in the
file — and 17% of segments sampled in 2026-10 had no audio left at all. These
tests pin the mapping the endpoint returns and that voiceprint and playback ask
the same function, so the two cannot drift apart.

Run:
    cd backend && python3 tests/test_recording_alignment.py
"""

import ast
import os
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from utils.stt.recording_alignment import (  # noqa: E402
    RecordingAlignmentUnavailable,
    conversation_audio_alignment,
    conversation_segments_on_wav,
    kept_intervals_hint,
    session_id_from_audio_path,
)

UID_DIR = 'dev_d_u'


def seg(seg_id, start, end, **extra):
    return dict(id=seg_id, text=seg_id, speaker='SPEAKER_00', start=start, end=end, **extra)


def live(seg_id, original_start, original_end, display_offset):
    """A live segment as stored: display times rebased, STT times kept as provenance."""
    return seg(seg_id, original_start - display_offset, original_end - display_offset,
               original_start=original_start, original_end=original_end, timestamp_axis='display')


def listen_db(session=None, error=None):
    """Stand-in for `database.developer_data` (the real one needs Firestore)."""
    calls = []

    def get_listen_session(developer_id, external_user_id, session_id):
        calls.append(session_id)
        if error:
            raise error
        return session

    module = types.ModuleType('database.developer_data')
    module.get_listen_session = get_listen_session
    package = types.ModuleType('database')
    package.developer_data = module
    return mock.patch.dict(sys.modules, {'database': package, 'database.developer_data': module}), calls


class ConversationAudioAlignment(unittest.TestCase):
    def test_upload_seeks_on_the_stt_axis_not_the_displayed_one(self):
        # Display normalized to 0, the sentence is really 203.82 s into the file.
        conversation = dict(source='audio_upload', audio_path='u/conv.wav',
                            transcript_segments=[live('a', 203.82, 206.0, 203.82)])
        patcher, calls = listen_db()
        with patcher:
            payload = conversation_audio_alignment('d', 'u', conversation)
        self.assertEqual(payload, {'aligned': True, 'segments': [
            {'id': 'a', 'start': 203.82, 'end': 206.0, 'has_audio': True}]})
        self.assertEqual(calls, [], 'an upload has no listen session to read')

    def test_live_recording_maps_through_the_sessions_vad_intervals(self):
        # Session kept [100,110] and [200,220]; the conversation was split off at 195 s.
        session = {'audio_kept_intervals': [{'start': 100, 'end': 110}, {'start': 200, 'end': 220}]}
        conversation = dict(source='app', audio_path=f'{UID_DIR}/sess-1.wav', transcript_segments=[
            live('kept', 205, 207, 195),
            live('cut', 150, 152, 195),  # inside removed silence
        ])
        patcher, calls = listen_db(session)
        with patcher:
            payload = conversation_audio_alignment('d', 'u', conversation)
        self.assertTrue(payload['aligned'])
        by_id = {s['id']: s for s in payload['segments']}
        self.assertEqual((by_id['kept']['start'], by_id['kept']['end']), (15.0, 17.0))
        self.assertTrue(by_id['kept']['has_audio'])
        self.assertFalse(by_id['cut']['has_audio'], 'VAD removed it: nothing to seek to')
        self.assertEqual(calls, ['sess-1'])

    def test_zero_length_segments_still_have_audio(self):
        # Soniox emits zero-length segments; start == end is not "cut".
        upload = dict(source='audio_upload', audio_path='u/conv.wav',
                      transcript_segments=[live('z', 40.0, 40.0, 0)])
        session = {'audio_kept_intervals': [[100, 110]]}
        kept_live = dict(source='app', audio_path=f'{UID_DIR}/sess-1.wav',
                         transcript_segments=[live('z', 105.0, 105.0, 100)])
        patcher, _ = listen_db(session)
        with patcher:
            for conversation in (upload, kept_live):
                with self.subTest(conversation['source']):
                    self.assertTrue(conversation_audio_alignment('d', 'u', conversation)['segments'][0]['has_audio'])

    def test_old_client_segments_are_restored_from_the_session_transcript(self):
        # An older client sent display times only; the session still has STT times.
        canonical = live('a', 205, 207, 195)
        session = {'audio_kept_intervals': [[200, 220]], 'transcript_segments': [canonical]}
        bare = seg('a', 10, 12)
        patcher, _ = listen_db(session)
        with patcher:
            payload = conversation_audio_alignment('d', 'u', dict(
                source='app', audio_path=f'{UID_DIR}/sess-1.wav', transcript_segments=[bare]))
        self.assertEqual(payload['segments'], [{'id': 'a', 'start': 5.0, 'end': 7.0, 'has_audio': True}])

    def test_unalignable_recordings_say_so_instead_of_guessing(self):
        cases = {
            'audio alignment metadata missing': (dict(source='app'), {}, None),
            'legacy timestamp axis needs repair': (dict(source='app'), {'audio_kept_intervals': [[0, 50]]}, None),
            'could not read audio alignment metadata': (dict(source='app'), None, RuntimeError('firestore down')),
        }
        for reason, (conversation, session, error) in cases.items():
            with self.subTest(reason):
                conversation = dict(conversation, audio_path=f'{UID_DIR}/sess-1.wav',
                                    transcript_segments=[seg('a', 1, 2)])
                patcher, _ = listen_db(session, error)
                with patcher:
                    payload = conversation_audio_alignment('d', 'u', conversation)
                self.assertEqual(payload, {'aligned': False, 'reason': reason, 'segments': []})
        self.assertFalse(conversation_audio_alignment('d', 'u', dict(source='app', transcript_segments=[]))['aligned'])

    def test_hint_and_session_id(self):
        self.assertEqual(kept_intervals_hint({'source': 'audio_upload'}), [])
        self.assertIsNone(kept_intervals_hint({'source': 'app'}))
        self.assertEqual(session_id_from_audio_path(f'{UID_DIR}/f0e5e8a0-1.wav'), 'f0e5e8a0-1')


class SessionAlreadyInHand(unittest.TestCase):
    """Chapter evidence and enrolment hold the session doc already; same answer as matching."""

    def test_upload_ignores_any_session_intervals(self):
        out = conversation_segments_on_wav(
            dict(source='audio_upload', transcript_segments=[live('a', 40.0, 42.0, 40.0)]),
            {'audio_kept_intervals': [[100, 110]]})
        self.assertEqual((out[0]['start'], out[0]['end']), (40.0, 42.0))

    def test_live_conversation_maps_through_its_session(self):
        out = conversation_segments_on_wav(
            dict(source='app', transcript_segments=[live('a', 205, 207, 195)]),
            {'audio_kept_intervals': [[100, 110], [200, 220]]})
        self.assertEqual((out[0]['start'], out[0]['end']), (15.0, 17.0))

    def test_older_client_times_are_restored_for_every_reader(self):
        # Enrolment and chapter evidence used to skip this, so they refused
        # conversations that voiceprint matching aligned fine.
        session = {'audio_kept_intervals': [[200, 220]], 'transcript_segments': [live('a', 205, 207, 195)]}
        out = conversation_segments_on_wav(dict(source='app', transcript_segments=[seg('a', 10, 12)]), session)
        self.assertEqual((out[0]['start'], out[0]['end']), (5.0, 7.0))

    def test_no_session_means_no_alignment(self):
        with self.assertRaises(RecordingAlignmentUnavailable):
            conversation_segments_on_wav(dict(source='app', transcript_segments=[live('a', 1, 2, 0)]), {})


def calls_in(path, function_name):
    tree = ast.parse((ROOT / path).read_text())
    fn = next(n for n in ast.walk(tree)
              if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == function_name)
    return {node.func.id if isinstance(node.func, ast.Name) else getattr(node.func, 'attr', None)
            for node in ast.walk(fn) if isinstance(node, ast.Call)}


class OneAnswerForEveryReader(unittest.TestCase):
    """Matching, enrolment, chapter evidence and playback must not each carry their own copy."""

    def test_enrolment_and_chapter_evidence_use_the_shared_mapping(self):
        for path, function_name in (('utils/speech_sample_collector.py', 'collect_speech_samples_developer'),
                                    ('utils/timeline/speaker_audio.py', 'audio_bounds')):
            with self.subTest(path):
                self.assertIn('conversation_segments_on_wav', calls_in(path, function_name))

    def test_nothing_else_maps_transcripts_onto_the_wav(self):
        # Four copies of this lookup disagreed before 2026-11-02; a fifth is how it starts again.
        callers = []
        for folder in ('utils', 'routers', 'database'):
            for path in sorted((ROOT / folder).rglob('*.py')):
                rel = str(path.relative_to(ROOT))
                if rel == 'utils/stt/timeline.py':
                    continue  # where it is defined
                for node in ast.walk(ast.parse(path.read_text())):
                    if isinstance(node, ast.Call) and 'segments_on_audio_axis' in (
                            getattr(node.func, 'id', None), getattr(node.func, 'attr', None)):
                        callers.append(rel)
        self.assertEqual(sorted(set(callers)), ['utils/stt/recording_alignment.py'])

    def test_voiceprint_uses_the_shared_mapping(self):
        called = calls_in('utils/stt/speech_profile.py', 'identify_developer_speakers')
        self.assertIn('segments_on_recording_axis', called)
        self.assertNotIn('segments_on_audio_axis', called, 'inlined copy of the shared lookup')

    def test_endpoint_uses_the_shared_mapping(self):
        called = calls_in('routers/developer_conversations.py', 'get_conversation_audio_alignment')
        self.assertIn('conversation_audio_alignment', called)


if __name__ == '__main__':
    os.environ.setdefault('OPENAI_API_KEY', 'test')
    unittest.main()
