"""The consensus voiceprint: recordings earn their weight by agreeing with the rest.

Runs the real `_consensus_centroid` source (extracted from the Modal module's AST,
so neither torch nor the Modal runtime is needed) on synthetic embeddings whose
geometry follows what was measured on production audio (2026-11-04): a user's own
clips agree at cos≈0.6, other voices at ≈0.2, and an onboarding recording made on
another device agrees with today's clips at only ≈0.4.

Run:
    cd backend && python3 -m pytest tests/test_speaker_consensus_centroid.py
"""
import ast
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
MODAL_SRC = ROOT / 'modal' / 'speech_profile_modal_campplus.py'
D = 192


def l2(v):
    v = np.asarray(v, dtype=float)
    return v / max(float(np.linalg.norm(v)), 1e-12)


def cos(a, b):
    return float(np.dot(l2(a), l2(b)))


def weighted_centroid(vectors, weights):
    usable = [(v, w) for v, w in zip(vectors, weights) if w > 0]
    if not usable:
        return None
    return l2(sum(l2(v) * w for v, w in usable))


def load(screened_calls, printed):
    tree = ast.parse(MODAL_SRC.read_text())
    wanted = {'_consensus_centroid', '_clip_weight'}
    nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in wanted]
    assert len(nodes) == len(wanted)
    consts = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            if name in {'CONSENSUS_MIN_CLIPS', 'ANCHOR_PRIOR_CLIPS', 'CONSENSUS_TRUST_LO', 'CONSENSUS_TRUST_HI',
                        'CONSENSUS_ROUNDS', 'CLIP_AGREEMENT_MIN', 'WEIGHT_SATURATION_SECONDS',
                        'DROP_RATIO_WARN', 'DROP_RATIO_MIN_CLIPS'}:
                consts[name] = node.value

    def screened(anchor, clips, label):
        screened_calls.append(label)
        return l2(anchor)

    ns = dict(List=list, _l2_normalize=l2, _cosine_score=cos, _weighted_centroid=weighted_centroid,
              _screened_centroid=screened, print=lambda *a, **k: printed.append(' '.join(map(str, a))),
              os=__import__('os'))
    for name, value in consts.items():
        ns[name] = eval(compile(ast.Expression(value), str(MODAL_SRC), 'eval'), ns)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(MODAL_SRC), 'exec'), ns)
    return ns


@pytest.fixture
def env():
    calls, printed = [], []
    ns = load(calls, printed)
    return ns, calls, printed


rng = np.random.default_rng(7)


def around(center, agreement):
    """A unit vector at roughly `agreement` cosine from `center`."""
    noise = l2(rng.standard_normal(D))
    noise = l2(noise - np.dot(noise, center) * center)
    return l2(agreement * center + np.sqrt(1 - agreement ** 2) * noise)


VOICE = l2(rng.standard_normal(D))            # how the user sounds on the device they wear


def clips_of(center, n, agreement=0.78, seconds=10.0):
    # Two clips at 0.78 from the same voice agree with each other at ≈0.6.
    return [{'emb': around(center, agreement), 'seconds': seconds, 'name': f'c{i}'} for i in range(n)]


def strangers(n):
    return [{'emb': l2(rng.standard_normal(D)), 'seconds': 10.0, 'name': f'bad{i}'} for i in range(n)]


def test_few_clips_keep_the_anchor_pinned_centroid(env):
    ns, calls, _ = env
    anchor = around(VOICE, 0.7)
    ns['_consensus_centroid'](anchor, clips_of(VOICE, 2), 'user')
    assert calls == ['user']


def test_a_mismatched_anchor_no_longer_drags_the_profile(env):
    # 2026-11-04: an onboarding recording made on another device scored 0.28–0.55
    # against the user's own clips; pinned at half the weight it hid 56 of 127
    # of their sentences in one recording.
    ns, calls, _ = env
    anchor = around(VOICE, 0.45)
    clips = clips_of(VOICE, 8)
    consensus = ns['_consensus_centroid'](anchor, clips, 'user')
    pinned = weighted_centroid([anchor] + [c['emb'] for c in clips], [8.0] + [1.0] * 8)
    assert calls == []
    assert cos(consensus, VOICE) > cos(pinned, VOICE) + 0.05


def test_the_anchor_share_shrinks_as_labels_accumulate(env):
    ns, _, _ = env
    anchor = around(VOICE, 0.6)
    pulls = [cos(ns['_consensus_centroid'](anchor, clips_of(VOICE, n), 'user'), anchor) for n in (3, 8, 24)]
    assert pulls[0] > pulls[1] > pulls[2]


def test_bad_clips_fade_without_being_deleted(env):
    ns, _, printed = env
    anchor = around(VOICE, 0.6)
    good = clips_of(VOICE, 8)
    clean = ns['_consensus_centroid'](anchor, good, 'user')
    dirty = ns['_consensus_centroid'](anchor, good + strangers(4), 'user')
    assert cos(clean, dirty) > 0.99
    assert any('faded: bad0' in line for line in printed)
    # A plain average of the same clips is what the reweighting protects against.
    plain = weighted_centroid([anchor] + [c['emb'] for c in good + strangers(4)], [2.0] + [1.0] * 12)
    assert cos(clean, plain) < cos(clean, dirty)


def test_more_genuine_labels_shrink_what_a_bad_clip_can_do(env):
    ns, _, _ = env
    anchor = around(VOICE, 0.6)
    bad = strangers(3)

    def shift(n_good):
        good = clips_of(VOICE, n_good)
        return 1 - cos(ns['_consensus_centroid'](anchor, good, 'user'),
                       ns['_consensus_centroid'](anchor, good + bad, 'user'))
    assert shift(20) <= shift(4) + 1e-6


def test_a_consensus_of_someone_else_falls_back_to_the_anchor(env):
    # One voice tagged as the user over and over agrees with itself; the majority
    # is then the contamination and only the anchor is left to trust.
    ns, calls, printed = env
    anchor = around(VOICE, 0.95)
    other = l2(rng.standard_normal(D))
    ns['_consensus_centroid'](anchor, clips_of(other, 10, agreement=0.9), 'user')
    assert calls == ['user']
    assert any('PROFILE_HEALTH user' in line for line in printed)


def test_every_identity_reference_goes_through_the_consensus():
    tree = ast.parse(MODAL_SRC.read_text())
    ref = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_reference_embedding')
    called = {n.func.id for n in ast.walk(ref) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
    assert '_consensus_centroid' in called and '_screened_centroid' not in called


def test_people_recorded_on_the_same_device_are_not_dropped_as_contamination():
    # At the accept threshold the screen dropped the user's son and three
    # colleagues once the user's profile came from the device they wear, and every
    # sentence of theirs could then only match the user.
    src = MODAL_SRC.read_text()
    consts = {}
    for name in ('CONTAMINATION_MIN', 'SIMILARITY_THRESHOLD'):
        line = next(l for l in src.splitlines() if l.startswith(f'{name} = '))
        consts[name] = float(line.split("'")[-2])
    assert consts['CONTAMINATION_MIN'] >= 0.45 > consts['SIMILARITY_THRESHOLD']
    assert 'if contamination >= CONTAMINATION_MIN:' in src
