"""
Simple functional tests for audio upload API.

Usage:
    # Run with pytest
    pytest tests/test_audio_upload.py -v

    # Or run directly
    python tests/test_audio_upload.py
"""

import os
import sys

# Add parent directory to path for imports FIRST
backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(backend_dir)
sys.path.insert(0, backend_dir)

# Load .env file using python-dotenv if available
try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(backend_dir, '.env'))
except ImportError:
    pass  # python-dotenv not installed, rely on shell environment

# `.env`'s GOOGLE_APPLICATION_CREDENTIALS is the container path `/home/ubuntu/...`;
# importing `database` tries to create it and dies with OSError 45 on macOS. Other
# tests dodge this with `setdefault`, which does not work here because load_dotenv
# above has to run first (the Soniox integration test needs SONIOX_API_KEY from
# `.env`) — so this overwrites instead.
#
# ⚠️ Without this, every test that imports the router skipped, and the runner counted
# each skip as a pass. The four tests that actually verify this endpoint's wiring were
# reported green while never executing.
_creds = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')
if _creds and not os.path.exists(_creds):
    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = '/tmp/memorion-service-account.json'

# Set required environment variables BEFORE any imports (only if not already set)
# These are fallback dummy values for when running without full environment
if not os.environ.get('ENCRYPTION_SECRET'):
    os.environ['ENCRYPTION_SECRET'] = 'x' * 32
if not os.environ.get('SERVICE_ACCOUNT_JSON'):
    os.environ['SERVICE_ACCOUNT_JSON'] = '{}'
if not os.environ.get('OPENAI_API_KEY'):
    os.environ['OPENAI_API_KEY'] = 'sk-dummy-key-for-testing'

import wave
import struct
import tempfile
from datetime import datetime


class Skipped(Exception):
    """Raised by a test that cannot run (missing key, unimportable module).

    ⚠️ This exists because the skips used to be `print(...); return`, which the runner
    could not distinguish from a pass — a missing credentials path made four tests
    vanish while the summary still read "8 passed, 0 skipped". A skip has to be
    *visible* in the tally or the suite lies about its own coverage.
    """


def create_test_wav_file(duration_seconds: float = 5.0, sample_rate: int = 16000) -> str:
    """Create a simple test WAV file with a sine wave tone."""
    import math

    num_samples = int(duration_seconds * sample_rate)
    frequency = 440  # A4 note

    # Generate sine wave samples
    samples = []
    for i in range(num_samples):
        t = i / sample_rate
        # Generate a simple sine wave
        sample = int(32767 * 0.5 * math.sin(2 * math.pi * frequency * t))
        samples.append(sample)

    # Create temp file
    temp_file = tempfile.NamedTemporaryFile(suffix='.wav', delete=False)

    # Write WAV file
    with wave.open(temp_file.name, 'wb') as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)  # 16-bit
        wav_file.setframerate(sample_rate)
        for sample in samples:
            wav_file.writeframes(struct.pack('<h', sample))

    return temp_file.name


def test_validate_audio_file():
    """Test audio file validation."""
    try:
        from routers.audio_upload import validate_audio_file
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__}: {e})")

    # Create a test WAV file
    test_file = create_test_wav_file(duration_seconds=6.0)

    try:
        is_valid, error_msg, duration = validate_audio_file(test_file)

        assert is_valid, f"Validation failed: {error_msg}"
        assert duration >= 5.0, f"Duration too short: {duration}"
        assert duration <= 10.0, f"Duration too long: {duration}"
        print(f"✓ Audio validation passed: duration={duration:.2f}s")
    finally:
        os.unlink(test_file)


def test_validate_audio_file_too_short():
    """Test that short audio files are rejected."""
    try:
        from routers.audio_upload import validate_audio_file
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__})")

    # Create a very short WAV file (2 seconds)
    test_file = create_test_wav_file(duration_seconds=2.0)

    try:
        is_valid, error_msg, duration = validate_audio_file(test_file, min_duration=5.0)

        assert not is_valid, "Should reject short audio"
        assert "too short" in error_msg.lower(), f"Wrong error message: {error_msg}"
        print(f"✓ Short audio rejection passed: {error_msg}")
    finally:
        os.unlink(test_file)


