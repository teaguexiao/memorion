import ast
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest
import wave
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('media', ROOT / 'utils/audio_upload_media.py')
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)

class MediaTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def wav(self, seconds):
        path = self.root / 'audio.wav'
        with wave.open(str(path), 'wb') as audio:
            audio.setparams((1, 2, 16000, 0, 'NONE', ''))
            for _ in range(seconds):
                audio.writeframesraw(bytes(32000))
        return str(path)

    def test_duration_boundaries_and_truncation(self):
        self.assertFalse(media.validate_audio_file(self.wav(4))[0])
        path = self.wav(5)
        self.assertEqual(media.validate_audio_file(path), (True, '', 5.0))
        with open(path, 'r+b') as out:
            out.truncate(50)
        self.assertIn('truncated', media.validate_audio_file(path)[1])

    def test_short_voice_notes_are_opt_in_and_empty_audio_still_rejected(self):
        short_note = self.wav(1)
        self.assertFalse(media.validate_audio_file(short_note)[0])
        self.assertEqual(media.validate_audio_file(short_note, min_duration=0.1), (True, '', 1.0))
        self.assertFalse(media.validate_audio_file(self.wav(0), min_duration=0.1)[0])

    def test_streamed_decode_preserves_duration_and_rejects_invalid_input(self):
        source = self.root / 'source.ogg'
        subprocess.run(['ffmpeg','-nostdin','-loglevel','error','-f','lavfi','-i',
                        'sine=frequency=440:sample_rate=48000','-t','6','-c:a','libopus',str(source)], check=True)
        output = str(self.root / 'normalized.wav')
        self.assertTrue(media.convert_to_wav_16k(str(source), output))
        self.assertEqual(media.validate_audio_file(output), (True, '', 6.0))
        unnamed = self.root / 'original'
        unnamed.write_bytes(source.read_bytes())
        self.assertTrue(media.convert_to_wav_16k(str(unnamed), output))
        source.write_bytes(b'not audio')
        self.assertFalse(media.convert_to_wav_16k(str(source), output))

    def test_conversion_timeout_is_not_reported_as_bad_audio(self):
        with patch.object(media.subprocess, 'run', side_effect=subprocess.TimeoutExpired('ffmpeg', 180)):
            with self.assertRaises(subprocess.TimeoutExpired):
                media.convert_to_wav_16k('input', 'output')

    def test_conversion_resource_failure_is_retryable_http_503(self):
        from fastapi import HTTPException
        from unittest.mock import Mock
        tree = ast.parse((ROOT / 'routers/audio_upload.py').read_text())
        fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_convert_upload_audio')
        convert = Mock(side_effect=subprocess.TimeoutExpired('ffmpeg', 180))
        namespace = {'convert_to_wav_16k': convert, 'subprocess': subprocess, 'HTTPException': HTTPException}
        exec(compile(ast.Module(body=[fn], type_ignores=[]), '<convert_upload>', 'exec'), namespace)
        with self.assertRaises(HTTPException) as raised:
            namespace['_convert_upload_audio']('input', 'output')
        self.assertEqual(raised.exception.status_code, 503)
        convert.side_effect = None
        convert.return_value = False
        self.assertFalse(namespace['_convert_upload_audio']('input', 'output'))

    def test_vad_chunks_are_bounded_and_include_the_tail(self):
        chunks = list(media.pcm16_chunks(self.wav(65)))
        self.assertEqual([len(x) for x in chunks], [960000, 976000, 176000])

    def test_streaming_vad_finds_late_speech_and_stops_early(self):
        # Execute the actual function with a synthetic detector; no cloud/model
        # initialization is needed to verify chunking, locks and early return.
        import numpy as np
        import threading
        from types import SimpleNamespace
        from unittest.mock import patch
        tree = ast.parse((ROOT / 'utils/stt/vad.py').read_text())
        fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'vad_is_empty_streaming')
        ns = {'np': np, 'torch': SimpleNamespace(from_numpy=lambda x: x), '_model': None,
              '_vad_lock': threading.Lock()}
        calls = []
        def detector(samples, model, sampling_rate):
            calls.append(len(samples))
            return [{'start': 0, 'end': 100}] if len(calls) == 2 else []
        ns['_get_speech_timestamps'] = detector
        exec(compile(ast.Module(body=[fn], type_ignores=[]), '<vad>', 'exec'), ns)
        with patch.dict('sys.modules', {'utils.audio_upload_media': media}):
            self.assertFalse(ns['vad_is_empty_streaming'](self.wav(100)))
        self.assertEqual(calls, [480000, 488000])

class SonioxStreamingTest(unittest.TestCase):
    def test_outbound_multipart_is_streamed_and_resources_are_cleaned(self):
        import sys, os
        from types import SimpleNamespace
        sys.path.insert(0, str(ROOT))
        from utils.stt import pre_recorded as stt
        seen = []
        def response(code, data):
            return SimpleNamespace(status_code=code, json=lambda: data, text='')
        def post(url, **kwargs):
            if url.endswith('/files'):
                self.assertNotIn('files', kwargs)
                encoder = kwargs['data']
                self.assertIn('multipart/form-data;', kwargs['headers']['Content-Type'])
                total = 0
                while block := encoder.read(8192):
                    self.assertLessEqual(len(block), 8192)
                    total += len(block)
                self.assertEqual(total, encoder.len)
                seen.append(total)
                return response(201, {'id': 'file-fixture'})
            return response(201, {'id': 'transcript-fixture'})
        def get(url, **kwargs):
            return response(200, {'tokens': []} if url.endswith('/transcript') else {'status': 'completed'})
        with tempfile.NamedTemporaryFile(suffix='.wav') as f:
            f.write(bytes(100000)); f.flush()
            with patch.dict(os.environ, {'SONIOX_API_KEY': 'synthetic'}), \
                 patch.object(stt.http_requests, 'post', side_effect=post), \
                 patch.object(stt.http_requests, 'get', side_effect=get), \
                 patch.object(stt.http_requests, 'delete') as delete:
                self.assertEqual(stt.soniox_transcribe_file(f.name, raise_on_error=True), ([], 'en'))
                self.assertEqual(delete.call_count, 2)
        self.assertGreater(seen[0], 100000)


if __name__ == '__main__':
    unittest.main()
