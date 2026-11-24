import copy
import os
from unittest.mock import Mock

import pytest
import requests

from utils.audio_jobs.soniox import Soniox
from utils.audio_jobs.state import JobFailure


def response(data=None, status=200, headers=None):
    value = Mock(status_code=status, headers=headers or {})
    value.json.return_value = data or {}
    return value


@pytest.fixture(autouse=True)
def key(monkeypatch):
    monkeypatch.setenv('SONIOX_API_KEY', 'synthetic-test-key')


def test_existing_remote_id_is_polled_without_reupload_or_delete(tmp_path):
    http = Mock()
    http.request.side_effect = [response({'status': 'completed'}), response({'tokens': [
        {'text': 'Hello', 'start_ms': 0, 'duration_ms': 1000, 'speaker': '1', 'language': 'en'}]})]
    result = Soniox(http).transcribe(str(tmp_path / 'not-required.wav'), 'auto',
                                   {'soniox_file_id': 'file', 'soniox_transcription_id': 'task'}, Mock())
    assert result['segments']
    assert result['segments'][0]['end'] == 1.0
    assert [call.args[0] for call in http.request.call_args_list] == ['GET', 'GET']


def test_ambiguous_submission_stops_without_another_billable_request(tmp_path):
    http = Mock()
    with pytest.raises(JobFailure, match='provider_submission_unknown') as error:
        Soniox(http).transcribe('unused.wav', 'auto', {'soniox_file_id': 'file', 'soniox_submission_pending': True}, Mock())
    assert not error.value.retryable
    http.request.assert_not_called()


def test_create_response_lost_preserves_submission_intent(tmp_path):
    http = Mock()
    http.request.side_effect = requests.Timeout()
    checkpoint = {'soniox_file_id': 'file'}
    with pytest.raises(requests.Timeout):
        Soniox(http).transcribe('unused.wav', 'auto', checkpoint, checkpoint.update)
    assert checkpoint['soniox_submission_pending']
    assert len(http.request.call_args_list) == 1
    with pytest.raises(JobFailure, match='provider_submission_unknown'):
        Soniox(http).transcribe('unused.wav', 'auto', checkpoint, checkpoint.update)
    assert len(http.request.call_args_list) == 1


def test_rate_limit_retains_file_id_and_releases_submission_intent():
    http = Mock()
    http.request.return_value = response(status=429, headers={'Retry-After': '180'})
    checkpoint = {'soniox_file_id': 'file'}
    with pytest.raises(JobFailure) as error:
        Soniox(http).transcribe('unused.wav', 'auto', checkpoint, checkpoint.update)
    assert error.value.retry_after == 180
    assert not checkpoint['soniox_submission_pending']
    assert checkpoint['soniox_file_id'] == 'file'


def test_poll_timeout_keeps_remote_resources():
    http = Mock()
    http.request.return_value = response({'status': 'processing'})
    now = [0]
    def sleep(seconds):
        now[0] += seconds
    checkpoint = {'soniox_file_id': 'file', 'soniox_transcription_id': 'task'}
    with pytest.raises(JobFailure, match='provider_timeout'):
        Soniox(http, clock=lambda: now[0], sleep=sleep).transcribe('unused.wav', 'auto', checkpoint, Mock())
    assert all(call.args[0] == 'GET' for call in http.request.call_args_list)
    assert checkpoint['soniox_transcription_id'] == 'task'


def test_ids_are_saved_before_polling(tmp_path):
    audio = tmp_path / 'audio.wav'
    audio.write_bytes(b'test')
    checkpoint = {}
    http = Mock()
    def request(method, url, **kwargs):
        if url.endswith('/files'):
            assert kwargs['data'].read()  # Exercise actual streaming multipart.
            return response({'id': 'file'})
        if url.endswith('/transcriptions'):
            assert checkpoint['soniox_file_id'] == 'file'
            assert checkpoint['soniox_submission_pending']
            return response({'id': 'task'}, status=201)
        assert checkpoint['soniox_transcription_id'] == 'task'
        raise requests.ConnectionError()
    http.request.side_effect = request
    with pytest.raises(requests.ConnectionError):
        Soniox(http).transcribe(str(audio), 'auto', checkpoint, checkpoint.update)
    assert checkpoint['soniox_transcription_id'] == 'task'
    assert not checkpoint['soniox_submission_pending']


def test_cleanup_only_explicitly_and_missing_resources_are_ok():
    http = Mock()
    http.request.return_value = response(status=404)
    Soniox(http).cleanup({'soniox_file_id': 'file', 'soniox_transcription_id': 'task'})
    assert [call.args[0] for call in http.request.call_args_list] == ['DELETE', 'DELETE']
