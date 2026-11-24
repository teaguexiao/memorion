"""Evidence-backed chapter attribution. IDs are never inferred from display names.

The LLM copies a source token, e.g. [[speaker:e0123...]], at the point where it
attributes speech. The token addresses ONE source segment, whose identity comes
from the recognizer/manual annotation. Only tokens actually used in the body
produce header chips. Transcript copies stay out of the day/list cache.
"""

import re
from copy import deepcopy
from difflib import SequenceMatcher

from utils.timeline.summary_dependencies import digest

VERSION = 1
TOKEN = re.compile(r'\[\[speaker:(e[a-f0-9]{16})\]\]')
MARKUP_START = re.compile(r'\[\[\s*speaker\s*:', re.IGNORECASE)


class InvalidAttribution(ValueError):
    """Safe validation category; never contains transcript text or identities."""

# Attribution is sparse on purpose. The first version asked for a token on every
# substantive statement; a one-hour meeting then came back with ~100 tokens per
# batch (one per ~60 characters) and read like the transcript it summarized:
# "说话人 A 说明……说话人 B 补充……说话人 C 推测……". Every extra token is also one
# more 17-character random string the model must copy exactly — see
# `neutralize_references` for what that costs.
ATTRIBUTION_POLICY = '''
Chapter speaker attribution contract (applies to draft and final grounding):
Each transcript line has a literal [[speaker:...]] evidence token and identity
metadata. The notes are a summary, not a transcript: state most content
directly, without naming who said it, and never narrate the discussion turn by
turn ("A explained ... B added ... C confirmed ..."). Attribute only where who
said it matters to the reader:
- the device owner (identity=user): their views, decisions and commitments;
- an identified person (identity=person:...): their decisions, commitments, or
  a position that differs from others';
- an unidentified speaker: only a commitment or decision, or one side of a
  genuine disagreement that must stay distinct.
Explanations, questions, answers, confirmations and agreement need no
attribution. Attribute each speaker at most once per point. When you do
attribute, make the token the grammatical subject. Copy only the
[[speaker:...]] token itself, character for character, from a line that
supports the statement (never the speaker key or timestamp after it), and
never shorten, alter or invent a token. Do not merge a genuine disagreement
into a false consensus. A name mentioned INSIDE speech is not its speaker.
Never infer an identity from a name, role, proximity, or the word "you" in the
speech.
Tokens, not literal names/pronouns/roles, identify speakers in the overview;
the app resolves them to names, 'you', or stable neutral anonymous labels.
Only identity=user metadata supports the device owner's actions. Do not infer
roles from it. Do not assume the same raw speaker number across recordings or
conflicting segment identities is one person. Keep tokens only in overview,
not title or observation. Preserve useful detail and qualifications. This
contract overrides older instructions to remove speaker identifiers: tokens
are app markup, never user-facing raw ASR numbers. Background noise/filler need
no attribution. Do not add a person solely to populate the header.
'''


def evidence_id(cid, segment, index):
    # Including the text/timing makes stale evidence fail closed after a repair.
    return 'e' + digest([cid, segment.get('id'), index, segment.get('text'),
                         segment.get('start'), segment.get('end')])[:16]


def chapter_evidence(chapter, by_id):
    result, seen = {}, set()
    for ref in chapter.get('segment_refs') or []:
        cid, index = ref.get('conversation_id'), ref.get('index')
        if cid not in (chapter.get('source_conversation_ids') or []):
            continue
        segments = (by_id.get(cid) or {}).get('transcript_segments') or []
        if type(index) is not int or not 0 <= index < len(segments) or (cid, index) in seen:
            continue
        seen.add((cid, index))
        seg = segments[index]
        if not isinstance(seg, dict) or not (seg.get('text') or '').strip():
            continue
        eid = evidence_id(cid, seg, index)
        uncertain = seg.get('speaker_status') in ('unknown', 'ambiguous', 'conflict')
        user = bool(seg.get('is_user')) and not uncertain
        person = seg.get('person_id') if not user and not uncertain else None
        identity = ['user'] if user else ['person', person] if person else [
            'unknown', cid, seg.get('speaker_id') if seg.get('speaker_id') is not None else eid,
            seg.get('speaker_status')]
        sid = 's' + digest(identity)[:16]
        # Recognition protects legacy labels from overwrite because they MAY be
        # manual, not because their provenance is known. Missing provenance must
        # neither assert human confirmation nor claim a voice-model match.
        source_status = {'manual': 'confirmed', 'auto': 'matched'}.get(
            seg.get('speaker_assignment_source'), 'unverified')
        status = source_status if (
            user or person) else ('conflict' if seg.get('speaker_status') in ('ambiguous', 'conflict') else 'unknown')
        result[eid] = {'id': eid, 'speaker_id': sid, 'conversation_id': cid, 'index': index,
                       'segment_id': seg.get('id'), 'text': seg['text'],
                       'start': seg.get('start'), 'end': seg.get('end'),
                       'is_user': user, 'person_id': person, 'status': status}
    return result


