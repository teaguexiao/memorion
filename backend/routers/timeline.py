"""Developer API — timeline chapters.

Two endpoints over the same projection:

* `GET /v1/timeline/{date}` — the shadow comparison from Phase 1. Computes
  chapters on the fly and returns them next to the current
  one-conversation-per-card view, so the two can be diffed on real data. Writes
  nothing.
* `GET /v1/timeline/{date}/chapters` — the served form from Phase 2. Reads the
  cached day (`timeline_days/{YYYY-MM-DD}`) and recomputes only when the day's
  conversations actually changed. This is what the app will call.

The chapter layer is a pure projection (`utils/timeline/chaptering`), so these
handlers are thin: fetch the day's conversations (`day_query`), run the boundary
function, and — because a chapter can merge several conversations — roll their
summaries up (`rollup`). Persistence, locking and debouncing live in
`utils/timeline/store`.

⚠️ No `response_model` on purpose. FastAPI silently drops fields a response model
doesn't declare (this codebase has been bitten repeatedly — see
`developer_users.py` `UserPreferencesResponse`), and the whole point of a shadow
endpoint is to expose every field of the comparison. Both return plain dicts.
"""

import logging
import uuid
from datetime import datetime
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field, model_validator

import database.developer_data as dev_db
import database.redis_db as redis_db
import database.timeline_edits as edits_db
from dependencies import get_developer_id_from_api_key
from utils.timeline.chaptering import ALGO_VERSION, segment_day_into_chapters
from utils.timeline.day_query import RECORDING_QUERY_VERSION, DayQueryLimitExceeded, _resolve_tz, get_day_conversations, parse_day
from utils.timeline.rollup import (ROLLUP_VERSION, RollupBudgetExceeded, prepare_rollup, summarize_chapter,
                                   validate_day_rollup_budget, resolve_summary_dependencies)
from utils.timeline.sources import chapter_fragments
from utils.llm.model_config import MODEL_CONFIG_VERSION
from utils.timeline.store import LOCK_TTL_SECONDS, TimelineLeaseUnavailable, day_lock_key, recompute_day, should_recompute_now
from utils.timeline.edits import apply_chapter_edits, chapter_edit_id

logger = logging.getLogger(__name__)

router = APIRouter()


def _iso(value: Any) -> Any:
    return value.isoformat() if isinstance(value, datetime) else value


def _structured_of(convo: dict) -> dict:
    return convo.get('structured') or {}


def _fragments_for(chapter: dict, by_id: Dict[str, dict]) -> List[dict]:
    return chapter_fragments(chapter, by_id)


def _present_chapter(chapter: dict, by_id: Dict[str, dict], language_hint: str, prepared_request=None) -> dict:
    fragments = prepared_request.usable if prepared_request else _fragments_for(chapter, by_id)
    summary = summarize_chapter(fragments, language_hint=language_hint, prepared_request=prepared_request) or {}
    return {
        'start': _iso(chapter['start']),
        'end': _iso(chapter['end']),
        'duration_seconds': chapter['duration_seconds'],
        'speech_seconds': chapter['speech_seconds'],
        'source_conversation_ids': chapter['source_conversation_ids'],
        'segment_refs': chapter['segment_refs'],
        'title': summary.get('title', ''),
        'overview': summary.get('overview', ''),
        'emoji': summary.get('emoji', '🧠'),
        'first_person_observation': summary.get('first_person_observation', ''),
        'speaker_display': summary.get('speaker_display'),
        # How the summary was produced — reused (single fragment), a real rollup,
        # or a degraded fallback. Lets the comparison count actual LLM cost.
        'rollup': summary.get('rollup', False),
    }


def _current_cards(convos: List[dict]) -> List[dict]:
    """The status-quo view: one card per non-discarded conversation."""
    cards = []
    for convo in convos:
        if convo.get('discarded'):
            continue
        structured = _structured_of(convo)
        cards.append({
            'conversation_id': convo.get('id'),
            'source': convo.get('source'),
            'started_at': _iso(convo.get('started_at')),
            'title': structured.get('title', ''),
        })
    return cards


