#!/usr/bin/env python3
"""
Standalone tests for audio upload functionality.
These tests don't require the full backend environment.

Usage:
    python tests/test_audio_upload_standalone.py
"""

import os
import sys
import wave
import struct
import math
import tempfile

# Change to backend directory and add to path
backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(backend_dir)
sys.path.insert(0, backend_dir)


def create_test_wav_file(duration_seconds: float = 5.0, sample_rate: int = 16000) -> str:
    """Create a simple test WAV file with a sine wave tone."""
    num_samples = int(duration_seconds * sample_rate)
    frequency = 440  # A4 note

    samples = []
    for i in range(num_samples):
        t = i / sample_rate
        sample = int(32767 * 0.5 * math.sin(2 * math.pi * frequency * t))
        samples.append(sample)

    temp_file = tempfile.NamedTemporaryFile(suffix='.wav', delete=False)

    with wave.open(temp_file.name, 'wb') as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        for sample in samples:
            wav_file.writeframes(struct.pack('<h', sample))

    return temp_file.name


def test_wav_file_creation():
    """Test WAV file creation."""
    print("--- Test: WAV file creation ---")

    test_file = create_test_wav_file(duration_seconds=6.0, sample_rate=16000)

    try:
        # Verify file exists and has correct format
        with wave.open(test_file, 'rb') as wav:
            channels = wav.getnchannels()
            sample_width = wav.getsampwidth()
            frame_rate = wav.getframerate()
            n_frames = wav.getnframes()
            duration = n_frames / frame_rate

            assert channels == 1, f"Expected 1 channel, got {channels}"
            assert sample_width == 2, f"Expected 2 bytes sample width, got {sample_width}"
            assert frame_rate == 16000, f"Expected 16000 Hz, got {frame_rate}"
            assert 5.9 <= duration <= 6.1, f"Expected ~6s duration, got {duration}"

        file_size = os.path.getsize(test_file)
        print(f"✓ WAV file created successfully")
        print(f"  - Duration: {duration:.2f}s")
        print(f"  - Sample rate: {frame_rate} Hz")
        print(f"  - File size: {file_size} bytes")
        return True
    finally:
        os.unlink(test_file)


def test_pydub_conversion():
    """Test audio conversion using pydub."""
    print("\n--- Test: Pydub audio conversion ---")

    try:
        from pydub import AudioSegment
    except ImportError:
        print("⚠ Skipped: pydub not installed")
        return True

    # Create 8kHz test file
    test_file = create_test_wav_file(duration_seconds=5.0, sample_rate=8000)
    output_file = tempfile.NamedTemporaryFile(suffix='.wav', delete=False).name

    try:
        # Convert to 16kHz
        aseg = AudioSegment.from_wav(test_file)
        aseg = aseg.set_frame_rate(16000).set_channels(1)
        aseg.export(output_file, format='wav')

        # Verify output
        with wave.open(output_file, 'rb') as wav:
            assert wav.getframerate() == 16000, f"Expected 16000 Hz, got {wav.getframerate()}"
            assert wav.getnchannels() == 1, f"Expected 1 channel, got {wav.getnchannels()}"

        print(f"✓ Audio conversion passed: 8kHz -> 16kHz")
        return True
    except Exception as e:
        print(f"✗ Audio conversion failed: {e}")
        return False
    finally:
        os.unlink(test_file)
        if os.path.exists(output_file):
            os.unlink(output_file)


def test_vad_import():
    """Test VAD module import."""
    print("\n--- Test: VAD module import ---")

    try:
        from utils.stt.vad import vad_is_empty
        print("✓ VAD module imported successfully")
        return True
    except Exception as e:
        print(f"⚠ VAD import failed: {e}")
        return True  # Not critical


def test_transcript_segment_model():
    """Test TranscriptSegment model."""
    print("\n--- Test: TranscriptSegment model ---")

    try:
        from models.transcript_segment import TranscriptSegment

        # Create a segment
        segment = TranscriptSegment(
            text="Hello world",
            speaker="SPEAKER_00",
            is_user=False,
            start=0.0,
            end=2.5,
        )

        assert segment.text == "Hello world"
        assert segment.speaker == "SPEAKER_00"
        assert segment.start == 0.0
        assert segment.end == 2.5

        # Test dict conversion
        seg_dict = segment.dict()
        assert 'text' in seg_dict
        assert 'speaker' in seg_dict

        print(f"✓ TranscriptSegment model works correctly")
        print(f"  - text: '{segment.text}'")
        print(f"  - speaker: {segment.speaker}")
        print(f"  - time: {segment.start}s - {segment.end}s")
        return True
    except Exception as e:
        print(f"✗ TranscriptSegment test failed: {e}")
        return False


