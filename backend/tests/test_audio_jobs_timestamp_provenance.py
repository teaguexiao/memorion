"""Keep file coordinates across persistence; reject unsafe legacy voice cuts."""
from copy import deepcopy
from types import SimpleNamespace
from typing import Optional

import pytest
from pydub import AudioSegment

from models.transcript_segment import TranscriptSegment
from utils.stt.pre_recorded import _soniox_tokens_to_segments
from utils.stt.timeline import UnknownTimestampAxis, conversation_segments, segments_on_audio_axis, stream_segment
from utils.stt.recording_alignment import RecordingAlignmentUnavailable, conversation_segments_on_wav
from test_audio_jobs_voice_windows import functions, pcm


@pytest.mark.parametrize('normalize', [False, True])
def test_optional_display_normalization_survives_models_without_changing_voice_cut(normalize):
    tokens = [dict(text='Synthetic', start_ms=99030, duration_ms=1000, speaker=1),
              dict(text=' words', start_ms=100030, duration_ms=2000, speaker=1)]
    row = _soniox_tokens_to_segments(tokens, normalize=normalize)[0]
    model = TranscriptSegment.model_validate_json(TranscriptSegment(**row).model_dump_json())
    assert model.original_start == 99.03 and model.original_end == 102.03
    assert model.timestamp_axis == ('display' if normalize else 'audio')
    aligned = segments_on_audio_axis([model.model_dump()], [], require_provenance=True)[0]
    assert (aligned['start'], aligned['end']) == (99.03, 102.03)


def test_stream_display_coordinates_survive_persistence_and_map_vad_once():
    row = stream_segment(dict(text='Synthetic', speaker_id=1, is_user=False, start=203.82, end=207.94), 203.82)
    model = TranscriptSegment.model_validate_json(TranscriptSegment(**row).model_dump_json())
    intervals = [(202.97, 204.58), (205.53, 207.94)]
    aligned = segments_on_audio_axis([model.model_dump()], intervals, require_provenance=True)
    assert (aligned[0]['start'], aligned[0]['end']) == (0.85, 4.02)
    assert segments_on_audio_axis(aligned, intervals, require_provenance=True) == aligned
    assert model.start == 0 and model.original_start == 203.82


def test_rebasing_known_file_coordinates_cannot_leave_a_false_audio_axis_marker():
    raw = _soniox_tokens_to_segments([dict(text='Synthetic', start_ms=99030, duration_ms=18120, speaker=1)])
    display = conversation_segments(raw)
    assert display[0]['start'] == 0 and display[0]['timestamp_axis'] == 'display'
    restored = TranscriptSegment.model_validate_json(TranscriptSegment(**display[0]).model_dump_json())
    aligned = segments_on_audio_axis([restored.model_dump()], [], require_provenance=True)
    assert (aligned[0]['start'], aligned[0]['end']) == (99.03, 117.15)
    assert raw[0]['start'] == 99.03 and raw[0]['timestamp_axis'] == 'audio'


@pytest.mark.parametrize('axis', [None, 'display'])
def test_unmarked_offline_legacy_coordinates_are_not_proof_of_audio_alignment(axis):
    rows = [dict(start=0, end=18, timestamp_axis=axis, is_user=True, speaker_assignment_source='manual')]
    before = deepcopy(rows)
    with pytest.raises(UnknownTimestampAxis):
        segments_on_audio_axis(rows, [], require_provenance=True)
    assert rows == before


@pytest.mark.parametrize('axis', ['audio', 'stream'])
def test_explicit_original_axis_without_display_rebasing_is_accepted(axis):
    row = dict(start=99.03, end=117.15, timestamp_axis=axis)
    assert segments_on_audio_axis([row], [], require_provenance=True)[0] == row


def segment(start, end, original_start=None, original_end=None, axis='display', text='Synthetic.'):
    return TranscriptSegment(text=text, speaker_id=1, is_user=False, start=start, end=end,
                             original_start=original_start, original_end=original_end, timestamp_axis=axis)


def test_combining_compatible_display_spans_extends_both_coordinate_ranges():
    rows, _ = TranscriptSegment.combine_segments(
        [segment(0, 4, 99, 103)], [segment(5, 8, 104, 107)])
    assert len(rows) == 1
    assert (rows[0].start, rows[0].end, rows[0].original_start, rows[0].original_end) == (0, 8, 99, 107)


@pytest.mark.parametrize('second', [segment(5, 8, 205, 208), segment(5, 8),
                                   segment(5, 8, 104, 107, axis='audio')])
