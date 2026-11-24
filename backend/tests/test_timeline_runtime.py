"""Bound expensive work before calling models; preserve data across lease loss."""

import ast
from datetime import datetime, timezone
import os
from pathlib import Path
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from starlette.requests import Request
from database import redis_db
from scripts.rebuild_timeline_day import canonical_document
from utils.other.timeout import TimeoutMiddleware
from utils.timeline import rollup
from utils.timeline.day_query import MAX_FETCH, DayQueryLimitExceeded, get_day_conversations

try:
    import fakeredis
except ImportError:
    fakeredis = None


class TimelineRuntimeTests(unittest.TestCase):
    def test_day_budget_checked_before_any_inference(self):
        with patch.object(rollup, 'resolve_llm') as model:
            with self.assertRaises(rollup.RollupBudgetExceeded):
                rollup.validate_day_rollup_budget([SimpleNamespace(batches=[None] * 7) for _ in range(3)])
            model.assert_not_called()

    def test_oversized_chapter_rejected_before_prompt_or_model_io(self):
        source = {'source_text': 'x' * (rollup.MAX_FRAGMENT_BLOCK_CHARS * rollup.MAX_CHAPTER_BATCHES),
                  'requires_rollup': True}
        with patch.object(rollup, 'get_prompt') as prompt, patch.object(rollup, 'resolve_llm') as model:
            with self.assertRaises(rollup.RollupBudgetExceeded):
                rollup.summarize_chapter([source])
            prompt.assert_not_called()
            model.assert_not_called()

    def test_candidate_limit_checked_before_day_filter(self):
        class Db:
            def get_conversations_by_recording_time(self, *args, **kwargs):
                # All candidates would disappear during local-day filtering.
                return [{'started_at': None}] * MAX_FETCH

        with self.assertRaises(DayQueryLimitExceeded):
            get_day_conversations(Db(), 'dev', 'uid', datetime(2026, 1, 1).date(),
                                  tz=timezone.utc, require_complete=True)

    def test_firestore_datetime_roundtrip_comparison(self):
        from google.api_core.datetime_helpers import DatetimeWithNanoseconds
        written = {'chapters': [{'start': datetime(2026, 1, 1), 'voice_runs': [datetime(2026, 1, 1)]}]}
        read = {'chapters': [{'start': DatetimeWithNanoseconds(2026, 1, 1, tzinfo=timezone.utc),
                              'voice_runs': [DatetimeWithNanoseconds(2026, 1, 1, tzinfo=timezone.utc)]}]}
        self.assertEqual(canonical_document(written), canonical_document(read))
        read['chapters'][0]['overview'] = 'different content'
        self.assertNotEqual(canonical_document(written), canonical_document(read))

    def test_timeline_timeout_overrides_get_but_not_unrelated_routes(self):
        source = (Path(__file__).resolve().parents[1] / 'main.py').read_text()
        node = next(node for node in ast.parse(source).body if isinstance(node, ast.Assign)
                    and any(isinstance(target, ast.Name) and target.id == 'paths_timeout' for target in node.targets))
        with patch.dict(os.environ, {}, clear=True):
            paths = eval(compile(ast.Expression(node.value), '<paths_timeout>', 'eval'), {'os': os})
            middleware = TimeoutMiddleware(None, methods_timeout={'GET': 120}, paths_timeout=paths)
        for path in ('/v1/timeline/2026-10-12', '/v1/timeline/2026-10-12/chapters'):
            self.assertGreaterEqual(middleware._timeout_for(Request({'type': 'http', 'path': path, 'method': 'GET', 'headers': []})), 1200)
        self.assertEqual(middleware._timeout_for(Request({'type': 'http', 'path': '/v1/profile', 'method': 'GET', 'headers': []})), 120)
        self.assertEqual(middleware._timeout_for(Request({'type': 'http', 'path': '/v1/daily-summary', 'method': 'POST', 'headers': []})), 600)


@unittest.skipIf(fakeredis is None, 'Install tests/requirements.timeline.txt for Lua lease tests')
class OwnedRedisLeaseTests(unittest.TestCase):
    def setUp(self):
        self.redis = fakeredis.FakeRedis()
        self.patcher = patch.object(redis_db, 'r', self.redis)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        self.addCleanup(self.redis.close)

    def test_renew_and_release_check_owner_atomically(self):
        self.assertTrue(redis_db.acquire_owned_lock('day', 'first', 300))
        self.assertFalse(redis_db.acquire_owned_lock('day', 'second', 300))
        self.redis.expire('lock:day', 2)
        self.assertFalse(redis_db.renew_owned_lock('day', 'second', 300))
        self.assertLessEqual(self.redis.ttl('lock:day'), 2)
        self.assertTrue(redis_db.renew_owned_lock('day', 'first', 300))
        self.assertGreater(self.redis.ttl('lock:day'), 290)
        # Simulate expiry and acquisition by another worker.
        self.redis.set('lock:day', 'second', ex=300)
        redis_db.release_owned_lock('day', 'first')
        self.assertEqual(self.redis.get('lock:day'), b'second')
        redis_db.release_owned_lock('day', 'second')
        self.assertIsNone(self.redis.get('lock:day'))

    def test_legacy_and_owned_locks_share_namespace(self):
        self.assertTrue(redis_db.acquire_lock('day'))
        self.assertFalse(redis_db.acquire_owned_lock('day', 'owner'))
        self.assertFalse(redis_db.renew_owned_lock('day', 'owner'))
        redis_db.release_owned_lock('day', 'owner')
        self.assertEqual(self.redis.get('lock:day'), b'1')

    def test_acquire_fails_closed_on_redis_error(self):
        with patch.object(self.redis, 'set', side_effect=ConnectionError('unavailable')):
            with self.assertRaises(ConnectionError):
                redis_db.acquire_owned_lock('day', 'owner')




class RuntimeParityTests(unittest.TestCase):
    def test_focused_runtime_matches_production_interfaces(self):
        """A passing HTTP/cache suite must exercise the deployed API versions."""
        from importlib.metadata import version
        production = {}
        for line in (Path(__file__).resolve().parents[1] / 'requirements.fargate.txt').read_text().splitlines():
            if '==' in line and not line.startswith('#'):
                name, expected = line.split('==', 1)
                production[name.lower().replace('_', '-')] = expected
        interfaces = ('fastapi', 'starlette', 'anyio', 'httpx', 'httpcore', 'h11', 'numpy', 'protobuf',
                      'pydantic', 'pydantic-core', 'langchain-core', 'langchain-openai', 'langchain-aws',
                      'langchain-google-genai', 'openai', 'google-genai', 'boto3', 'botocore',
                      'firebase-admin', 'google-cloud-firestore', 'redis')
        focused = {}
        for line in (Path(__file__).parent / 'requirements.timeline-ci.txt').read_text().splitlines():
            if '==' in line and not line.startswith('#'):
                name, pinned = line.split('==', 1)
                focused[name.lower().replace('_', '-')] = pinned
        for package in sorted(set(interfaces) | (production.keys() & focused.keys())):
            with self.subTest(package=package):
                self.assertEqual(focused[package], production[package])
                self.assertEqual(version(package), production[package],
                                 'Install tests/requirements.timeline-ci.txt with --no-deps')


if __name__ == '__main__':
    unittest.main()
