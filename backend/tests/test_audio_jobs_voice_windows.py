"""Execute hosted decision code with real WAV slices and a deterministic encoder.

Load the actual function AST to avoid importing/deploying a Modal app or requiring
a GPU in CI. The embedding double stands in only for the neural model.
"""
import ast
import math
import os
import sys
from collections import defaultdict
from pathlib import Path
from types import SimpleNamespace

import pytest
from pydub import AudioSegment

from models.transcript_segment import TranscriptSegment
from utils.stt.recording_alignment import RecordingAlignmentUnavailable, segments_on_recording_axis


ROOT = Path(__file__).resolve().parents[1]


def functions(path, names, namespace):
    source = ast.parse((ROOT / path).read_text())
    selected = [node for node in source.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in names]
    assert len(selected) == len(names)
    for node in selected:
        node.decorator_list = []
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(path), 'exec'), namespace)
    return namespace


@pytest.fixture
def hosted(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / '_temp').mkdir()
    monkeypatch.setitem(sys.modules, 'torch', SimpleNamespace(cuda=SimpleNamespace(is_available=lambda: False)))

    def embedding(path):
        samples = AudioSegment.from_wav(path).get_array_of_samples()
        return sum(samples) / len(samples)

    def cosine(reference, value):
        if isinstance(value, str):
            return 0.1  # Independent user/person anchors, not contamination.
        winner = 'user' if value < 5000 else 'person'
        return 0.8 if reference == winner else 0.2

    return functions('modal/speech_profile_modal_campplus.py',
                     {'_local_parts', '_combine_local_matches', '_match_audio', '_segment_speaker_key',
                      '_decide', '_classify_local', 'classify_segments'},
                     dict(math=math, os=os, time=__import__('time'), defaultdict=defaultdict, AudioSegment=AudioSegment,
                          TranscriptSegment=TranscriptSegment, List=list, Optional=__import__('typing').Optional,
                          MIN_SEGMENT_DURATION=1, MIN_LOCAL_SEGMENT_SECONDS=2, MAX_SPEAKER_AUDIO_SECONDS=30,
                          LOCAL_CLASSIFICATION_BUDGET_SECONDS=600,
                          SIMILARITY_THRESHOLD=0.31, CONTAMINATION_MIN=0.5, SCORE_MARGIN=0.06, _init=lambda: None,
                          _get_embedding=embedding, _cosine_score=cosine,
                          _reference_embedding=lambda path, *args: path))


def pcm(marker, seconds):
    from array import array
    return AudioSegment(array('h', [marker]) * round(seconds * 1000), sample_width=2,
                        frame_rate=1000, channels=1)


def classify(hosted, tmp_path, audio, spans, scope='local'):
    path = tmp_path / 'synthetic.wav'
    audio.export(path, format='wav')
    segments = [TranscriptSegment(text='synthetic', is_user=False, start=s, end=e, speaker='SPEAKER_01')
                for s, e in spans]
    matches = hosted['classify_segments'](str(path), 'user', [{'id': 'person', 'path': 'person'}], segments,
                                          classification_scope=scope)
    assert not list((tmp_path / '_temp').iterdir()), 'Every encoding tempfile must be cleaned'
    return matches


def test_longest_sample_cannot_name_distant_speech_of_the_same_diarization_speaker(hosted, tmp_path):
    audio = pcm(1000, 18) + pcm(0, 82) + pcm(9000, 60)
    spans = [(0, 18), (100, 160)]
    legacy = classify(hosted, tmp_path, audio, spans, scope='speaker')
    assert [m['person_id'] for m in legacy] == ['person', 'person']  # Reproduce the bug.
    local = classify(hosted, tmp_path, audio, spans)
    assert [m['decision'] for m in local] == ['user', 'person']
    assert all(m['scope'] == 'local' for m in local)


def test_alternating_voices_under_one_diarization_label_each_keep_their_own_name(hosted, tmp_path):
    # 2026-10-31: diarization filed a father and son trading card-game lines under
    # one SPEAKER label. Pooling neighbouring sentences into one sample scored both
    # voices at once and named nobody; each sentence must be judged on its own audio.
    voices = [1000, 9000, 1000, 9000, 1000, 9000]
    audio = sum((pcm(marker, 3) for marker in voices[1:]), pcm(voices[0], 3))
    matches = classify(hosted, tmp_path, audio, [(3 * i, 3 * i + 3) for i in range(6)])
    assert [m['decision'] for m in matches] == ['user', 'person'] * 3


