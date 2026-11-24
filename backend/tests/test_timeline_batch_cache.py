"""Exercise reuse with the real renderer, parser, rollup and Redis serialization.

Models are deterministic fakes; these tests measure calls, not model quality.
"""
import copy
import json
import os
from pathlib import Path
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault('OPENAI_API_KEY', 'test')
os.environ.setdefault('OPENROUTER_API_KEY', 'test')

import fakeredis
import pytest
from utils.llm.prompt_registry import ResolvedPrompt
from utils.timeline import rollup, store
from utils.timeline.batch_cache import BatchCache, CACHE_TTL_SECONDS, MAX_ENTRY_BYTES
from utils.timeline.sources import chapter_fragments
from test_timeline_sources import recording
from test_timeline_store import FakeFirestore, DayDb, convo, DEV, UID, DAY
from test_timeline_store import dev_db
from database import redis_db


class Model:
    def __init__(self, model_name):
        self.model_name = model_name
        self.reasoning_effort = 'medium'
        self.calls = []
        self.fail = False
        self.entered = None
        self.proceed = None

    def with_structured_output(self, schema):
        return self

    def invoke(self, prompt, **kwargs):
        self.calls.append(prompt)
        if self.entered:
            self.entered.set()
            assert self.proceed.wait(5), 'test did not release inference'
        if self.fail:
            raise RuntimeError('private prompt must never enter logs')
        if self.model_name.startswith('draft'):
            return rollup.ChapterRollup(title='facts', overview=prompt.split('<CORE>')[1].split('</CORE>')[0])
        return prompt.split('<untrusted_draft>\n')[1].split('\n</untrusted_draft>')[0]


@pytest.fixture
def models():
    return Model('draft-luna'), Model('review-sol')


def dependencies(models):
    return rollup.SummaryDependencies(
        ResolvedPrompt('timeline.chapter_rollup', rollup._ROLLUP_TEMPLATE.content, {}),
        ResolvedPrompt('timeline.chapter_grounding', rollup._GROUNDING_TEMPLATE.content, {}), *models)


@pytest.fixture
def cache():
    client = fakeredis.FakeRedis()
    yield BatchCache(client, DEV, UID, DAY.isoformat())
    client.close()


def source(text='Budget 37. Approval is pending.', label='R-a: Recording started 2026-10-14'):
    return {'source_label': label, 'source_text': text, 'requires_rollup': True}


def request(models, fragments=None, **kwargs):
    return rollup.prepare_rollup(fragments or [source()], dependencies=dependencies(models), **kwargs)


def counts(models):
    return tuple(len(model.calls) for model in models)


def test_unchanged_request_shared_between_cache_instances_uses_zero_calls(models, cache):
    req = request(models)
    first = rollup.run_rollup(req, cache)
    new_worker = BatchCache(cache.redis, DEV, UID, DAY.isoformat())
    assert rollup.run_rollup(request(models), new_worker) == first
    assert counts(models) == (1, 1)
    assert len(cache.redis.keys()) == 2
    assert all(0 < cache.redis.ttl(k) <= CACHE_TTL_SECONDS for k in cache.redis.keys())


def test_appending_source_reuses_earlier_batches_and_preserves_all_evidence(models, cache):
    sources = [source('a' * 96000)]
    before = request(models, sources)
    assert len(before.batches) == 5
    rollup.run_rollup(before, cache)
    after = request(models, sources + [source('NEW_DETAIL ' + 'b' * 2000, 'R-b: Recording started later')])
    assert len(after.batches) == 5
    changed = [i for i, p in enumerate(after.prompts) if p != before.prompts[i]]
    assert changed == [3, 4]
    first_counts = counts(models)
    result = rollup.run_rollup(after, cache)
    assert counts(models) == tuple(n + 2 for n in first_counts)
    assert 'NEW_DETAIL' in result['overview']
    assert ''.join(after.batches) == rollup.render_fragments(after.usable)
    assert all('R-b:' not in p for p in after.prompts[:3])


def test_boundary_correction_invalidates_neighbor_and_keeps_context(models, cache):
    original = source('a' * 23880 + '\nMay we approve?\n' + 'z' * 25000)
    before = request(models, [original])
    rollup.run_rollup(before, cache)
    corrected = copy.deepcopy(original)
    corrected['source_text'] = original['source_text'].replace('z' * 20, 'No; approval pending.', 1)
    after = request(models, [corrected])
    assert 'No; approval pending.' in after.prompts[0]
    changed = sum(p not in before.prompts for p in after.prompts)
    first_counts = counts(models)
    rollup.run_rollup(after, cache)
    assert counts(models) == tuple(n + changed for n in first_counts)
    assert changed >= 2