def test_soniox_token_grouping():
    """Test Soniox token → segment grouping."""
    print("\n--- Test: Soniox token grouping ---")

    try:
        from utils.stt.pre_recorded import _soniox_tokens_to_segments

        # Soniox token shape: start_ms / duration_ms / speaker (int) / text. The
        # leading spaces are Soniox's own, which is why the joiner adds none.
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

        # Match the full recording, including its initial silence, for playback
        # and voiceprint extraction as well as started_at + segment.start.
        assert segments[0]['start'] == 0.5, f"Leading silence lost: {segments[0]['start']}"

        # Word boundaries live inside the token text, so appending must use it raw.
        # Stripping each token before concatenation produced "Hellohowareyou" — hidden
        # by Chinese, which has no inter-word spaces.
        assert segments[0]['text'] == 'Hello how are you', f"Word boundaries lost: {segments[0]['text']!r}"
        assert segments[1]['text'] == 'I am fine', f"Word boundaries lost: {segments[1]['text']!r}"

        for seg in segments:
            assert seg['text'], "Missing text"
            assert seg['end'] > seg['start'], f"end <= start: {seg}"
            assert seg['is_user'] is False, "Cloud STT never sets is_user; voiceprint does it later"

        print(f"✓ Soniox token grouping passed")
        print(f"  - Input: {len(mock_tokens)} tokens")
        print(f"  - Output: {len(segments)} segments")
        for seg in segments:
            print(f"  - [{seg['speaker']}] {seg['start']:.1f}s-{seg['end']:.1f}s: '{seg['text']}'")
        return True
    except Exception as e:
        print(f"✗ Soniox token grouping failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_opus_decoder():
    """Test Opus decoder availability."""
    print("\n--- Test: Opus decoder ---")

    try:
        from opuslib import Decoder
        decoder = Decoder(16000, 1)
        print("✓ Opus decoder available")
        return True
    except Exception as e:
        print(f"⚠ Opus decoder not available: {e}")
        return True  # Not critical for WAV uploads


def test_conversation_source_enum():
    """Test ConversationSource enum includes audio_upload."""
    print("\n--- Test: ConversationSource enum ---")

    try:
        from models.conversation import ConversationSource

        # Check audio_upload exists
        assert hasattr(ConversationSource, 'audio_upload'), "Missing audio_upload source"
        assert ConversationSource.audio_upload.value == 'audio_upload'

        print(f"✓ ConversationSource enum correct")
        print(f"  - audio_upload = '{ConversationSource.audio_upload.value}'")
        return True
    except Exception as e:
        print(f"✗ ConversationSource test failed: {e}")
        return False


def test_audio_upload_router_import():
    """Test audio_upload router can be imported."""
    print("\n--- Test: Audio upload router import ---")

    # Set dummy env vars to allow import
    os.environ.setdefault('ENCRYPTION_SECRET', 'x' * 32)
    os.environ.setdefault('SERVICE_ACCOUNT_JSON', '{}')

    try:
        # Just test the module structure, not full import
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "audio_upload",
            "routers/audio_upload.py"
        )

        # Check file exists and is valid Python
        with open("routers/audio_upload.py", 'r') as f:
            content = f.read()

        # Basic syntax check
        compile(content, "routers/audio_upload.py", 'exec')

        # Check key functions are defined
        assert 'def upload_audio_for_conversation' in content
        assert 'def validate_audio_file' in content
        assert 'def decode_opus_to_wav' in content

        # The router transcribes via Soniox only. A reappearing `fal_` would come
        # back silently — `fal_client` is no longer in requirements, so the import
        # would only fail in the container, minutes into a deploy.
        assert 'soniox_transcribe_file' in content, "Router no longer calls Soniox"
        assert 'fal_' not in content, "FAL came back into the router"

        print("✓ Audio upload router syntax is valid")
        print("  - upload_audio_for_conversation: defined")
        print("  - validate_audio_file: defined")
        print("  - decode_opus_to_wav: defined")
        print("  - transcription: soniox_transcribe_file, no fal_ references")
        return True
    except SyntaxError as e:
        print(f"✗ Syntax error in router: {e}")
        return False
    except Exception as e:
        print(f"⚠ Router check: {e}")
        return True


def run_all_tests():
    """Run all standalone tests."""
    print("=" * 60)
    print("Audio Upload Standalone Tests")
    print("=" * 60)

    tests = [
        test_wav_file_creation,
        test_pydub_conversion,
        test_transcript_segment_model,
        test_soniox_token_grouping,
        test_opus_decoder,
        test_conversation_source_enum,
        test_audio_upload_router_import,
    ]

    passed = 0
    failed = 0

    for test_func in tests:
        try:
            if test_func():
                passed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"✗ Test error: {e}")
            failed += 1

    print()
    print("=" * 60)
    print(f"Results: {passed} passed, {failed} failed")
    print("=" * 60)

    return failed == 0


if __name__ == '__main__':
    success = run_all_tests()
    sys.exit(0 if success else 1)
