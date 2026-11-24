"""Exercise chapter learning through the real collector and revocation storage."""
import copy
from contextlib import ExitStack
from unittest.mock import Mock, mock_open, patch

from test_speech_sample_revocation import RevocationTestCase, DEV, UID, CONV, PEOPLE, SAMPLES

# The storage module eagerly constructs a client; all actual collection I/O is
# replaced below, so importing must not consult ambient developer credentials.
with patch('google.cloud.storage.Client', return_value=object()):
    from utils import speech_sample_collector as collector


class ChapterCollectionTests(RevocationTestCase):
    def setUp(self):
        super().setUp()
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.conversation = {
            'id': CONV, 'audio_path': 'account/session.wav', 'source': 'audio_upload',
            'transcript_segments': [{'id': 's1', 'start': 0, 'end': 12.5,
                                     'timestamp_axis': 'audio', 'person_id': 'alice',
                                     'speaker_assignment_source': 'manual'}],
        }
        self.original = copy.deepcopy(self.conversation)
        self.clip = Mock(duration_seconds=12.5)
        self.duplicate = self.stack.enter_context(patch.object(collector.dev_profile_db, 'find_duplicate_sample', return_value=None))
        self.person_seconds = self.stack.enter_context(patch.object(collector.dev_db, 'increment_person_speech_samples_duration'))
        self.user_seconds = self.stack.enter_context(patch.object(collector.dev_db, 'increment_speech_samples_duration'))
        self.person_upload = self.stack.enter_context(patch.object(collector, 'upload_developer_person_speech_sample_from_file'))
        self.user_upload = self.stack.enter_context(patch.object(collector, 'upload_developer_sample'))
        self.extract = self.stack.enter_context(patch.object(collector, '_extract_clips_from_segments', return_value=(self.clip, 12.5, ['s1'])))
        for target, name, value in [
            (collector, 'download_recording_from_path', '/not-a-real-file.wav'),
            (collector.dev_db, 'get_listen_session', {'audio_kept_intervals': []}),
            (collector.AudioSegment, 'from_wav', collector.AudioSegment.silent(duration=45000)),
            (collector, '_screen_collected_sample', None),
            (collector, '_discard_paths', None),
            (collector.os, 'remove', None),
        ]:
            self.stack.enter_context(patch.object(target, name, return_value=value))
        self.stack.enter_context(patch('builtins.open', mock_open(read_data=b'synthetic-audio')))

    def collect(self, assign_type='person_id', value='bob', before_upload=lambda: True):
        return collector.collect_speech_samples_developer(
            DEV, UID, self.conversation, ['s1'], assign_type, value,
            chapter_operation_id='chapter-op', before_upload=before_upload)

    def add_person(self, person, filename='old', segments=('s1',), operation=None):
        metadata = self.provenance(target_id=person, segment_ids=list(segments))
        if operation:
            metadata['chapter_operation_id'] = operation
        return self.bucket.add(f'{PEOPLE}{person}/{filename}.wav', metadata)

    def test_chapter_learning_retracts_other_targets_across_entrypoints(self):
        alice = self.add_person('alice')
        carol = self.add_person('carol', operation='another-chapter')
        bob = self.add_person('bob')
        unrelated = self.add_person('alice', 'unrelated', ('s9',))
        self.assertEqual(self.collect()['status'], 'enrolled')
        self.assertNotIn(alice.name, self.bucket.blobs)
        self.assertNotIn(carol.name, self.bucket.blobs)
        self.assertIn(bob.name, self.bucket.blobs)
        self.assertIn(unrelated.name, self.bucket.blobs)
        self.assertEqual(self.conversation, self.original)
        self.person_upload.assert_called_once()
        metadata = self.person_upload.call_args.kwargs['metadata']
        self.assertEqual(metadata['chapter_operation_id'], 'chapter-op')
        self.assertEqual(metadata['segment_ids'], 's1')
        self.person_seconds.assert_any_call(DEV, UID, 'alice', -12.5, clamp_at_zero=True)
        self.person_seconds.assert_any_call(DEV, UID, 'carol', -12.5, clamp_at_zero=True)
        self.person_seconds.assert_any_call(DEV, UID, 'bob', 12.5)

    def test_cleanup_failure_does_not_upload_a_second_identity(self):
        old = self.add_person('alice')
        with patch.object(self.bucket, 'copy_blob', side_effect=RuntimeError('storage unavailable')):
            self.assertEqual(self.collect()['status'], 'failed')
        self.assertIn(old.name, self.bucket.blobs)
        self.person_upload.assert_not_called()
        self.user_upload.assert_not_called()
        self.person_seconds.assert_not_called()

    def test_partial_cleanup_counts_once_and_retry_removes_only_remaining(self):
        first = self.add_person('alice')
        second = self.add_person('carol')
        copy_blob = self.bucket.copy_blob

        def fail_second(blob, *args):
            if blob.name == second.name:
                raise RuntimeError('storage unavailable')
            return copy_blob(blob, *args)

        with patch.object(self.bucket, 'copy_blob', side_effect=fail_second):
            self.assertEqual(self.collect()['status'], 'failed')
        self.assertNotIn(first.name, self.bucket.blobs)
        self.assertIn(second.name, self.bucket.blobs)
        self.person_upload.assert_not_called()
        self.person_seconds.assert_called_once_with(DEV, UID, 'alice', -12.5, clamp_at_zero=True)
        self.person_seconds.reset_mock()
        self.assertEqual(self.collect()['status'], 'enrolled')
        self.assertNotIn(second.name, self.bucket.blobs)
        self.assertEqual(self.person_seconds.call_count, 2)
        self.person_seconds.assert_any_call(DEV, UID, 'carol', -12.5, clamp_at_zero=True)
        self.person_seconds.assert_any_call(DEV, UID, 'bob', 12.5)

    def test_learning_owner_preserves_samples_already_assigned_to_owner(self):
        owner = self.bucket.add(SAMPLES + 'old.wav', self.provenance(assign_type='is_user', target_id='user'))
        wrong = self.add_person('alice')
        self.assertEqual(self.collect('is_user', 'true')['status'], 'enrolled')
        self.assertIn(owner.name, self.bucket.blobs)
        self.assertNotIn(wrong.name, self.bucket.blobs)
        self.user_upload.assert_called_once()
        self.user_seconds.assert_called_once_with(DEV, UID, 12.5)

    def test_existing_target_duplicate_still_cleans_other_identities(self):
        wrong = self.add_person('alice')
        correct = self.add_person('bob')
        self.duplicate.return_value = correct.name
        self.assertEqual(self.collect()['status'], 'already_enrolled')
        self.assertNotIn(wrong.name, self.bucket.blobs)
        self.assertIn(correct.name, self.bucket.blobs)
        self.person_upload.assert_not_called()
        self.person_seconds.assert_called_once_with(DEV, UID, 'alice', -12.5, clamp_at_zero=True)

    def test_stale_or_rejected_audio_leaves_existing_samples_untouched(self):
        old = self.add_person('alice')
        self.assertEqual(self.collect(before_upload=lambda: False)['status'], 'stale')
        self.extract.return_value = (None, 0, [])
        self.assertEqual(self.collect()['status'], 'not_eligible')
        self.assertIn(old.name, self.bucket.blobs)
        self.person_upload.assert_not_called()
        self.person_seconds.assert_not_called()

    def test_net_speech_required_and_vad_failure_does_not_touch_samples(self):
        old = self.add_person('alice')
        for net, status in [(9.99, 'insufficient_speech'), (None, 'quality_unavailable'), (float('nan'), 'quality_unavailable')]:
            self.extract.return_value = (self.clip, net, ['s1'])
            self.assertEqual(self.collect()['status'], status)
        self.assertIn(old.name, self.bucket.blobs)
        self.person_upload.assert_not_called()
        self.person_seconds.assert_not_called()

    def test_short_and_overlapping_quotes_never_reach_extraction(self):
        self.conversation['transcript_segments'][0]['end'] = 9.9
        self.assertEqual(self.collect()['status'], 'too_short')
        self.conversation['transcript_segments'][0]['end'] = 30
        self.conversation['transcript_segments'].append({'id': 'other', 'start': 5, 'end': 7, 'timestamp_axis': 'audio'})
        self.assertEqual(self.collect()['status'], 'overlapping_speech')
        self.extract.assert_not_called()
        self.person_upload.assert_not_called()

    def test_long_quote_uses_only_previewed_twenty_seconds(self):
        self.conversation['transcript_segments'][0].update(start=3, end=40)
        self.assertEqual(self.collect()['status'], 'enrolled')
        self.assertEqual(self.extract.call_args.args[1],
                         [{**self.conversation['transcript_segments'][0], 'end': 23.0}])

    def test_duplicate_lookup_failure_is_retryable_without_any_upload(self):
        self.duplicate.side_effect = RuntimeError('storage unavailable')
        self.assertEqual(self.collect()['status'], 'failed')
        self.person_upload.assert_not_called()

    def test_heavily_clipped_waveform_is_rejected_before_learning(self):
        import array
        audio = collector.AudioSegment(array.array('h', [32767, -32768] * 12000).tobytes(),
                                       sample_width=2, frame_rate=1000, channels=1)
        with patch.object(collector.AudioSegment, 'from_wav', return_value=audio):
            self.assertEqual(self.collect()['status'], 'distorted_audio')
        self.extract.assert_not_called()
        self.person_upload.assert_not_called()