@pytest.mark.parametrize('field,value', [('text', 'Budget 73, corrected.'), ('speaker_id', 2),
                                        ('is_user', True), ('start', 2.0), ('timestamp', 4.0)])
def test_source_corrections_invalidate_affected_batch(models, cache, field, value):
    rec = recording('a', ['Budget 37.', 'not selected'])
    chapter = {'source_conversation_ids': ['a'], 'segment_refs': [{'conversation_id': 'a', 'index': 0}]}
    before = request(models, chapter_fragments(chapter, {'a': rec}))
    rollup.run_rollup(before, cache)
    rec['transcript_segments'][0][field] = value
    after = request(models, chapter_fragments(chapter, {'a': rec}))
    assert before.cache_key != after.cache_key
    rollup.run_rollup(after, cache)
    assert counts(models) == (2, 2)


def test_stable_recording_labels_survive_chapter_membership_changes():
    convos = {cid: recording(cid, ['detail']) for cid in ('a', 'b')}
    def fragments(ids):
        chapter = {'source_conversation_ids': ids, 'segment_refs': [
            {'conversation_id': cid, 'index': 0} for cid in ids]}
        return chapter_fragments(chapter, convos)
    a = fragments(['a'])[0]
    assert a == fragments(['a', 'b'])[0] == fragments(['b', 'a'])[1]
    assert a['source_label'] != fragments(['b'])[0]['source_label']


@pytest.mark.parametrize('stage', ['draft', 'grounding'])
@pytest.mark.parametrize('change', ['prompt', 'model', 'reasoning', 'max_tokens'])
def test_only_changed_inference_stage_recomputes(models, cache, stage, change):
    before = request(models)
    rollup.run_rollup(before, cache)
    deps = dependencies(models)
    prompt = deps.resolved if stage == 'draft' else deps.grounding
    model = models[0] if stage == 'draft' else models[1]
    if change == 'prompt':
        prompt.content += '\nKeep deadlines.'
    elif change == 'model':
        model.model_name += '-new'
    elif change == 'reasoning':
        model.reasoning_effort = 'high'
    else:
        model.max_tokens = 32000
    after = rollup.prepare_rollup([source()], dependencies=deps)
    rollup.run_rollup(after, cache)
    if stage == 'grounding':
        assert counts(models) == (1, 2)
    else:
        # A new generation dependency is exercised. Identical draft bytes can
        # still reuse an identical factual review: its actual input is unchanged.
        assert counts(models) == (2, 1)


def test_language_change_is_not_reused(models, cache):
    rollup.run_rollup(request(models, language_hint='Use Chinese'), cache)
    rollup.run_rollup(request(models, language_hint='Use English'), cache)
    assert counts(models)[0] == 2


def test_failed_grounding_retries_only_the_failed_stage(models, cache):
    req = request(models)
    models[1].fail = True
    failed = rollup.run_rollup(req, cache)
    assert failed['rollup'] == 'failed'
    assert len(cache.redis.keys()) == 1  # Only the draft, never a reviewed success.
    models[1].fail = False
    assert rollup.run_rollup(req, cache)['rollup'] is True
    assert counts(models) == (1, 2)


def test_partial_failure_keeps_other_batches_and_failed_batch_draft(models, cache):
    req = request(models, [source('a' * 49000)])
    invoke = models[1].invoke
    failing_prompt = req.evidence_blocks[1]
    def fail_one(prompt, **kw):
        if failing_prompt in prompt:
            models[1].calls.append(prompt)
            raise RuntimeError('one failed review')
        return invoke(prompt, **kw)
    with patch.object(models[1], 'invoke', side_effect=fail_one):
        assert rollup.run_rollup(req, cache)['rollup'] == 'failed'
    n = len(req.batches)
    assert counts(models) == (n, n)
    assert rollup.run_rollup(req, cache)['rollup'] is True
    assert counts(models) == (n, n + 1)


@pytest.mark.parametrize('changes', [(DEV + '-other', UID, DAY.isoformat()),
                                    (DEV, UID + '-other', DAY.isoformat()),
                                    (DEV, UID, '2026-08-08')])