def build_display(overview, evidence):
    """Validate references and retain only explicitly attributed speakers."""
    if MARKUP_START.search(TOKEN.sub('', overview or '')):
        raise InvalidAttribution('malformed_speaker_reference')
    used, speakers = {}, {}
    # Presentation ordinals must not enter reusable source/batch cache keys.
    # Anonymous speakers are lettered in reading order among those mentioned:
    # numbering them among every speaker in the evidence showed a summary that
    # attributes one of nine as a lone "说话人 H".
    anonymous = 0
    for match in TOKEN.finditer(overview or ''):
        eid = match[1]
        if eid not in evidence:
            raise InvalidAttribution('unknown_speaker_reference')
        item = evidence[eid]
        sid = item['speaker_id']
        used[eid] = sid
        if sid not in speakers:
            speakers[sid] = {k: item[k] for k in ('person_id', 'is_user', 'status')}
            if not item['is_user'] and not item['person_id']:
                anonymous += 1
            speakers[sid]['number'] = 0 if item['is_user'] or item['person_id'] else anonymous
            speakers[sid].update(id=sid, evidence_ids=[])
        speaker = speakers[sid]
        if item['status'] != 'confirmed' and speaker['status'] != 'unverified':
            speaker['status'] = item['status']
        if eid not in speaker['evidence_ids']:
            speaker['evidence_ids'].append(eid)
    return {'version': VERSION, 'speakers': list(speakers.values()), 'mentions': used}


# Any attempt at speaker markup. The start covers everything MARKUP_START does
# (so `build_display` cannot reject what is left) plus a single opening bracket
# and a full-width colon. A reference is either closed, however malformed
# (`[[speaker:e40?]]`, `[[speaker:eA, eB, …]]`, `[speaker: Alice]`), or cut off
# before its brackets (`[[speaker:e40 说明`), in which case only an `e…`
# identifier belongs to it, never the words after it.
_REFERENCE_START = r'\[\[?\s*speaker\s*[:：]'
# Source-line metadata (`sources.chapter_fragments` renders `[[speaker:e…]] S455108
# +1138.29s text`) a model may copy after a reference, in any order.
_LINE_TIME = r'(?:\+\d+(?:\.\d+)?s|\d{4}-\d{2}-\d{2}T[0-9:.+\-]+)'
# An unclosed identifier directly follows the colon, as every real token does,
# and holds a digit or '?'. A word after a space ("each", "e2e tests") or a
# bare name stays statement text.
_IDENTIFIER = r'[eE](?=[0-9a-fA-F?]*[0-9?])[0-9a-fA-F?]{0,40}'
_REFERENCE = re.compile(
    r'(?P<reference>' + _REFERENCE_START + r'(?:[^\[\]\n]{0,300}?\]{1,2}|(?:' + _IDENTIFIER + r')?))'
    r'(?P<metadata>(?:[ \t]*(?:S\d+|' + _LINE_TIME + r')(?![\w.]))*)', re.IGNORECASE)
_CLAUSE_START = '。！？!?；;：:，,、（(「“"\n'
_SENTENCE_START = '.!?\n'


def _copied_metadata(metadata):
    # A bare short key may be content ("S3"); a timestamp or a full key is not.
    return bool(re.search(_LINE_TIME + r'|S\d{6,}', metadata, re.IGNORECASE))


