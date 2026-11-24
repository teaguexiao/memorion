"""Exercise the production-pinned GCS SDK, mocking only its HTTP transport."""
import base64
import hashlib
import json
from unittest.mock import Mock

import google_crc32c
import pytest
import requests
from google.auth.credentials import AnonymousCredentials
from google.cloud import storage

from utils.audio_jobs.artifacts import Artifacts


@pytest.mark.parametrize('size', [24, 9 * 1024 * 1024])
def test_audio_upload_uses_supported_integrity_check_and_immutable_generation(tmp_path, size):
    path = tmp_path / 'audio.wav'
    path.write_bytes((b'RIFF synthetic recording' * (size // 24 + 1))[:size])
    crc = base64.b64encode(google_crc32c.Checksum(path.read_bytes()).digest()).decode()
    response = requests.Response()
    response.status_code = 200
    response._content = json.dumps({'name': 'audio_jobs/job/token/audio.wav', 'generation': '42',
                                    'crc32c': crc}).encode()
    session = requests.Session()
    session.is_mtls = False
    if size > 8 * 1024 * 1024:
        initiated = requests.Response()
        initiated.status_code = 200
        initiated.headers['location'] = 'https://synthetic.invalid/resumable-upload'
        session.request = Mock(side_effect=[initiated, response])
    else:
        session.request = Mock(return_value=response)
    client = storage.Client(project='synthetic-test', credentials=AnonymousCredentials(), _http=session)
    result = Artifacts(client.bucket('synthetic-test')).put_audio('job', 'token', str(path))
    assert result['generation'] == 42
    assert result['sha256'] == hashlib.sha256(path.read_bytes()).hexdigest()
    assert result['size'] == path.stat().st_size
    call = session.request.call_args_list[0]
    assert 'ifGenerationMatch=0' in call.args[1]
    if size <= 8 * 1024 * 1024:
        assert crc.encode() in call.kwargs['data']
    else:
        assert session.request.call_count == 2
