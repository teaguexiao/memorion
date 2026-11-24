"""Opt-in acceptance against an ephemeral Redis service, never production Redis."""
import os
import time
import uuid
from datetime import date
from unittest.mock import patch

import pytest
from redis import Redis
from database import redis_db
from utils.timeline import rollup, store
from utils.timeline.batch_cache import BatchCache, CACHE_TTL_SECONDS
from test_timeline_batch_cache import Model, dependencies, request, counts
from test_timeline_store import FakeFirestore, DayDb, convo, dev_db


@pytest.fixture
def live_cache():
    url = os.environ.get('TIMELINE_TEST_REDIS_URL')
    if not url:
        pytest.skip('Set TIMELINE_TEST_REDIS_URL to opt into ephemeral local Redis')
    from urllib.parse import urlsplit
    assert urlsplit(url).hostname == '127.0.0.1', 'This test may only use loopback Redis'
    client = Redis.from_url(url, socket_timeout=2, socket_connect_timeout=2)
    assert client.ping()
    owner = 'synthetic-' + uuid.uuid4().hex
    cache = BatchCache(client, owner, 'synthetic-user', '2026-08-07')
    try:
        yield cache, owner
    finally:
        # Only this run's own cache entries; never FLUSHDB or a global sweep.
        keys = list(client.scan_iter(cache.prefix + '*'))
        if keys:
            client.delete(*keys)
        assert not list(client.scan_iter(cache.prefix + '*'))
        client.close()


def test_real_redis_reuse_expiry_and_atomic_ttl(live_cache):
    cache, owner = live_cache
    models = (Model('draft-luna'), Model('review-sol'))
    req = request(models)
    first = rollup.run_rollup(req, cache)
    assert rollup.run_rollup(req, BatchCache(cache.redis, owner, 'synthetic-user', '2026-08-07')) == first
    assert counts(models) == (1, 1)
    keys = list(cache.redis.scan_iter(cache.prefix + '*'))
    assert len(keys) == 2
    for key in keys:
        assert 0 < cache.redis.ttl(key) <= CACHE_TTL_SECONDS
        cache.redis.pexpire(key, 100)
    time.sleep(0.15)
    assert not list(cache.redis.scan_iter(cache.prefix + '*'))
    assert rollup.run_rollup(req, cache)['rollup'] is True
    assert counts(models) == (2, 2)


def test_real_redis_retry_after_lease_loss_does_not_repeat_inference(live_cache):
    cache, owner = live_cache
    models = (Model('draft-luna'), Model('review-sol'))
    db = DayDb([convo('a', 0), convo('b', 5)])
    with patch.object(dev_db, 'db', FakeFirestore()), patch.object(redis_db, 'r', cache.redis):
        def compute():
            return store.recompute_day(db, redis_db, owner, 'synthetic-user', date(2026, 8, 7),
                                       dependencies=dependencies(models))
        with patch.object(redis_db, 'renew_owned_lock', return_value=False):
            with pytest.raises(store.TimelineLeaseUnavailable):
                compute()
        assert db.store_calls == 0
        assert counts(models) == (1, 1)
        assert compute()['status'] == 'computed'
        assert counts(models) == (1, 1)
        assert cache.redis.get('lock:' + store.day_lock_key(owner, 'synthetic-user', '2026-08-07')) is None


def test_real_redis_owner_fencing(live_cache):
    cache, owner = live_cache
    key = 'timeline-synthetic-' + owner
    with patch.object(redis_db, 'r', cache.redis):
        try:
            assert redis_db.acquire_owned_lock(key, 'first', 10)
            assert not redis_db.acquire_owned_lock(key, 'second', 10)
            assert not redis_db.renew_owned_lock(key, 'second', 10)
            redis_db.release_owned_lock(key, 'second')
            assert cache.redis.get('lock:' + key) == b'first'
            assert redis_db.renew_owned_lock(key, 'first', 10)
        finally:
            redis_db.release_owned_lock(key, 'first')
        assert cache.redis.get('lock:' + key) is None
