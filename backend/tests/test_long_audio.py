"""Long media is real local PCM; provider HTTP is synthetic and never billed."""
import copy
import struct
import wave
from unittest.mock import Mock

import pytest
import requests

from utils import audio_upload_media as media
from utils.audio_jobs.soniox import Soniox
from utils.audio_jobs.state import JobFailure


def sparse_wav(path, seconds, rate=16000):
    size = round(seconds * rate) * 2
    with open(path, 'wb') as output:
        output.write(struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', size + 36, b'WAVE',
                                 b'fmt ', 16, 1, 1, rate, rate * 2, 2, 16, b'data', size))
        output.truncate(44 + size)
        output.seek(44 + size - 2)
        output.write(struct.pack('<h', 12345))
    return str(path)


@pytest.mark.parametrize('seconds,accepted', [(7200, True), (14400, True), (28800, True), (28800.02, False)])
def test_actual_wav_duration_boundary(tmp_path, seconds, accepted):
    valid, _, duration = media.validate_audio_file(sparse_wav(tmp_path / 'audio.wav', seconds))
    assert valid is accepted
    assert duration == seconds


def test_real_eight_hour_conversion_keeps_last_sample(tmp_path):
    source = sparse_wav(tmp_path / 'source.wav', 28800)
    target = str(tmp_path / 'normalized.wav')
    assert media.convert_to_wav_16k(source, target)
    assert media.validate_audio_file(target) == (True, '', 28800)
    with wave.open(target, 'rb') as audio:
        audio.setpos(audio.getnframes() - 1)
        assert audio.readframes(1) == struct.pack('<h', 12345)


def test_overlong_conversion_is_rejected_instead_of_silently_accepted(tmp_path):
    source = sparse_wav(tmp_path / 'source.wav', 28802)
    target = str(tmp_path / 'normalized.wav')
    assert media.convert_to_wav_16k(source, target)
    valid, reason, duration = media.validate_audio_file(target)
    assert not valid and 'too long' in reason
    assert duration > 28800


def test_eight_hour_split_covers_tail_with_bounded_parts(tmp_path):
    source = sparse_wav(tmp_path / 'source.wav', 28800)
    ranges = []
    for chunk in media.transcription_chunks(source):
        ranges.append((chunk.core_start_seconds, chunk.core_end_seconds))
        with wave.open(chunk.path, 'rb') as audio:
            assert audio.getnframes() / audio.getframerate() <= 7202
            if chunk.core_end_seconds == 28800:
                audio.setpos(audio.getnframes() - 1)
                assert audio.readframes(1) == struct.pack('<h', 12345)
    assert ranges == [(0, 7200), (7200, 14400), (14400, 21600), (21600, 28800)]


def test_chunk_token_ownership_preserves_absolute_time_and_boundary_words():
    tokens = [dict(text='before', start_ms=7199800, duration_ms=100),
              dict(text='boundary', start_ms=7199900, duration_ms=200)]
    first = media.AudioChunk('', 0, 0, 7200)
    second = media.AudioChunk('', 7199, 7200, 14400)
    local = [{**t, 'start_ms': t['start_ms'] - 7199000} for t in tokens]
    owned = first.tokens(tokens) + second.tokens(local)
    assert [t['text'] for t in owned] == ['before', 'boundary']
    assert owned[-1]['start_ms'] == 7199900


def test_chunk_retry_resumes_remote_jobs_and_preserves_silence_and_speaker_scope(tmp_path, monkeypatch):
    monkeypatch.setenv('SONIOX_API_KEY', 'synthetic')
    source = sparse_wav(tmp_path / 'source.wav', 8, rate=10)
    split = media.transcription_chunks
    monkeypatch.setattr(media, 'needs_transcription_chunks', lambda _: True)
    monkeypatch.setattr(media, 'transcription_chunks', lambda path: split(path, chunk_seconds=2))
    http = Mock()
    uploads, submissions, deletes = [], [], []
    fail = [True]

    def response(data):
        value = Mock(status_code=200, headers={})
        value.json.return_value = data
        return value

    def request(method, url, **kwargs):
        if method == 'DELETE':
            deletes.append(url)
            return response({})
        if url.endswith('/files'):
            uploads.append(kwargs['data'].read())
            return response({'id': f'file-{len(uploads)}'})
        if url.endswith('/transcriptions'):
            submissions.append(kwargs['json'])
            return response({'id': f'task-{len(submissions)}'})
        number = int(url.split('/task-')[1].split('/')[0])
        if number == 2 and fail[0]:
            fail[0] = False
            raise requests.Timeout()
        if url.endswith('/transcript'):
            # Part zero is silence. All later jobs reuse their local speaker 1.
            tokens = [] if number == 1 else [dict(text=f'part{number}', start_ms=1500,
                                                duration_ms=200, speaker='1', language='en')]
            return response({'tokens': tokens})
        return response({'status': 'completed'})

    http.request.side_effect = request
    provider, cp = Soniox(http), {}
    snapshots = []

    def save(values, next_stage=None):
        cp.update(copy.deepcopy(values))
        snapshots.append(copy.deepcopy(cp))

    with pytest.raises(requests.Timeout):
        provider.transcribe(source, 'auto', cp, save)
    assert len(uploads) == len(submissions) == 2
    result = provider.transcribe(source, 'auto', cp, save)
    assert len(uploads) == len(submissions) == 4  # no repeated billable jobs
    assert [s['start'] for s in result['segments']] == [2.5, 4.5, 6.5]
    assert [s['speaker'] for s in result['segments']] == ['SPEAKER_00', 'SPEAKER_01', 'SPEAKER_02']
    assert snapshots[0]['soniox_chunks']['0'] == {'soniox_file_id': 'file-1'}
    provider.cleanup(cp)
    assert len(deletes) == 8


def test_all_silent_chunks_fail_only_after_checking_each_part(tmp_path, monkeypatch):
    source = sparse_wav(tmp_path / 'source.wav', 8, rate=10)
    split = media.transcription_chunks
    monkeypatch.setattr(media, 'needs_transcription_chunks', lambda _: True)
    monkeypatch.setattr(media, 'transcription_chunks', lambda path: split(path, chunk_seconds=2))
    provider = Soniox()
    provider._transcribe_one = Mock(return_value={'segments': [], 'language': 'en'})
    with pytest.raises(JobFailure, match='no_speech'):
        provider.transcribe(source, 'auto', {}, Mock())
    assert provider._transcribe_one.call_count == 4


def test_legacy_synchronous_limit_remains_explicit(tmp_path):
    path = sparse_wav(tmp_path / 'long.wav', 7201)
    assert media.validate_audio_file(path)[0]
    assert not media.validate_audio_file(path, max_duration=7200)[0]


def test_synchronous_decode_stops_after_its_own_limit(tmp_path):
    source = sparse_wav(tmp_path / 'source.wav', 28800)
    target = str(tmp_path / 'normalized.wav')
    assert media.convert_to_wav_16k(source, target, max_duration=7200)
    assert media.validate_audio_file(target, max_duration=7200)[2] == 7201
