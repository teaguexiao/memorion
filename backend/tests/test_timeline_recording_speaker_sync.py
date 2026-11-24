"""Recording assignment HTTP -> immediate marker -> normal timeline GET.

Compile the three production route functions and their request model verbatim,
without importing the unrelated streaming/STT dependency tree. Authentication,
persistence, dirty marker, recomputation and response presentation are real code;
only IO, summaries and background audio collection are fixtures.
"""
import ast
import copy
import pathlib
import types
import unittest
from datetime import datetime, timezone
from typing import List, Optional
from unittest.mock import patch, Mock
import fakeredis

from fastapi import APIRouter, Depends, Query, HTTPException
from pydantic import BaseModel, Field
from dependencies import get_developer_id_from_api_key
from routers import timeline
from utils.timeline import store
from database import redis_db
from utils.timeline.speakers import chapter_evidence, build_display
from test_timeline_edits import TimelineEditTests, DAY
from test_timeline_speakers import SpeakerRoutesTests


def recording_routes():
    source = pathlib.Path(__file__).parents[1] / 'routers/developer_conversations.py'
    tree = ast.parse(source.read_text())
    names = {'BulkAssignSegmentsRequest', 'mark_timeline_day_dirty', 'assign_segments_bulk',
             'set_assignee_conversation_segment', 'assign_speaker_to_segments'}
    nodes = [node for node in tree.body if getattr(node, 'name', None) in names]
    assert len(nodes) == len(names)
    router = APIRouter()
    env = dict(router=router, BaseModel=BaseModel, Field=Field, List=List, Optional=Optional,
               Depends=Depends, Query=Query, HTTPException=HTTPException,
               get_developer_id_from_api_key=get_developer_id_from_api_key,
               ConversationResponse=None, dev_db=timeline.dev_db,
               threading=types.SimpleNamespace(Thread=lambda **kw: types.SimpleNamespace(start=lambda: None)),
               collect_speech_samples_developer=Mock())
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), 'exec'), env)
    return router