@router.get("/v1/timeline/{date}", tags=["developer-api-timeline"])
def get_timeline_shadow(
    date: str,
    external_user_id: str = Query(..., description="External user identifier"),
    mode: str = Query('shadow', description="'shadow' returns the current vs chaptered comparison"),
    summarize: bool = Query(True, description="Roll up chapter titles/overviews (costs LLM calls)"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """Chapter a single local day. Read-only; nothing is persisted (Phase 1).

    `summarize=false` skips the rollup entirely (boundaries only, no LLM), which
    is the cheap path for eyeballing where cuts land.

    ⚠️ Sync `def` on purpose — same reason as `get_day_chapters` below. The default
    `summarize=true` runs one LLM rollup per chapter, so `async def` held the event
    loop for the whole day's worth of them.
    """
    try:
        day = parse_day(date)
    except ValueError:
        raise HTTPException(status_code=400, detail="date must be YYYY-MM-DD")

    tz = _resolve_tz(dev_db.get_user_timezone(developer_id, external_user_id))
    try:
        convos = get_day_conversations(dev_db, developer_id, external_user_id, day, tz=tz, require_complete=True)
    except DayQueryLimitExceeded as error:
        raise HTTPException(status_code=422, detail=str(error)) from error

    chapters = segment_day_into_chapters(convos, tz)
    by_id = {c.get('id'): c for c in convos}

    language_hint = ''  # rollup infers language from the fragments themselves
    if summarize:
        try:
            requests = [prepare_rollup(_fragments_for(ch, by_id), language_hint=language_hint) for ch in chapters]
            validate_day_rollup_budget(requests)
        except RollupBudgetExceeded as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
        presented = [_present_chapter(ch, by_id, language_hint, request) for ch, request in zip(chapters, requests)]
    else:
        presented = [
            {
                'start': _iso(ch['start']),
                'end': _iso(ch['end']),
                'duration_seconds': ch['duration_seconds'],
                'source_conversation_ids': ch['source_conversation_ids'],
            }
            for ch in chapters
        ]

    current = _current_cards(convos)
    return {
        # Normalized, not the raw path parameter: `strptime('%Y-%m-%d')` accepts
        # `2026-8-7` as well as `2026-08-07`, and Phase 2 keys a Firestore document
        # on this string (`timeline_days/{YYYY-MM-DD}`). Echoing the caller's
        # spelling would let one day produce two documents.
        'date': day.isoformat(),
        'timezone': getattr(tz, 'key', str(tz)),
        'mode': mode,
        'current_card_count': len(current),
        'chapter_count': len(presented),
        'current': current,
        'chapters': presented,
    }


def _serialize_day(document: Optional[Dict[str, Any]], day_str: str) -> Dict[str, Any]:
    """The stored day document as a response body — every field, nothing renamed.

    Datetimes are handed back as `datetime` objects on purpose. FastAPI's
    `jsonable_encoder` walks the whole structure and ISO-formats them at any
    depth, including the ones inside `chapters[].voice_runs[]`, and it handles
    Firestore's `DatetimeWithNanoseconds` (a `datetime` subclass) the same way.

    Converting them here by hand is a second, *partial* copy of that walk: a
    dict-comprehension over `.items()` only reaches the top level of each
    chapter, so every newly nested field needs its own special case or it slips
    through — and it slips through invisibly, because the encoder catches it
    anyway. The one thing that must not happen is bypassing the encoder (a
    hand-rolled `json.dumps`, or a `response_model`); that is pinned by
    `tests/test_timeline_endpoint_smoke.py`.
    """
    if not document:
        return {'date': day_str, 'chapters': [], 'chapter_count': 0,
                'source_conversation_ids': [], 'computed_at': None}
    return dict(document)


@router.get("/v1/timeline/{date}/chapters", tags=["developer-api-timeline"])
def get_day_chapters(
    date: str,
    external_user_id: str = Query(..., description="External user identifier"),
    refresh: bool = Query(False, description="Recompute now, ignoring the debounce window"),
    developer_id: str = Depends(get_developer_id_from_api_key),
    speaker_attribution: bool = Query(False),
):
    """One day's chapters, from cache when it is still valid.

    The cheap path — a cached day whose conversations have not changed since —
    reads the cached day and the current timezone, with no LLM call. Checking the
    timezone is intentional: a profile edit can change day membership even when
    no transcript was edited or marked dirty.

    When to recompute, in order:

    * nothing cached yet → compute (the user is looking at the day; there is no
      cheaper answer to give);
    * `refresh=true` → recompute, ignoring the debounce window. This is the
      pull-to-refresh path, and it still respects the per-day lock;
    * the day is marked dirty and has waited out the debounce window → recompute.

    A dirty day *inside* the window is served stale on purpose: another segment can
    still join the chapter within the merge gap, so recomputing now is work that
    would be redone. See `store.DEBOUNCE_MINUTES`.

    ⚠️ Sync `def` on purpose. Every path here blocks (Firestore reads, and on a miss
    a recompute that calls the LLM per merged chapter), so `async def` ran all of it
    on the event loop — and uvicorn serves this app as a single worker
    (`Dockerfile`), so one recompute stalled every other request on the same task.
    Measured: p50 356ms but p90 3.7s / max 18.3s (api_logs_daily, 2026-08-08..12),
    and the `GET /v1/conversations` right behind an 8.6s recompute took 1.2s instead
    of its usual 90ms. FastAPI runs a sync handler in its threadpool instead. The
    long note on `developer_conversations.process_conversation` has the full story.
    """
    try:
        day = parse_day(date)
    except ValueError:
        raise HTTPException(status_code=400, detail="date must be YYYY-MM-DD")

    day_str = day.isoformat()
    cached = dev_db.get_timeline_day(developer_id, external_user_id, day_str)
    dependencies = resolve_summary_dependencies()
    tz = _resolve_tz(dev_db.get_user_timezone(developer_id, external_user_id) or 'UTC')
    timezone_name = getattr(tz, 'key', str(tz))

    reason = None
    if refresh:
        reason = 'refresh'
    elif cached is None:
        reason = 'cold'
    elif cached.get('query_version') != RECORDING_QUERY_VERSION:
        # Old caches may have omitted recordings uploaded >36h later. Refresh
        # once on access, even if the old query already cleared the dirty marker.
        reason = 'query_version'
    elif (cached.get('rollup_version') != ROLLUP_VERSION
          or cached.get('algo_version') != ALGO_VERSION
          or cached.get('summary_fingerprint') != dependencies.fingerprint):
        reason = 'summary_version'
    elif cached.get('timezone') != timezone_name:
        reason = 'timezone'
    elif should_recompute_now(redis_db, developer_id, external_user_id, day):
        reason = 'dirty'

    if reason is None:
        return {**_edited_day(cached, day_str, developer_id, external_user_id, speaker_attribution is True), 'cache': 'hit'}

    try:
        result = recompute_day(
            dev_db, redis_db, developer_id, external_user_id, day,
            # Refresh bypasses debounce, while the fingerprint avoids repeat calls.
            force=False,
            dependencies=dependencies,
        )
    except (DayQueryLimitExceeded, RollupBudgetExceeded) as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    except dev_db.TimelineDocumentTooLarge as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    except TimelineLeaseUnavailable as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    document = result.get('document')
    if document is None and cached is not None:
        # `locked` with nothing stored yet — a concurrent first computation.
        document = cached
    # A correction can arrive while the current summary is being computed. Tell
    # mutation clients to retry rather than accepting that older projection.
    pending = result['status'] != 'locked' and should_recompute_now(redis_db, developer_id, external_user_id, day)
    return {**_edited_day(document, day_str, developer_id, external_user_id, speaker_attribution is True),
            'cache': 'pending' if pending else result['status'], 'cache_reason': reason}


def _edited_day(document, day_str, developer_id, external_user_id, attribution=False):
    document = _serialize_day(document, day_str)
    if not document.get('chapters'):
        return document
    edits = edits_db.get_chapter_edits(developer_id, external_user_id, day_str)
    # Recompute stores the small identity projection for manual prose. Cache
    # hits must not decompress every source recording just to render its owner.
    result = apply_chapter_edits(document, edits)
    people = _speaker_people(result['chapters'], developer_id, external_user_id)
    for chapter in result['chapters']:
        _speaker_names(chapter, developer_id, external_user_id, people)
        _speaker_response(chapter, attribution)
    return result


def _speaker_response(chapter, attribution):
    if not attribution:
        from utils.timeline.speakers import plain_overview
        chapter['overview'] = plain_overview(chapter)
        chapter.pop('speaker_display', None)
    return chapter


def _live_edited_chapter(chapter, edit, developer_id, external_user_id):
    # Editing and evidence endpoints must use the same current identities and
    # revision as GET, including tokens retained only in manually edited prose.
    source_ids = chapter.get('source_conversation_ids') or [] if edit.get('overview_speaker_display') else []
    sources = {cid: dev_db.get_conversation(developer_id, external_user_id, cid) or {} for cid in source_ids}
    return apply_chapter_edits({'chapters': [chapter]}, {chapter_edit_id(chapter): edit},
                               sources=sources if source_ids else None)['chapters'][0]


class ChapterEditRequest(BaseModel):
    start: datetime
    end: datetime
    source_conversation_ids: List[str] = Field(min_length=1, max_length=500)
    title: Optional[str] = Field(default=None, max_length=500)
    overview: Optional[str] = Field(default=None, max_length=100000)

    @model_validator(mode='after')
    def validate_edit(self):
        if self.start.tzinfo is None or self.end.tzinfo is None or self.end < self.start:
            raise ValueError('Valid timezone-aware chapter timestamps are required')
        if self.title is None and self.overview is None:
            raise ValueError('title or overview is required')
        for field in ('title', 'overview'):
            value = getattr(self, field)
            if value is not None:
                if not value.strip():
                    raise ValueError(f'{field} cannot be blank')
                setattr(self, field, value.strip())
        return self


@router.patch('/v1/timeline/{date}/chapters', tags=['developer-api-timeline'])
def edit_day_chapter(
    date: str,
    body: ChapterEditRequest,
    external_user_id: str = Query(..., description='External user identifier'),
    speaker_attribution: bool = Query(False),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """Correct the displayed Summary without rewriting a source conversation."""
    try:
        day_str = parse_day(date).isoformat()
    except ValueError:
        raise HTTPException(status_code=400, detail='date must be YYYY-MM-DD')
    # A recompute must not move the chapter between validating its selector and
    # saving the correction. It uses this same per-day lock.
    lock_key = day_lock_key(developer_id, external_user_id, day_str)
    owner = uuid.uuid4().hex
    try:
        acquired = redis_db.acquire_owned_lock(lock_key, owner, ttl_seconds=LOCK_TTL_SECONDS)
    except Exception as error:
        raise HTTPException(status_code=503, detail='Summary update unavailable; retry shortly') from error
    if not acquired:
        raise HTTPException(status_code=409, detail='Summary is updating; retry shortly')
    try:
        document = dev_db.get_timeline_day(developer_id, external_user_id, day_str)
        edit_id = chapter_edit_id(body.model_dump())
        chapter = next((ch for ch in (document or {}).get('chapters') or []
                        if chapter_edit_id(ch) == edit_id), None)
        if chapter is None:
            raise HTTPException(status_code=409, detail='Summary changed; refresh and retry')
        fields = {key: getattr(body, key) for key in ('title', 'overview') if getattr(body, key) is not None}
        if body.overview is not None:
            from utils.timeline.speakers import validate_overview_edit, present_speakers, restore_legacy_overview
            existing = edits_db.get_chapter_edits(developer_id, external_user_id, day_str).get(edit_id) or {}
            current = _live_edited_chapter(chapter, existing, developer_id, external_user_id)
            try:
                if speaker_attribution is not True:
                    _speaker_names(current, developer_id, external_user_id)
                    fields['overview'] = restore_legacy_overview(body.overview, current)
                validate_overview_edit(fields['overview'], current)
            except ValueError as error:
                raise HTTPException(422, str(error)) from error
            fields['overview_speaker_display'] = current.get('speaker_display')
        try:
            renewed = redis_db.renew_owned_lock(lock_key, owner, ttl_seconds=LOCK_TTL_SECONDS)
        except Exception as error:
            raise HTTPException(status_code=503, detail='Summary update unavailable; retry shortly') from error
        if not renewed:
            raise HTTPException(status_code=409, detail='Summary changed; refresh and retry')
        saved = edits_db.save_chapter_edit(developer_id, external_user_id, day_str, edit_id, fields)
        corrected = _live_edited_chapter(chapter, saved, developer_id, external_user_id)
        _speaker_names(corrected, developer_id, external_user_id)
        return {'date': day_str, 'chapter': _speaker_response(corrected, speaker_attribution is True)}
    finally:
        redis_db.release_owned_lock(lock_key, owner)


class SpeakerRequest(BaseModel):
    start: datetime
    end: datetime
    source_conversation_ids: List[str] = Field(min_length=1, max_length=500)
    revision: str = Field(min_length=1, max_length=128)
    speaker_id: str = Field(pattern=r'^s[a-f0-9]{16}$')

    @model_validator(mode='after')
    def validate_selector(self):
        if self.start.tzinfo is None or self.end.tzinfo is None or self.end < self.start:
            raise ValueError('Valid timezone-aware chapter timestamps are required')
        return self


class SpeakerCorrection(SpeakerRequest):
    operation_id: str = Field(pattern=r'^[a-zA-Z0-9_-]{16,64}$')
    person_id: Optional[str] = Field(default=None, min_length=1, max_length=128)
    is_user: bool = False
    name: Optional[str] = Field(default=None, min_length=1, max_length=80)
    new_person_name: Optional[str] = Field(default=None, min_length=1, max_length=80)
    undo: bool = False

    @model_validator(mode='after')
    def validate_target(self):
        if sum([bool(self.person_id), self.is_user, bool(self.name), bool(self.new_person_name)]) > 1:
            raise ValueError('Choose one identity')
        for field in ('name', 'new_person_name'):
            if getattr(self, field) is not None:
                setattr(self, field, getattr(self, field).strip())
                if not getattr(self, field):
                    raise ValueError('Name cannot be blank')
        return self


def _speaker_context(date, body, developer_id, external_user_id, *, check_revision=True, require_speaker=True):
    from utils.timeline.speakers import present_speakers
    try:
        day = parse_day(date).isoformat()
    except ValueError:
        raise HTTPException(400, 'date must be YYYY-MM-DD')
    document = dev_db.get_timeline_day(developer_id, external_user_id, day)
    edit_id = chapter_edit_id(body.model_dump())
    chapter = next((ch for ch in (document or {}).get('chapters', []) if chapter_edit_id(ch) == edit_id), None)
    if chapter is None:
        raise HTTPException(409, 'Chapter changed; refresh and retry')
    edit = edits_db.get_chapter_edits(developer_id, external_user_id, day).get(edit_id) or {}
    presented = _live_edited_chapter(chapter, edit, developer_id, external_user_id)
    if check_revision and presented['speaker_revision'] != body.revision:
        raise HTTPException(409, 'Chapter changed; refresh and retry')
    speaker = next((s for s in (presented.get('speaker_display') or {}).get('speakers', [])
                    if s['id'] == body.speaker_id), None)
    if speaker is None and require_speaker:
        raise HTTPException(409, 'Attribution changed; refresh and retry')
    return day, edit_id, chapter, edit, presented, speaker


def _speaker_evidence(chapter, speaker, developer_id, external_user_id):
    from utils.timeline.speakers import chapter_evidence
    by_id = {cid: dev_db.get_conversation(developer_id, external_user_id, cid) or {}
             for cid in chapter['source_conversation_ids']}
    if not chapter.get('segment_refs'):
        # Large day documents deliberately omit refs to stay below Firestore's
        # size limit. Rebuild this projection from its sources without generating
        # a summary or writing it back. Require the exact span AND source set:
        # one recording can contain multiple chapters, so using every segment in
        # the recording would allow an attribution to cross chapter boundaries.
        selector = chapter_edit_id(chapter)
        chapter = next((candidate for candidate in segment_day_into_chapters(list(by_id.values()))
                        if chapter_edit_id(candidate) == selector), None)
        if chapter is None:
            raise HTTPException(409, 'Source transcript changed; refresh and retry')
    evidence = chapter_evidence(chapter, by_id)
    selected = [evidence[eid] for eid in speaker['evidence_ids'] if eid in evidence]
    if len(selected) != len(speaker['evidence_ids']) or any(e['speaker_id'] != speaker['id'] for e in selected):
        raise HTTPException(409, 'Source transcript changed; refresh and retry')
    return selected, by_id


@router.post('/v1/timeline/{date}/chapters/speakers/evidence', tags=['developer-api-timeline'])
def get_chapter_speaker_evidence(date: str, body: SpeakerRequest, external_user_id: str = Query(...),
                                 developer_id: str = Depends(get_developer_id_from_api_key)):
    from utils.timeline.speaker_audio import evidence_audio
    _, _, chapter, _, _, speaker = _speaker_context(date, body, developer_id, external_user_id)
    evidence, by_id = _speaker_evidence(chapter, speaker, developer_id, external_user_id)
    # Audio availability is explicit; raw start/end are never used as a guess.
    for item in evidence:
        item['audio'] = evidence_audio(dev_db, developer_id, external_user_id,
                                      by_id[item['conversation_id']], item['index'])
    return {'evidence': evidence, 'revision': body.revision}


@router.patch('/v1/timeline/{date}/chapters/speakers', tags=['developer-api-timeline'])
def correct_chapter_speaker(date: str, body: SpeakerCorrection, external_user_id: str = Query(...),
                            developer_id: str = Depends(get_developer_id_from_api_key)):
    from utils.timeline.speakers import present_speakers
    try:
        day = parse_day(date).isoformat()
    except ValueError:
        raise HTTPException(400, 'date must be YYYY-MM-DD')
    key, owner = day_lock_key(developer_id, external_user_id, day), uuid.uuid4().hex
    if not redis_db.acquire_owned_lock(key, owner, ttl_seconds=LOCK_TTL_SECONDS):
        raise HTTPException(409, 'Chapter is updating; retry shortly')
    try:
        day, edit_id, chapter, edit, current, speaker = _speaker_context(
            date, body, developer_id, external_user_id, check_revision=False, require_speaker=not body.undo)
        last = edit.get('speaker_last_operation') or {}
        enrollments = _enrollment_receipts(edit)
        if last.get('enrollment_attempted') and not last.get('undone'):
            receipts = enrollments.setdefault(last['speaker_id'], [])
            if not any(r['id'] == last['id'] for r in receipts):
                receipts.append(_enrollment_receipt(last))
        # A lost response can be retried with the same ID without applying twice.
        if last.get('id') == body.operation_id and last.get('undone', False) == body.undo:
            if last.get('speaker_id') != body.speaker_id:
                raise HTTPException(409, 'Operation belongs to another speaker')
            return {'date': day, 'chapter': _speaker_names(current, developer_id, external_user_id)}
        overrides = dict(edit.get('speaker_overrides') or {})
        if body.undo:
            # Retraction follows the stored operation, not mutable transcript
            # hashes or the current summary's set of displayed people.
            if last.get('id') != body.operation_id or last.get('speaker_id') != body.speaker_id:
                raise HTTPException(409, 'A later edit prevents undo')
            if last.get('enrollment_attempted'):
                try:
                    _revoke_chapter_enrollment(developer_id, external_user_id, last)
                except Exception as error:
                    raise HTTPException(status_code=503, detail='Undo is incomplete; retry to remove the learned samples') from error
            overrides[body.speaker_id] = last.get('previous')
            enrollments[body.speaker_id] = [r for r in enrollments.get(body.speaker_id, [])
                                           if r['id'] != body.operation_id]
            last = {**last, 'undone': True}
        else:
            if current['speaker_revision'] != body.revision:
                raise HTTPException(409, 'Chapter changed; refresh and retry')
            _speaker_evidence(chapter, speaker, developer_id, external_user_id)
            name, person_id = body.name, body.person_id
            if body.new_person_name:
                person_id = str(uuid.uuid5(uuid.NAMESPACE_URL,
                    f'{developer_id}/{external_user_id}/{edit_id}/{body.speaker_id}/{body.operation_id}'))
                try:
                    person = dev_db.create_chapter_person(developer_id, external_user_id, person_id, body.new_person_name)
                except ValueError as error:
                    raise HTTPException(409, str(error)) from error
                name = person['name']
            elif person_id:
                person = dev_db.get_person(developer_id, external_user_id, person_id)
                if not person or person.get('deleted'):
                    raise HTTPException(422, 'Person unavailable')
                name = person.get('name')
            # Keep receipts per speaker so editing a different person cannot
            # orphan a learned sample. Reassignment retracts the prior sample
            # before committing the new identity; failed cleanup is retryable.
            previous_enrollment = enrollments.get(body.speaker_id, [])
            same_target = ((body.is_user and speaker.get('is_user')) or
                           (person_id and not speaker.get('is_user') and person_id == speaker.get('person_id')))
            if previous_enrollment and not same_target:
                try:
                    for receipt in previous_enrollment:
                        _revoke_chapter_enrollment(developer_id, external_user_id, receipt)
                except Exception as error:
                    raise HTTPException(503, 'Previous sample cleanup failed; retry shortly') from error
                enrollments.pop(body.speaker_id)
            override = {'person_id': person_id, 'is_user': body.is_user, 'name': name,
                        'status': 'confirmed' if body.is_user or person_id or name else 'unknown'}
            last = {'id': body.operation_id, 'speaker_id': body.speaker_id,
                    'previous': overrides.get(body.speaker_id), 'undone': False}
            overrides[body.speaker_id] = override
        if not redis_db.renew_owned_lock(key, owner, ttl_seconds=LOCK_TTL_SECONDS):
            raise HTTPException(409, 'Chapter changed; retry shortly')
        saved = edits_db.save_chapter_edit(developer_id, external_user_id, day, edit_id, {
            'speaker_overrides': overrides, 'speaker_last_operation': last,
            'speaker_enrollments': enrollments,
            'speaker_edit_sequence': edit.get('speaker_edit_sequence', 0) + 1})
        return {'date': day, 'chapter': _speaker_names(_live_edited_chapter(chapter, saved, developer_id, external_user_id), developer_id, external_user_id)}
    finally:
        redis_db.release_owned_lock(key, owner)


def _speaker_people(chapters, developer_id, external_user_id):
    # Resolve each referenced identity once per response, including archived
    # people whose names still belong on historical speech. No cross-user cache.
    ids = sorted({speaker['person_id'] for chapter in chapters
                  for speaker in (chapter.get('speaker_display') or {}).get('speakers', [])
                  if speaker.get('person_id')})
    return {person['id']: person for person in dev_db.get_people_by_ids(developer_id, external_user_id, ids)} if ids else {}


def _speaker_names(chapter, developer_id, external_user_id, people=None):
    if people is None:
        people = _speaker_people([chapter], developer_id, external_user_id)
    for speaker in (chapter.get('speaker_display') or {}).get('speakers', []):
        if speaker.get('person_id'):
            person = people.get(speaker['person_id'])
            speaker['name'] = (person or {}).get('name') or speaker.get('name')
    return chapter


class SpeakerEnrollment(SpeakerRequest):
    operation_id: str = Field(pattern=r'^[a-zA-Z0-9_-]{16,64}$')
    evidence_id: str = Field(pattern=r'^e[a-f0-9]{16}$')
    reviewed: bool = False


def _enrollment_receipt(operation):
    # Compact receipts do not recursively retain earlier edit history.
    return {k: operation[k] for k in ('id', 'enrollment_segments') if k in operation}


def _enrollment_receipts(edit):
    return {sid: ([_enrollment_receipt(value)] if isinstance(value, dict) else list(value))
            for sid, value in (edit.get('speaker_enrollments') or {}).items()}


def _revoke_chapter_enrollment(developer_id, external_user_id, operation):
    from database.developer_speech_profile import revoke_samples_from_segments
    from utils.speech_sample_collector import _correct_tracked_durations
    for cid, segment_ids in (operation.get('enrollment_segments') or {}).items():
        revoked = []
        try:
            revoke_samples_from_segments(developer_id, external_user_id, cid, segment_ids,
                reason='chapter_undo', chapter_operation_id=operation['id'], revoked_samples=revoked)
        finally:
            # Removed blobs disappear from the next retry's listing. Account
            # for successful removals even when a later storage operation fails.
            _correct_tracked_durations(developer_id, external_user_id, revoked)


@router.post('/v1/timeline/{date}/chapters/speakers/enroll', tags=['developer-api-timeline'])
def enroll_chapter_speaker(date: str, body: SpeakerEnrollment, external_user_id: str = Query(...),
                           developer_id: str = Depends(get_developer_id_from_api_key)):
    """Explicitly enroll ONLY the reviewed quotation, retaining undo provenance."""
    from utils.speech_sample_collector import collect_speech_samples_developer
    try:
        day = parse_day(date).isoformat()
    except ValueError:
        raise HTTPException(400, 'date must be YYYY-MM-DD')
    key, owner = day_lock_key(developer_id, external_user_id, day), uuid.uuid4().hex
    if not redis_db.acquire_owned_lock(key, owner, ttl_seconds=LOCK_TTL_SECONDS):
        raise HTTPException(409, 'Chapter is updating; retry shortly')
    try:
        day, edit_id, chapter, edit, current, speaker = _speaker_context(date, body, developer_id, external_user_id)
        last = edit.get('speaker_last_operation') or {}
        if (last.get('id') != body.operation_id or last.get('speaker_id') != body.speaker_id or last.get('undone')
                or speaker['status'] != 'confirmed' or not (speaker.get('person_id') or speaker.get('is_user'))):
            raise HTTPException(409, 'Confirm this speaker before enrolling')
        if last.get('enrollment_status'):
            return {'status': last['enrollment_status']}
        if not body.reviewed:
            return {'status': 'review_required'}
        evidence, by_id = _speaker_evidence(chapter, speaker, developer_id, external_user_id)
        selected = next((e for e in evidence if e['id'] == body.evidence_id), None)
        if selected is None or not selected.get('segment_id'):
            raise HTTPException(422, 'No verifiable speech segment')
        cid, ids = selected['conversation_id'], [selected['segment_id']]
        # A worker may have uploaded before losing its response. Revoke its
        # recorded selection before retrying (possibly with a different quote).
        if last.get('enrollment_attempted'):
            try:
                _revoke_chapter_enrollment(developer_id, external_user_id, last)
            except Exception:
                raise HTTPException(503, 'Previous sample cleanup failed; retry shortly')
        # Durable intent precedes upload: undo can retract even after a lost response.
        last.update(enrollment_attempted=True, enrollment_segments={cid: ids})
        enrollments = _enrollment_receipts(edit)
        retained = [r for r in enrollments.get(body.speaker_id, []) if r['id'] != body.operation_id]
        enrollments[body.speaker_id] = retained + [_enrollment_receipt(last)]
        edits_db.save_chapter_edit(developer_id, external_user_id, day, edit_id, {
            'speaker_last_operation': last, 'speaker_enrollments': enrollments})
        result = collect_speech_samples_developer(developer_id, external_user_id, by_id[cid], ids,
                 'is_user' if speaker.get('is_user') else 'person_id',
                 'true' if speaker.get('is_user') else speaker['person_id'],
                 chapter_operation_id=body.operation_id,
                 before_upload=lambda: redis_db.renew_owned_lock(key, owner, ttl_seconds=LOCK_TTL_SECONDS))
        if not redis_db.renew_owned_lock(key, owner, ttl_seconds=LOCK_TTL_SECONDS):
            _revoke_chapter_enrollment(developer_id, external_user_id, last)
            raise HTTPException(409, 'Chapter changed; sample withdrawn')
        status = (result or {}).get('status', 'not_eligible')
        if status in ('failed', 'stale'):
            _revoke_chapter_enrollment(developer_id, external_user_id, last)
            last['enrollment_attempted'] = False
        # Failed operations remain retryable; successful/no-quality outcomes are idempotent.
        if status not in ('failed', 'stale'):
            last['enrollment_status'] = status
        enrollments[body.speaker_id] = retained + ([_enrollment_receipt(last)]
                                                  if last.get('enrollment_attempted') else [])
        edits_db.save_chapter_edit(developer_id, external_user_id, day, edit_id, {
            'speaker_last_operation': last, 'speaker_enrollments': enrollments})
        return {'status': status}
    finally:
        redis_db.release_owned_lock(key, owner)
