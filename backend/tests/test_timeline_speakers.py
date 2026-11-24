"""Evidence identity, presentation, chapter isolation and authenticated mutations."""
import copy
import sys
import types
import unittest
from unittest.mock import Mock, patch
from test_timeline_edits import TimelineEditTests, DAY
from routers import timeline
from utils.timeline.speakers import (chapter_evidence, build_display, present_speakers, plain_overview,
                                     restore_legacy_overview, neutralize_references, strip_references)
from utils.timeline.speaker_audio import audio_bounds


class EvidenceTests(unittest.TestCase):
    def test_legacy_labels_follow_summary_language_and_keep_anonymous_views_distinct(self):
        ch, sources = self.fixture()
        sources['a']['transcript_segments'][1].update(is_user=True, person_id=None)
        evidence = chapter_evidence(ch, sources)
        ids = list(evidence)
        for prose, owner, anonymous in [
                ('opposes the proposal discussed with 阿宁', 'You', 'Speaker '),
                ('反对提前上线的提议', '你', '说话人 ')]:
            with self.subTest(prose=prose):
                ch['overview'] = '; '.join(f'[[speaker:{eid}]] {prose}' for eid in (ids[0], ids[1], ids[3]))
                ch['speaker_display'] = build_display(ch['overview'], evidence)
                text = plain_overview(ch)
                self.assertIn(owner + ' ' + prose, text)
                self.assertIn(anonymous + 'A', text)
                self.assertIn(anonymous + 'B', text)
                self.assertNotIn('[[speaker:', text)
                self.assertEqual(restore_legacy_overview(text, ch), ch['overview'])

    def test_legacy_edit_restores_each_repeated_name_to_its_original_evidence(self):
        ch, sources = self.fixture()
        sources['a']['transcript_segments'][0].update(person_id='p')
        evidence = chapter_evidence(ch, sources)
        ids = list(evidence)
        ch['overview'] = f'[[speaker:{ids[0]}]]建议核实。[[speaker:{ids[1]}]]反对提前上线。'
        ch['speaker_display'] = build_display(ch['overview'], evidence)
        ch['speaker_display']['speakers'][0]['name'] = '阿宁'
        text = plain_overview(ch)
        edited = '我的注释：' + text.replace('提前上线', '本周上线') + '继续跟进。'
        restored = restore_legacy_overview(edited, ch)
        self.assertEqual(restored, '我的注释：' + ch['overview'].replace('提前上线', '本周上线') + '继续跟进。')

    def test_legacy_edit_rejects_removed_or_replaced_attributed_labels(self):
        ch, sources = self.fixture()
        evidence = chapter_evidence(ch, sources)
        eid = next(iter(evidence))
        ch['overview'] = f'[[speaker:{eid}]]建议继续核实。'
        ch['speaker_display'] = build_display(ch['overview'], evidence)
        for edited in ('建议继续核实。', '阿宁建议继续核实。', '说话人 B建议继续核实。'):
            with self.subTest(edited=edited), self.assertRaises(ValueError):
                restore_legacy_overview(edited, ch)

    def test_legacy_identity_is_preserved_without_inventing_confirmation_or_voice_match(self):
        ch, sources = self.fixture()
        segment = sources['a']['transcript_segments'][1]
        for source, expected in [(None, 'unverified'), ('auto', 'matched'), ('manual', 'confirmed')]:
            with self.subTest(source=source):
                segment['speaker_assignment_source'] = source
                evidence = list(chapter_evidence(ch, sources).values())[1]
                self.assertEqual(evidence['person_id'], 'p')
                self.assertEqual(evidence['status'], expected)
        segment['speaker_status'] = 'ambiguous'
        evidence = list(chapter_evidence(ch, sources).values())[1]
        self.assertIsNone(evidence['person_id'])
        self.assertEqual(evidence['status'], 'conflict')

    def test_unproven_reference_keeps_shared_person_unconfirmed_in_either_order(self):
        ch, sources = self.fixture()
        sources['a']['transcript_segments'][2].update(person_id='p', speaker_assignment_source='auto')
        evidence = chapter_evidence(ch, sources)
        ids = list(evidence)[1:3]
        for order in (ids, ids[::-1]):
            display = build_display('；'.join(f'[[speaker:{eid}]]提出意见' for eid in order), evidence)
            self.assertEqual(len(display['speakers']), 1)
            self.assertEqual(display['speakers'][0]['status'], 'unverified')

    def test_undo_accounts_for_partial_storage_progress_before_propagating_failure(self):
        from database import developer_speech_profile
        correct = Mock()
        removed = {'assign_type': 'person_id', 'target_id': 'p', 'duration_seconds': 12.5}

        def fail_after_removal(*args, **kwargs):
            kwargs['revoked_samples'].append(removed)
            raise RuntimeError('storage unavailable')

        with patch.object(developer_speech_profile, 'revoke_samples_from_segments', side_effect=fail_after_removal), \
                patch.dict(sys.modules, {'utils.speech_sample_collector': types.SimpleNamespace(_correct_tracked_durations=correct)}):
            with self.assertRaises(RuntimeError):
                timeline._revoke_chapter_enrollment('dev', 'user', {'id': 'operation', 'enrollment_segments': {'c': ['s']}})
            correct.assert_called_once_with('dev', 'user', [removed])

    def fixture(self):
        sources = {'a': {'transcript_segments': [
            {'id': 'a1', 'text': '小李还没确认。', 'speaker_id': 1, 'start': 0, 'end': 6},
            {'id': 'a2', 'text': '我反对提前上线。', 'speaker_id': 1, 'person_id': 'p', 'start': 6, 'end': 10},
            {'id': 'a3', 'text': '先检查支付。', 'speaker_id': 1, 'person_id': 'q', 'start': 10, 'end': 18}]},
            'b': {'transcript_segments': [{'id': 'b1', 'text': '先做小范围测试。', 'speaker_id': 1, 'start': 0, 'end': 8}]}}
        chapter = {'source_conversation_ids': ['a', 'b'], 'segment_refs': [
            {'conversation_id': 'a', 'index': i} for i in range(3)] + [{'conversation_id': 'b', 'index': 0}]}
        return chapter, sources

    def test_unbacked_references_become_neutral_and_valid_ones_survive(self):
        ch, sources = self.fixture()
        valid, other = list(chapter_evidence(ch, sources))[:2]
        allowed = {valid}
        # Shapes the grounding model produced on 2026-10-27: one character short,
        # one extra, a placeholder, plus forms that never close or hold two IDs.
        for bad in (valid[:-1], valid + 'a', 'e40?', other, 'E' + valid[1:].upper()):
            with self.subTest(bad=bad):
                text, replaced = neutralize_references(f'[[speaker:{valid}]]建议核实；[[speaker:{bad}]]反对上线。', allowed)
                self.assertEqual(text, f'[[speaker:{valid}]]建议核实；有人反对上线。')
                self.assertEqual(replaced, 1)
                self.assertEqual(set(build_display(text, chapter_evidence(ch, sources))['mentions']), {valid})
        for text, expected in [
                (f'[[speaker:{valid}, {other}]]都同意。', '有人都同意。'),
                (f'[[ Speaker: {other}]]同意。', '有人同意。'),
                (f'[[speaker:{other} 说明了原因。', '有人 说明了原因。'),
                (f'[[speaker:{other}]] agreed to ship.', 'Someone agreed to ship.')]:
            with self.subTest(text=text):
                self.assertEqual(neutralize_references(text, allowed), (expected, 1))
        # The rest of the source-line prefix copied along with a valid token.
        for copied in (' S455108 +1138.29s', 'S455108', ' S455108999 2026-10-27T07:04:44.390000+00:00', ' +12.5s'):
            with self.subTest(copied=copied):
                self.assertEqual(neutralize_references(f'[[speaker:{valid}]]{copied} 承认盛多了。', allowed),
                                 (f'[[speaker:{valid}]] 承认盛多了。', 0))
        self.assertEqual(neutralize_references('型号 S455108 已停产。', allowed), ('型号 S455108 已停产。', 0))
        unchanged = f'[[speaker:{valid}]]建议核实。'
        self.assertEqual(neutralize_references(unchanged, allowed), (unchanged, 0))
        self.assertEqual(neutralize_references(f'[[speaker:{valid}]]建议核实。', set())[0], '有人建议核实。')
        self.assertEqual(strip_references(f'[[speaker:{valid}]] 上线 [[speaker:e40?]] 意见'), '上线 意见')
        self.assertEqual(strip_references('预算 37 万'), '预算 37 万')

    def test_neutralizing_never_eats_the_statement_or_leaks_markup(self):
        ch, sources = self.fixture()
        valid, other = list(chapter_evidence(ch, sources))[:2]
        allowed = {valid}
        cases = [
            # Unclosed and abutting Chinese: only the identifier belongs to it.
            (f'[[speaker:{valid[:-1]}反对上线，要求先修复问题。', '有人反对上线，要求先修复问题。'),
            # An unclosed reference must not swallow the paragraph break after it.
            (f'最后由[[speaker:\n\n下一个话题。', '最后由某人\n\n下一个话题。'),
            (f'最后由[[speaker:\n\nE组的话题。', '最后由某人\n\nE组的话题。'),
            # Seven IDs in one reference, a full-width colon, a single bracket.
            ('[[speaker:' + ', '.join([other] * 7) + ']]都同意。', '有人都同意。'),
            (f'[[speaker：{other}]]同意。', '有人同意。'),
            (f'[speaker:{other}]]同意。', '有人同意。'),
            # A name is not an identifier: none of its letters belong to the reference.
            ('[speaker: Alice] agreed to ship.', 'Someone agreed to ship.'),
            ('[[speaker: Alice agreed to ship.', 'Someone Alice agreed to ship.'),
            ('[[speaker: each person agreed.', 'Someone each person agreed.'),
            ('[[speaker: e2e tests passed.', 'Someone e2e tests passed.'),
            ('[[speaker:2026年的计划。', '有人2026年的计划。'),
            # A malformed reference with copied metadata, and metadata out of order.
            (f'[[speaker:{valid[:-1]}]] S455108 +1138.29s 承认盛多了。', '有人 承认盛多了。'),
            (f'[[speaker:{valid}]] +12.5s S455108 承认盛多了。', f'[[speaker:{valid}]] 承认盛多了。'),
            # The neutral person reads right outside the subject slot too.
            (f'[[speaker:{valid}]]向[[speaker:{other}]]确认了交付日期。', f'[[speaker:{valid}]]向某人确认了交付日期。'),
            (f'It was confirmed by [[speaker:{other}]] on Friday.', 'It was confirmed by someone on Friday.'),
        ]
        for text, expected in cases:
            with self.subTest(text=text):
                cleaned, _ = neutralize_references(text, allowed)
                self.assertEqual(cleaned, expected)
                self.assertEqual(neutralize_references(cleaned, allowed), (cleaned, 0))  # Idempotent.
                build_display(cleaned, chapter_evidence(ch, sources))  # Never rejected afterwards.
        # Glued to the colon, a word keeps every letter: an identifier holds a digit.
        self.assertIn('ebb and flow', neutralize_references('[[speaker:ebb and flow.', allowed)[0])
        self.assertEqual(strip_references(f'[[speaker:{valid}]] S455108 +1138.29s 上线意见'), '上线意见')
        # A short key is content unless it carries the line's timestamp.
        self.assertEqual(neutralize_references(f'[[speaker:{valid}]] S3 存储桶已满。', allowed),
                         (f'[[speaker:{valid}]] S3 存储桶已满。', 0))

    def test_anonymous_speakers_are_lettered_in_reading_order(self):
        sources = {'a': {'transcript_segments': [
            {'id': f'a{i}', 'text': f'第{i}句。', 'speaker_id': i, 'start': i * 10, 'end': i * 10 + 5}
            for i in range(9)]}}
        sources['a']['transcript_segments'][0].update(is_user=True)
        chapter = {'source_conversation_ids': ['a'], 'segment_refs': [
            {'conversation_id': 'a', 'index': i} for i in range(9)]}
        evidence = chapter_evidence(chapter, sources)
        ids = list(evidence)
        display = build_display(f'[[speaker:{ids[0]}]]提出预算。[[speaker:{ids[8]}]]承诺周五前提交。'
                                f'[[speaker:{ids[3]}]]反对。', evidence)
        numbers = [(s['is_user'], s['number']) for s in display['speakers']]
        self.assertEqual(numbers, [(True, 0), (False, 1), (False, 2)])  # 你, 说话人 A, 说话人 B

    def test_raw_numbers_never_merge_recordings_or_conflicting_people(self):
        ch, sources = self.fixture()
        evidence = chapter_evidence(ch, sources)
        self.assertEqual(len({e['speaker_id'] for e in evidence.values()}), 4)
        self.assertEqual([e['person_id'] for e in evidence.values()], [None, 'p', 'q', None])
        ids = list(evidence)
        body = f'[[speaker:{ids[1]}]]反对提前上线；[[speaker:{ids[3]}]]建议小范围测试。'
        display = build_display(body, evidence)
        self.assertEqual(len(display['speakers']), 2)
        self.assertEqual(set(display['mentions']), {ids[1], ids[3]})
        self.assertNotIn('小李', str(display))
        with self.assertRaises(ValueError): build_display('[[speaker:e0000000000000000]]', evidence)

    def test_manual_prose_and_scope_survive_override_and_undo(self):
        ch, sources = self.fixture(); evidence = chapter_evidence(ch, sources); eid = next(iter(evidence))
        ch.update(overview=f'[[speaker:{eid}]]说「小李还没确认」；保留用户自己写的注释。',
                  first_person_observation='你还在等待小李确认')
        ch['speaker_display'] = build_display(ch['overview'], evidence)
        sid = ch['speaker_display']['speakers'][0]['id']; original = copy.deepcopy(ch)
        edited = present_speakers(ch, {'speaker_overrides': {sid: {'name': '阿宁', 'status': 'confirmed'}}})
        self.assertIn('阿宁说', plain_overview(edited)); self.assertEqual(edited['overview'], ch['overview'])
        self.assertEqual(edited['first_person_observation'], '')
        self.assertTrue(edited['observation_stale'])
        undone = present_speakers(ch, {'speaker_overrides': {sid: None}})
        self.assertEqual(undone['first_person_observation'], ch['first_person_observation'])
        self.assertFalse(undone.get('observation_stale', False))
        self.assertEqual(ch, original)
        removed = present_speakers(ch, {'overview': '只剩用户自己的话。'})
        self.assertEqual(removed['speaker_display']['speakers'], [])
        self.assertNotIn('[[speaker:', plain_overview(removed))
        sources['a']['transcript_segments'][0]['text'] += '改动'
        self.assertNotIn(eid, chapter_evidence(ch, sources))

    def test_audio_missing_unproven_or_invalid_is_not_playable(self):
        self.assertIsNone(audio_bounds({'transcript_segments': [{'start': 1, 'end': 3}]}, 0, {}))
        self.assertIsNone(audio_bounds({'audio_path': 'a.wav', 'transcript_segments': [{'start': 1, 'end': 3}]}, 0, {}))
        self.assertIsNone(audio_bounds({'audio_path': 'a.wav', 'source': 'audio_upload', 'transcript_segments': [
            {'start': 1, 'end': 1, 'timestamp_axis': 'original'}]}, 0, {}))

    def test_missing_person_names_and_owner_reassigned_unknown_have_distinct_labels(self):
        ch, sources = self.fixture()
        sources['a']['transcript_segments'][1].update(is_user=True, person_id=None)
        evidence = chapter_evidence(ch, sources)
        ch['overview'] = '；'.join(f'[[speaker:{eid}]]提出意见' for eid in evidence)
        ch['speaker_display'] = build_display(ch['overview'], evidence)
        owner = next(s for s in ch['speaker_display']['speakers'] if s['is_user'])
        shown = present_speakers(ch, {'speaker_overrides': {owner['id']: {
            'is_user': False, 'person_id': None, 'name': None, 'status': 'unknown'}}})
        numbers = [s['number'] for s in shown['speaker_display']['speakers']]
        self.assertEqual(len(set(numbers)), len(numbers))
        self.assertTrue(all(n > 0 for n in numbers))
        self.assertEqual(present_speakers(ch)['speaker_display']['speakers'][1]['number'], 0)


