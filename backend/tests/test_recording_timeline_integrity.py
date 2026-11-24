"""Regression coverage for leading silence, VAD, batches, and worker isolation."""
import ast
import asyncio
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import threading
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from utils.stt.timeline import (
    UnknownTimestampAxis, conversation_segments, has_original_timestamps, restore_original_timestamps,
    segments_on_audio_axis, stream_segment, transcribed_spans,
)


KEPT = [(202.970, 204.582), (205.530, 207.942), (211.450, 212.550)]


class TimelineIntegrity(unittest.TestCase):
    def test_leading_silence_uses_original_coordinates(self):
        display = stream_segment({'start': 203.82, 'end': 233.28}, 203.82)
        self.assertEqual((display['start'], display['end']), (0, 29.46))
        audio = segments_on_audio_axis([display], KEPT, require_provenance=True)[0]
        self.assertEqual((audio['start'], audio['end']), (0.85, 5.124))
        self.assertGreater(audio['end'] - audio['start'], 1)
        self.assertEqual(display['end'], 29.46)

    def test_repeated_audio_alignment_is_idempotent(self):
        display = stream_segment({'start': 203.82, 'end': 233.28}, 203.82)
        once = segments_on_audio_axis([display], KEPT, require_provenance=True)
        self.assertEqual(segments_on_audio_axis(once, KEPT, require_provenance=True), once)

    def test_missing_intervals_do_not_mark_mixed_display_times_as_audio(self):
        mixed = [stream_segment({'start': 203.82, 'end': 233.28}, 203.82), {'start': 0, 'end': 6}]
        pending = segments_on_audio_axis(mixed, None, require_provenance=True)
        self.assertEqual(pending[0]['timestamp_axis'], 'stream')
        self.assertNotEqual(pending[1].get('timestamp_axis'), 'audio')
        with self.assertRaises(UnknownTimestampAxis):
            segments_on_audio_axis(pending, KEPT, require_provenance=True)

    def test_second_batch_retains_its_session_coordinates(self):
        segments = [stream_segment({'start': 600, 'end': 690}, 203.82)]
        batch = conversation_segments(segments)
        self.assertEqual((batch[0]['start'], batch[0]['end']), (0, 90))
        self.assertEqual(batch[0]['original_start'], 600)
        self.assertEqual(segments[0]['start'], 396.18)
        start = datetime(2026, 10, 10, tzinfo=timezone.utc) + timedelta(seconds=batch[0]['original_start'])
        self.assertEqual(start.minute, 10)

    def test_cancelled_waiter_cannot_change_worker_snapshot(self):
        async def scenario():
            original = [stream_segment({'start': 203.82, 'end': 303.82}, 203.82)]
            ready, release = threading.Event(), threading.Event()
            observations = []
            batch = conversation_segments(original)
            def worker():
                ready.set()
                release.wait(2)
                observations.append((batch[0]['start'], batch[0]['end']))
            task = asyncio.create_task(asyncio.to_thread(worker))
            self.assertTrue(await asyncio.to_thread(ready.wait, 2))
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            original[0]['end'] = 0  # Simulate the old finalizer's shared mutation.
            release.set()
            for _ in range(100):
                if observations:
                    break
                await asyncio.sleep(0.01)
            self.assertEqual(observations, [(0, 100)])
        asyncio.run(scenario())

    def test_legacy_ambiguous_axis_is_rejected_without_mutation(self):
        old = [{'start': 0, 'end': 6.138, 'is_user': True, 'person_id': 'manual'}]
        before = deepcopy(old)
        with self.assertRaises(UnknownTimestampAxis):
            segments_on_audio_axis(old, KEPT, require_provenance=True)
        self.assertEqual(old, before)

    def test_older_client_can_recover_from_server_transcript(self):
        canonical = stream_segment({'text': 'sentence', 'speaker_id': 1, 'start': 203.82, 'end': 233.28}, 203.82)
        client = {'text': 'sentence', 'speaker_id': 1, 'start': 0, 'end': 29.46, 'is_user': True}
        restored = restore_original_timestamps([client], {'transcript_segments': [canonical]})
        self.assertEqual(restored[0]['original_start'], 203.82)
        self.assertTrue(restored[0]['is_user'])
        self.assertNotIn('original_start', client)

    def test_repeated_text_is_not_guessed(self):
        canonical = [stream_segment({'text': 'yes', 'start': s, 'end': s + 2}, 0) for s in (200, 300)]
        restored = restore_original_timestamps([{'text': 'yes', 'start': 0, 'end': 2}], {'transcript_segments': canonical})
        self.assertNotIn('original_start', restored[0])

    def test_complete_ordered_repeated_text_can_be_recovered(self):
        canonical = [stream_segment({'text': 'yes', 'start': s, 'end': s + 2}, 0) for s in (200, 300)]
        client = [{'text': 'yes', 'start': 0, 'end': 2}, {'text': 'yes', 'start': 100, 'end': 102}]
        restored = restore_original_timestamps(client, {'transcript_segments': canonical})
        self.assertEqual([s['original_start'] for s in restored], [200, 300])

    def test_actual_stream_callback_keeps_separate_coordinates_and_objects(self):
        source = (Path(__file__).resolve().parents[1] / 'routers/developer_listen.py').read_text()
        node = next(n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.AsyncFunctionDef) and n.name == 'stream_transcript')
        callback = ast.unparse(node)
        metadata = next(n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.FunctionDef) and n.name == '_transcript_timeline')
        factory = '''def factory():
    current_segments, all_segments = [], []
    current_segments_index, all_segments_index = {}, {}
    flushed_segment_ids = set()
    timestamp_offset = None
'''
        factory += '\n'.join('    ' + line for line in ast.unparse(metadata).splitlines()) + '\n'
        factory += '\n'.join('    ' + line for line in callback.splitlines())
        factory += '\n    return stream_transcript, lambda: (current_segments, all_segments)\n'
        sent, persisted = [], []
        async def send(payload):
            sent.append(payload)
        async def reset():
            pass
        namespace = {
            'List': list, 'Dict': dict, 'Any': object, 'asyncio': asyncio, 'deepcopy': deepcopy,
            'stream_segment': stream_segment, 'coerce_speaker_id': int,
            '_apply_manual_tag_to_seg': lambda s: None, '_reset_conversation_timer': reset,
            'websocket': SimpleNamespace(client_state=1, send_json=send),
            'WebSocketState': SimpleNamespace(CONNECTED=1),
            'dev_db': SimpleNamespace(update_listen_session=lambda **kw: persisted.append(kw)),
            'developer_id': 'test', 'external_user_id': 'test', 'session_id': 'test',
            'start_time': datetime(2026, 10, 10), 'timezone': timezone,
            'custom_stt_mode': False,
        }
        exec(factory, namespace)
        stream, state = namespace['factory']()
        raw = {'id': 'a', 'speaker_id': 1, 'start': 203.82, 'end': 233.28}
        asyncio.run(stream([raw]))
        current, all_segments = state()
        self.assertEqual(raw['start'], 203.82)
        self.assertEqual(current[0]['original_start'], 203.82)
        self.assertIsNot(current[0], all_segments[0])
        self.assertIsNot(current[0], sent[0]['segments'][0])
        self.assertEqual(persisted[0]['transcript_timeline']['display_offset_seconds'], 203.82)
        updated = {**raw, 'end': 240}
        asyncio.run(stream([updated]))
        self.assertEqual(len(state()[0]), 1)
        self.assertEqual(state()[0][0]['original_end'], 240)
        namespace['custom_stt_mode'] = True
        custom_stream, custom_state = namespace['factory']()
        asyncio.run(custom_stream([raw]))
        self.assertNotIn('original_start', custom_state()[0][0])
        self.assertFalse(persisted[-1]['transcript_timeline']['original_coordinates_available'])
        def fail(**kw):
            raise RuntimeError('test database unavailable')
        namespace['dev_db'] = SimpleNamespace(update_listen_session=fail)
        namespace['custom_stt_mode'] = False
        retry_stream, retry_state = namespace['factory']()
        asyncio.run(retry_stream([raw]))
        self.assertEqual(retry_state()[0][0]['original_start'], 203.82)
        self.assertEqual(sent[-1]['segments'][0]['end'], 29.46)

    def test_alignment_database_failure_still_uploads_raw_recording(self):
        source = (Path(__file__).resolve().parents[1] / 'routers/developer_listen.py').read_text()
        block = next(n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.If)
                     and ast.unparse(n.test) == 'len(audio_buffer) > 0')
        wrapper = ast.parse('async def save():\n    audio_path = None\n    audio_kept_intervals = None\n    return audio_path, audio_kept_intervals').body[0]
        wrapper.body[2:2] = [block]
        uploaded = []
        def fail(**kw):
            raise RuntimeError('test database unavailable')
        namespace = {
            'asyncio': asyncio, 'deepcopy': deepcopy,
            'audio_buffer': bytearray(b'original'), 'sample_rate': 16000, 'all_segments': [],
            'vad_trim_silence_bytes': lambda *a, **kw: (b'trimmed', [(10, 20)]), 'transcribed_spans': transcribed_spans,
            'dev_db': SimpleNamespace(update_listen_session=fail),
            '_transcript_timeline': lambda: {'version': 2},
            'upload_conversation_recording_from_bytes': lambda **kw: uploaded.append(kw),
            'developer_id': 'test', 'external_user_id': 'user', 'session_id': 'session',
        }
        exec(compile(ast.fix_missing_locations(ast.Module(body=[wrapper], type_ignores=[])), '<save-audio>', 'exec'), namespace)
        path, intervals = asyncio.run(namespace['save']())
        self.assertEqual(uploaded[0]['audio_bytes'], b'original')
        self.assertEqual(path, 'dev_test_user/session.wav')
        self.assertEqual(intervals, [])

    def test_manual_speaker_control_updates_both_buffers(self):
        source = (Path(__file__).resolve().parents[1] / 'routers/developer_listen.py').read_text()
        branch = next(n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.If)
                      and ast.unparse(n.test) == "msg.get('type') == 'speaker_assigned'")
        current = [{'id': 'a', 'speaker_id': 1, 'is_user': False}]
        all_segments = deepcopy(current)
        namespace = {
            'msg': {'speaker_id': 1, 'person_id': 'user', 'segment_ids': ['a']},
            'coerce_speaker_id': lambda value, default=None: int(value),
            'manual_speaker_tags': {}, 'current_segments': current, 'all_segments': all_segments,
        }
        exec(compile(ast.Module(body=branch.body, type_ignores=[]), '<speaker-control>', 'exec'), namespace)
        self.assertTrue(current[0]['is_user'])
        self.assertTrue(all_segments[0]['is_user'])

    def test_old_client_post_preserves_content_when_coordinates_are_unavailable(self):
        source = (Path(__file__).resolve().parents[1] / 'routers/developer_conversations.py').read_text()
        node = next(n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.FunctionDef) and n.name == '_do_process_conversation')
        prefix = []
        for statement in node.body:
            if isinstance(statement, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'person_ids' for t in statement.targets):
                break
            prefix.append(statement)
        node.body = prefix + [ast.Return(value=ast.Name(id='segment_data', ctx=ast.Load()))]
        class Segment(SimpleNamespace):
            def model_dump(self):
                return vars(self).copy()
        class Request(SimpleNamespace):
            def model_copy(self, **kw):
                return deepcopy(self)
        class HTTPError(Exception):
            def __init__(self, **kw):
                self.status_code = kw['status_code']
        session = {'transcript_timeline': {'version': 2, 'original_coordinates_available': True}}
        namespace = {
            'dev_db': SimpleNamespace(get_listen_session=lambda **kw: session),
            'restore_original_timestamps': restore_original_timestamps,
            'has_original_timestamps': has_original_timestamps,
            'conversation_segments': conversation_segments,
            'TranscriptSegment': Segment, 'HTTPException': HTTPError,
        }
        module = ast.fix_missing_locations(ast.Module(body=[node], type_ignores=[]))
        exec(compile(module, '<process-timestamps>', 'exec'), namespace)
        request = Request(session_id='test', external_user_id='test', segments=[Segment(text='sentence', start=0, end=29.46)])
        unresolved = namespace['_do_process_conversation'](request, 'test')
        self.assertEqual(unresolved[0]['text'], 'sentence')
        self.assertFalse(has_original_timestamps(unresolved))
        with self.assertRaises(UnknownTimestampAxis):
            segments_on_audio_axis(unresolved, KEPT, require_provenance=True)
        session['transcript_segments'] = [stream_segment({'text': 'sentence', 'start': 203.82, 'end': 233.28}, 203.82)]
        restored = namespace['_do_process_conversation'](request, 'test')
        self.assertEqual(restored[0]['original_start'], 203.82)


if __name__ == '__main__':
    unittest.main()