def test_convert_to_wav_16k():
    """Test audio conversion to 16kHz WAV."""
    try:
        from routers.audio_upload import convert_to_wav_16k
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__})")

    # Create a test file at 8kHz
    test_file = create_test_wav_file(duration_seconds=5.0, sample_rate=8000)
    output_file = tempfile.NamedTemporaryFile(suffix='.wav', delete=False).name

    try:
        success = convert_to_wav_16k(test_file, output_file)
        assert success, "Conversion failed"

        # Verify output file
        with wave.open(output_file, 'rb') as wav:
            assert wav.getframerate() == 16000, f"Wrong sample rate: {wav.getframerate()}"
            assert wav.getnchannels() == 1, f"Wrong channels: {wav.getnchannels()}"

        print(f"✓ Audio conversion passed: 8kHz -> 16kHz")
    finally:
        os.unlink(test_file)
        if os.path.exists(output_file):
            os.unlink(output_file)


def test_soniox_transcription_integration():
    """
    Test Soniox async transcription (stt-async-v5) against the real API.

    Requires SONIOX_API_KEY and network access; skipped otherwise. Unlike the FAL
    path this replaced, Soniox takes a local file, so there is no GCS bucket in the
    way.

    The generated fixture is a sine tone with no speech in it, so an empty segment
    list is the expected result — what this exercises is the upload → create →
    poll → fetch → cleanup round-trip, not recognition quality.
    """
    if not os.environ.get('SONIOX_API_KEY'):
        raise Skipped("SONIOX_API_KEY not set")

    try:
        from utils.stt.pre_recorded import soniox_transcribe_file
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__})")

    test_file = create_test_wav_file(duration_seconds=6.0)
    try:
        segments, language = soniox_transcribe_file(test_file, raise_on_error=True)

        assert isinstance(segments, list), "Segments should be a list"
        assert isinstance(language, str) and language, "A language string is always returned"
        for seg in segments:
            assert seg.end >= seg.start, "Segment end should not precede its start"

        print(f"✓ Soniox integration passed:")
        print(f"  - Language detected: {language}")
        print(f"  - Segments count: {len(segments)} (0 is expected for a sine tone)")
        for i, seg in enumerate(segments[:3]):
            print(f"  - Segment {i}: '{seg.text[:50]}' ({seg.start:.1f}s-{seg.end:.1f}s)")

    # ⚠️ Deliberately no `except Exception: print(...)` here. It used to swallow
    # everything — including the assertions above — so a genuinely broken Soniox call
    # printed a warning and the runner still counted the test as passed.
    finally:
        os.unlink(test_file)


def test_full_upload_flow_mock():
    """
    Test the full upload flow with mocked external services.

    This is the test that catches "two individually-correct functions wired together
    wrongly" — specifically that the endpoint consumes `soniox_transcribe_file`'s
    `(List[TranscriptSegment], str)` shape rather than FAL's `(List[dict], str)`.
    No source-level assertion can see that.

    ⚠️ It therefore has to assert on the status code. It previously only printed it,
    while patching names the router no longer has (`process_conversation`,
    `upsert_conversation`), overriding a dependency the endpoint does not use
    (`get_current_user_uid` vs `get_current_user_context`) and omitting the mandatory
    `started_at` — so it reported success on a request that never got past the 400.
    """
    try:
        from fastapi.testclient import TestClient
        from unittest.mock import patch
        from main import app
        from models.transcript_segment import TranscriptSegment
        from utils.other import endpoints as auth
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__})")

    test_file = create_test_wav_file(duration_seconds=6.0)

    # The endpoint depends on `get_current_user_context`, which yields (developer_id, uid).
    async def mock_get_current_user_context():
        return ('test_developer', 'test_user_123')

    app.dependency_overrides[auth.get_current_user_context] = mock_get_current_user_context

    try:
        mock_segments = [
            TranscriptSegment(text='Hello world', speaker='SPEAKER_00', is_user=False,
                              person_id=None, start=0.0, end=2.0),
            TranscriptSegment(text='How are you', speaker='SPEAKER_01', is_user=False,
                              person_id=None, start=3.0, end=4.5),
        ]

        with patch('routers.audio_upload.soniox_transcribe_file', return_value=(mock_segments, 'en')) as mock_stt, \
             patch('routers.audio_upload.vad_is_empty', return_value=False), \
             patch('routers.audio_upload.developer_data_db.upsert_conversation_full'), \
             patch('routers.audio_upload.developer_data_db.update_conversation_status_dev'):

            client = TestClient(app)
            with open(test_file, 'rb') as f:
                response = client.post(
                    '/v1/conversations/upload-audio',
                    files={'file': ('test.wav', f, 'audio/wav')},
                    params={
                        'language': 'en',
                        'auto_process': 'false',  # skip the LLM; this test is about wiring
                        'started_at': '2026-08-13T10:00:00Z',
                    },
                )

            assert response.status_code == 200, f"Expected 200, got {response.status_code}: {response.text[:300]}"
            data = response.json()
            assert data['conversation_id'], "No conversation_id returned"
            assert len(data['transcript_segments']) == 2, \
                f"Expected 2 segments, got {len(data['transcript_segments'])}"
            assert data['language'] == 'en', f"Expected language 'en', got {data['language']!r}"

            # Soniox takes the local wav path, not a GCS URL — the whole point of the
            # migration. A signed URL slipping in here means the upload came back.
            stt_path = mock_stt.call_args[0][0]
            assert not stt_path.startswith('http'), f"Soniox was handed a URL, not a local path: {stt_path}"

            print(f"✓ Full upload flow passed:")
            print(f"  - Conversation ID: {data['conversation_id']}")
            print(f"  - Segments: {len(data['transcript_segments'])}")
            print(f"  - Soniox received local path: {stt_path}")

    finally:
        app.dependency_overrides.clear()
        os.unlink(test_file)