class SpeakerRoutesTests(unittest.TestCase):
    recompute = TimelineEditTests.recompute
    def setUp(self):
        TimelineEditTests.setUp(self)
        self.raw = copy.deepcopy(self.convos)
        for c in self.convos:
            for i, seg in enumerate(c['transcript_segments']): seg.update(id=f"{c['id']}-{i}", speaker_id=1)
        chapter = self.original['chapters'][0]
        self.evidence = chapter_evidence(chapter, {c['id']: c for c in self.convos})
        self.eid = next(iter(self.evidence))
        chapter['overview'] = f'[[speaker:{self.eid}]]建议继续核实；保留长篇用户注释。'
        chapter['speaker_display'] = build_display(chapter['overview'], self.evidence)
        timeline.dev_db.store_timeline_day('dev', 'user', DAY, self.original)
        self.sid = chapter['speaker_display']['speakers'][0]['id']
        self.revision = present_speakers(chapter)['speaker_revision']
        self.op = 'chapter-test-operation-001'
        self.collect = Mock(return_value={'status': 'enrolled'})
        self.revoke = Mock()
        for p in [patch.object(timeline.dev_db, 'get_conversation', side_effect=lambda d,u,c: next((x for x in self.convos if x['id']==c), None)),
                  patch.object(timeline.dev_db, 'get_person', side_effect=lambda d,u,p: {'id': p, 'name': '阿宁'} if p == 'person1' else None),
                  patch.object(timeline.dev_db, 'get_people_by_ids', side_effect=lambda d,u,ids: [{'id': 'person1', 'name': '阿宁'}] if 'person1' in ids else []),
                  patch.object(timeline.dev_db, 'get_listen_session', return_value={}),
                  patch.dict(sys.modules, {'utils.speech_sample_collector': types.SimpleNamespace(collect_speech_samples_developer=self.collect)}),
                  patch.object(timeline, '_revoke_chapter_enrollment', self.revoke)]:
            p.start(); self.addCleanup(p.stop)

    def call(self, suffix='', method='patch', fields=None, uid='user'):
        return getattr(self.client, method)(f'/v1/timeline/{DAY}/chapters/speakers{suffix}',
            params={'external_user_id': uid}, headers={'Authorization': 'test-key'},
            json={**self.selector, 'revision': self.revision, 'speaker_id': self.sid,
                  **({'operation_id': self.op} if suffix != '/evidence' else {}),
                  **({'reviewed': True} if suffix == '/enroll' else {}), **(fields or {})})

    def test_evidence_revision_survives_firestore_map_order_across_requests(self):
        chapter = self.original['chapters'][0]
        ids = [eid for eid, item in self.evidence.items() if item['speaker_id'] == self.sid]
        self.assertGreaterEqual(len(ids), 2)
        chapter['overview'] = '；'.join(f'[[speaker:{eid}]]建议继续核实' for eid in ids)
        chapter['speaker_display'] = build_display(chapter['overview'], self.evidence)
        timeline.dev_db.store_timeline_day('dev', 'user', DAY, self.original)
        shown = self.client.get(f'/v1/timeline/{DAY}/chapters',
            params={'external_user_id': 'user', 'speaker_attribution': True},
            headers={'Authorization': 'test-key'}).json()['chapters'][0]
        self.revision = shown['speaker_revision']
        chapter['speaker_display']['mentions'] = dict(reversed(list(chapter['speaker_display']['mentions'].items())))
        timeline.dev_db.store_timeline_day('dev', 'user', DAY, self.original)
        response = self.call('/evidence', 'post')
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual({item['id'] for item in response.json()['evidence']}, set(ids))
        self.assertEqual(self.call(fields={'person_id': 'person1'}).status_code, 200)
        # A real later edit still invalidates the previously shown version.
        self.assertEqual(self.call('/evidence', 'post').status_code, 409)

    def test_correction_idempotency_undo_and_source_isolation(self):
        before = copy.deepcopy(self.convos)
        response = self.call(fields={'person_id': 'person1'})
        self.assertEqual(response.status_code, 200, response.text)
        chapter = response.json()['chapter']; self.assertEqual(chapter['speaker_display']['speakers'][0]['name'], '阿宁')
        self.assertEqual(self.call(fields={'person_id': 'person1'}).json()['chapter'], chapter)
        self.assertEqual(self.convos, before); self.collect.assert_not_called()
        self.assertEqual(timeline.dev_db.get_timeline_day('dev', 'user', DAY), self.original)
        self.revision = chapter['speaker_revision']
        undone = self.call(fields={'undo': True})
        self.assertEqual(undone.status_code, 200, undone.text)
        self.assertEqual(undone.json()['chapter']['speaker_display']['speakers'][0]['status'], 'unknown')
        self.revoke.assert_not_called()

    def test_listen_session_failure_preserves_evidence_and_correction(self):
        for conversation in self.convos:
            conversation['audio_path'] = 'account/session.wav'
        with patch.object(timeline.dev_db, 'get_listen_session', side_effect=RuntimeError('unavailable')):
            response = self.call('/evidence', 'post')
            self.assertEqual(response.status_code, 200, response.text)
            items = response.json()['evidence']
            self.assertTrue(items)
            self.assertEqual(items[0]['text'], self.evidence[self.eid]['text'])
            self.assertTrue(all(item['audio'] is None for item in items))
            corrected = self.call(fields={'person_id': 'person1'})
            self.assertEqual(corrected.status_code, 200, corrected.text)
            self.assertEqual(corrected.json()['chapter']['speaker_display']['speakers'][0]['name'], '阿宁')
        self.collect.assert_not_called()

    def drop_stored_refs(self):
        # Exercise the real persistence guard, not just a fabricated empty list.
        with patch.object(timeline.dev_db, 'TIMELINE_DAY_MAX_SEGMENT_REFS', 0):
            written = timeline.dev_db.store_timeline_day('dev', 'user', DAY, self.original)
        self.assertTrue(written['segment_refs_dropped'])
        self.assertTrue(all(not ch['segment_refs'] for ch in written['chapters']))
        return written

    def test_storage_guard_preserves_evidence_correction_and_undo_after_fresh_get(self):
        stored = self.drop_stored_refs()
        before = copy.deepcopy(self.convos)
        response = self.client.get(f'/v1/timeline/{DAY}/chapters',
            params={'external_user_id': 'user', 'speaker_attribution': 'true'},
            headers={'Authorization': 'test-key'})
        self.assertEqual(response.status_code, 200, response.text)
        chapter = response.json()['chapters'][0]
        self.selector = {k: chapter[k] for k in ('start', 'end', 'source_conversation_ids')}
        self.revision = chapter['speaker_revision']
        response = self.call('/evidence', 'post')
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual([e['id'] for e in response.json()['evidence']], [self.eid])
        self.assertEqual(response.json()['evidence'][0]['text'], self.evidence[self.eid]['text'])
        corrected = self.call(fields={'person_id': 'person1'})
        self.assertEqual(corrected.status_code, 200, corrected.text)
        self.revision = corrected.json()['chapter']['speaker_revision']
        self.assertEqual(self.call('/evidence', 'post').status_code, 200)
        self.assertEqual(self.call(fields={'undo': True}).status_code, 200)
        self.assertEqual(timeline.dev_db.get_timeline_day('dev', 'user', DAY), stored)
        self.assertEqual(self.convos, before)
        self.collect.assert_not_called()

    def test_rebuilt_refs_still_reject_changed_text_identity_time_or_missing_source(self):
        self.drop_stored_refs()
        original = copy.deepcopy(self.convos)
        for field, value in [('text', 'changed words'), ('person_id', 'different-person'), ('start', -30)]:
            with self.subTest(field=field):
                self.convos[:] = copy.deepcopy(original)
                self.convos[0]['transcript_segments'][0][field] = value
                self.assertEqual(self.call('/evidence', 'post').status_code, 409)
        self.convos.clear()
        self.assertEqual(self.call('/evidence', 'post').status_code, 409)

    def test_rebuilt_refs_keep_split_recording_chapters_isolated(self):
        conversation = copy.deepcopy(self.convos[0])
        conversation['source'] = 'audio_upload'
        conversation['transcript_segments'] = [
            {'id': 'first', 'start': 0, 'end': 10, 'text': 'first chapter', 'speaker_id': 1},
            {'id': 'second', 'start': 1200, 'end': 1210, 'text': 'second chapter', 'speaker_id': 1}]
        self.convos[:] = [conversation]
        chapters = timeline.segment_day_into_chapters(self.convos)
        self.assertEqual(len(chapters), 2)
        for ch in chapters:
            evidence = chapter_evidence(ch, {conversation['id']: conversation})
            ch['overview'] = f'[[speaker:{next(iter(evidence))}]] offers a view.'
            ch['speaker_display'] = build_display(ch['overview'], evidence)
        self.original['chapters'] = chapters
        self.drop_stored_refs()
        for ch, expected in zip(chapters, ('first chapter', 'second chapter')):
            self.selector = {k: ch[k].isoformat() if k in ('start', 'end') else ch[k]
                             for k in ('start', 'end', 'source_conversation_ids')}
            self.revision = present_speakers(ch)['speaker_revision']
            self.sid = ch['speaker_display']['speakers'][0]['id']
            response = self.call('/evidence', 'post')
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual([e['text'] for e in response.json()['evidence']], [expected])
        # Even a stored reference from the same speaker and recording cannot
        # resolve a quotation belonging to the other chapter.
        chapters[1]['overview'] = chapters[0]['overview']
        chapters[1]['speaker_display'] = chapters[0]['speaker_display']
        self.drop_stored_refs()
        self.revision = present_speakers(chapters[1])['speaker_revision']
        self.assertEqual(self.call('/evidence', 'post').status_code, 409)

    def test_enrollment_separate_exact_segment_and_full_undo(self):
        self.assertEqual(self.call('/enroll', 'post', {'evidence_id': self.eid}).status_code, 409)
        corrected = self.call(fields={'person_id': 'person1'}).json()['chapter']; self.revision = corrected['speaker_revision']
        self.assertEqual(self.call('/enroll', 'post', {'evidence_id': self.eid}).json()['status'], 'enrolled')
        self.assertEqual(self.call('/enroll', 'post', {'evidence_id': self.eid}).json()['status'], 'enrolled')
        self.collect.assert_called_once()
        args, kw = self.collect.call_args
        self.assertEqual(args[3], [self.evidence[self.eid]['segment_id']]); self.assertEqual(kw['chapter_operation_id'], self.op)
        self.assertEqual(self.call(fields={'undo': True}).status_code, 200)
        self.revoke.assert_called_once()
        self.assertEqual(self.revoke.call_args.args[2]['id'], self.op)

    def test_reassignment_retracts_previous_learning_without_reenrolling_on_undo(self):
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        self.call('/enroll', 'post', {'evidence_id': self.eid})
        learned_operation = self.op
        self.op = 'chapter-test-operation-002'
        response = self.call(fields={'is_user': True})
        self.assertEqual(response.status_code, 200, response.text)
        self.revoke.assert_called_once()
        self.assertEqual(self.revoke.call_args.args[2]['id'], learned_operation)
        self.assertEqual(self.call(fields={'undo': True}).status_code, 200)
        self.revoke.assert_called_once()
        self.collect.assert_called_once()

    def test_other_speaker_edit_preserves_learning_receipt_until_reassignment(self):
        other_eid = next(eid for eid, e in self.evidence.items() if e['speaker_id'] != self.sid)
        chapter = self.original['chapters'][0]
        chapter['overview'] += f'[[speaker:{other_eid}]]提出了另一种意见。'
        chapter['speaker_display'] = build_display(chapter['overview'], self.evidence)
        timeline.dev_db.store_timeline_day('dev', 'user', DAY, self.original)
        self.revision = present_speakers(chapter)['speaker_revision']
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        self.call('/enroll', 'post', {'evidence_id': self.eid})
        learned_operation = self.op
        self.op = 'chapter-test-operation-002'
        response = self.call(fields={'speaker_id': self.evidence[other_eid]['speaker_id'], 'name': '另一位'})
        self.assertEqual(response.status_code, 200, response.text)
        self.revoke.assert_not_called()
        self.revision = response.json()['chapter']['speaker_revision']
        self.op = 'chapter-test-operation-003'
        response = self.call(fields={'is_user': True})
        self.assertEqual(response.status_code, 200, response.text)
        self.revoke.assert_called_once()
        self.assertEqual(self.revoke.call_args.args[2]['id'], learned_operation)

    def test_reassignment_cleanup_failure_preserves_receipt_and_identity_for_retry(self):
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        self.call('/enroll', 'post', {'evidence_id': self.eid})
        before = copy.deepcopy(timeline.edits_db.get_chapter_edits('dev', 'user', DAY))
        self.op = 'chapter-test-operation-002'
        self.revoke.side_effect = RuntimeError('storage unavailable')
        self.assertEqual(self.call(fields={'is_user': True}).status_code, 503)
        self.assertEqual(timeline.edits_db.get_chapter_edits('dev', 'user', DAY), before)
        self.revoke.side_effect = None
        self.assertEqual(self.call(fields={'is_user': True}).status_code, 200)
        self.assertEqual(self.revoke.call_count, 2)
        self.collect.assert_called_once()

    def test_undo_retracts_learning_after_source_transcript_changes(self):
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        self.call('/enroll', 'post', {'evidence_id': self.eid})
        for c in self.convos:
            for seg in c['transcript_segments']:
                seg['text'] += ' corrected'
                seg['start'] += 0.1
        response = self.call(fields={'undo': True})
        self.assertEqual(response.status_code, 200, response.text)
        self.revoke.assert_called_once()

    def test_undo_retracts_learning_after_regenerated_summary_omits_person(self):
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        self.call('/enroll', 'post', {'evidence_id': self.eid})
        chapter = self.original['chapters'][0]
        chapter['overview'] = '更新后的摘要不再提及此人。'
        chapter['speaker_display'] = build_display(chapter['overview'], self.evidence)
        timeline.dev_db.store_timeline_day('dev', 'user', DAY, self.original)
        response = self.call(fields={'undo': True})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['chapter']['overview'], chapter['overview'])
        self.revoke.assert_called_once()

    def test_stale_source_scope_and_auth_rejected(self):
        self.assertEqual(self.call(fields={'person_id': 'person1'}, uid='other').status_code, 403)
        original_revision = self.revision; self.revision = 'stale'
        self.assertEqual(self.call().status_code, 409); self.revision = original_revision
        self.selector['end'] = '2026-08-07T23:59:00+00:00'; self.assertEqual(self.call().status_code, 409)
        self.selector['end'] = self.original['chapters'][0]['end'].isoformat()
        self.convos[0]['transcript_segments'][0]['text'] += 'Changed'
        self.assertEqual(self.call('/evidence', 'post').status_code, 409)

    def test_legacy_get_resolves_tokens_without_mutating_cache(self):
        response = self.client.get(f'/v1/timeline/{DAY}/chapters', params={'external_user_id': 'user'}, headers={'Authorization':'test-key'})
        chapter = response.json()['chapters'][0]
        self.assertNotIn('[[speaker:', chapter['overview']); self.assertNotIn('speaker_display', chapter)
        self.assertIn('speaker_display', timeline.dev_db.get_timeline_day('dev', 'user', DAY)['chapters'][0])

    def test_legacy_prose_edits_preserve_corrected_identity_and_evidence_on_fresh_get(self):
        self.assertEqual(self.call(fields={'person_id': 'person1'}).status_code, 200)
        params = {'external_user_id': 'user'}
        headers = {'Authorization': 'test-key'}
        url = f'/v1/timeline/{DAY}/chapters'
        for before, after in [('继续核实', '明天核实'), ('长篇用户注释', '我的补充注释')]:
            with self.subTest(after=after):
                old = self.client.get(url, params=params, headers=headers).json()['chapters'][0]
                self.assertIn('阿宁', old['overview'])
                self.assertNotIn('[[speaker:', old['overview'])
                edited = old['overview'].replace(before, after)
                response = self.client.patch(url, params=params, headers=headers,
                    json={**self.selector, 'overview': edited})
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(response.json()['chapter']['overview'], edited)
                fresh = self.client.get(url, params={**params, 'speaker_attribution': 'true'},
                    headers=headers).json()['chapters'][0]
                self.assertIn(f'[[speaker:{self.eid}]]', fresh['overview'])
                self.assertIn(after, fresh['overview'])
                self.assertEqual(fresh['speaker_display']['mentions'], {self.eid: self.sid})
                self.assertEqual(fresh['speaker_display']['speakers'][0]['name'], '阿宁')
        self.assertEqual(timeline.dev_db.get_timeline_day('dev', 'user', DAY), self.original)
        self.collect.assert_not_called()

    def test_legacy_changed_attribution_rejected_without_writing_but_new_client_can_remove_it(self):
        self.assertEqual(self.call(fields={'person_id': 'person1'}).status_code, 200)
        params = {'external_user_id': 'user'}
        headers = {'Authorization': 'test-key'}
        url = f'/v1/timeline/{DAY}/chapters'
        edits_before = timeline.edits_db.get_chapter_edits('dev', 'user', DAY)
        for edited in ('有人建议继续核实。', '只保留自己的注释。'):
            with self.subTest(edited=edited):
                response = self.client.patch(url, params=params, headers=headers,
                    json={**self.selector, 'overview': edited})
                self.assertEqual(response.status_code, 422, response.text)
                self.assertEqual(timeline.edits_db.get_chapter_edits('dev', 'user', DAY), edits_before)
        response = self.client.patch(url, params={**params, 'speaker_attribution': 'true'},
            headers=headers, json={**self.selector, 'overview': '只保留自己的注释。'})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['chapter']['speaker_display']['speakers'], [])

    def test_chapter_edit_returns_legacy_plain_text_or_opted_in_attribution(self):
        # Include a user correction: both GET and PATCH must return its current
        # label, but only attribution-aware clients may receive internal tokens.
        self.assertEqual(self.call(fields={'person_id': 'person1'}).status_code, 200)
        for attribution in (None, 'false', 'true'):
            with self.subTest(attribution=attribution):
                params = {'external_user_id': 'user'}
                if attribution is not None:
                    params['speaker_attribution'] = attribution
                response = self.client.patch(f'/v1/timeline/{DAY}/chapters', params=params,
                    headers={'Authorization': 'test-key'}, json={**self.selector, 'title': '修正标题'})
                self.assertEqual(response.status_code, 200, response.text)
                shown = response.json()['chapter']
                self.assertEqual(shown['title'], '修正标题')
                if attribution == 'true':
                    self.assertIn('[[speaker:', shown['overview'])
                    self.assertEqual(shown['speaker_display']['speakers'][0]['name'], '阿宁')
                else:
                    self.assertIn('阿宁', shown['overview'])
                    self.assertNotIn('[[speaker:', shown['overview'])
                    self.assertNotIn('speaker_display', shown)
                self.assertEqual(timeline.dev_db.get_timeline_day('dev', 'user', DAY), self.original)

    def test_day_resolves_repeated_people_once_for_new_and_legacy_clients(self):
        document = copy.deepcopy(self.original)
        chapter = document['chapters'][0]
        chapter['speaker_display']['speakers'][0]['person_id'] = 'person1'
        document['chapters'] = [copy.deepcopy(chapter) for _ in range(12)]
        original = copy.deepcopy(document)
        for attribution in (True, False):
            with self.subTest(attribution=attribution), patch.object(
                    timeline.dev_db, 'get_people_by_ids', return_value=[{'id': 'person1', 'name': '阿宁'}]) as bulk, patch.object(
                    timeline.dev_db, 'get_person', side_effect=AssertionError('serial lookup')):
                result = timeline._edited_day(document, DAY, 'dev', 'user', attribution)
                bulk.assert_called_once_with('dev', 'user', ['person1'])
                self.assertEqual(len(result['chapters']), 12)
                for shown in result['chapters']:
                    if attribution:
                        self.assertEqual(shown['speaker_display']['speakers'][0]['name'], '阿宁')
                    else:
                        self.assertIn('阿宁', shown['overview'])
                self.assertEqual(document, original)

    def test_failed_enrollment_compensates_before_retry(self):
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        self.collect.side_effect = [{'status': 'failed'}, {'status': 'enrolled'}]
        self.assertEqual(self.call('/enroll', 'post', {'evidence_id': self.eid}).json()['status'], 'failed')
        self.assertEqual(self.call('/enroll', 'post', {'evidence_id': self.eid}).json()['status'], 'enrolled')
        self.assertEqual(self.collect.call_count, 2)
        self.revoke.assert_called_once()

    def test_failed_revocation_keeps_correction_for_retry(self):
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        self.call('/enroll', 'post', {'evidence_id': self.eid})
        self.revoke.side_effect = RuntimeError('temporary storage failure')
        response = self.call(fields={'undo': True})
        self.assertGreaterEqual(response.status_code, 500)
        self.revoke.side_effect = None
        self.assertEqual(self.call(fields={'undo': True}).status_code, 200)

    def test_lost_enrollment_response_is_cleaned_up_before_retry(self):
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        self.collect.side_effect = RuntimeError('worker interrupted after upload')
        with self.assertRaises(RuntimeError):
            self.call('/enroll', 'post', {'evidence_id': self.eid})
        self.revoke.side_effect = RuntimeError('storage unavailable')
        self.assertEqual(self.call('/enroll', 'post', {'evidence_id': self.eid}).status_code, 503)
        self.assertEqual(self.collect.call_count, 1)
        self.revoke.side_effect = None
        self.collect.side_effect = lambda *a, **kw: (
            self.assertEqual(self.revoke.call_count, 2) or {'status': 'enrolled'})
        self.assertEqual(self.call('/enroll', 'post', {'evidence_id': self.eid}).json()['status'], 'enrolled')
        self.assertEqual(self.revoke.call_args.args[2]['enrollment_segments'],
            {self.evidence[self.eid]['conversation_id']: [self.evidence[self.eid]['segment_id']]})

    def test_learning_requires_explicit_review(self):
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        result = self.call('/enroll', 'post', {'evidence_id': self.eid, 'reviewed': False})
        self.assertEqual(result.json()['status'], 'review_required')
        self.collect.assert_not_called()

    def test_same_person_keeps_previous_sample_and_undo_only_removes_new_sample(self):
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        self.call('/enroll', 'post', {'evidence_id': self.eid})
        original_op = self.op
        self.op = 'chapter-test-operation-002'
        self.revision = self.call(fields={'person_id': 'person1'}).json()['chapter']['speaker_revision']
        self.revoke.assert_not_called()
        self.call('/enroll', 'post', {'evidence_id': self.eid})
        self.assertEqual(self.call(fields={'undo': True}).status_code, 200)
        self.assertEqual([c.args[2]['id'] for c in self.revoke.call_args_list], [self.op])
        self.op = 'chapter-test-operation-003'
        current = timeline.edits_db.get_chapter_edits('dev', 'user', DAY)
        edit = next(iter(current.values()))
        self.revision = present_speakers(self.original['chapters'][0], edit)['speaker_revision']
        self.assertEqual(self.call(fields={'is_user': True}).status_code, 200)
        self.assertEqual([c.args[2]['id'] for c in self.revoke.call_args_list],
                         ['chapter-test-operation-002', original_op])

    def test_new_person_id_is_stable_after_lost_save_and_never_reuses_namesake(self):
        created = {}
        def create(dev, user, pid, name):
            created.setdefault(pid, {'id': pid, 'name': name})
            return created[pid]
        with patch.object(timeline.dev_db, 'create_chapter_person', side_effect=create):
            with patch.object(timeline.edits_db, 'save_chapter_edit', side_effect=RuntimeError('lost write')):
                with self.assertRaises(RuntimeError):
                    self.call(fields={'new_person_name': '阿宁'})
            response = self.call(fields={'new_person_name': '阿宁'})
            self.assertEqual(response.status_code, 200, response.text)
            person = response.json()['chapter']['speaker_display']['speakers'][0]
            self.assertEqual(len(created), 1)
            self.assertIn(person['person_id'], created)
            self.assertNotEqual(person['person_id'], 'person1')
            self.assertEqual(person['name'], '阿宁')
            self.assertEqual(self.call(fields={'new_person_name': '阿宁'}).status_code, 200)
            self.assertEqual(len(created), 1)
            self.assertEqual(self.call(fields={'undo': True}).status_code, 200)
            self.assertEqual(len(created), 1)  # A person may already be used elsewhere.
