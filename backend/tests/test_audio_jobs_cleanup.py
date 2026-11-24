from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from test_audio_jobs import store, accepted
from utils.audio_jobs.cleanup import delete_owner_jobs
from utils.audio_jobs.state import LeaseLost


def test_owner_deletion_fences_worker_and_removes_all_job_artifacts(store):
    job = accepted(store)
    other = accepted(store, owner='other')
    store.claim(job['id'], 'running')
    store.checkpoint(job['id'], 'running', {'soniox_file_id': 'synthetic-file'})
    blobs = [Mock(), Mock()]
    bucket = Mock()
    def list_blobs(prefix):
        assert prefix == f"audio_jobs/{job['id']}/"
        with pytest.raises(LeaseLost):
            store.publish(job['id'], 'running', {'transcript_segments': []})
        return blobs
    bucket.list_blobs.side_effect = list_blobs
    provider = Mock()
    delete_owner_jobs('test-dev', 'user', store=store,
                      artifacts=SimpleNamespace(bucket=bucket), soniox=provider)
    assert store.get(job['id']) is None
    assert store.get(other['id'])['status'] == 'queued'
    provider.cleanup.assert_called_once_with({'soniox_file_id': 'synthetic-file'})
    for blob in blobs:
        blob.delete.assert_called_once_with()
    bucket.reset_mock()
    delete_owner_jobs('test-dev', 'user', store=store,
                      artifacts=SimpleNamespace(bucket=bucket), soniox=provider)
    bucket.list_blobs.assert_not_called()