def test_cache_is_scoped_to_developer_user_and_day(models, cache, changes):
    req = request(models)
    rollup.run_rollup(req, cache)
    rollup.run_rollup(req, BatchCache(cache.redis, *changes))
    assert counts(models) == (2, 2)


@pytest.mark.parametrize('payload', [b'not-json', b'[]', b'{"result": {}}', b'x' * (MAX_ENTRY_BYTES + 1)])
def test_corrupt_cache_entry_is_a_miss(models, cache, payload):
    req = request(models)
    rollup.run_rollup(req, cache)
    key = next(k for k in cache.redis.keys() if b':grounded:' in k)
    cache.redis.set(key, payload, ex=60)
    assert rollup.run_rollup(req, cache)['rollup'] is True
    assert counts(models) == (1, 2)


@pytest.mark.parametrize('mutation', ['empty_overview', 'long_title', 'wrong_stage', 'wrong_fingerprint'])
def test_invalid_cached_result_cannot_bypass_review(models, cache, mutation):
    req = request(models)
    rollup.run_rollup(req, cache)
    key = next(k for k in cache.redis.keys() if b':grounded:' in k)
    value = json.loads(cache.redis.get(key))
    if mutation == 'empty_overview':
        value['result']['overview'] = ''
    elif mutation == 'long_title':
        value['result']['title'] = 'x' * 121
    elif mutation == 'wrong_stage':
        value['stage'] = 'draft'
    else:
        value['fingerprint'] = 'other'
    cache.redis.set(key, json.dumps(value), ex=60)
    assert rollup.run_rollup(req, cache)['rollup'] is True
    assert counts(models) == (1, 2)


def test_expired_entries_regenerate_but_oversized_outputs_are_not_truncated(models, cache):
    req = request(models)
    rollup.run_rollup(req, cache)
    for key in cache.redis.keys():
        cache.redis.expire(key, 0)
    rollup.run_rollup(req, cache)
    assert counts(models) == (2, 2)
    large = rollup.ChapterRollup(title='facts', overview='好' * MAX_ENTRY_BYTES)
    with patch.object(models[0], 'invoke', return_value=large):
        result = rollup.run_rollup(request(models, [source('different source')]), cache)
    assert result['overview'] == large.overview
    assert len(cache.redis.keys()) == 2  # Old small results only.


@pytest.mark.parametrize('operation', ['get', 'set'])
def test_redis_failure_preserves_success_and_does_not_log_source(models, cache, operation, caplog):
    req = request(models)
    with patch.object(cache.redis, operation, side_effect=ConnectionError('PRIVATE_REDIS_ERROR')):
        assert rollup.run_rollup(req, cache)['rollup'] is True
    assert 'PRIVATE_REDIS_ERROR' not in caplog.text
    assert 'Budget' not in caplog.text
    assert counts(models) == (1, 1)


def test_invalid_provider_output_is_never_cached_as_success(models, cache, caplog):
    with patch.object(models[1], 'invoke', return_value='PRIVATE_UNPARSEABLE_OUTPUT'):
        assert rollup.run_rollup(request(models), cache)['rollup'] == 'failed'
    assert 'PRIVATE_UNPARSEABLE_OUTPUT' not in caplog.text
    assert len(cache.redis.keys()) == 1
    assert rollup.run_rollup(request(models), cache)['rollup'] is True
    assert counts(models)[0] == 1


@pytest.fixture
def day_runtime(models, cache):
    db = DayDb([convo('a', 0), convo('b', 5)])
    with patch.object(dev_db, 'db', FakeFirestore()), patch.object(redis_db, 'r', cache.redis):
        def compute(**kwargs):
            return store.recompute_day(db, redis_db, DEV, UID, DAY, dependencies=dependencies(models), **kwargs)
        yield compute, db


def test_failed_day_retries_from_saved_draft(day_runtime, models):
    compute, db = day_runtime
    models[1].fail = True
    assert compute()['document']['chapters'][0]['rollup'] == 'failed'
    models[1].fail = False
    assert compute()['document']['chapters'][0]['rollup'] is True
    assert counts(models) == (1, 2)
    assert compute()['status'] == 'unchanged'
    assert counts(models) == (1, 2)


def test_lease_loss_blocks_day_write_but_keeps_completed_work(day_runtime, models):
    compute, db = day_runtime
    with patch.object(redis_db, 'renew_owned_lock', return_value=False):
        with pytest.raises(store.TimelineLeaseUnavailable):
            compute()
    assert db.store_calls == 0
    assert counts(models) == (1, 1)
    assert compute()['status'] == 'computed'
    assert counts(models) == (1, 1)


