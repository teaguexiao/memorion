"""Summary corrections: real HTTP/auth/serialization and persistence over fake IO."""

import copy
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
os.environ.setdefault('OPENAI_API_KEY', 'test')
os.environ.setdefault('GOOGLE_APPLICATION_CREDENTIALS', '/tmp/memorion-service-account.json')

from fastapi import FastAPI
from fastapi.testclient import TestClient
from dependencies import developers_db
from routers import timeline
from utils.timeline.edits import chapter_edit_id
from test_timeline_store import FakeDoc, FakeCollection, FakeRedis, DayDb, convo
from utils.timeline import store

DAY = '2026-08-07'


class Doc(FakeDoc):
    @property
    def id(self):
        return self._key.rsplit('/', 1)[-1]

    def collection(self, name):
        return Collection(self._store, f'{self._key}/{name}')


class Collection(FakeCollection):
    def document(self, doc_id):
        return Doc(self._store, f'{self._prefix}/{doc_id}')

    def where(self, field, operator, value):
        assert operator == '=='
        self.predicate = (field, value)
        return self

    def stream(self):
        field, value = self.predicate
        return [Doc(self._store, key) for key, data in self._store.items()
                if key.startswith(self._prefix + '/') and data.get(field) == value]


class TimelineEditTests(unittest.TestCase):
    def setUp(self):
        self.memory = {}
        self.redis = FakeRedis()
        self.patchers = [
            patch.object(timeline.dev_db, '_get_user_ref',
                         side_effect=lambda dev, uid: Doc(self.memory, f'{dev}/{uid}')),
            patch.object(timeline.dev_db, '_ensure_user_exists'),
            patch.object(timeline, 'should_recompute_now', return_value=False),
            patch.object(timeline.redis_db, 'acquire_lock', side_effect=self.redis.acquire_lock),
            patch.object(timeline.redis_db, 'release_lock', side_effect=self.redis.release_lock),
            patch.object(timeline.redis_db, 'acquire_owned_lock', side_effect=self.redis.acquire_owned_lock),
            patch.object(timeline.redis_db, 'renew_owned_lock', side_effect=self.redis.renew_owned_lock),
            patch.object(timeline.redis_db, 'release_owned_lock', side_effect=self.redis.release_owned_lock),
            patch.object(developers_db, 'get_api_key_auth',
                         return_value={'developer_id': 'dev', 'bound_external_user_id': 'user'}),
        ]
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)
        app = FastAPI()
        app.include_router(timeline.router)
        self.client = TestClient(app)
        self.addCleanup(self.client.close)
        self.convos = [convo('a', 0), convo('b', 5)]
        self.day_db = DayDb(self.convos)
        self.summary = patch.object(store, 'summarize_chapters', side_effect=lambda chapters, *args, **kw: [
            {**ch, 'title': 'AI title', 'overview': 'AI body', 'rollup': True} for ch in chapters])
        self.summary.start()
        self.addCleanup(self.summary.stop)
        self.recompute()
        self.original = timeline.dev_db.get_timeline_day('dev', 'user', DAY)
        chapter = self.original['chapters'][0]
        self.selector = {'start': chapter['start'].isoformat(), 'end': chapter['end'].isoformat(),
                         'source_conversation_ids': chapter['source_conversation_ids']}

    def recompute(self):
        return store.recompute_day(self.day_db, self.redis, 'dev', 'user',
                                   datetime.fromisoformat(DAY).date(), force=True)

    def save(self, fields, uid='user', headers=None):
        return self.client.patch(f'/v1/timeline/{DAY}/chapters',
                                 params={'external_user_id': uid}, json={**self.selector, **fields},
                                 headers={'Authorization': 'test-key'} if headers is None else headers)

    def read(self, refresh=False):
        return self.client.get(f'/v1/timeline/{DAY}/chapters', params={
            'external_user_id': 'user', 'refresh': str(refresh).lower()},
            headers={'Authorization': 'test-key'})

    def test_title_and_body_are_independent_and_persist_on_reopen(self):
        response = self.save({'title': ' 用户标题 & A+B? '})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.save({'overview': '用户修正正文'}).status_code, 200)
        chapter = self.read().json()['chapters'][0]
        self.assertEqual(chapter['title'], '用户标题 & A+B?')
        self.assertEqual(chapter['overview'], '用户修正正文')
        self.assertEqual(timeline.dev_db.get_timeline_day('dev', 'user', DAY), self.original)
        # This collection is covered by the existing account deletion sweep.
        self.assertTrue(any('/timeline_edits/' in key for key in self.memory))
        self.assertFalse(any('/timeline_days/' in key and '/edits/' in key for key in self.memory))

    def test_saved_corrections_survive_forced_ai_recomputation(self):
        self.assertEqual(self.save({'title': 'User title', 'overview': 'User body'}).status_code, 200)
        with patch.object(timeline, 'recompute_day', side_effect=lambda *args, **kw: self.recompute()):
            body = self.read(refresh=True).json()
        self.assertEqual(body['cache'], 'computed')
        self.assertEqual(body['chapters'][0]['title'], 'User title')
        self.assertEqual(body['chapters'][0]['overview'], 'User body')
        self.assertEqual(timeline.dev_db.get_timeline_day('dev', 'user', DAY)['chapters'][0]['title'], 'AI title')

    def test_equivalent_timezone_and_source_order_match(self):
        for field in ('start', 'end'):
            self.selector[field] = datetime.fromisoformat(self.selector[field]).astimezone(
                timezone(timedelta(hours=8))).isoformat()
        self.selector['source_conversation_ids'].reverse()
        response = self.save({'title': 'Timezone title'})
        self.assertEqual(response.status_code, 200, response.text)

    def test_changed_chapter_rejects_stale_save(self):
        self.selector['end'] = '2026-08-07T23:59:00+00:00'
        self.assertEqual(self.save({'title': 'stale'}).status_code, 409)
        self.assertEqual(self.read().json()['chapters'][0]['title'], 'AI title')

    def test_corrections_do_not_bleed_to_other_span_or_source(self):
        self.save({'overview': 'User body'})
        document = copy.deepcopy(self.original)
        chapter = document['chapters'][0]
        chapter['end'] += timedelta(seconds=30)
        timeline.dev_db.store_timeline_day('dev', 'user', DAY, document)
        self.assertEqual(self.read().json()['chapters'][0]['overview'], 'AI body')
        chapter['end'] -= timedelta(seconds=30)
        chapter['source_conversation_ids'] = ['other']
        timeline.dev_db.store_timeline_day('dev', 'user', DAY, document)
        self.assertEqual(self.read().json()['chapters'][0]['overview'], 'AI body')

    def test_missing_auth_and_bound_key_cannot_write_other_user(self):
        self.assertEqual(self.save({'title': 'bad'}, headers={}).status_code, 401)
        self.assertEqual(self.save({'title': 'bad'}, uid='other').status_code, 403)
        self.assertFalse(any('/timeline_edits/' in key for key in self.memory))

    def test_other_developer_cannot_target_this_summary(self):
        with patch.object(developers_db, 'get_api_key_auth', return_value={'developer_id': 'other'}):
            self.assertEqual(self.save({'title': 'bad'}).status_code, 409)

    def test_validation_rejects_blank_missing_and_oversized_text(self):
        for fields in ({}, {'title': '  '}, {'overview': '\n'}, {'title': 'x' * 501},
                       {'overview': 'x' * 100001}, {'title': None, 'overview': None}):
            with self.subTest(fields=list(fields)):
                self.assertEqual(self.save(fields).status_code, 422)

    def test_naive_timestamps_rejected(self):
        self.selector['start'] = '2026-08-07T13:00:00'
        self.assertEqual(self.save({'title': 'bad'}).status_code, 422)

    def test_failed_storage_does_not_report_success(self):
        with patch.object(timeline.edits_db, 'save_chapter_edit', side_effect=RuntimeError('storage unavailable')):
            with self.assertRaisesRegex(RuntimeError, 'storage unavailable'):
                self.save({'title': 'not saved'})
        self.assertEqual(self.read().json()['chapters'][0]['title'], 'AI title')
        self.assertFalse(self.redis.locks)

    def test_recompute_in_progress_rejects_save_without_writing(self):
        key = store.day_lock_key('dev', 'user', DAY)
        self.redis.acquire_lock(key)
        self.assertEqual(self.save({'title': 'busy'}).status_code, 409)
        self.assertIn(key, self.redis.locks)
        self.assertFalse(any('/timeline_edits/' in key for key in self.memory))

    def test_redis_unavailability_returns_retryable_error_without_saving(self):
        for operation in ('acquire_owned_lock', 'renew_owned_lock'):
            with self.subTest(operation=operation), \
                 patch.object(timeline.redis_db, operation, side_effect=ConnectionError('unavailable')):
                self.assertEqual(self.save({'title': 'not saved'}).status_code, 503)
            self.assertFalse(any('/timeline_edits/' in key for key in self.memory))
            self.assertFalse(self.redis.locks)

    def test_same_sources_in_different_chapters_have_distinct_identity(self):
        chapter = self.original['chapters'][0]
        other = {**chapter, 'start': chapter['start'] + timedelta(minutes=20),
                 'end': chapter['end'] + timedelta(minutes=20)}
        self.assertNotEqual(chapter_edit_id(chapter), chapter_edit_id(other))


if __name__ == '__main__':
    unittest.main()