def _substitute_references(text, replace):
    """Run `replace(match)` on every reference, dropping copied line metadata."""
    def substitute(match):
        metadata = match['metadata']
        return replace(match) + ('' if _copied_metadata(metadata) else metadata)
    return _REFERENCE.sub(substitute, text or '')


def _prose_is_chinese(text):
    """Compare Han characters with Latin words, ignoring references.

    An English summary with a Chinese proper name still counts as English. A
    malformed reference is ignored too: the hex runs in one would otherwise
    outnumber the Han characters of a short Chinese sentence.
    """
    prose = _substitute_references(text, lambda match: '')
    return len(re.findall(r'[\u3400-\u9fff]', prose)) > len(re.findall(r'[A-Za-z]+', prose))


def _neutral_label(chinese):
    # The same words the app shows for a reference it cannot resolve.
    return '有人' if chinese else 'Someone'


def _neutral_label_at(match, chinese):
    """'有人' reads right only as a clause-initial subject; '向某人确认' needs '某人'."""
    before = match.string[:match.start()].rstrip(' \t')
    if chinese:
        return '有人' if not before or before[-1] in _CLAUSE_START else '某人'
    return 'Someone' if not before or before[-1] in _SENTENCE_START else 'someone'


def neutralize_references(text, allowed):
    """Replace every reference not backed by `allowed` evidence with a neutral person.

    Returns `(text, replaced)`. The model copies dozens of random 17-character
    tokens per batch and gets roughly 3% of them wrong — a dropped or extra
    character, or a placeholder such as `[[speaker:e40?]]` — so at ~100 tokens a
    batch nearly always contained one. Rejecting the batch for that slip used to
    replace its whole summary with the raw transcript (2026-10-27: 31 of 33 batch
    failures in two days, a 75,000-character chapter that was 91% transcript).

    Dropping one unverifiable attribution keeps the summary and never asserts an
    identity. Do not "repair" a mistyped token to its nearest valid one instead:
    only 4 of 9 measured slips were one edit away from a unique token, and a
    repair is a guess about who spoke.

    The speaker key and timestamp a model sometimes copies along with a
    reference are internal source metadata and are removed, not counted.
    """
    chinese = _prose_is_chinese(text)
    replaced = 0

    def replace(match):
        nonlocal replaced
        token = TOKEN.fullmatch(match['reference'])
        if token and token[1] in allowed:
            return match['reference']
        replaced += 1
        return _neutral_label_at(match, chinese)

    return _substitute_references(text, replace), replaced


def strip_references(text):
    """Remove all speaker markup, valid or not, from a field that must not carry it."""
    if not re.search(_REFERENCE_START, text or '', re.IGNORECASE):
        return text
    return re.sub(r'[ \t]{2,}', ' ', _substitute_references(text, lambda match: '')).strip()


def present_speakers(chapter, edit=None, evidence=None):
    """Overlay chapter-local identity edits, preserving tokens and manual prose."""
    edit = edit or {}
    result = deepcopy(chapter)
    for field in ('title', 'overview'):
        if field in edit:
            result[field] = edit[field]
    display = deepcopy(edit.get('overview_speaker_display') or result.get('speaker_display'))
    if evidence is not None and edit.get('overview_speaker_display'):
        # Manual prose retains evidence tokens even when a later AI summary no
        # longer quotes them. Refresh those identities from the source segments.
        current = deepcopy(evidence)
        overrides = edit.get('speaker_overrides') or {}
        for eid, sid in (display.get('mentions') or {}).items():
            if eid in current and overrides.get(sid):
                current[eid].update(overrides[sid])
                current[eid]['speaker_id'] = sid
        valid_tokens = ''.join(f'[[speaker:{eid}]]' for eid in TOKEN.findall(result.get('overview') or '')
                               if eid in current)
        display = build_display(valid_tokens, current)
    if display:
        result['speaker_display'] = display
    if display and display.get('version') == VERSION:
        ids = set(TOKEN.findall(result.get('overview') or ''))
        mentions = {eid: sid for eid, sid in display['mentions'].items() if eid in ids}
        display['mentions'] = mentions
        display['speakers'] = [s for s in display['speakers'] if s['id'] in mentions.values()]
        for speaker in display['speakers']:
            override = (edit.get('speaker_overrides') or {}).get(speaker['id'])
            if override:
                speaker.update(override)
            # Firestore maps have no stable iteration order across readers. This
            # list is part of the revision: identical evidence must hash alike.
            speaker['evidence_ids'] = sorted(e for e, sid in mentions.items() if sid == speaker['id'])
        # Known identities normally have ordinal zero. Reserve distinct fallback
        # labels as well: a deleted/unnamed person or an owner corrected to unknown
        # must not collide with the existing anonymous speaker A.
        next_number = max((s.get('number', 0) for s in display['speakers']), default=0) + 1
        for speaker in sorted(display['speakers'], key=lambda s: s['id']):
            if not speaker.get('is_user') and speaker.get('number', 0) < 1:
                speaker['number'] = next_number
                next_number += 1
        # This older field has no evidence references, so its ownership cannot
        # safely follow an identity edit. Undo restores the original observation.
        if any((edit.get('speaker_overrides') or {}).values()):
            result['first_person_observation'] = ''
            result['observation_stale'] = True
    result['speaker_revision'] = digest([chapter.get('overview'), result.get('speaker_display'),
                                          edit.get('overview'), edit.get('speaker_overrides'),
                                          edit.get('speaker_edit_sequence', 0)])
    return result