def test_simultaneous_refreshes_share_day_lease(day_runtime, models):
    compute, db = day_runtime
    models[0].entered, models[0].proceed = threading.Event(), threading.Event()
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(compute)
        try:
            assert models[0].entered.wait(5)
            assert pool.submit(compute).result(timeout=5)['status'] == 'locked'
        finally:
            models[0].proceed.set()
        assert first.result(timeout=5)['status'] == 'computed'
    assert counts(models) == (1, 1)
    assert db.store_calls == 1


def test_grounding_can_repair_bad_draft_title(models, cache):
    draft = rollup.ChapterRollup(title='x' * 121, overview='detail')
    fixed = rollup.ChapterRollup(title='Fixed', overview='detail')
    with patch.object(models[0], 'invoke', return_value=draft), \
            patch.object(models[1], 'invoke', return_value=fixed.model_dump_json()):
        assert rollup.run_rollup(request(models), cache)['title'] == 'Fixed'
        assert rollup.run_rollup(request(models), cache)['rollup'] is True


def test_http_refresh_and_prompt_change_use_actual_store_and_batch_cache(day_runtime, models):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from dependencies import developers_db
    from routers import timeline
    compute, db = day_runtime
    app = FastAPI()
    app.include_router(timeline.router)
    with patch.object(developers_db, 'get_api_key_auth', return_value={
                'developer_id': DEV, 'bound_external_user_id': UID}), \
            patch.object(timeline.dev_db, 'get_user_timezone', side_effect=db.get_user_timezone), \
            patch.object(timeline.dev_db, 'get_conversations_by_recording_time', side_effect=db.get_conversations_by_recording_time), \
            patch.object(timeline, 'resolve_summary_dependencies', side_effect=lambda: dependencies(models)), \
            patch.object(timeline, 'should_recompute_now', return_value=False), \
            patch.object(timeline.edits_db, 'get_chapter_edits', return_value={}), \
            TestClient(app) as client:
        def get(refresh=False):
            response = client.get(f'/v1/timeline/{DAY.isoformat()}/chapters',
                                  params={'external_user_id': UID, 'refresh': str(refresh).lower()},
                                  headers={'Authorization': 'synthetic-test-key'})
            assert response.status_code == 200, response.text
            return response.json()
        first = get()
        assert first['cache'] == 'computed'
        assert get()['cache'] == 'hit'
        assert get(refresh=True)['cache'] == 'unchanged'
        assert counts(models) == (1, 1)
        models[1].reasoning_effort = 'high'
        assert get()['cache'] == 'computed'
        assert counts(models) == (1, 2)
        assert get()['cache'] == 'hit'


def test_failure_never_presents_opaque_recording_ids_as_title_or_body(models, cache):
    convos = {cid: recording(cid, [f'{cid} budget detail']) for cid in ('a', 'b')}
    for rec in convos.values():
        rec['structured'] = {}
    chapter = {'source_conversation_ids': ['a', 'b'], 'segment_refs': [
        {'conversation_id': cid, 'index': 0} for cid in convos]}
    fragments = chapter_fragments(chapter, convos)
    models[0].fail = True
    result = rollup.run_rollup(request(models, fragments), cache)
    assert result['rollup'] == 'failed'
    assert result['title'] == '(untitled)'
    for fragment in fragments:
        assert fragment['recording_key'] not in result['overview']
    for expected in ('a budget detail', 'b budget detail', '[Recording 1 +0s]', '[Recording 2 +0s]'):
        assert expected in result['overview']


def test_echoed_recording_anchors_are_readable_on_success_and_cache_hit(models, cache):
    rec = recording('a', ['detail', 'another chapter'])
    fragments = chapter_fragments({'source_conversation_ids': ['a'], 'segment_refs': [
        {'conversation_id': 'a', 'index': 0}]}, {'a': rec})
    key = fragments[0]['recording_key']
    echoed = rollup.ChapterRollup(title=key, overview=f'From {key}: detail', first_person_observation=key)
    req = request(models, fragments)
    with patch.object(models[1], 'invoke', return_value=echoed.model_dump_json()) as model:
        for _ in range(2):
            result = rollup.run_rollup(req, cache)
            assert result['title'] == 'Recording 1'
            assert result['overview'] == 'From Recording 1: detail'
            assert result['first_person_observation'] == 'Recording 1'
        assert model.call_count == 1


