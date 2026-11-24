"""What may enter a voiceprint, and what of it actually reaches the model.

Two separate questions, and production was getting both wrong at once on the same
account — which is why they are covered together here.

**What reaches the model.** Enrolment audio travels as an anchor plus separate
clips so the model can screen and weight each one. Choosing which clips to send is
a budget allocation, and it was written twice — once for the user's own samples,
once for each enrolled person — with the same defect both times: the running total
compared against the cap at the TOP of the loop, so the first clip passed at any
length and starved everything after it.

On the people path that meant **exactly one recording per person, forever**. Proven
in production, not inferred: the ``People references: {id}={n}s`` log line reported
84.2s for a person holding 84.2+56.7+56.7+56.7s of enrolled audio, and 57.5s for
one holding 57.5+36.1+31.6s. Every figure was that person's single longest file.
"I have tagged this person a dozen times and they are still never recognized" was
that. On the user's path the same shape gave 3 clips out of 39, and the summed
budget made ``MAX_PROFILE_CLIPS = 8`` unreachable by construction (0.5 x a 47.3s
anchor is 23.6s, which at 10s per clip is 2.4 clips).

Note what did NOT catch it. The people cap had a test, and that test asserted the
literal source line ``if total_seconds >= MAX_PERSON_REFERENCE_SECONDS:`` — the bug
itself. It read as coverage and pinned the defect in place. So everything here is
written against behaviour: give the allocator production's real clip lengths and
count what comes out.

**What may enter.** Every gate that existed measured the audio — long enough,
speech-dense enough — and none measured the *speaker*. On the account that prompted
this, 31 of 39 stored samples were somebody else, most not remotely borderline
(cos -0.073 to 0.294 against the user's own onboarding recording). Three gates are
added: the session's audio must not have arrived inflated, the clip must sound like
the user's anchor (or, for a person, must NOT sound like it), and byte-identical
re-uploads must not be stored as separate recordings.

Run:
    cd backend && python3 tests/test_speaker_enrolment_gates.py
"""

import base64
import hashlib
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")
os.environ.setdefault("BUCKET_SPEECH_PROFILES", "test-speech-profiles")

from pydub import AudioSegment  # noqa: E402

import database.developer_speech_profile as speech_db  # noqa: E402

DEV = "dev1"
UID = "user1"
PID = "alice"

COLLECTOR_SRC = os.path.join(
    os.path.dirname(__file__), "..", "utils", "speech_sample_collector.py"
)
SCREEN_SRC = os.path.join(
    os.path.dirname(__file__), "..", "scripts", "screen_speech_samples.py"
)


def read(path):
    with open(path) as f:
        return f.read()


def wav_bytes(seconds, frame_rate=16000):
    """A real, readable wav of a given length. pydub must be able to parse it."""
    buf = AudioSegment.silent(duration=int(seconds * 1000), frame_rate=frame_rate)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmp = f.name
    try:
        buf.export(tmp, format="wav")
        with open(tmp, "rb") as f:
            return f.read()
    finally:
        os.remove(tmp)


class FakeBlob:
    def __init__(self, name, content=b"", metadata=None, bucket=None):
        self.name = name
        self.content = content
        self.metadata = dict(metadata) if metadata else None
        self._bucket = bucket
        self.updated = None

    @property
    def size(self):
        return len(self.content)

    @property
    def md5_hash(self):
        # Matches what GCS returns: base64 of the raw md5 digest.
        return base64.b64encode(hashlib.md5(self.content).digest()).decode()

    def exists(self):
        return self.name in self._bucket.blobs

    def reload(self):
        pass

    def download_to_filename(self, dest):
        if self.name not in self._bucket.blobs:
            raise FileNotFoundError(self.name)
        with open(dest, "wb") as f:
            f.write(self.content)

    def delete(self):
        self._bucket.blobs.pop(self.name, None)

    def patch(self):
        pass


class FakeBucket:
    def __init__(self):
        self.blobs = {}

    def add(self, name, content=b"", metadata=None, updated=None):
        blob = FakeBlob(name, content, metadata, self)
        blob.updated = updated
        self.blobs[name] = blob
        return blob

    def blob(self, name):
        existing = self.blobs.get(name)
        if existing is not None:
            return existing
        return FakeBlob(name, b"", None, self)

    def list_blobs(self, prefix=""):
        return [b for n, b in sorted(self.blobs.items()) if n.startswith(prefix)]

    def copy_blob(self, blob, destination_bucket, new_name):
        assert destination_bucket is self
        copy = FakeBlob(new_name, blob.content, blob.metadata, self)
        self.blobs[new_name] = copy
        return copy