def test_transcription_failure_is_not_reported_as_empty_audio():
    """
    A Soniox outage must not be reported to the user as "your audio had no speech".

    This is the regression guard for `raise_on_error=True`. The default swallows
    every failure into `([], "en")`, which is indistinguishable at the call site from
    audio that genuinely contained no speech — and telling a user to re-record
    perfectly good audio is the wrong recovery advice.
    """
    try:
        from fastapi.testclient import TestClient
        from unittest.mock import patch
        from main import app
        from utils.other import endpoints as auth
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__})")

    test_file = create_test_wav_file(duration_seconds=6.0)

    async def mock_get_current_user_context():
        return ('test_developer', 'test_user_123')

    app.dependency_overrides[auth.get_current_user_context] = mock_get_current_user_context

    try:
        with patch('routers.audio_upload.soniox_transcribe_file',
                   side_effect=Exception('Soniox file upload failed: 503')), \
             patch('routers.audio_upload.vad_is_empty', return_value=False):

            client = TestClient(app)
            with open(test_file, 'rb') as f:
                response = client.post(
                    '/v1/conversations/upload-audio',
                    files={'file': ('test.wav', f, 'audio/wav')},
                    params={'language': 'en', 'auto_process': 'false',
                            'started_at': '2026-08-13T10:00:00Z'},
                )

        assert response.status_code == 502, \
            f"A transcription outage should be 502, got {response.status_code}: {response.text[:200]}"
        detail = response.json().get('detail', '')
        assert 'Transcription service failed' in detail, f"Unexpected detail: {detail!r}"
        assert 'clear speech' not in detail, \
            "An outage was described as an audio-content problem — the exact confusion raise_on_error exists to prevent"

        print(f"✓ Transcription outage correctly reported as 502:")
        print(f"  - detail: {detail[:80]}")

    finally:
        app.dependency_overrides.clear()
        os.unlink(test_file)


def _deferred_thread():
    """The background transcription thread, or None.

    Found by name rather than by capturing the `Thread` object, because the thread is
    created inside the endpoint and the test only ever sees the HTTP response.
    """
    import threading
    for t in threading.enumerate():
        if t.name.startswith('upload-audio-'):
            return t
    return None


def _deferred_patches(**extra):
    """Patch everything the endpoint touches outside the process, minus Soniox.

    ⚠️ `acquire_lock` / `release_lock` are patched for speed, not correctness: Redis
    is unreachable outside the VPC and every fail-open call costs ~4s, which is enough
    to turn these tests into timeouts and read as a code failure.
    """
    from unittest.mock import patch
    mocks = {
        'acquire_lock': patch('routers.audio_upload.acquire_lock', return_value=True),
        'release_lock': patch('routers.audio_upload.release_lock'),
        'dup': patch('routers.audio_upload.developer_data_db.get_conversation_id_by_source_started_at',
                     return_value=None),
        'upsert': patch('routers.audio_upload.developer_data_db.upsert_conversation_full'),
        'status': patch('routers.audio_upload.developer_data_db.update_conversation_status_dev'),
        'audio_path': patch('routers.audio_upload.developer_data_db.update_conversation_audio_path_dev'),
        'gcs': patch('routers.audio_upload.upload_conversation_recording'),
        'vad': patch('routers.audio_upload.vad_is_empty', return_value=False),
    }
    mocks.update(extra)
    return mocks