def test_hard_splits_inside_source_keys_preserve_complete_readable_fallback(models):
    rec = recording('a', ['detail', 'another chapter'])
    fragments = chapter_fragments({'source_conversation_ids': ['a'], 'segment_refs': [
        {'conversation_id': 'a', 'index': 0}]}, {'a': rec})
    key = fragments[0]['recording_key']
    # Deliberately small request boundaries put hard splits inside both the
    # source header and the per-segment anchor, exercising the real splitter.
    with patch.object(rollup, 'MAX_FRAGMENT_BLOCK_CHARS', 6), \
            patch.object(rollup, 'MAX_CHAPTER_BATCHES', 100), \
            patch.object(rollup, 'MAX_DAY_BATCHES', 100):
        req = request(models, fragments)
    assert any(key[:6] in batch for batch in req.batches)
    full_req = request(models, fragments)
    assert ''.join(rollup._fallback_batches(req)) == ''.join(rollup._fallback_batches(full_req))
    assert ''.join(rollup._fallback_batches(req)).count('detail') == 1


def test_compact_source_anchors_do_not_create_extra_long_recording_batches():
    from utils.timeline.sources import _recording_keys
    rec = recording('synthetic-long-source', [
        '预算37万元，付款须法务批准；状态未知，交付日期未承诺。' for _ in range(1000)])
    chapter = {'source_conversation_ids': [rec['id']], 'segment_refs': [
        {'conversation_id': rec['id'], 'index': i} for i in range(1000)]}
    fragments = chapter_fragments(chapter, {rec['id']: rec})
    key = fragments[0]['recording_key']
    assert len(key) == 7 and key[1:].isdigit()
    assert key == _recording_keys([rec['id']])[rec['id']]
    rendered = rollup.render_fragments(fragments)
    assert rendered.count('预算37万元') == 1000
    # Per-segment evidence tokens now carry attribution; keep a bounded budget
    # while ensuring no source text is dropped to hit the former batch count.
    assert len(rollup._source_batches(rendered)) <= 5
    assert ''.join(rollup._source_batches(rendered)) == rendered


def test_short_anchor_collisions_extend_only_the_affected_sources():
    from utils.timeline.sources import _recording_keys
    from utils.timeline.summary_dependencies import digest
    hashes = {'a': f'{1:064x}', 'b': f'{1000001:064x}', 'c': f'{2:064x}'}
    with patch('utils.timeline.sources.digest', side_effect=lambda key: hashes.get(key) or digest(key)):
        before = _recording_keys(['a', 'c'])
        after = _recording_keys(['a', 'b', 'c'])
        assert before['a'] == 'R000001'
        assert after['a'] == 'R000000001' and after['b'] == 'R001000001'
        assert after['c'] == before['c'] == 'R000002'
        assert len(set(after.values())) == 3
        assert _recording_keys(['c', 'b', 'a']) == after
        convos = {cid: recording(cid, ['speaker detail']) for cid in hashes}
        fragments = chapter_fragments({'source_conversation_ids': list(convos), 'segment_refs': [
            {'conversation_id': cid, 'index': 0} for cid in convos]}, convos)
        assert len(set(f['recording_key'] for f in fragments)) == 3
        assert all(after[cid] in f['source_label'] for cid, f in zip(convos, fragments))


def test_full_hash_collision_fails_closed_instead_of_merging_speakers():
    from utils.timeline.sources import _recording_keys
    with patch('utils.timeline.sources.digest', return_value='1' * 64):
        with pytest.raises(ValueError, match='Source fingerprints collide'):
            _recording_keys(['a', 'b'])


def test_extended_anchor_cannot_be_misread_as_another_recording_or_sku(models):
    from utils.timeline.sources import _recording_keys
    hashes = {'a': f'{1:064x}', 'b': f'{1999:064x}', 'c': f'{1001999:064x}'}
    with patch('utils.timeline.sources.digest', side_effect=hashes.__getitem__):
        keys = _recording_keys(hashes)
    assert keys == {'a': 'R000001', 'b': 'R000001999', 'c': 'R001001999'}
    sources = [{**source(label=key), 'recording_key': key} for key in keys.values()]
    req = request(models, sources)
    value = '来源R000001999，R000001，R001001999; XR000001999Y is a technical code.'
    expected = '来源Recording 2，Recording 1，Recording 3; XR000001999Y is a technical code.'
    assert rollup._readable_sources(value, req) == expected
    # Deliberately cut inside both a real anchor and a similar technical code.
    cuts = [value.index('1999') + 1, value.index('XR') + 1]
    req.batches = [value[:cuts[0]], value[cuts[0]:cuts[1]], value[cuts[1]:]]
    assert ''.join(rollup._fallback_batches(req)) == expected


