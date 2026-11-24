"""Offline validation must fail even if application fallbacks swallow errors."""
from unittest.mock import patch
from redis import Redis
from utils.timeline.batch_cache import BatchCache
from run_timeline_tests import _run_tests


def test_swallowed_unexpected_network_attempt_still_fails_the_suite():
    client = Redis(host='127.0.0.1', port=1, socket_connect_timeout=0.1)
    cache = BatchCache(client, 'synthetic', 'synthetic', '2026-10-14')
    def apparently_passing_tests(args):
        # The cache intentionally fails open. The suite's independent guard must
        # still notice the attempted network connection and reject a false green.
        assert cache.get('draft', 'synthetic') is None
        return 0
    try:
        with patch('pytest.main', side_effect=apparently_passing_tests):
            assert _run_tests(['synthetic-test']) == 1
    finally:
        client.close()