def test_a_long_mixed_segment_requires_agreement_through_its_tail(hosted, tmp_path):
    matches = classify(hosted, tmp_path, pcm(1000, 60) + pcm(9000, 20), [(0, 80)])
    assert matches[0]['decision'] == 'ambiguous'


def test_short_sentences_get_no_verdict(hosted, tmp_path):
    matches = classify(hosted, tmp_path, pcm(1000, 10), [(0, 1.5), (2, 3.9), (5, 7)])
    assert [m['decision'] for m in matches] == [None, None, 'user']


def test_sentences_are_never_pooled(hosted, tmp_path):
    seen = []
    match_audio = hosted['_match_audio']

    def spy(audio, *args):
        seen.append(audio.duration_seconds)
        return match_audio(audio, *args)
    hosted['_match_audio'] = spy
    classify(hosted, tmp_path, pcm(1000, 6), [(0, 2), (2, 4), (4, 6)])
    assert seen == pytest.approx([2, 2, 2])


def test_long_sentence_parts_are_bounded_and_cover_it(hosted):
    parts = hosted['_local_parts'](99.03, 179.03)
    assert sum(end - start for start, end in parts) == pytest.approx(80)
    assert all(end - start <= 30 + 1e-9 for start, end in parts)
    assert parts[0][0] == 99.03 and parts[-1][1] == pytest.approx(179.03)


def apply(segments, matches, protected=()):
    ns = functions('utils/stt/speech_profile.py', {'_speaker_key', '_split_local_speaker_labels', '_apply_speaker_matches'},
                   dict(defaultdict=defaultdict, List=list, Tuple=__import__('typing').Tuple,
                        MIN_DECIDED_SEGMENTS=2, SPLIT_MIN_SEGMENTS=3, SPLIT_MIN_SHARE=0.3))
    return ns['_apply_speaker_matches'](segments, matches, set(protected))


def match(decision, pid=None):
    return dict(scope='local', decision=decision, is_user=decision == 'user', person_id=pid)


def test_local_application_never_broadcasts_or_overrules_abstentions():
    segments = [dict(speaker_id=1, is_user=False, person_id='stale', speaker_assignment_source='auto') for _ in range(102)]
    _, updated = apply(segments, [match('user'), match('ambiguous')] + [match('person', 'other')] * 100)
    assert updated
    assert segments[0]['is_user'] and segments[0]['person_id'] is None
    assert not segments[1]['is_user'] and segments[1]['person_id'] is None
    assert segments[1]['speaker_status'] == 'ambiguous'
    assert segments[-1]['person_id'] == 'other'
    persisted = TranscriptSegment(text='synthetic', start=99.03, end=117.15, **segments[1])
    assert TranscriptSegment.model_validate_json(persisted.model_dump_json()).speaker_status == 'ambiguous'


def test_manual_tags_and_missing_model_results_are_preserved():
    segments = [dict(speaker_id=1, is_user=True, person_id=None),
                dict(speaker_id=2, is_user=False, person_id='manual')]
    assert not apply(segments, [match('unknown'), match('unknown')], {'SPEAKER_01', 'SPEAKER_02'})[1]
    assert segments[0]['is_user'] and segments[1]['person_id'] == 'manual'
    assert not apply(segments, [match(None)])[1]


def test_mixed_local_owners_get_collision_free_client_groups_and_stable_segment_ids():
    segments = [dict(id=f'row-{i}', speaker='SPEAKER_01', speaker_id=1, is_user=False,
                     person_id=None) for i in range(4)]
    segments.append(dict(id='existing', speaker='SPEAKER_09', speaker_id='9', is_user=False))
    apply(segments, [match('user'), match('person', 'synthetic'), match('unknown'), match(None)])
    assert [s['speaker_id'] for s in segments[:4]] == [10, 11, 1, 1]
    assert [s['id'] for s in segments[:4]] == [f'row-{i}' for i in range(4)]
    for s in segments[:4]:
        restored = TranscriptSegment(text='synthetic', start=0, end=8, **s)
        assert restored.speaker == f'SPEAKER_{restored.speaker_id:02d}'
    before = [dict(s) for s in segments]
    assert not apply(segments, [match('user'), match('person', 'synthetic'), match('unknown'), match(None)])[1]
    assert segments == before