def test_readable_anchor_expansion_cannot_turn_valid_cached_notes_into_failure(models, cache):
    rec = recording('a', ['detail', 'another chapter'])
    fragments = chapter_fragments({'source_conversation_ids': ['a'], 'segment_refs': [
        {'conversation_id': 'a', 'index': 0}]}, {'a': rec})
    key = fragments[0]['recording_key']
    topic = 'x' * (rollup.MAX_TITLE_CHARS - len(key) - 1)
    reviewed = rollup.ChapterRollup(title=key + ' ' + topic, overview='Detail retained.')
    req = request(models, fragments)
    with patch.object(models[1], 'invoke', return_value=reviewed.model_dump_json()) as model:
        for _ in range(2):
            result = rollup.run_rollup(req, cache)
            assert result['rollup'] is True
            assert result['title'] == 'R1 ' + topic
            assert len(result['title']) <= rollup.MAX_TITLE_CHARS
            assert result['overview'] == reviewed.overview
        assert model.call_count == 1


def test_failed_rollup_preserves_attribution_without_identity_metadata(models):
    # Part of a recording: its own summary covers another chapter, so only the
    # transcript can stand in for this one.
    rec = recording('a', ['先修复问题再发布。', 'OTHER_CHAPTER_LINE'])
    rec['transcript_segments'][0].update(person_id='private-person-id', speaker_id=98)
    fragments = chapter_fragments({'source_conversation_ids': ['a'],
        'segment_refs': [{'conversation_id': 'a', 'index': 0}]}, {'a': rec})
    models[0].fail = True
    result = rollup.run_rollup(request(models, fragments))
    assert result['rollup'] == 'failed'
    assert '先修复问题再发布。' in result['overview']
    assert 'OTHER_CHAPTER_LINE' not in result['overview']
    assert 'other chapter secret' not in result['overview']
    assert 'private-person-id' not in result['overview']
    assert 'speaker 98' not in result['overview']
    assert len(result['speaker_display']['speakers']) == 1


@pytest.mark.parametrize('failing', [0, 1])
def test_failed_whole_recordings_show_their_own_summaries_not_the_transcript(models, failing):
    convos = {cid: recording(cid, [f'{cid} RAW_TRANSCRIPT_LINE']) for cid in ('a', 'b')}
    convos['a']['structured'] = {'title': '推理配额讨论', 'overview': '配额从 600 批到 128。', 'emoji': '☁️',
                                 'first_person_observation': '需核实扩额路径'}
    convos['b']['structured'] = {'title': '炒菜设备演示', 'overview': '演示了自动炒菜。'}
    chapter = {'source_conversation_ids': ['a', 'b'], 'segment_refs': [
        {'conversation_id': cid, 'index': 0} for cid in convos]}
    models[failing].fail = True  # Draft or factual review: either loses the batch.
    result = rollup.run_rollup(request(models, chapter_fragments(chapter, convos)))
    assert result['rollup'] == 'failed'
    assert result['title'] == '推理配额讨论'
    assert result['overview'] == '推理配额讨论\n\n配额从 600 批到 128。\n\n炒菜设备演示\n\n演示了自动炒菜。'
    assert 'RAW_TRANSCRIPT_LINE' not in result['overview']
    assert result['emoji'] == '☁️'
    # One recording's observation does not describe the merged chapter.
    assert result['first_person_observation'] == ''
    assert result['speaker_display']['speakers'] == []


def long_recordings(titles, size=30000):
    convos = {f'c{i}': recording(f'c{i}', [f'c{i} ' + 'x' * size, f'c{i} tail']) for i in range(len(titles))}
    for convo, title in zip(convos.values(), titles):
        convo['structured'] = {'title': title, 'overview': f'{title}的纪要'}
    chapter = {'source_conversation_ids': list(convos), 'segment_refs': [
        {'conversation_id': cid, 'index': i} for cid in convos for i in (0, 1)]}
    return convos, chapter