def test_combining_incompatible_axes_never_invents_one_audio_span(second):
    rows, _ = TranscriptSegment.combine_segments([segment(0, 4, 99, 103)], [second.model_copy(deep=True)])
    assert len(rows) == 2
    assert rows[0].original_end == 103


def test_text_splits_and_display_delta_preserve_original_file_coordinates():
    source = segment(99, 109, 99, 109, axis='audio', text='hello. world')
    rows, _ = TranscriptSegment.combine_segments([], [source], delta_seconds=20)
    # The existing combiner may rejoin adjacent fragments. Every resulting range
    # still maps to the same original recording after the display offset.
    for row in rows:
        assert row.timestamp_axis == 'display'
        assert row.original_start == pytest.approx(row.start - 20)
        assert row.original_end == pytest.approx(row.end - 20)


def test_nonlinear_original_range_is_not_fabricated_when_text_is_split():
    rows, _ = TranscriptSegment.combine_segments([], [segment(0, 10, 99, 129, text='hello. world')])
    assert all(row.original_start is None and row.original_end is None for row in rows)
    with pytest.raises(UnknownTimestampAxis):
        segments_on_audio_axis([r.model_dump() for r in rows], [], require_provenance=True)


def test_display_delta_cannot_invent_original_coordinates_from_already_trimmed_audio():
    rows, _ = TranscriptSegment.combine_segments([], [segment(0.85, 4.02, axis='audio')], delta_seconds=20)
    assert rows[0].timestamp_axis == 'display' and rows[0].original_start is None
    with pytest.raises(UnknownTimestampAxis):
        segments_on_audio_axis([r.model_dump() for r in rows], [(202.97, 204.58), (205.53, 207.94)], require_provenance=True)


def test_actual_sd_sync_merge_drops_file_local_provenance_on_the_combined_timeline():
    from datetime import datetime, timezone
    stored = []
    ns = functions('routers/sync.py', {'_merge_into_existing'},
                   dict(List=list, TranscriptSegment=TranscriptSegment,
                        dev_db=SimpleNamespace(update_conversation_segments_dev=lambda *a: stored.append(a[-1]))))
    raw = segment(99.03, 117.15, 99.03, 117.15, axis='audio')
    anchor = datetime(2026, 1, 1, tzinfo=timezone.utc)
    ns['_merge_into_existing']('synthetic', 'synthetic', dict(id='synthetic', started_at=anchor),
                               [raw], int(anchor.timestamp()) + 60, {'updated_memories': set()}, set())
    assert stored[0][0]['start'] == pytest.approx(159.03)
    assert stored[0][0]['timestamp_axis'] == 'display'
    assert 'original_start' not in stored[0][0] and 'original_end' not in stored[0][0]
    with pytest.raises(UnknownTimestampAxis):
        segments_on_audio_axis(stored[0], [], require_provenance=True)
    assert raw.start == 99.03 and raw.original_start == 99.03


def test_actual_manual_sample_collector_refuses_unproven_uploads_before_cutting_or_enrolling(tmp_path):
    audio_path = tmp_path / 'legacy.wav'
    pcm(1000, 18).export(audio_path, format='wav')
    calls = []
    def forbidden(*args, **kwargs):
        raise AssertionError('Legacy audio must not be cut or enrolled')
    def discard(path):
        calls.append('discard')
        __import__('os').remove(path)
    ns = functions('utils/speech_sample_collector.py', {'collect_speech_samples_developer'},
                   dict(List=list, Optional=Optional, AudioSegment=AudioSegment, UnknownTimestampAxis=UnknownTimestampAxis,
                        segments_on_audio_axis=segments_on_audio_axis,
                        RecordingAlignmentUnavailable=RecordingAlignmentUnavailable,
                        conversation_segments_on_wav=conversation_segments_on_wav,
                        dev_profile_db=SimpleNamespace(revoke_samples_from_segments=lambda *a, **kw: {}),
                        _correct_tracked_durations=lambda *a: None, _session_for_conversation=lambda *a: {},
                        _inflation_refusal=lambda *a: None, download_recording_from_path=lambda *a: str(audio_path),
                        _discard_paths=discard, _extract_clips_from_segments=forbidden,
                        upload_developer_sample=forbidden))
    row = dict(id='synthetic', start=0, end=18, is_user=True, speaker_assignment_source='manual')
    conversation = dict(id='synthetic', source='audio_upload', audio_path='synthetic.wav', transcript_segments=[row])
    before = deepcopy(conversation)
    ns['collect_speech_samples_developer']('synthetic', 'synthetic', conversation, ['synthetic'], 'is_user', 'true')
    assert calls == ['discard'] and not audio_path.exists()
    assert conversation == before