class FakeClient:
    def __init__(self, bucket):
        self._bucket = bucket

    def bucket(self, _name):
        return self._bucket


class BucketBackedTestCase(unittest.TestCase):
    def setUp(self):
        self.bucket = FakeBucket()
        self._orig = speech_db._get_storage_client
        speech_db._get_storage_client = lambda: FakeClient(self.bucket)
        self.tmp = tempfile.mkdtemp(prefix="enrol_")

    def tearDown(self):
        speech_db._get_storage_client = self._orig

    def leftover(self):
        return sorted(os.listdir(self.tmp))


# ---------------------------------------------------------------------------
# What reaches the model
# ---------------------------------------------------------------------------


class PersonClipsAccumulate(BucketBackedTestCase):
    """Tagging the same person again must add to their reference, not be discarded.

    Lengths taken from production person ``ee723de2``: one 84.2s recording plus
    three of 56.7s. Before the fix this person contributed 84.2s and nothing else.
    """

    PROD_LENGTHS = [84.2, 56.7, 56.7, 56.7]

    def enrol(self, lengths, pid=PID):
        base = speech_db._get_developer_people_prefix(DEV, UID)
        for i, seconds in enumerate(lengths):
            self.bucket.add(f"{base}{pid}/clip{i}.wav", wav_bytes(seconds))

    def fetch(self, person_ids=None):
        return speech_db.download_developer_people_for_identification(
            DEV, UID, person_ids=person_ids, temp_dir=self.tmp
        )

    def test_a_person_with_four_recordings_contributes_more_than_one(self):
        self.enrol(self.PROD_LENGTHS)
        people = self.fetch()
        self.assertEqual(len(people), 1)
        self.assertGreater(
            len(people[0]["clip_paths"]), 0,
            "this is the whole bug: every recording after the anchor was dropped",
        )

    def test_the_number_of_clips_is_what_the_budget_allows(self):
        self.enrol(self.PROD_LENGTHS)
        people = self.fetch()
        expected = min(
            len(self.PROD_LENGTHS) - 1,
            int(speech_db.MAX_PERSON_REFERENCE_SECONDS
                // speech_db.WEIGHT_SATURATION_SECONDS),
        )
        self.assertEqual(len(people[0]["clip_paths"]), expected)

    def test_the_anchor_is_the_longest_recording_and_is_not_truncated(self):
        self.enrol(self.PROD_LENGTHS)
        people = self.fetch()
        anchor = AudioSegment.from_wav(people[0]["path"])
        self.assertAlmostEqual(anchor.duration_seconds, 84.2, delta=0.2,
                               msg="the anchor must travel whole")
        self.assertAlmostEqual(people[0]["anchor_seconds"], 84.2, delta=0.2)

    def test_each_clip_is_truncated_to_saturation_on_disk(self):
        # Not merely accounted for as truncated: the bytes have to shrink, or the
        # upload part and the encode still pay for audio that carries no weight.
        self.enrol(self.PROD_LENGTHS)
        people = self.fetch()
        for path in people[0]["clip_paths"]:
            seconds = AudioSegment.from_wav(path).duration_seconds
            self.assertLessEqual(seconds, speech_db.WEIGHT_SATURATION_SECONDS + 0.2,
                                 f"{path} still carries {seconds:.1f}s")

    def test_unused_downloads_are_deleted(self):
        self.enrol(self.PROD_LENGTHS + [56.7, 56.7])
        people = self.fetch()
        kept = {os.path.basename(people[0]["path"])} | {
            os.path.basename(p) for p in people[0]["clip_paths"]
        }
        self.assertEqual(set(self.leftover()), kept,
                         "a fetched-but-unused clip left on disk is unbounded growth")

    def test_a_single_recording_still_works_and_carries_no_clips(self):
        self.enrol([31.6])
        people = self.fetch()
        self.assertEqual(len(people), 1)
        self.assertEqual(people[0]["clip_paths"], [])
        self.assertEqual(people[0]["clip_count"], 0)

    def test_an_under_enrolled_person_is_still_refused(self):
        # The floor is not collateral damage of the fix: too little audio makes an
        # unstable embedding, and a false "that was your mother" is worse than blank.
        self.enrol([4.0])
        self.assertEqual(self.fetch(), [])
        self.assertEqual(self.leftover(), [],
                         "the refused person's download must not be left behind")

    def test_the_floor_counts_the_anchor_plus_what_is_actually_sent(self):
        # 5s anchor + 5s clip clears an 8s floor; either one alone would not.
        self.enrol([5.0, 5.0])
        people = self.fetch()
        self.assertEqual(len(people), 1)
        self.assertAlmostEqual(people[0]["seconds"], 10.0, delta=0.3)

    def test_an_unreadable_anchor_promotes_the_next_recording(self):
        base = speech_db._get_developer_people_prefix(DEV, UID)
        # Biggest blob, but not a wav at all — sorting is by size, so this is first.
        self.bucket.add(f"{base}{PID}/broken.wav", b"\x00" * 4_000_000)
        self.bucket.add(f"{base}{PID}/good.wav", wav_bytes(40.0))
        people = self.fetch()
        self.assertEqual(len(people), 1)
        self.assertAlmostEqual(people[0]["anchor_seconds"], 40.0, delta=0.2)


class CappedPeopleAreNamedNotCounted(BucketBackedTestCase):
    """A person dropped by the cap is invisible to the user; the log must name them."""

    def test_the_names_of_capped_people_are_logged(self):
        base = speech_db._get_developer_people_prefix(DEV, UID)
        # Descending sizes so the ordering (by enrolled bytes) is deterministic.
        for i in range(speech_db.MAX_PEOPLE_FOR_MATCHING + 3):
            self.bucket.add(f"{base}p{i:02d}/a.wav", wav_bytes(60.0 - i))
        import io
        import contextlib

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            people = speech_db.download_developer_people_for_identification(
                DEV, UID, temp_dir=self.tmp
            )
        log = out.getvalue()
        self.assertEqual(len(people), speech_db.MAX_PEOPLE_FOR_MATCHING)
        self.assertIn("not used for matching", log)
        # The three that fell off the end are the smallest, and must be named.
        for pid in ("p10", "p11", "p12"):
            self.assertIn(pid, log, "a bare count cannot answer 'why not my mother?'")

    def test_capped_people_do_not_leave_downloads_behind(self):
        base = speech_db._get_developer_people_prefix(DEV, UID)
        for i in range(speech_db.MAX_PEOPLE_FOR_MATCHING + 3):
            self.bucket.add(f"{base}p{i:02d}/a.wav", wav_bytes(60.0 - i))
        people = speech_db.download_developer_people_for_identification(
            DEV, UID, temp_dir=self.tmp
        )
        # Capped people are skipped before any download, so nothing to clean up.
        self.assertEqual(len(self.leftover()), len(people))


class ReferenceLogMakesTheBugVisible(BucketBackedTestCase):
    """The old log line summed anchor and clips, which is what hid the defect."""

    def test_the_log_reports_anchor_and_clip_count_separately(self):
        import io
        import contextlib

        base = speech_db._get_developer_people_prefix(DEV, UID)
        for i, seconds in enumerate([84.2, 56.7, 56.7]):
            self.bucket.add(f"{base}{PID}/c{i}.wav", wav_bytes(seconds))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            speech_db.download_developer_people_for_identification(
                DEV, UID, temp_dir=self.tmp
            )
        log = out.getvalue()
        self.assertIn("People references:", log)
        self.assertRegex(log, r"alice=84\.\ds\+\dclip",
                         "a single summed figure is what made 1-clip look healthy")


class UserProfileClipsReachTheCap(BucketBackedTestCase):
    """The parts path must be bounded by the clip cap, not by a summed budget."""

    def seed(self, anchor_seconds, sample_seconds):
        import datetime

        self.bucket.add(
            speech_db._get_developer_profile_path(DEV, UID), wav_bytes(anchor_seconds)
        )
        base = speech_db._get_developer_samples_prefix(DEV, UID)
        stamp = datetime.datetime(2026, 8, 1, tzinfo=datetime.timezone.utc)
        for i, seconds in enumerate(sample_seconds):
            # Descending timestamps: newest first, as the loop sorts them.
            self.bucket.add(
                f"{base}sample_{i:02d}.wav", wav_bytes(seconds),
                updated=stamp - datetime.timedelta(days=i),
            )

    PROD_SAMPLES = [58.8, 41.2, 33.0, 27.5, 22.1, 19.4, 15.8, 12.3, 11.0, 9.5]

    def test_the_parts_path_reaches_the_clip_cap(self):
        self.seed(47.3, self.PROD_SAMPLES)
        _anchor, clips = speech_db.download_developer_profile_parts(
            DEV, UID, temp_dir=self.tmp
        )
        self.assertEqual(len(clips), min(len(self.PROD_SAMPLES), speech_db.MAX_PROFILE_CLIPS),
                         "3 of 39 was the production outcome this replaces")

    def test_the_summed_budget_would_have_allowed_only_three(self):
        self.seed(47.3, self.PROD_SAMPLES)
        _anchor, clips = speech_db.download_developer_profile_parts(
            DEV, UID, temp_dir=self.tmp,
            share_of_anchor=speech_db.MAX_SAMPLE_SHARE_OF_PROFILE,
        )
        self.assertLessEqual(len(clips), 3, "this is the bound being lifted")

    def test_the_concatenating_helper_keeps_the_anchor_in_the_majority(self):
        # The one caller that still needs the summed bound, checked end to end on the
        # combined waveform rather than on the argument it passes.
        self.seed(47.3, self.PROD_SAMPLES)
        combined = speech_db.download_developer_profile_for_identification(
            DEV, UID, temp_dir=self.tmp
        )
        self.assertIsNotNone(combined)
        try:
            total = AudioSegment.from_wav(combined).duration_seconds
        finally:
            os.remove(combined)
        self.assertLess(total - 47.3, 47.3,
                        "collected audio outweighed the onboarding recording")

    def test_no_clip_exceeds_saturation(self):
        self.seed(47.3, self.PROD_SAMPLES)
        _anchor, clips = speech_db.download_developer_profile_parts(
            DEV, UID, temp_dir=self.tmp
        )
        for path in clips:
            self.assertLessEqual(
                AudioSegment.from_wav(path).duration_seconds,
                speech_db.WEIGHT_SATURATION_SECONDS + 0.2,
            )

    def test_a_profile_with_no_samples_still_returns_its_anchor(self):
        self.seed(47.3, [])
        anchor, clips = speech_db.download_developer_profile_parts(
            DEV, UID, temp_dir=self.tmp
        )
        self.assertIsNotNone(anchor)
        self.assertEqual(clips, [])


# ---------------------------------------------------------------------------
# What may enter
# ---------------------------------------------------------------------------


class InflatedSessionsMayNotEnrol(unittest.TestCase):
    """Duplicated-BLE-frame audio destroys the speech; it cannot carry a voiceprint."""

    def refusal(self, session):
        from utils.speech_sample_collector import _inflation_refusal

        return _inflation_refusal(session)

    def test_a_healthy_session_passes(self):
        self.assertIsNone(self.refusal({"audio_realtime_factor": 0.9}))

    def test_a_session_at_the_threshold_passes(self):
        # Healthy sessions measure up to ~1.4 (audio buffered before the socket
        # opens), so the bar has to sit above 1.0 — see the constant's note.
        from utils.speech_sample_collector import MAX_SESSION_REALTIME_FACTOR

        self.assertIsNone(
            self.refusal({"audio_realtime_factor": MAX_SESSION_REALTIME_FACTOR})
        )

    def test_an_inflated_session_is_refused(self):
        reason = self.refusal({"audio_realtime_factor": 10.59})
        self.assertIsNotNone(reason, "10.59x was recorded in production on 2026-08-18")
        self.assertIn("10.59", reason, "the reason must carry the number it saw")

    def test_a_session_predating_the_detector_passes(self):
        # Only sessions after 2026-08-17 carry the field. Refusing the rest would turn
        # a targeted guard into a total stop on enrolment.
        self.assertIsNone(self.refusal({}))
        self.assertIsNone(self.refusal({"audio_realtime_factor": None}))

    def test_a_corrupt_value_passes_rather_than_blocking(self):
        self.assertIsNone(self.refusal({"audio_realtime_factor": "n/a"}))

    def test_the_gate_runs_before_the_audio_is_downloaded(self):
        # Ordering is the point: downloading the wav and running VAD on audio we have
        # already decided to reject is pure waste, and the wav is the expensive part.
        src = read(COLLECTOR_SRC)
        body = src.split("def collect_speech_samples_developer")[1]
        self.assertLess(
            body.index("_inflation_refusal(session)"),
            body.index("download_recording_from_path(audio_gcs_path)"),
        )

    def test_the_refusal_returns_instead_of_only_logging(self):
        src = read(COLLECTOR_SRC)
        body = src.split("def collect_speech_samples_developer")[1]
        self.assertIn("_inflation_refusal(session)", body)
        self.assertIn("download_recording_from_path", body)
        after = body.split("_inflation_refusal(session)")[1]
        self.assertIn("download_recording_from_path", after,
                      "the gate moved below the download — it must run before it")
        head = after[: after.index("download_recording_from_path")]
        self.assertIn("return", head)

    def test_the_bar_matches_the_rescue_script(self):
        # Two places refuse to spend money on inflated audio; a mismatch would mean
        # one of them silently disagrees about which sessions are usable.
        rescue = read(os.path.join(
            os.path.dirname(__file__), "..", "scripts",
            "rescue_orphaned_listen_sessions.py",
        ))
        from utils.speech_sample_collector import MAX_SESSION_REALTIME_FACTOR

        self.assertIn(f"_MAX_REALTIME_FACTOR = {MAX_SESSION_REALTIME_FACTOR}", rescue)


class CollectedClipsAreScreenedAgainstTheAnchor(unittest.TestCase):
    """The gate that was missing entirely: whose voice is this?"""

    def reject(self, cos, assign_type):
        from utils.speech_sample_collector import _reject_by_anchor_cos

        return _reject_by_anchor_cos(cos, assign_type)

    def setUp(self):
        from utils.stt.speech_profile import COLLECT_AGREEMENT_MIN

        self.bar = COLLECT_AGREEMENT_MIN

    def test_the_bar_is_the_matchers_own_accept_threshold(self):
        # This is the entire safety argument for the gate: a clip below the bar is
        # refused by the matcher on every future conversation anyway, so declining to
        # store it cannot change any match — it only stops the corpus filling with
        # audio that will never be used.
        modal_src = read(os.path.join(
            os.path.dirname(__file__), "..", "modal",
            "speech_profile_modal_campplus.py",
        ))
        self.assertIn("CAMPPLUS_CLIP_AGREEMENT_MIN', '0.31'", modal_src)
        self.assertAlmostEqual(self.bar, 0.31)

    def test_a_clip_that_does_not_sound_like_the_user_is_not_stored_as_the_user(self):
        # 0.148 was this account's median stored sample; 0.119 and 0.126 were the two
        # that occupied 13.6s of a 23.6s budget.
        for cos in (-0.073, 0.119, 0.126, 0.148, 0.294):
            self.assertTrue(self.reject(cos, "is_user"), f"cos={cos}")

    def test_a_clip_that_does_sound_like_the_user_is_stored(self):
        for cos in (0.431, 0.487, 0.532, 0.535):
            self.assertFalse(self.reject(cos, "is_user"), f"cos={cos}")

    def test_the_direction_flips_for_a_person(self):
        # The user's own voice filed under someone else's name is what makes that
        # person start winning the user's segments.
        self.assertTrue(self.reject(0.535, "person_id"))
        self.assertFalse(self.reject(0.119, "person_id"))

    def test_the_two_directions_are_not_the_same_predicate(self):
        # A single shared threshold applied in one direction would silently make one
        # of the two assign types a no-op.
        for cos in (0.10, 0.60):
            self.assertNotEqual(
                self.reject(cos, "is_user"), self.reject(cos, "person_id")
            )

    def test_an_unscored_clip_is_enrolled_rather_than_dropped(self):
        # score None means "could not judge" — no anchor, cold encoder, bad response.
        # Losing enrolment to a cold Modal container would be a worse failure than
        # storing one unscreened clip, which the matcher screens again anyway.
        src = read(COLLECTOR_SRC)
        body = src.split("def collect_speech_samples_developer")[1]
        self.assertIn("if anchor_cos is not None and _reject_by_anchor_cos(", body)

    def test_a_missing_anchor_yields_no_opinion(self):
        import utils.stt.speech_profile as sp

        orig = speech_db.download_developer_anchor
        speech_db.download_developer_anchor = lambda *a, **k: None
        try:
            self.assertIsNone(
                sp.score_sample_against_anchor(DEV, UID, "/nonexistent.wav")
            )
        finally:
            speech_db.download_developer_anchor = orig

    def test_an_unreachable_encoder_yields_no_opinion(self):
        import utils.stt.speech_profile as sp

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            anchor = f.name
        orig_dl = speech_db.download_developer_anchor
        orig_embed = sp.embed_wavs

        def boom(*_a, **_k):
            raise RuntimeError("embed endpoint 503")

        speech_db.download_developer_anchor = lambda *a, **k: anchor
        sp.embed_wavs = boom
        try:
            self.assertIsNone(sp.score_sample_against_anchor(DEV, UID, anchor))
        finally:
            speech_db.download_developer_anchor = orig_dl
            sp.embed_wavs = orig_embed
            if os.path.exists(anchor):
                os.remove(anchor)
        self.assertFalse(os.path.exists(anchor),
                         "the anchor download must be cleaned up on the error path")

    def test_an_empty_embedding_yields_no_opinion(self):
        import utils.stt.speech_profile as sp

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            anchor = f.name
        orig_dl = speech_db.download_developer_anchor
        orig_embed = sp.embed_wavs
        speech_db.download_developer_anchor = lambda *a, **k: anchor
        sp.embed_wavs = lambda paths, **k: [None, None]
        try:
            self.assertIsNone(sp.score_sample_against_anchor(DEV, UID, anchor))
        finally:
            speech_db.download_developer_anchor = orig_dl
            sp.embed_wavs = orig_embed
            if os.path.exists(anchor):
                os.remove(anchor)

    def test_the_score_is_recorded_on_the_sample(self):
        # Answering "was this screened, and how well did it score?" costs two
        # downloads and two GPU encodes after the fact. Auditing 39 samples that way
        # is a 40-file embed run, which is how this account's corpus had to be
        # measured in the first place.
        md = speech_db.sample_provenance(
            source="manual", assign_type="is_user", target_id="user",
            conversation_id="c1", segment_ids=["s1"], duration_seconds=12.0,
            anchor_cos=0.5321,
        )
        self.assertEqual(md["anchor_cos"], "0.5321")

    def test_the_collector_actually_passes_the_score_through(self):
        # `sample_provenance` accepting the field proves nothing on its own: dropping
        # the argument at the one call site leaves every stored sample unscreened-
        # looking while both the gate and the formatter still test green.
        src = read(COLLECTOR_SRC)
        body = src.split("def collect_speech_samples_developer")[1]
        self.assertIn("provenance = dev_profile_db.sample_provenance(", body)
        call = body.split("provenance = dev_profile_db.sample_provenance(")[1]
        call = call[: call.index(")")]
        self.assertIn("anchor_cos=anchor_cos", call)

    def test_an_unscreened_sample_carries_no_score_field(self):
        # Absence is the signal that it was never checked; a default of 0.0 would be
        # indistinguishable from a clip that scored 0.0, i.e. a stranger.
        md = speech_db.sample_provenance(
            source="manual", assign_type="is_user", target_id="user",
            conversation_id="c1", segment_ids=["s1"], duration_seconds=12.0,
        )
        self.assertNotIn("anchor_cos", md)

    def test_the_screening_only_uses_the_anchor_not_the_stored_samples(self):
        # Scoring against existing samples would judge new audio by a reference that
        # already contains unscreened clips — agreement with a mistake reads exactly
        # like agreement with the person.
        src = read(os.path.join(
            os.path.dirname(__file__), "..", "database", "developer_speech_profile.py"
        ))
        body = src.split("def download_developer_anchor")[1]
        body = body.split("def list_developer_samples")[0]
        self.assertIn("_get_developer_profile_path", body)
        self.assertNotIn("_get_developer_samples_prefix", body)


class DuplicateUploadsAreNotSecondRecordings(BucketBackedTestCase):
    """N copies of one clip would carry N times the weight of one recording."""

    def test_byte_identical_audio_is_found(self):
        content = wav_bytes(56.7)
        base = speech_db._get_developer_samples_prefix(DEV, UID)
        self.bucket.add(f"{base}sample_aaaa.wav", content)
        self.assertEqual(
            speech_db.find_duplicate_sample(DEV, UID, content),
            f"{base}sample_aaaa.wav",
        )

    def test_different_audio_is_not_a_duplicate(self):
        base = speech_db._get_developer_samples_prefix(DEV, UID)
        self.bucket.add(f"{base}sample_aaaa.wav", wav_bytes(56.7))
        self.assertIsNone(
            speech_db.find_duplicate_sample(DEV, UID, wav_bytes(41.2))
        )

    def test_a_person_is_scoped_to_their_own_folder(self):
        # Person ee723de2 held three identical blobs; the same audio legitimately
        # existing under a DIFFERENT person must not block this one.
        content = wav_bytes(56.7)
        base = speech_db._get_developer_people_prefix(DEV, UID)
        self.bucket.add(f"{base}bob/x.wav", content)
        self.assertIsNone(
            speech_db.find_duplicate_sample(DEV, UID, content, person_id=PID)
        )
        self.bucket.add(f"{base}{PID}/y.wav", content)
        self.assertEqual(
            speech_db.find_duplicate_sample(DEV, UID, content, person_id=PID),
            f"{base}{PID}/y.wav",
        )

    def test_the_users_own_samples_are_not_searched_for_a_person(self):
        content = wav_bytes(56.7)
        self.bucket.add(
            f"{speech_db._get_developer_samples_prefix(DEV, UID)}sample_a.wav", content
        )
        self.assertIsNone(
            speech_db.find_duplicate_sample(DEV, UID, content, person_id=PID)
        )

    def test_the_hash_matches_what_gcs_reports(self):
        # Compared on the listing's md5 so the check costs no bytes; if the encoding
        # disagreed with GCS the check would never fire and would look implemented.
        content = wav_bytes(10.0)
        blob = self.bucket.add("x.wav", content)
        self.assertEqual(
            blob.md5_hash,
            base64.b64encode(hashlib.md5(content).digest()).decode(),
        )

    def test_the_collector_stops_before_uploading_a_duplicate(self):
        src = read(COLLECTOR_SRC)
        body = src.split("def collect_speech_samples_developer")[1]
        self.assertLess(
            body.index("find_duplicate_sample("),
            body.index("upload_developer_sample("),
        )
        self.assertIn("if duplicate:", body, "the duplicate is found but not acted on")
        after = body.split("if duplicate:")[1]
        self.assertIn("return", after[: after.index("provenance =")])

    def test_a_failed_duplicate_check_does_not_cost_the_enrolment(self):
        # A duplicate is a weighting problem; a missing sample is a recall problem.
        src = read(COLLECTOR_SRC)
        body = src.split("def collect_speech_samples_developer")[1]
        self.assertIn("find_duplicate_sample(", body)
        self.assertIn("if duplicate:", body)
        block = body[body.index("find_duplicate_sample("):]
        self.assertIn("audio_bytes, duplicate = None, None",
                      block[: block.index("if duplicate:")])


class ScreeningToolJudgesWhatProductionEmbeds(unittest.TestCase):
    """A tool that quarantines audio must score it the way the matcher does."""

    def test_the_anchor_is_not_truncated_for_screening(self):
        # MAX_EMBED_SECONDS = 25 cut a 47.3s onboarding recording in half, which moves
        # the reference every other file is scored against. Measured on this account:
        # cos went 0.532 -> 0.356, 0.450 -> 0.400 and 0.431 -> 0.403 (three of the
        # user's own clips would have been quarantined as somebody else) while
        # 0.347 -> 0.390 and 0.383 -> 0.402 moved the other way (two contaminated ones
        # would have been kept).
        src = read(SCREEN_SRC)
        self.assertNotIn("MAX_EMBED_SECONDS = 25.0", src)
        self.assertIn("SCREEN_MAX_EMBED_SECONDS", src)
        import re

        match = re.search(r"SCREEN_MAX_EMBED_SECONDS['\"],\s*['\"]([\d.]+)['\"]", src)
        self.assertIsNotNone(match)
        self.assertGreater(float(match.group(1)), 300.0,
                           "must not bite the anchor, nor the 305s sample in this bucket")

    def test_the_model_averages_chunks_rather_than_truncating(self):
        # Which is why not truncating is safe: production never sees a half anchor.
        modal_src = read(os.path.join(
            os.path.dirname(__file__), "..", "modal",
            "speech_profile_modal_campplus.py",
        ))
        self.assertIn("embeddings.append(_encode(chunk))", modal_src)
        self.assertIn("chunk_samples = MAX_CHUNK_SECONDS * fs", modal_src)

    def test_people_can_be_left_alone_during_a_targeted_cleanup(self):
        # Raising --user-threshold to clean one user's samples must not silently
        # re-decide every person reference under them via the is_the_user branch.
        src = read(SCREEN_SRC)
        self.assertIn("--skip-people", src)
        self.assertIn("if not skip_people:", src)
        self.assertIn("skip_people=args.skip_people", src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