def test_defer_processing_answers_before_transcribing():
    """
    `defer_processing=true` must answer while Soniox is still running.

    This is the whole point of the flag, and it is the one thing no source-level
    assertion can see. Soniox is held on an `Event` so the ordering is *proved*
    rather than inferred from a timing measurement: if the response arrives while the
    transcription call is still blocked, the request genuinely did not wait for it.

    Also asserts the durability invariant — the audio is in GCS **before** the 200.
    The client deletes its only copy on a 200 (`watch_recording_service.dart` calls
    `markUploaded`), so answering early without a stored copy would turn any crash
    during background processing into a permanently lost recording.
    """
    try:
        import threading
        from fastapi.testclient import TestClient
        from unittest.mock import patch
        from main import app
        from models.transcript_segment import TranscriptSegment
        from utils.other import endpoints as auth
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__}: {e})")

    test_file = create_test_wav_file(duration_seconds=6.0)

    async def mock_get_current_user_context():
        return ('test_developer', 'test_user_123')

    app.dependency_overrides[auth.get_current_user_context] = mock_get_current_user_context

    soniox_entered = threading.Event()
    soniox_may_return = threading.Event()

    def blocking_soniox(path, **kwargs):
        soniox_entered.set()
        # Bounded so a broken run fails instead of hanging the suite forever.
        assert soniox_may_return.wait(timeout=30), "test never released the transcription"
        return ([TranscriptSegment(text='Hello', speaker='SPEAKER_00', is_user=False,
                                  person_id=None, start=0.0, end=2.0)], 'en')

    mocks = _deferred_patches()
    try:
        with patch('routers.audio_upload.soniox_transcribe_file', side_effect=blocking_soniox) as mock_stt, \
             mocks['acquire_lock'], mocks['release_lock'], mocks['dup'], mocks['upsert'], \
             mocks['status'], mocks['audio_path'], mocks['vad'], mocks['gcs'] as mock_gcs:

            client = TestClient(app)
            with open(test_file, 'rb') as f:
                response = client.post(
                    '/v1/conversations/upload-audio',
                    files={'file': ('test.wav', f, 'audio/wav')},
                    params={'language': 'en', 'auto_process': 'false',
                            'started_at': '2026-08-13T10:00:00Z',
                            'save_recording': 'true', 'defer_processing': 'true'},
                )

            assert response.status_code == 200, \
                f"Expected 200 (the app only accepts 200), got {response.status_code}: {response.text[:300]}"
            data = response.json()

            # The ordering proof: Soniox is inside the call and cannot have returned.
            assert soniox_entered.wait(timeout=10), "background transcription never started"
            assert not soniox_may_return.is_set(), "test bug: the gate was already open"
            assert mock_stt.call_count == 1, f"Soniox call count {mock_stt.call_count}"

            # Durability, checked at the moment the client was told it may delete.
            assert mock_gcs.called, \
                "audio was not parked in GCS before the 200 — an early answer without a " \
                "stored copy makes any background crash a permanently lost recording"

            assert data['conversation_id'], "No conversation_id returned"
            assert data['status'] == 'processing', \
                f"status must not claim completion before the transcript exists: {data['status']!r}"
            assert data['transcript_segments'] == [], \
                f"a deferred response cannot carry a transcript: {data['transcript_segments']}"
            assert data['duration_seconds'] > 5.0, \
                f"duration is known synchronously and must be reported: {data['duration_seconds']}"

            # Let the background finish inside the patch context — leaving it early
            # would drop the mocks and hand the real Soniox/GCS calls a live thread.
            soniox_may_return.set()
            thread = _deferred_thread()
            assert thread is not None, "no background thread was named upload-audio-*"
            thread.join(timeout=30)
            assert not thread.is_alive(), "background thread did not finish"

        print("✓ Deferred upload answered before transcription, with audio already stored:")
        print(f"  - conversation_id: {data['conversation_id']}")
        print(f"  - status: {data['status']}, duration: {data['duration_seconds']:.1f}s")
    finally:
        app.dependency_overrides.clear()
        os.unlink(test_file)


