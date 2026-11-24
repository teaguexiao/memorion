"""Measured audio axis for legacy uploads: accepted only when many unique sentences agree."""
import importlib.util
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('repair', ROOT / 'scripts' / 'repair_upload_timestamp_axis.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)

import database  # noqa: E402,F401
from utils.stt.recording_alignment import RecordingAlignmentUnavailable, segments_on_recording_axis  # noqa: E402


def transcript(n, shift=0.0, jitter=0.0):
    return [{'id': f'g{i}', 'text': f'第{i}句话说得很清楚', 'start': i * 5.0 + shift + (jitter if i % 2 else -jitter),
             'end': i * 5.0 + 3 + shift, 'speaker': 'SPEAKER_01', 'is_user': False} for i in range(n)]


def test_a_consistent_offset_is_measured():
    offset, matches, spread = repair.measure_offset(transcript(40), transcript(40, shift=12.4, jitter=0.1))
    assert offset == pytest.approx(12.4, abs=0.11) and matches == 40 and spread <= repair.MAX_SPREAD


def test_too_few_or_inconsistent_matches_are_not_trusted():
    assert repair.measure_offset(transcript(10), transcript(10, shift=3))[0] is None
    noisy = transcript(40, shift=3)
    for i, seg in enumerate(noisy):
        seg['start'] += (i % 7) * 0.4
    assert repair.measure_offset(transcript(40), noisy)[0] is None


def test_repeated_and_short_sentences_never_vote():
    stored, fresh = transcript(30), transcript(30, shift=5)
    for seg in stored + fresh:
        if seg['id'] in ('g0', 'g1'):
            seg['text'] = '嗯'
    stored[2]['text'] = stored[3]['text'] = fresh[2]['text'] = fresh[3]['text'] = '对对对对对'
    offset, matches, _ = repair.measure_offset(stored, fresh)
    assert matches == 26 and offset == pytest.approx(5)


def test_repaired_segments_pass_production_alignment_on_the_audio_axis():
    legacy = transcript(5)
    with pytest.raises(RecordingAlignmentUnavailable):
        segments_on_recording_axis('d', 'u', 's', legacy, [])
    repaired = repair.with_audio_axis(legacy, 7.25)
    aligned, _ = segments_on_recording_axis('d', 'u', 's', repaired, [])
    assert [s['start'] for s in aligned] == [s['start'] + 7.25 for s in legacy]
    assert [s['start'] for s in repaired] == [s['start'] for s in legacy], 'displayed times are kept'


class FakeDB:
    def __init__(self, segments):
        self.segments = [dict(s) for s in segments]
        self.writes = 0

    def get_conversation(self, dev, uid, cid):
        return {'id': cid, 'transcript_segments': [dict(s) for s in self.segments]}

    def set_conversation_transcript_segments(self, dev, uid, cid, segments):
        self.segments = [dict(s) for s in segments]
        self.writes += 1


def test_apply_restore_round_trip_and_refuse_changed(tmp_path, monkeypatch):
    legacy = transcript(5)
    entry = {'conversation_id': 'c1', 'before': repair.axis_labels(legacy),
             'after': repair.axis_labels(repair.with_audio_axis(legacy, 2.0))}
    path = tmp_path / 'plan.json'
    path.write_text(json.dumps({'developer_id': 'd', 'uid': 'u', 'conversations': [entry, {'conversation_id': 'x', 'error': 'e'}]}))
    db = FakeDB(legacy)
    monkeypatch.setitem(sys.modules, 'database.developer_data', db)
    monkeypatch.setattr(sys.modules['database'], 'developer_data', db, raising=False)
    repair.write_side(path, 'before', 'after')
    assert db.writes == 1 and db.segments[0]['original_start'] == 2.0 and db.segments[0]['timestamp_axis'] == 'display'
    repair.write_side(path, 'after', 'before')
    assert db.segments == legacy and db.writes == 2
    db.segments[0]['text'] = 'changed'  # text is not part of the plan, so this still applies
    db.segments[0]['start'] = 99.0      # a timing change since the plan is refused
    repair.write_side(path, 'before', 'after')
    assert db.writes == 2


def test_a_deleted_conversation_is_skipped_not_fatal(tmp_path, monkeypatch, capsys):
    legacy = transcript(3)
    entries = [{'conversation_id': cid, 'before': repair.axis_labels(legacy),
                'after': repair.axis_labels(repair.with_audio_axis(legacy, 1.0))} for cid in ('gone', 'c1')]
    path = tmp_path / 'plan.json'
    path.write_text(json.dumps({'developer_id': 'd', 'uid': 'u', 'conversations': entries}))
    db = FakeDB(legacy)
    real = db.get_conversation
    db.get_conversation = lambda dev, uid, cid: None if cid == 'gone' else real(dev, uid, cid)
    monkeypatch.setitem(sys.modules, 'database.developer_data', db)
    monkeypatch.setattr(sys.modules['database'], 'developer_data', db, raising=False)
    repair.write_side(path, 'before', 'after')
    assert db.writes == 1 and 'no longer exists' in capsys.readouterr().out