@pytest.fixture
def titled_batches(models):
    """Give every batch its own title, as a real model does."""
    invoke = models[0].invoke
    def titled(prompt, **kwargs):
        draft = invoke(prompt, **kwargs)
        return draft.model_copy(update={'title': 'batch ' + digest_of(prompt.split('<CORE>')[1])})
    with patch.object(models[0], 'invoke', side_effect=titled):
        yield


def digest_of(text):
    import hashlib
    return hashlib.sha256(text.encode()).hexdigest()[:6]


def test_multi_batch_chapter_is_titled_by_its_whole_recordings_when_shorter(models, titled_batches):
    convos, whole = long_recordings(['推理配额讨论', '炒菜设备演示'])
    req = request(models, chapter_fragments(whole, convos))
    assert len(req.batches) > 2
    result = rollup.run_rollup(req)
    assert result['rollup'] is True
    assert result['title'] == '推理配额讨论 / 炒菜设备演示'
    # Part of each recording: the recording titles describe other chapters too.
    partial = dict(whole, segment_refs=[ref for ref in whole['segment_refs'] if ref['index'] == 0])
    assert rollup.run_rollup(request(models, chapter_fragments(partial, convos)))['title'].startswith('batch ')


@pytest.mark.parametrize('titles', [
    ['短会一', '短会二', '短会三', '短会四', '短会五'],  # More recordings than batches.
    ['长' * 70, '标题' * 30],  # Joined past MAX_TITLE_CHARS.
])
def test_multi_batch_chapter_keeps_batch_titles_when_recording_titles_are_no_better(models, titled_batches, titles):
    convos, whole = long_recordings(titles, size=60000 // len(titles))
    result = rollup.run_rollup(request(models, chapter_fragments(whole, convos)))
    assert result['rollup'] is True
    assert result['title'].startswith('batch ')
    assert len(result['title']) <= rollup.MAX_TITLE_CHARS


def test_retitled_recording_changes_the_chapter_cache_key(models):
    convos, whole = long_recordings(['推理配额讨论', '炒菜设备演示'])
    before = request(models, chapter_fragments(whole, convos)).cache_key
    assert request(models, chapter_fragments(whole, convos)).cache_key == before
    convos['c0']['structured']['title'] = '推理配额与成本讨论'
    assert request(models, chapter_fragments(whole, convos)).cache_key != before


def test_one_failed_batch_of_whole_recordings_shows_their_summaries(models):
    convos, whole = long_recordings(['推理配额讨论', '炒菜设备演示'])
    req = request(models, chapter_fragments(whole, convos))
    assert len(req.batches) > 2
    invoke = models[1].invoke
    def fail_last(prompt, **kwargs):
        if req.evidence_blocks[-1] in prompt:
            raise RuntimeError('one failed review')
        return invoke(prompt, **kwargs)
    with patch.object(models[1], 'invoke', side_effect=fail_last):
        result = rollup.run_rollup(req)
    assert result['rollup'] == 'failed'
    assert result['overview'] == '推理配额讨论\n\n推理配额讨论的纪要\n\n炒菜设备演示\n\n炒菜设备演示的纪要'
    assert 'xxxxxxxxxx' not in result['overview']


def test_markup_in_a_recordings_own_summary_cannot_fail_the_day(models):
    rec = recording('a', ['先修复问题再发布。'])
    rec['structured'] = {'title': '[[speaker:e0000000000000000]] 发布讨论',
                         'overview': '[[speaker:e0000000000000000]]同意先修复。[[speaker: Alice]]附议。'}
    fragments = chapter_fragments({'source_conversation_ids': ['a'],
        'segment_refs': [{'conversation_id': 'a', 'index': 0}]}, {'a': rec})
    models[1].fail = True
    result = rollup.run_rollup(request(models, fragments))
    assert result['rollup'] == 'failed'
    assert result['title'] == '发布讨论'
    assert result['overview'] == '有人同意先修复。有人附议。'
    assert result['speaker_display']['speakers'] == []


def test_markup_in_recording_prose_cannot_fail_the_day_without_a_stand_in(models):
    # Part of a recording, so each failed batch shows its evidence, joined under
    # the recording's own (editable) title next to a SUMMARY ONLY source.
    rec = recording('a', ['先修复问题再发布。' + 'x' * 30000, 'OTHER_CHAPTER_LINE'])
    rec['structured'] = {'title': '[[speaker:e0000000000000000]] 发布讨论', 'overview': 'unused'}
    fragments = chapter_fragments({'source_conversation_ids': ['a'], 'segment_refs': [
        {'conversation_id': 'a', 'index': 0}]}, {'a': rec})
    fragments.append({'title': '[[speaker: Alice]] 旧记录', 'overview': '[[speaker:e0000000000000000]]同意。'})
    req = request(models, fragments)
    assert len(req.batches) > 1
    models[0].fail = True
    result = rollup.run_rollup(req)
    assert result['rollup'] == 'failed'
    assert result['title'] == '发布讨论'
    assert 'e0000000000000000' not in result['overview']
    assert 'Alice]]' not in result['overview']
    assert len(result['speaker_display']['speakers']) == 1  # The transcript's own evidence survives.


@pytest.mark.parametrize('overview,rollup_state', [
    # Mostly unbacked: a broken model or prompt, not a slip.
    ('[[speaker:{eid}]]反对上线。[[speaker:e40?]]同意。[[speaker:e123]]附议。', 'failed'),
    ('[[speaker:{eid}]]反对上线。[[speaker:{eid}]]要求修复。[[speaker:e40?]]同意。[[speaker:e123]]附议。', True),
    # Brackets abutting a valid token only become markup once it is removed.
    ('[[[[speaker:{eid}]]speaker:同意。', 'failed'),
])
def test_unrepairable_attribution_fails_only_the_batch(models, cache, overview, rollup_state):
    rec = recording('a', ['我不同意上线，先修复问题。', 'OTHER_CHAPTER_LINE'])
    fragments = chapter_fragments({'source_conversation_ids': ['a'],
        'segment_refs': [{'conversation_id': 'a', 'index': 0}]}, {'a': rec})
    eid = next(iter(fragments[0]['speaker_evidence']))
    reviewed = rollup.ChapterRollup(title='上线意见', overview=overview.format(eid=eid))
    with patch.object(rollup, 'ground_rollup', return_value=reviewed):
        result = rollup.run_rollup(request(models, fragments), cache)
    assert result['rollup'] == rollup_state
    assert len(cache.redis.keys()) == (1 if rollup_state == 'failed' else 2)  # Never a cached failure.


@pytest.mark.parametrize('field,reference,expected', [
    ('overview', '[[speaker:e0000000000000000]]', '有人同意先做小范围测试。'),  # Well formed, not evidence.
    ('overview', '[[speaker:e123]]', '有人同意先做小范围测试。'),  # Dropped characters.
    ('overview', '[[speaker:e40?]]', '有人同意先做小范围测试。'),  # Production placeholder.
    # Removed, not neutralized: the home-card line would credit the owner to "有人".
    ('first_person_observation', '[[speaker:{eid}]]', '同意先做小范围测试。'),
    ('title', '[[speaker:{eid}]] ', '上线意见'),
])
def test_unbacked_reference_loses_its_attribution_not_the_summary(models, cache, field, reference, expected):
    rec = recording('a', ['我不同意上线，先修复问题。'])
    fragments = chapter_fragments({'source_conversation_ids': ['a'],
        'segment_refs': [{'conversation_id': 'a', 'index': 0}]}, {'a': rec})
    req = request(models, fragments)
    eid = next(iter(fragments[0]['speaker_evidence']))
    good = rollup.ChapterRollup(title='上线意见', overview=f'[[speaker:{eid}]]反对上线，要求先修复问题。')
    if field == 'overview':
        bad = good.overview + reference + '同意先做小范围测试。'
    elif field == 'title':
        bad = reference.format(eid=eid) + good.title
    else:
        bad = reference.format(eid=eid) + '同意先做小范围测试。'
    with patch.object(rollup, 'ground_rollup', side_effect=[good.model_copy(update={field: bad})]) as ground:
        result = rollup.run_rollup(req, cache)
    assert ground.call_count == 1  # No second review to "fix" a token.
    assert result['rollup'] is True
    assert expected in result[field]
    assert result['title'] == '上线意见'
    assert '[[speaker:' not in result['first_person_observation']
    assert f'[[speaker:{eid}]]反对上线' in result['overview']
    assert result['overview'].count('[[speaker:') == 1
    assert '我不同意上线，先修复问题。' not in result['overview']
    assert len(result['speaker_display']['speakers']) == 1
    assert len(cache.redis.keys()) == 2
    with patch.object(rollup, 'ground_rollup', side_effect=AssertionError('must reuse the cleaned result')):
        assert rollup.run_rollup(req, cache) == result