def test_defer_processing_still_rejects_undecodable_audio_synchronously():
    """
    A file ffmpeg cannot decode must still be a **synchronous** 400.

    The client treats 400 as permanent (`_isPermanentRejection`), moves the file to
    `rejected/` and stops retrying — and that is the only channel through which the
    user ever learns a recording could not be transcribed. Deferring this particular
    verdict would answer 200, let the phone delete the file, and leave the failure in
    CloudWatch only.

    Not hypothetical: 2026-08-16 two watch recordings (3867668 and 6446373 bytes,
    both with plausible byte counts) failed exactly here with ffmpeg's "Invalid data
    found when processing input".
    """
    try:
        import tempfile as _tempfile
        from fastapi.testclient import TestClient
        from unittest.mock import patch
        from main import app
        from utils.other import endpoints as auth
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__})")

    # An .m4a header that goes nowhere — same shape of failure as a missing `moov`.
    bad = _tempfile.NamedTemporaryFile(suffix='.m4a', delete=False)
    bad.write(b'\x00\x00\x00\x18ftypmp42' + os.urandom(4096))
    bad.close()

    async def mock_get_current_user_context():
        return ('test_developer', 'test_user_123')

    app.dependency_overrides[auth.get_current_user_context] = mock_get_current_user_context

    mocks = _deferred_patches()
    try:
        with mocks['acquire_lock'], mocks['release_lock'], mocks['dup'], mocks['gcs'] as mock_gcs, \
             patch('routers.audio_upload.soniox_transcribe_file') as mock_stt:

            client = TestClient(app)
            with open(bad.name, 'rb') as f:
                response = client.post(
                    '/v1/conversations/upload-audio',
                    files={'file': ('rec_corrupt.m4a', f, 'audio/m4a')},
                    params={'language': 'auto', 'auto_process': 'false',
                            'started_at': '2026-08-16T13:03:00Z',
                            'save_recording': 'true', 'defer_processing': 'true'},
                )

        assert response.status_code == 400, \
            f"An undecodable file must stay a permanent 400, got {response.status_code}: {response.text[:200]}"
        assert not mock_stt.called, "an undecodable file must never reach transcription"
        assert not mock_gcs.called, "an undecodable file must not be stored"

        print(f"✓ Undecodable audio still rejected synchronously: 400 {response.json().get('detail','')[:60]}")
    finally:
        app.dependency_overrides.clear()
        os.unlink(bad.name)


def test_defer_processing_requires_save_recording():
    """
    `defer_processing=true` without `save_recording=true` degrades to synchronous.

    Answering early is a promise that we hold a copy the work can be re-run from.
    With `save_recording=false` there is none, so the flag must be refused rather
    than honoured — the failure mode it would otherwise buy is a recording the client
    has deleted and the server never transcribed.
    """
    try:
        from fastapi.testclient import TestClient
        from unittest.mock import patch
        from main import app
        from models.transcript_segment import TranscriptSegment
        from utils.other import endpoints as auth
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__})")

    test_file = create_test_wav_file(duration_seconds=6.0)

    async def mock_get_current_user_context():
        return ('test_developer', 'test_user_123')

    app.dependency_overrides[auth.get_current_user_context] = mock_get_current_user_context

    segments = [TranscriptSegment(text='Hello', speaker='SPEAKER_00', is_user=False,
                                 person_id=None, start=0.0, end=2.0)]
    mocks = _deferred_patches()
    try:
        with patch('routers.audio_upload.soniox_transcribe_file', return_value=(segments, 'en')), \
             mocks['acquire_lock'], mocks['release_lock'], mocks['dup'], mocks['upsert'], \
             mocks['status'], mocks['audio_path'], mocks['vad'], mocks['gcs']:

            client = TestClient(app)
            with open(test_file, 'rb') as f:
                response = client.post(
                    '/v1/conversations/upload-audio',
                    files={'file': ('test.wav', f, 'audio/wav')},
                    params={'language': 'en', 'auto_process': 'false',
                            'started_at': '2026-08-13T11:00:00Z',
                            'save_recording': 'false', 'defer_processing': 'true'},
                )

        assert response.status_code == 200, f"Got {response.status_code}: {response.text[:200]}"
        data = response.json()
        assert len(data['transcript_segments']) == 1, \
            "without a stored copy the request must run synchronously and return the transcript, " \
            f"got {len(data['transcript_segments'])} segments and status {data['status']!r}"
        assert data['status'] == 'created', f"Expected the synchronous status, got {data['status']!r}"
        assert _deferred_thread() is None, "no background thread should have been spawned"

        print("✓ defer_processing without save_recording correctly fell back to synchronous")
    finally:
        app.dependency_overrides.clear()
        os.unlink(test_file)