def validate_overview_edit(overview, chapter):
    allowed = (chapter.get('speaker_display') or {}).get('mentions') or {}
    if MARKUP_START.search(TOKEN.sub('', overview)) or any(eid not in allowed for eid in TOKEN.findall(overview)):
        raise ValueError('Cannot introduce unverified speaker references')


def _plain_parts(chapter):
    """Readable labels follow the summary language for clients without a locale.

    New clients localize explicitly. Legacy clients never sent their UI locale;
    compare Han characters with Latin words in the prose (excluding references)
    so an English summary with a Chinese proper name still gets English labels.
    """
    overview = chapter.get('overview') or ''
    chinese = _prose_is_chinese(overview)
    display = chapter.get('speaker_display') or {}
    speakers = {s['id']: s for s in display.get('speakers', [])}
    parts, spans, length, previous = [], [], 0, 0
    for match in TOKEN.finditer(overview):
        prefix = overview[previous:match.start()]
        parts.append(prefix)
        length += len(prefix)
        speaker = speakers.get(display.get('mentions', {}).get(match[1]), {})
        if speaker.get('is_user'):
            label = '你' if chinese else 'You'
        elif speaker.get('name'):
            label = speaker['name']
        elif speaker:
            number = max(1, speaker.get('number', 1))
            letters = ''
            while number:
                number, remainder = divmod(number - 1, 26)
                letters = chr(65 + remainder) + letters
            label = ('说话人 ' if chinese else 'Speaker ') + letters
        else:
            label = _neutral_label(chinese)
        parts.append(label)
        spans.append((length, length + len(label), match.group()))
        length += len(label)
        previous = match.end()
    parts.append(overview[previous:])
    return ''.join(parts), spans


def plain_overview(chapter):
    """Compatibility for clients without attribution markup support."""
    return _plain_parts(chapter)[0]


def restore_legacy_overview(overview, chapter):
    """Restore only labels preserved verbatim by a legacy prose edit.

    Do not infer identities by searching names in the edited text. If diff
    alignment cannot preserve every existing attribution, reject without a write
    so a legacy client cannot silently destroy the evidence links.
    """
    original, spans = _plain_parts(chapter)
    if not spans:
        return overview
    if original == overview:
        return chapter.get('overview') or ''
    blocks = SequenceMatcher(None, original, overview).get_matching_blocks()
    replacements = []
    block_index = 0
    for start, end, token in spans:
        while block_index < len(blocks) and blocks[block_index].a + blocks[block_index].size < end:
            block_index += 1
        if block_index >= len(blocks) or blocks[block_index].a > start:
            raise ValueError('Attribution changed; use the updated app to edit speaker-linked text')
        block = blocks[block_index]
        offset = block.b - block.a
        replacements.append((start + offset, end + offset, token))
    for start, end, token in reversed(replacements):
        overview = overview[:start] + token + overview[end:]
    return overview