def test_a_provider_failure_does_not_regroup_existing_mixed_labels():
    segments = [dict(speaker_id=1, is_user=True, speaker_assignment_source='auto'),
                dict(speaker_id=1, is_user=False, speaker_assignment_source='auto')]
    assert not apply(segments, [match(None), match(None)])[1]
    assert [s['speaker_id'] for s in segments] == [1, 1]


def test_encoding_failure_abstains_and_cleans_up(hosted, tmp_path):
    def fail(_):
        raise RuntimeError('synthetic encoder outage')
    hosted['_get_embedding'] = fail
    assert classify(hosted, tmp_path, pcm(1000, 8), [(0, 8)])[0]['decision'] is None


def test_budget_returns_finished_evidence_without_erasing_unchecked_tail(hosted, tmp_path):
    ticks = iter([0, 1])  # Deadline set, first sentence checked, then out of time.
    hosted['time'] = SimpleNamespace(monotonic=lambda: next(ticks, 601))
    matches = classify(hosted, tmp_path, pcm(1000, 18) + pcm(0, 82) + pcm(9000, 8), [(0, 18), (100, 108)])
    assert matches[0]['decision'] == 'user'
    assert matches[1]['decision'] is None
    segments = [dict(speaker_id=1, is_user=False, person_id='old', speaker_assignment_source='auto') for _ in matches]
    apply(segments, matches)
    assert segments[0]['is_user']
    assert segments[1]['person_id'] == 'old'


def test_a_long_segment_cannot_be_named_when_budget_skips_its_mixed_tail(hosted, tmp_path):
    ticks = iter([0, 1, 2])  # Check two user parts, then stop before the other voice.
    hosted['time'] = SimpleNamespace(monotonic=lambda: next(ticks, 601))
    matches = classify(hosted, tmp_path, pcm(1000, 60) + pcm(9000, 20), [(0, 80)])
    assert matches[0]['decision'] is None
    old = dict(speaker_id=1, is_user=False, person_id='old', speaker_assignment_source='auto')
    assert not apply([old], matches)[1]
    assert old['person_id'] == 'old'


def test_model_request_carries_only_what_the_model_reads():
    ns = functions('utils/stt/speech_profile.py', {'_segments_for_request'},
                   dict(List=list, _MODEL_SEGMENT_FIELDS=('start', 'end', 'speaker', 'speaker_id')))
    import json
    segment = dict(id='x', text='很长的一句话' * 20, speaker='SPEAKER_04', speaker_id=4, is_user=True,
                   person_id='p', start=1.0, end=3.5, translations=[{'lang': 'en', 'text': 'long'}],
                   original_start=1.0, original_end=3.5, timestamp_axis='audio', speaker_status='ambiguous')
    slim = ns['_segments_for_request']([segment] * 3387)
    assert slim[0] == dict(start=1.0, end=3.5, speaker='SPEAKER_04', speaker_id=4, text='', is_user=False)
    assert len(json.dumps(slim)) < 1024 * 1024
    TranscriptSegment(**slim[0])


def test_unprotected_manual_and_legacy_labels_are_also_preserved():
    segments = [dict(speaker_id=1, is_user=False, person_id='manual', speaker_assignment_source='manual'),
                dict(speaker_id=1, is_user=True, person_id=None),
                dict(speaker_id=1, is_user=False, person_id=None, speaker_assignment_source='manual')]
    assert not apply(segments, [match('unknown')] * 3)[1]
    assert segments[0]['person_id'] == 'manual' and segments[1]['is_user']