def test_transcript_segment_processing():
    """Test Soniox token → segment grouping."""
    try:
        from utils.stt.pre_recorded import _soniox_tokens_to_segments
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__})")

    # Soniox token shape: start_ms / duration_ms / speaker / text. Note the leading
    # spaces — Soniox includes them, which is why the joiner does not add its own.
    mock_tokens = [
        {'text': 'Hello', 'start_ms': 500, 'duration_ms': 500, 'speaker': 0},
        {'text': ' how', 'start_ms': 1000, 'duration_ms': 500, 'speaker': 0},
        {'text': ' are', 'start_ms': 1500, 'duration_ms': 500, 'speaker': 0},
        {'text': ' you', 'start_ms': 2000, 'duration_ms': 500, 'speaker': 0},
        {'text': 'I', 'start_ms': 3000, 'duration_ms': 500, 'speaker': 1},
        {'text': ' am', 'start_ms': 3500, 'duration_ms': 500, 'speaker': 1},
        {'text': ' fine', 'start_ms': 4000, 'duration_ms': 500, 'speaker': 1},
    ]

    segments = _soniox_tokens_to_segments(mock_tokens)

    assert len(segments) == 2, f"Two speakers should give two segments, got {len(segments)}"
    assert segments[0]['speaker'] == 'SPEAKER_00', f"Got {segments[0]['speaker']}"
    assert segments[1]['speaker'] == 'SPEAKER_01', f"Got {segments[1]['speaker']}"

    # started_at is the recording's start, so leading silence belongs in segment
    # offsets. The full WAV is also used for playback and voiceprint cuts.
    assert segments[0]['start'] == 0.5, f"Leading silence lost: {segments[0]['start']}"

    # Word boundaries live inside the token text, so appending must use it raw. This
    # regressed once: stripping every token before concatenation produced
    # "Hellohowareyou". Chinese hid it (no inter-word spaces) and the only caller was
    # the SD-card path, which the shipping hardware cannot even use.
    assert segments[0]['text'] == 'Hello how are you', f"Word boundaries lost: {segments[0]['text']!r}"
    assert segments[1]['text'] == 'I am fine', f"Word boundaries lost: {segments[1]['text']!r}"

    for seg in segments:
        assert seg['text'], "Segment should have text"
        assert seg['start'] >= 0, "Start time should be >= 0"
        assert seg['end'] > seg['start'], "End time should be > start time"
        assert seg['is_user'] is False, "Cloud STT never sets is_user; voiceprint does it later"

    print(f"✓ Soniox token grouping passed:")
    print(f"  - Grouped {len(mock_tokens)} tokens into {len(segments)} segments")
    for seg in segments:
        print(f"  - [{seg['speaker']}] {seg['start']:.1f}s-{seg['end']:.1f}s: '{seg['text']}'")


