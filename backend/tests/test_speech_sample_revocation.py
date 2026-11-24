"""Taking a speaker tag back has to take the enrolled audio back with it.

A manual tag is the *only* thing that may enrol audio into a voiceprint
(``test_speech_sample_collector_quality.py`` covers that gate). This file covers
the other direction: when the user withdraws that tag, the sample it produced
must leave the read path.

Why it matters. The user cancels a mark for one of two reasons, and both mean the
voiceprint is wrong:

* voiceprint matching labelled the speaker wrong — but an AUTO label never
  collected a sample, so there is nothing to revoke and the fix is elsewhere;
* they tagged it wrong themselves — that DID collect a sample, filed under the
  wrong person. Leave it and that person keeps winning the same voice in the next
  conversation, i.e. the mistake compounds exactly where the user thought they
  had corrected it.

Three things make this subtler than "delete the sample":

1. **Attribution has to be written at collection time.** The object name is a bare
   ``{uuid[:8]}.wav``, one upload merges several transcript segments into one wav,
   and the segment itself persists only ``is_user`` / ``person_id`` /
   ``speaker_status``. By the time a cancel arrives the segments have already been
   overwritten with the new owner, so the mapping is unrecoverable after the fact.
2. **The quarantine location has to sit outside the read prefixes.** Both readers
   list by prefix and derive identity from the path, so a sample parked under
   ``people_profiles/{pid}/…`` is still read back as that person's audio and the
   revocation silently does nothing.
3. **Only samples we can attribute may be touched.** A cancel can be a mis-tap,
   and legacy samples carry no provenance — guessing would delete audio the user
   tagged correctly.

Run:
    cd backend && python3 tests/test_speech_sample_revocation.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")
os.environ.setdefault("BUCKET_SPEECH_PROFILES", "test-speech-profiles")

import database.developer_speech_profile as speech_db  # noqa: E402

DEV = "dev1"
UID = "user1"
CONV = "conv-aaa"

PEOPLE = speech_db._get_developer_people_prefix(DEV, UID)
SAMPLES = speech_db._get_developer_samples_prefix(DEV, UID)
REVOKED = speech_db._get_developer_revoked_prefix(DEV, UID)


class FakeBlob:
    def __init__(self, name, metadata=None, bucket=None):
        self.name = name
        self.metadata = dict(metadata) if metadata else None
        self._bucket = bucket
        self.patched = False

    def patch(self):
        self.patched = True

    def delete(self):
        self._bucket.blobs.pop(self.name, None)


class FakeBucket:
    def __init__(self):
        self.blobs = {}

    def add(self, name, metadata=None):
        self.blobs[name] = FakeBlob(name, metadata, self)
        return self.blobs[name]

    def list_blobs(self, prefix=""):
        # Real GCS prefix semantics: plain string match on the full object name.
        return [b for n, b in sorted(self.blobs.items()) if n.startswith(prefix)]

    def copy_blob(self, blob, destination_bucket, new_name):
        assert destination_bucket is self
        copy = FakeBlob(new_name, blob.metadata, self)
        self.blobs[new_name] = copy
        return copy


class FakeClient:
    def __init__(self, bucket):
        self._bucket = bucket

    def bucket(self, _name):
        return self._bucket


class RevocationTestCase(unittest.TestCase):
    def setUp(self):
        self.bucket = FakeBucket()
        self._orig_client = speech_db._get_storage_client
        speech_db._get_storage_client = lambda: FakeClient(self.bucket)

    def tearDown(self):
        speech_db._get_storage_client = self._orig_client

    def provenance(self, **kw):
        args = dict(
            source="manual",
            assign_type="person_id",
            target_id="alice",
            conversation_id=CONV,
            segment_ids=["s1", "s2"],
            duration_seconds=12.5,
        )
        args.update(kw)
        return speech_db.sample_provenance(**args)

    def revoke(self, segment_ids=("s1", "s2"), **kw):
        return speech_db.revoke_samples_from_segments(
            DEV, UID, CONV, list(segment_ids), **kw
        )


class QuarantineIsOutsideTheReadPath(RevocationTestCase):
    """The one mistake that makes revocation a no-op while looking correct."""

    def test_revoked_prefix_is_a_sibling_not_a_child(self):
        self.assertFalse(REVOKED.startswith(PEOPLE))
        self.assertFalse(REVOKED.startswith(SAMPLES))
        # And the inverse: `revoked_samples/` must not be swept up by a listing
        # of `samples/`, which is a string-prefix relationship people get wrong.
        self.assertFalse(REVOKED.startswith(SAMPLES.rstrip("/")))

    def test_revoked_sample_disappears_from_the_person_listing(self):
        self.bucket.add(f"{PEOPLE}alice/abc12345.wav", self.provenance())
        self.assertEqual(len(self.revoke()), 1)

        # This is the listing download_developer_people_for_identification uses.
        remaining = [b.name for b in self.bucket.list_blobs(prefix=PEOPLE)]
        self.assertEqual(remaining, [])

    def test_revoked_user_sample_disappears_from_the_profile_listing(self):
        self.bucket.add(
            f"{SAMPLES}sample_abc12345.wav",
            self.provenance(assign_type="is_user", target_id="user"),
        )
        self.assertEqual(len(self.revoke()), 1)
        self.assertEqual([b.name for b in self.bucket.list_blobs(prefix=SAMPLES)], [])


class OnlyAttributableSamplesAreTouched(RevocationTestCase):
    def test_legacy_sample_without_provenance_is_left_alone(self):
        self.bucket.add(f"{PEOPLE}alice/legacy999.wav")  # no metadata at all
        self.assertEqual(self.revoke(), [])
        self.assertIn(f"{PEOPLE}alice/legacy999.wav", self.bucket.blobs)

    def test_sample_from_another_conversation_is_left_alone(self):
        # Segment ids are uuids in production, but nothing enforces global
        # uniqueness across conversations, so the conversation must match too.
        self.bucket.add(
            f"{PEOPLE}alice/other111.wav",
            self.provenance(conversation_id="conv-bbb"),
        )
        self.assertEqual(self.revoke(), [])
        self.assertIn(f"{PEOPLE}alice/other111.wav", self.bucket.blobs)

    def test_sample_built_from_other_segments_is_left_alone(self):
        self.bucket.add(
            f"{PEOPLE}alice/other222.wav",
            self.provenance(segment_ids=["s7", "s8"]),
        )
        self.assertEqual(self.revoke(segment_ids=("s1", "s2")), [])

    def test_partial_overlap_still_revokes(self):
        # The wav is one waveform: if any of its clips is disowned, the sample as
        # a whole can no longer be attributed to that person.
        self.bucket.add(
            f"{PEOPLE}alice/abc12345.wav",
            self.provenance(segment_ids=["s1", "s2", "s3"]),
        )
        self.assertEqual(len(self.revoke(segment_ids=("s2",))), 1)

    def test_directly_uploaded_sample_is_not_revoked_by_a_cancel(self):
        # No transcript tag justified it, so no cancel can withdraw it.
        self.bucket.add(
            f"{SAMPLES}sample_upload01.wav",
            speech_db.sample_provenance(
                source="upload", assign_type="is_user", target_id="user",
                conversation_id="", segment_ids=[], duration_seconds=30.0,
            ),
        )
        self.assertEqual(self.revoke(), [])
        self.assertIn(f"{SAMPLES}sample_upload01.wav", self.bucket.blobs)


class KeepTargetProtectsReconfirmation(RevocationTestCase):
    def test_reconfirming_the_same_person_keeps_their_sample(self):
        self.bucket.add(f"{PEOPLE}alice/abc12345.wav", self.provenance())
        self.assertEqual(
            self.revoke(keep_target=("person_id", "alice"), reason="reassigned"), []
        )
        self.assertIn(f"{PEOPLE}alice/abc12345.wav", self.bucket.blobs)

    def test_reassigning_to_someone_else_revokes_the_old_sample(self):
        # "I marked this wrong, it was actually Bob." Without this, Alice keeps
        # the bogus voiceprint and keeps winning the same voice next time.
        self.bucket.add(f"{PEOPLE}alice/abc12345.wav", self.provenance())
        revoked = self.revoke(keep_target=("person_id", "bob"), reason="reassigned")
        self.assertEqual(len(revoked), 1)
        self.assertEqual(revoked[0]["target_id"], "alice")
        self.assertEqual(self.bucket.list_blobs(prefix=PEOPLE), [])

    def test_switching_between_a_person_and_the_user_revokes(self):
        self.bucket.add(
            f"{SAMPLES}sample_abc12345.wav",
            self.provenance(assign_type="is_user", target_id="user"),
        )
        revoked = self.revoke(keep_target=("person_id", "alice"))
        self.assertEqual(len(revoked), 1)
        self.assertEqual(revoked[0]["assign_type"], "is_user")


class RevocationIsReversible(RevocationTestCase):
    def test_quarantined_blob_keeps_provenance_and_records_the_revocation(self):
        self.bucket.add(f"{PEOPLE}alice/abc12345.wav", self.provenance())
        revoked = self.revoke()

        dest = revoked[0]["quarantined_to"]
        self.assertTrue(dest.startswith(REVOKED))
        blob = self.bucket.blobs[dest]
        self.assertTrue(blob.patched, "metadata patch never reached GCS")
        self.assertEqual(blob.metadata["conversation_id"], CONV)
        self.assertEqual(blob.metadata["target_id"], "alice")
        self.assertEqual(blob.metadata["original_path"], f"{PEOPLE}alice/abc12345.wav")
        self.assertEqual(blob.metadata["revoked_reason"], "unassigned")
        self.assertIn("revoked_at", blob.metadata)

    def test_returns_the_duration_needed_to_correct_the_counters(self):
        self.bucket.add(f"{PEOPLE}alice/abc12345.wav", self.provenance(duration_seconds=12.5))
        self.assertAlmostEqual(self.revoke()[0]["duration_seconds"], 12.5, places=2)

    def test_two_samples_from_one_conversation_do_not_collide_in_quarantine(self):
        self.bucket.add(f"{PEOPLE}alice/aaa11111.wav", self.provenance(segment_ids=["s1"]))
        self.bucket.add(f"{PEOPLE}alice/bbb22222.wav", self.provenance(segment_ids=["s2"]))
        revoked = self.revoke()
        self.assertEqual(len(revoked), 2)
        self.assertEqual(len({r["quarantined_to"] for r in revoked}), 2)


class NoArgumentsMeansNoAction(RevocationTestCase):
    def test_empty_segment_ids_revokes_nothing(self):
        self.bucket.add(f"{PEOPLE}alice/abc12345.wav", self.provenance())
        self.assertEqual(self.revoke(segment_ids=()), [])
        self.assertIn(f"{PEOPLE}alice/abc12345.wav", self.bucket.blobs)

    def test_missing_conversation_id_revokes_nothing(self):
        # Guards the upload path, which passes conversation_id='' on purpose.
        self.bucket.add(f"{PEOPLE}alice/abc12345.wav", self.provenance())
        self.assertEqual(
            speech_db.revoke_samples_from_segments(DEV, UID, "", ["s1"]), []
        )


class ProvenanceIsWellFormed(unittest.TestCase):
    def test_all_values_are_strings(self):
        md = speech_db.sample_provenance(
            source="manual", assign_type="person_id", target_id="alice",
            conversation_id=CONV, segment_ids=["s1", "s2"],
            duration_seconds=12.5, net_speech_seconds=9.25,
        )
        # GCS custom metadata is a string->string map; a float here is a 400.
        for key, value in md.items():
            self.assertIsInstance(value, str, f"{key} is not a string")
        self.assertEqual(md["segment_ids"], "s1,s2")
        self.assertEqual(md["segment_ids_complete"], "1")

    def test_oversized_segment_list_is_truncated_and_flagged(self):
        # Bounded in practice (~60 uuids), but the cap must degrade visibly
        # rather than let GCS reject the whole upload with a 400.
        many = [f"seg-{i:04d}-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" for i in range(500)]
        md = speech_db.sample_provenance(
            source="manual", assign_type="person_id", target_id="alice",
            conversation_id=CONV, segment_ids=many, duration_seconds=60.0,
        )
        self.assertLessEqual(
            len(md["segment_ids"].encode()), speech_db.MAX_SEGMENT_IDS_BYTES
        )
        self.assertEqual(md["segment_ids_complete"], "0")


COLLECTOR_SRC = os.path.join(
    os.path.dirname(__file__), "..", "utils", "speech_sample_collector.py"
)


class CollectorWiring(unittest.TestCase):
    """Source-level, because importing the collector pulls in GCS and Firestore.

    Both assertions guard ordering/argument mistakes that leave every unit above
    passing while the feature does nothing in production.
    """

    def setUp(self):
        with open(COLLECTOR_SRC) as f:
            self.src = f.read()
        # Scope every assertion to collect_speech_samples_developer's body. The
        # legacy sibling above it contains a byte-identical `not value` guard, so
        # searching the whole file silently measures the wrong function.
        body = self.src[self.src.index("def collect_speech_samples_developer("):]
        self.body = body[: body.index("\ndef ")] if "\ndef " in body else body

    def test_revocation_runs_before_the_unassign_early_return(self):
        revoke_at = self.body.index("revoke_samples_from_segments")
        early_return = self.body.index("if assign_type == 'is_user' and not value:")
        self.assertLess(
            revoke_at, early_return,
            "revocation must run before the early return, or CLEARING a speaker "
            "— the case that matters most — never reaches it",
        )

    def test_provenance_records_contributing_segments_not_assigned_ones(self):
        call = self.body[self.body.index("provenance = dev_profile_db.sample_provenance"):]
        call = call[: call.index(")\n")]
        self.assertIn("segment_ids=used_segment_ids", call)
        self.assertNotIn(
            "segment_ids=assigned_segment_ids", call,
            "segments are dropped for three reasons (too short, duration cap "
            "exhausted, span collapsed by axis remapping); attributing a sample "
            "to audio it does not contain makes an unrelated cancel revoke it",
        )


class ChapterOperationIsolation(RevocationTestCase):
    def test_undo_revokes_only_this_operations_samples(self):
        old = self.bucket.add(PEOPLE + 'alice/old.wav', self.provenance())
        other = self.bucket.add(PEOPLE + 'alice/other.wav', {**self.provenance(), 'chapter_operation_id': 'other'})
        added = self.bucket.add(PEOPLE + 'alice/added.wav', {**self.provenance(), 'chapter_operation_id': 'chapter-op'})
        result = self.revoke(chapter_operation_id='chapter-op')
        self.assertEqual(len(result), 1)
        self.assertIn(old.name, self.bucket.blobs)
        self.assertIn(other.name, self.bucket.blobs)
        self.assertNotIn(added.name, self.bucket.blobs)

    def test_quarantine_failure_is_not_reported_as_success(self):
        from unittest.mock import patch
        added = self.bucket.add(PEOPLE + 'alice/added.wav', {**self.provenance(), 'chapter_operation_id': 'chapter-op'})
        with patch.object(self.bucket, 'copy_blob', side_effect=RuntimeError('storage unavailable')):
            with self.assertRaises(RuntimeError): self.revoke(chapter_operation_id='chapter-op')
        self.assertIn(added.name, self.bucket.blobs)

    def test_partial_failure_reports_removed_samples_once_across_retry(self):
        from unittest.mock import patch
        md = {**self.provenance(), 'chapter_operation_id': 'chapter-op'}
        first = self.bucket.add(PEOPLE + 'alice/a.wav', md)
        second = self.bucket.add(PEOPLE + 'alice/b.wav', md)
        original = self.bucket.copy_blob
        progress = []

        def fail_second(blob, *args):
            if blob.name == second.name:
                raise RuntimeError('storage unavailable')
            return original(blob, *args)

        with patch.object(self.bucket, 'copy_blob', side_effect=fail_second):
            with self.assertRaises(RuntimeError):
                self.revoke(chapter_operation_id='chapter-op', revoked_samples=progress)
        self.assertEqual([r['original_path'] for r in progress], [first.name])
        self.assertEqual(progress[0]['duration_seconds'], 12.5)
        self.assertIn(second.name, self.bucket.blobs)
        retry = []
        self.revoke(chapter_operation_id='chapter-op', revoked_samples=retry)
        self.assertEqual([r['original_path'] for r in retry], [second.name])


if __name__ == "__main__":
    unittest.main(verbosity=2)