@pytest.mark.parametrize('kind', ['bulk', 'single', 'speaker'])
def test_actual_assignment_handlers_mark_manual_origin_and_clear_uncertainty(kind):
    import asyncio
    segment = dict(id='synthetic', speaker_id=1, is_user=False, person_id='auto-name',
                   speaker_status='ambiguous', speaker_assignment_source='auto')
    conversation = {'transcript_segments': [segment], 'started_at': '2026-10-27T00:00:00+00:00'}
    dirty_marks = []
    ns = functions('routers/developer_conversations.py',
                   {'assign_segments_bulk', 'set_assignee_conversation_segment', 'assign_speaker_to_segments'},
                   dict(Optional=__import__('typing').Optional, BulkAssignSegmentsRequest=object,
                        Query=lambda *args, **kw: None, Depends=lambda *_: None,
                        get_developer_id_from_api_key=lambda: 'synthetic',
                        dev_db=SimpleNamespace(get_conversation=lambda **_: conversation,
                                               update_conversation_segments_dev=lambda **_: True),
                        threading=SimpleNamespace(Thread=lambda **_: SimpleNamespace(start=lambda: None)),
                        collect_speech_samples_developer=lambda *_: None,
                        mark_timeline_day_dirty=lambda *args, **kwargs: dirty_marks.append((args, kwargs))))
    common = dict(conversation_id='synthetic', external_user_id='synthetic', developer_id='synthetic')
    if kind == 'bulk':
        coro = ns['assign_segments_bulk'](data=SimpleNamespace(segment_ids=['synthetic'],
                                          assign_type='is_user', value='true', source='manual'), **common)
    else:
        function = ns['set_assignee_conversation_segment' if kind == 'single' else 'assign_speaker_to_segments']
        index = {'segment_idx': 0} if kind == 'single' else {'speaker_id': 1}
        coro = function(assign_type='is_user', value='true', source='manual', **index, **common)
    asyncio.run(coro)
    assert dirty_marks == [(('synthetic', 'synthetic', conversation['started_at']), {'immediate': True})]
    assert segment['is_user'] and segment['person_id'] is None
    assert segment['speaker_assignment_source'] == 'manual'
    assert 'speaker_status' not in segment
    assert not apply([segment], [match('unknown')])[1]


@pytest.mark.parametrize('trimmed', [False, True])
@pytest.mark.parametrize('legacy', [False, True])
def test_real_backend_call_selects_scope_and_preserves_the_audio_axis(tmp_path, monkeypatch, trimmed, legacy):
    audio_path = tmp_path / 'audio.wav'
    pcm(1000, 40).export(audio_path, format='wav')
    profile_path = tmp_path / 'profile.wav'
    pcm(1000, 8).export(profile_path, format='wav')
    monkeypatch.setenv('HOSTED_SPEECH_PROFILE_API_URL', 'https://synthetic.invalid')
    monkeypatch.setenv('SPEECH_PROFILE_SERVICE_TOKEN', 'synthetic-service-token')
    monkeypatch.setitem(sys.modules, 'database.developer_speech_profile', SimpleNamespace(
        download_developer_profile_parts=lambda *_, **__: (str(profile_path), []),
        download_developer_people_for_identification=lambda *_, **__: []))
    monkeypatch.setitem(sys.modules, 'utils.other.storage', SimpleNamespace(
        get_conversation_recording_if_exists=lambda *_: str(audio_path),
        download_recording_from_path=lambda *_: str(audio_path)))
    captured = {}

    def post(url, **kwargs):
        captured.update(kwargs)
        result = match('user') if not trimmed else dict(is_user=True, person_id=None, decision='user')
        return SimpleNamespace(status_code=200, json=lambda: [result])

    ns = functions('utils/stt/speech_profile.py',
                   {'_speaker_key', '_split_local_speaker_labels', '_apply_speaker_matches', '_segments_for_request',
                    'identify_developer_speakers', 'speech_profile_service_headers'},
                   dict(defaultdict=defaultdict, List=list, Tuple=__import__('typing').Tuple,
                        Optional=__import__('typing').Optional, os=os, json=__import__('json'),
                        shutil=__import__('shutil'), uuid=__import__('uuid'),
                        requests=SimpleNamespace(post=post), MIN_DECIDED_SEGMENTS=2,
                        SPLIT_MIN_SEGMENTS=3, SPLIT_MIN_SHARE=0.3,
                        _MODEL_SEGMENT_FIELDS=('start', 'end', 'speaker', 'speaker_id'),
                        RecordingAlignmentUnavailable=RecordingAlignmentUnavailable,
                        segments_on_recording_axis=segments_on_recording_axis))
    segment = dict(text='synthetic', speaker_id=1, start=26.37, end=34.37, is_user=False,
                   timestamp_axis='audio')
    intervals = [(20, 40)] if trimmed else []
    if trimmed:
        segment.update(original_start=26.37, original_end=34.37, timestamp_axis='display', start=0, end=8)
    if legacy:
        for key in ('original_start', 'original_end', 'timestamp_axis'):
            segment.pop(key, None)
        segment.update(person_id='existing-auto', speaker_assignment_source='auto')
    result, updated = ns['identify_developer_speakers'](
        'synthetic', 'synthetic', 'synthetic', [segment], audio_kept_intervals=intervals,
        audio_wait_attempts=1, audio_gcs_path='synthetic/audio.wav')
    if legacy:
        assert not updated and not captured
        assert result[0]['person_id'] == 'existing-auto'
        assert not audio_path.exists() and not profile_path.exists()
        return
    assert updated and result[0]['is_user']
    assert captured['headers'] == {'X-Speech-Profile-Token': 'synthetic-service-token'}
    assert captured['allow_redirects'] is False
    assert captured['data']['classification_scope'] == ('speaker' if trimmed else 'local')
    assert captured['timeout'] == (120 if trimmed else 900)
    posted = __import__('json').loads(captured['data']['segments'])[0]
    assert posted['start'] == (6.37 if trimmed else 26.37)