def test_soniox_preserves_casing_and_spacing():
    """
    The token → TranscriptSegment conversion must not re-case or re-space the text.

    Fakes the four Soniox HTTP calls so this covers the whole conversion step without
    the network. It guards a fix rather than a hypothetical: the code used to end with
    `.strip().capitalize()`, and `str.capitalize()` lower-cases everything after the
    first character — so "I flew to Paris with John" arrived as "I flew to paris with
    john". stt-async-v5 already returns cased, punctuated text, and the live streaming
    path never re-cases it.
    """
    try:
        from unittest.mock import patch, MagicMock
        import utils.stt.pre_recorded as pre_recorded
    except Exception as e:
        raise Skipped(f"could not import module ({type(e).__name__})")

    tokens = [
        {'text': 'I', 'start_ms': 0, 'duration_ms': 200, 'speaker': 0, 'language': 'en'},
        {'text': ' flew', 'start_ms': 200, 'duration_ms': 300, 'speaker': 0, 'language': 'en'},
        {'text': ' to', 'start_ms': 500, 'duration_ms': 200, 'speaker': 0, 'language': 'en'},
        {'text': ' Paris', 'start_ms': 700, 'duration_ms': 400, 'speaker': 0, 'language': 'en'},
        {'text': ' with', 'start_ms': 1100, 'duration_ms': 300, 'speaker': 0, 'language': 'en'},
        {'text': ' John.', 'start_ms': 1400, 'duration_ms': 400, 'speaker': 0, 'language': 'en'},
    ]

    def fake_post(url, **kwargs):
        resp = MagicMock()
        if url.endswith('/files'):
            resp.status_code = 201
            resp.json.return_value = {'id': 'file-1'}
        else:
            resp.status_code = 201
            resp.json.return_value = {'id': 'txn-1'}
        return resp

    def fake_get(url, **kwargs):
        resp = MagicMock()
        resp.status_code = 200
        if url.endswith('/transcript'):
            resp.json.return_value = {'tokens': tokens}
        else:
            resp.json.return_value = {'status': 'completed'}
        return resp

    test_file = create_test_wav_file(duration_seconds=2.0)
    try:
        with patch.dict(os.environ, {'SONIOX_API_KEY': 'test-key'}), \
             patch.object(pre_recorded.http_requests, 'post', side_effect=fake_post), \
             patch.object(pre_recorded.http_requests, 'get', side_effect=fake_get), \
             patch.object(pre_recorded.http_requests, 'delete', return_value=MagicMock(status_code=200)):
            segments, language = pre_recorded.soniox_transcribe_file(test_file, raise_on_error=True)

        assert len(segments) == 1, f"Expected one segment (single speaker), got {len(segments)}"
        assert segments[0].text == 'I flew to Paris with John.', \
            f"Text was re-cased or re-spaced: {segments[0].text!r}"
        assert language == 'en', f"Expected 'en', got {language!r}"

        print(f"✓ Casing and spacing preserved:")
        print(f"  - text: {segments[0].text!r}")
    finally:
        os.unlink(test_file)


def run_all_tests():
    """Run all tests."""
    print("=" * 60)
    print("Audio Upload API Tests")
    print("=" * 60)
    print()

    tests = [
        ("Audio file validation", test_validate_audio_file),
        ("Short audio rejection", test_validate_audio_file_too_short),
        ("Audio conversion to 16kHz", test_convert_to_wav_16k),
        ("Soniox token grouping", test_transcript_segment_processing),
        ("Soniox preserves casing and spacing", test_soniox_preserves_casing_and_spacing),
        ("Soniox async integration", test_soniox_transcription_integration),
        ("Full upload flow (mock)", test_full_upload_flow_mock),
        ("Outage is not reported as empty audio", test_transcription_failure_is_not_reported_as_empty_audio),
        ("Deferred upload answers before transcribing", test_defer_processing_answers_before_transcribing),
        ("Deferred upload still rejects bad audio synchronously",
         test_defer_processing_still_rejects_undecodable_audio_synchronously),
        ("Deferred upload requires save_recording", test_defer_processing_requires_save_recording),
    ]

    passed = 0
    failed = 0
    skipped = 0

    for name, test_func in tests:
        print(f"\n--- {name} ---")
        try:
            test_func()
            passed += 1
        except Skipped as e:
            print(f"⚠ SKIPPED: {e}")
            skipped += 1
        except AssertionError as e:
            print(f"✗ FAILED: {e}")
            failed += 1
        except Exception as e:
            print(f"⚠ ERROR: {e}")
            failed += 1

    print()
    print("=" * 60)
    print(f"Results: {passed} passed, {failed} failed, {skipped} skipped")
    if skipped:
        # Loud on purpose: a skipped test is not a passing test, and the reason is
        # nearly always local environment rather than anything about the code.
        print(f"⚠ {skipped} test(s) did not run — the suite covered less than it looks like")
    print("=" * 60)

    return failed == 0


if __name__ == '__main__':
    # Change to backend directory
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

    success = run_all_tests()
    sys.exit(0 if success else 1)