class RecordingSpeakerSyncTests(unittest.TestCase):
    recompute = TimelineEditTests.recompute
    read = TimelineEditTests.read
    save = TimelineEditTests.save

    def setUp(self):
        SpeakerRoutesTests.setUp(self)
        self.day_db.get_timeline_chapter_edits = timeline.edits_db.get_chapter_edits
        self.client.app.include_router(recording_routes())
        self.persist_ok = True
        def get_conversation(developer_id, external_user_id, conversation_id):
            return copy.deepcopy(next((c for c in self.convos if c['id'] == conversation_id), None))
        def persist(developer_id, external_user_id, conversation_id, segments):
            if not self.persist_ok:
                return False
            next(c for c in self.convos if c['id'] == conversation_id)['transcript_segments'] = copy.deepcopy(segments)
            return True
        def summary(chapters, convos, **kw):
            result = []
            for chapter in chapters:
                evidence = chapter_evidence(chapter, {c['id']: c for c in convos})
                prose = f'[[speaker:{next(iter(evidence))}]]建议继续核实。'
                result.append({**chapter, 'title': 'AI title', 'overview': prose,
                               'speaker_display': build_display(prose, evidence), 'rollup': True})
            return result
        patchers = [
            patch.object(timeline.dev_db, 'get_conversation', side_effect=get_conversation),
            patch.object(timeline.dev_db, 'update_conversation_segments_dev', side_effect=persist),
            patch.object(timeline.dev_db, 'get_user_timezone', return_value='UTC'),
            patch.object(timeline.redis_db, 'r', None),
            patch.object(timeline.redis_db, 'get_generic_cache', side_effect=self.redis.get_generic_cache),
            patch.object(timeline.redis_db, 'set_generic_cache', side_effect=self.redis.set_generic_cache),
            patch.object(timeline, 'should_recompute_now', side_effect=lambda _, d,u,day: store.should_recompute_now(self.redis,d,u,day)),
            patch.object(timeline, 'recompute_day', side_effect=lambda *a, **kw: store.recompute_day(
                self.day_db, self.redis, 'dev', 'user', datetime.fromisoformat(DAY).date(), dependencies=kw.get('dependencies'))),
            patch.object(store, 'summarize_chapters', side_effect=summary),
        ]
        for p in patchers:
            p.start(); self.addCleanup(p.stop)

    def assign(self, route='bulk', person='person1', uid='user'):
        paths = {'bulk': 'segments/assign-bulk', 'single': 'segments/0/assign', 'speaker': 'assign-speaker/1'}
        params = {'external_user_id': uid}
        kwargs = {}
        value = 'null' if person is None else person
        if route == 'bulk':
            kwargs['json'] = {'segment_ids': ['a-0','a-1','a-2'], 'assign_type': 'person_id', 'value': value}
        else:
            params.update(assign_type='person_id', value=value)
        return self.client.patch('/v1/conversations/a/' + paths[route], params=params,
                                 headers={'Authorization': 'test-key'}, **kwargs)

    def test_all_recording_assignment_routes_update_cached_calendar_without_refresh(self):
        for route in ['bulk', 'single', 'speaker']:
            with self.subTest(route=route):
                result = self.assign(route)
                self.assertEqual(result.status_code, 200, result.text)
                key = store.dirty_marker_key('dev','user',DAY)
                self.assertTrue(self.redis.cache[key]['immediate'])
                response = self.read()
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(response.json()['cache'], 'computed')
                chapter = response.json()['chapters'][0]
                self.assertIn('阿宁', chapter['overview'])
                stored = timeline.dev_db.get_timeline_day('dev','user',DAY)['chapters'][0]
                self.assertIn('person1', str(stored['speaker_display']))
                self.assertNotIn(key, self.redis.cache)
                self.assertEqual(self.assign(route, None).status_code, 200)
                self.assertNotIn('阿宁', self.read().json()['chapters'][0]['overview'])

    def test_failure_and_cross_account_never_mutate_or_dirty(self):
        original = copy.deepcopy(self.convos)
        self.persist_ok = False
        self.assertEqual(self.assign().status_code, 404)
        self.assertEqual(self.assign(uid='other').status_code, 403)
        self.assertEqual(self.convos, original)
        self.assertFalse(self.redis.cache)

    def test_manual_title_and_attributed_prose_survive_identity_recomputation(self):
        response = self.client.patch(f'/v1/timeline/{DAY}/chapters',
            params={'external_user_id': 'user', 'speaker_attribution': 'true'},
            headers={'Authorization': 'test-key'},
            json={**self.selector, 'title': '用户标题', 'overview': self.original['chapters'][0]['overview']})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.assign().status_code, 200)
        chapter = self.read().json()['chapters'][0]
        self.assertEqual(chapter['title'], '用户标题')
        self.assertIn('保留长篇用户注释', chapter['overview'])
        self.assertIn('阿宁', chapter['overview'])
        # A cache hit renders current manual attribution without reading or
        # decompressing any source recording, including after refs are dropped.
        with patch.object(timeline.dev_db, 'get_conversation', side_effect=AssertionError('cache read transcript')):
            cached = self.read().json()
        self.assertEqual(cached['cache'], 'hit')
        self.assertIn('阿宁', cached['chapters'][0]['overview'])

    def test_manual_prose_identity_survives_ai_omission_and_compacted_refs(self):
        response = self.client.patch(f'/v1/timeline/{DAY}/chapters',
            params={'external_user_id': 'user', 'speaker_attribution': 'true'},
            headers={'Authorization': 'test-key'},
            json={**self.selector, 'overview': self.original['chapters'][0]['overview']})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.assign().status_code, 200)
        with patch.object(store, 'summarize_chapters', side_effect=lambda chapters, *a, **kw: [
            {**ch, 'segment_refs': [], 'overview': '新的 AI 总结没有引用原来的人。',
             'speaker_display': {'version': 1, 'mentions': {}, 'speakers': []}} for ch in chapters]):
            chapter = self.read().json()['chapters'][0]
        self.assertIn('保留长篇用户注释', chapter['overview'])
        self.assertIn('阿宁', chapter['overview'])
        # GET and speaker evidence share the refreshed revision and identity.
        with patch.object(timeline.dev_db, 'get_conversation', side_effect=AssertionError('cache read transcript')):
            attributed = self.client.get(f'/v1/timeline/{DAY}/chapters',
                params={'external_user_id': 'user', 'speaker_attribution': 'true'},
                headers={'Authorization': 'test-key'}).json()['chapters'][0]
        stored = timeline.dev_db.get_timeline_day('dev', 'user', DAY)['chapters'][0]
        self.assertFalse(stored['segment_refs'])
        self.assertTrue(stored['_manual_speaker_evidence'])
        self.assertNotIn('text', str(stored['_manual_speaker_evidence']))
        self.assertNotIn('_manual_speaker_evidence', attributed)
        speaker = attributed['speaker_display']['speakers'][0]
        context = timeline._speaker_context(DAY, types.SimpleNamespace(
            model_dump=lambda: self.selector, revision=attributed['speaker_revision'], speaker_id=speaker['id']),
            'dev', 'user')
        self.assertEqual(context[-1]['person_id'], 'person1')

    def test_correction_during_recompute_keeps_new_dirty_marker(self):
        day = datetime.fromisoformat(DAY).date()
        store.mark_day_dirty(self.redis, 'dev','user',day, immediate=True)
        key = store.dirty_marker_key('dev','user',DAY)
        before = self.redis.cache[key]
        existing = store.summarize_chapters
        def correcting(*args, **kwargs):
            result = existing(*args, **kwargs)
            store.mark_day_dirty(self.redis, 'dev','user',day, immediate=True)
            return result
        with patch.object(store, 'summarize_chapters', side_effect=correcting):
            response = self.read()
        self.assertEqual(response.json()['cache'], 'pending')
        self.assertNotEqual(before, self.redis.cache[key])
        self.assertTrue(store.should_recompute_now(self.redis,'dev','user',day))
        self.read()
        self.assertNotIn(key, self.redis.cache)

    def test_normal_recording_marker_cannot_delay_manual_correction(self):
        day = datetime.fromisoformat(DAY).date()
        store.mark_day_dirty(self.redis,'dev','user',day)
        self.assertFalse(store.should_recompute_now(self.redis,'dev','user',day))
        self.assign()
        store.mark_day_dirty(self.redis,'dev','user',day)
        self.assertTrue(store.should_recompute_now(self.redis,'dev','user',day))