def test_each_call_downloads_reference_audio_into_its_own_directory(tmp_path, monkeypatch):
    # Fixed per-user file names, deleted by whichever call finished first, made a concurrent
    # call lose samples mid-read (2026-11-05 backfill, four workers for one user).
    monkeypatch.chdir(tmp_path)
    audio_path = tmp_path / 'audio.wav'
    pcm(1000, 40).export(audio_path, format='wav')
    dirs = []

    def profile_parts(*_, temp_dir='_temp'):
        dirs.append(temp_dir)
        os.makedirs(temp_dir, exist_ok=True)
        anchor = os.path.join(temp_dir, 'synthetic_profile.wav')
        pcm(1000, 8).export(anchor, format='wav')
        return anchor, []

    def people(*_, temp_dir='_temp'):
        assert temp_dir == dirs[-1], 'people references must share the call\'s directory'
        return []

    monkeypatch.setenv('HOSTED_SPEECH_PROFILE_API_URL', 'https://synthetic.invalid')
    monkeypatch.setenv('SPEECH_PROFILE_SERVICE_TOKEN', 'synthetic-service-token')
    monkeypatch.setitem(sys.modules, 'database.developer_speech_profile', SimpleNamespace(
        download_developer_profile_parts=profile_parts, download_developer_people_for_identification=people))
    monkeypatch.setitem(sys.modules, 'utils.other.storage', SimpleNamespace(
        get_conversation_recording_if_exists=lambda *_: str(audio_path),
        download_recording_from_path=lambda *_: str(audio_path)))
    post = lambda url, **kwargs: SimpleNamespace(status_code=200, json=lambda: [match('user')])
    ns = functions('utils/stt/speech_profile.py',
                   {'_speaker_key', '_split_local_speaker_labels', '_apply_speaker_matches', '_segments_for_request',
                    'identify_developer_speakers'},
                   dict(defaultdict=defaultdict, List=list, Tuple=__import__('typing').Tuple,
                        Optional=__import__('typing').Optional, os=os, json=__import__('json'),
                        shutil=__import__('shutil'), uuid=__import__('uuid'),
                        requests=SimpleNamespace(post=post), MIN_DECIDED_SEGMENTS=2,
                        SPLIT_MIN_SEGMENTS=3, SPLIT_MIN_SHARE=0.3,
                        _MODEL_SEGMENT_FIELDS=('start', 'end', 'speaker', 'speaker_id'),
                        RecordingAlignmentUnavailable=RecordingAlignmentUnavailable,
                        segments_on_recording_axis=segments_on_recording_axis))
    for _ in range(2):
        segment = dict(text='synthetic', speaker_id=1, start=2.0, end=9.0, is_user=False, timestamp_axis='audio')
        ns['identify_developer_speakers']('d', 'u', 's', [segment], audio_kept_intervals=[],
                                          audio_wait_attempts=1, audio_gcs_path='synthetic/audio.wav')
    assert len(set(dirs)) == 2 and all(d.startswith(os.path.join('_temp', 'voiceprint_')) for d in dirs)
    assert not any(os.path.exists(d) for d in dirs), 'each call removes its own directory'
