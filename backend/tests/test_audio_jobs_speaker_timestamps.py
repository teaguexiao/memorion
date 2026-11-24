"""Offline STT must cut the spoken audio, not a zero-normalized time range.

Synthetic PCM markers replace private speech; offset values reproduce the incident.
"""
import struct
import wave
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock

import pytest

from models.conversation import Conversation, ConversationSource, Structured
from utils.audio_jobs.soniox import Soniox
from utils.stt import pre_recorded
from utils.stt.timeline import segments_on_audio_axis


def response(data, status=200):
    result = Mock(status_code=status, headers={})
    result.json.return_value = data
    return result


def tokens(offset):
    return [
        dict(text='First', start_ms=round(offset * 1000), duration_ms=1000, speaker='1', language='en'),
        dict(text=' sentence.', start_ms=round((offset + 1) * 1000), duration_ms=2000, speaker='1'),
        dict(text='Other voice.', start_ms=round((offset + 4) * 1000), duration_ms=2000, speaker='2'),
    ]


@pytest.mark.parametrize('offset', [0, 0.15, 26.37, 99.03])
@pytest.mark.parametrize('durable', [False, True])
def test_offline_paths_roundtrip_and_extract_the_actual_voice(tmp_path, monkeypatch, offset, durable):
    monkeypatch.setenv('SONIOX_API_KEY', 'synthetic')
    path = tmp_path / 'recording.wav'
    # A known speaker's marker after leading silence; a second voice has another
    # marker. A normalized crop would contain silence or another speaker.
    rate = 1000
    pcm = b'\0\0' * round(offset * rate)
    pcm += struct.pack('<h', 1234) * (rate * 3)
    pcm += b'\0\0' * rate + struct.pack('<h', 5678) * (rate * 2)
    with wave.open(str(path), 'wb') as audio:
        audio.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        audio.writeframes(pcm)

    if durable:
        http = Mock()
        http.request.side_effect = [response({'status': 'completed'}), response({'tokens': tokens(offset)})]
        result = Soniox(http).transcribe(str(path), 'auto',
                                       {'soniox_file_id': 'file', 'soniox_transcription_id': 'task'}, Mock())
        segments = result['segments']
    else:
        monkeypatch.setattr(pre_recorded.http_requests, 'post', Mock(side_effect=[
            response({'id': 'file'}, 201), response({'id': 'task'}, 201)]))
        monkeypatch.setattr(pre_recorded.http_requests, 'get', Mock(side_effect=[
            response({'status': 'completed'}), response({'tokens': tokens(offset)})]))
        monkeypatch.setattr(pre_recorded.http_requests, 'delete', Mock(return_value=response({})))
        models, _ = pre_recorded.soniox_transcribe_file(str(path), raise_on_error=True)
        segments = [s.model_dump() for s in models]

    # Exercise the API/persistence boundary before the voiceprint cut.
    started = datetime(2026, 1, 1, tzinfo=timezone.utc)
    conversation = Conversation(id='synthetic', created_at=started, started_at=started,
                                finished_at=started + timedelta(seconds=offset + 6),
                                source=ConversationSource.audio_upload,
                                structured=Structured(title='', overview=''), transcript_segments=segments)
    persisted = Conversation.model_validate_json(conversation.model_dump_json())
    cuts = segments_on_audio_axis([s.model_dump() for s in persisted.transcript_segments], [],
                                 require_provenance=True)
    assert [(s['start'], s['end']) for s in cuts] == [
        (offset, round(offset + 3, 2)), (round(offset + 4, 2), round(offset + 6, 2))]
    assert persisted.transcript_segments[0].text == 'First sentence.'
    with wave.open(str(path), 'rb') as audio:
        for segment, marker in zip(cuts, [1234, 5678]):
            audio.setpos(round(segment['start'] * rate))
            clip = audio.readframes(round((segment['end'] - segment['start']) * rate))
            assert clip == struct.pack('<h', marker) * round((segment['end'] - segment['start']) * rate)


def test_explicit_display_normalization_is_opt_in():
    raw = tokens(99.03)
    assert pre_recorded._soniox_tokens_to_segments(raw, normalize=True)[0]['start'] == 0
    assert pre_recorded._soniox_tokens_to_segments(raw)[0]['start'] == 99.03
    assert raw[0]['start_ms'] == 99030


def test_empty_and_non_speech_tokens_stay_empty():
    assert pre_recorded._soniox_tokens_to_segments([]) == []
    assert pre_recorded._soniox_tokens_to_segments([{'text': ' ', 'start_ms': 99030}]) == []