class AtomicRecordingMarkerTests(unittest.TestCase):
    def test_atomic_set_and_compare_delete_keep_concurrent_correction(self):
        client = fakeredis.FakeRedis()
        self.addCleanup(client.close)
        with patch.object(redis_db, 'r', client):
            day = datetime.fromisoformat(DAY).date()
            key = store.dirty_marker_key('dev', 'user', DAY)
            store.mark_day_dirty(redis_db, 'dev', 'user', day)
            normal = redis_db.get_generic_cache(key)
            store.mark_day_dirty(redis_db, 'dev', 'user', day, immediate=True)
            checked = redis_db.get_generic_cache(key)
            store.mark_day_dirty(redis_db, 'dev', 'user', day)
            self.assertEqual(redis_db.get_generic_cache(key), checked)
            store._clear_checked_dirty_marker(redis_db, key, normal)
            self.assertEqual(redis_db.get_generic_cache(key), checked)
            store.mark_day_dirty(redis_db, 'dev', 'user', day, immediate=True)
            latest = redis_db.get_generic_cache(key)
            store._clear_checked_dirty_marker(redis_db, key, checked)
            self.assertEqual(redis_db.get_generic_cache(key), latest)
            store._clear_checked_dirty_marker(redis_db, key, latest)
            self.assertIsNone(redis_db.get_generic_cache(key))
