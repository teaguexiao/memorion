"""Persisting a day's chapters, and deciding when not to.

`chaptering` computes chapters and `rollup` names them; this module is what makes
that affordable to serve. Recomputing a day from scratch costs one Firestore query
plus one LLM call per merged chapter, so the app cannot call it per screen refresh
and a batch sync landing 480 files cannot trigger it 480 times.

Three mechanisms, each closing a different hole:

**Idempotent overwrite** — the day is one document keyed by its own date, rebuilt
whole. Chapters are a projection, so there is nothing to migrate and nothing to
append to: a stale chapter must vanish, not accumulate next to its replacement.

**A fingerprint** — recompute reads the day's conversations either way (that query
is cheap), then compares a fingerprint of what it read against the stored one. Equal
means the expensive half is skipped and the existing chapter summaries are kept
verbatim. This is what makes "the app asks for today's timeline on every launch"
free, and it is also why `ALGO_VERSION` and `ROLLUP_VERSION` are part of the
fingerprint: a threshold or prompt change must invalidate every cached day, or the
improvement never reaches historical data.

**A per-day lock plus a debounce window** — see `recompute_day` and
`should_recompute_now`. Both exist because of batch sync, where a single request
finishes dozens of conversations for the same day within seconds.

⚠️ The debounce window must stay *larger* than `chaptering.GAP_MERGE_MINUTES`.
A window shorter than the merge threshold guarantees wasted work: a recompute fires,
another segment lands inside the merge gap, and the chapter it produced was never
final. See `DEBOUNCE_MINUTES`.
"""

import hashlib
import json
import logging
import threading
import time
import uuid
from datetime import date as date_cls, datetime, timezone
from typing import Any, Dict, List, Optional, Sequence, Tuple

from utils.timeline.chaptering import ALGO_VERSION, segment_day_into_chapters
from utils.timeline.day_query import RECORDING_QUERY_VERSION
from utils.timeline.batch_cache import BatchCache
from utils.timeline.rollup import (ROLLUP_VERSION, prepare_rollup, run_rollup, summarize_chapter,
                                   validate_day_rollup_budget, resolve_summary_dependencies)
from utils.timeline.sources import chapter_fragments
from utils.llm.model_config import MODEL_CONFIG_VERSION

logger = logging.getLogger(__name__)

# How long to wait after a conversation lands before recomputing its day.
#
# Must exceed `chaptering.GAP_MERGE_MINUTES` (8): inside that gap another segment
# can still join the chapter we just computed, so recomputing earlier is work that
# is guaranteed to be redone. 10 minutes leaves margin without making a finished
# day feel stale — and note this only delays the *cache*; a client asking for a day
# explicitly can always force a recompute.
DEBOUNCE_MINUTES = 10

# Renew while work runs; a crashed process releases its lease through expiry.
LOCK_TTL_SECONDS = 300
LOCK_RENEW_SECONDS = 60


class TimelineLeaseUnavailable(RuntimeError):
    """Ownership cannot be verified; a derived summary must not be written."""

# How long a pending-recompute marker lives. Comfortably past the debounce window
# so the marker survives until it is due, but not forever: a marker that outlives
# its usefulness would make a long-idle day look permanently dirty.
DIRTY_TTL_SECONDS = 60 * 60 * 6


def day_lock_key(developer_id: str, external_user_id: str, day: str) -> str:
    """The one place this key is spelled.

    Written once for the same reason the listen-session lock key is
    (`developer_conversations.listen_session_lock_key`): a lock whose key is
    assembled at two call sites is two locks, and the failure is silent — both
    holders think they are exclusive.
    """
    return f'timeline_day:{developer_id}:{external_user_id}:{day}'


def dirty_marker_key(developer_id: str, external_user_id: str, day: str) -> str:
    return f'timeline_dirty:{developer_id}:{external_user_id}:{day}'


def _iso(value: Any) -> Any:
    return value.isoformat() if isinstance(value, datetime) else value


def _conversation_fingerprint(convo: Dict[str, Any]) -> List[Any]:
    """The parts of a conversation that can change its chapters.

    Deliberately narrow. `updated_at` is *not* in here even though it would be the
    obvious choice: it moves on unrelated writes such as confirmed action items.
    Speaker labels now enter source-grounded summaries, so they must invalidate
    them when corrected.

    Segment text is included via a hash rather than verbatim — text is what the
    rollup summarizes, so an edited transcript must invalidate the summary, but the
    fingerprint has to stay small enough to store.
    """
    segments = convo.get('transcript_segments') or []
    spans: List[Any] = []
    hasher = hashlib.sha256()
    for seg in segments:
        if not isinstance(seg, dict):
            continue
        spans.append((seg.get('start'), seg.get('end'), _iso(seg.get('timestamp'))))
        hasher.update((seg.get('text') or '').encode('utf-8'))
        hasher.update(json.dumps([seg.get('speaker_id'), bool(seg.get('is_user')), seg.get('person_id'),
                                  seg.get('speaker_assignment_source'), seg.get('speaker_status')], default=str).encode('utf-8'))
        hasher.update(b'\x00')
    structured = convo.get('structured') or {}
    return [
        convo.get('id'),
        convo.get('source'),
        _iso(convo.get('started_at')),
        bool(convo.get('discarded')),
        len(spans),
        spans,
        hasher.hexdigest()[:16],
        # The rollup's own inputs: a re-summarized conversation must change the
        # chapter that quotes it, even when not one segment moved.
        (structured.get('title') or ''),
        (structured.get('overview') or ''),
        (structured.get('first_person_observation') or ''),
    ]


def compute_fingerprint(convos: Sequence[Dict[str, Any]], summary_fingerprint: str = '', timezone_name: str = '') -> str:
    """A stable digest of everything that can change a day's chapters.

    Sorted by conversation id, not by arrival: under batch transcription the same
    day arrives in whatever order the scheduler produced, and a fingerprint that
    depended on that ordering would report a change on every sync.
    """
    payload = sorted((_conversation_fingerprint(c) for c in convos or ()), key=lambda row: str(row[0]))
    blob = json.dumps([ALGO_VERSION, ROLLUP_VERSION, summary_fingerprint, RECORDING_QUERY_VERSION,
                       timezone_name, payload], default=str, sort_keys=True)
    return hashlib.sha256(blob.encode('utf-8')).hexdigest()


def _chapter_identity(chapter: Dict[str, Any]) -> Tuple[Any, ...]:
    """What makes two chapters "the same chapter" for summary reuse.

    Boundaries plus provenance. A chapter that kept its exact span and its exact
    conversation list holds the same content, so its stored title still describes
    it — which lets a day where only *one* chapter changed pay for one rollup
    instead of all of them.
    """
    return (
        _iso(chapter.get('start')),
        _iso(chapter.get('end')),
        tuple(chapter.get('source_conversation_ids') or []),
    )


_SUMMARY_FIELDS = ('title', 'overview', 'emoji', 'first_person_observation', 'rollup', 'rollup_key', 'speaker_display')
_MANUAL_IDENTITY_FIELDS = ('_manual_speaker_evidence', '_manual_overview_digest')


def build_day_document(
    day: str,
    timezone_name: str,
    chapters: Sequence[Dict[str, Any]],
    fingerprint: str,
    computed_at: datetime,
    summary_fingerprint: str = '',
) -> Dict[str, Any]:
    """Assemble the stored form of one day. Pure — no IO, no clock read.

    `computed_at` is passed in rather than read here so a caller can produce a
    byte-identical document twice, which is what the idempotency test rests on.
    """
    stored_chapters: List[Dict[str, Any]] = []
    for chapter in chapters:
        entry = {
            'start': chapter['start'],
            'end': chapter['end'],
            'duration_seconds': chapter.get('duration_seconds', 0.0),
            'speech_seconds': chapter.get('speech_seconds', 0.0),
            'source_conversation_ids': list(chapter.get('source_conversation_ids') or []),
            'segment_refs': list(chapter.get('segment_refs') or []),
            'voice_runs': list(chapter.get('voice_runs') or []),
        }
        for key in (*_SUMMARY_FIELDS, *_MANUAL_IDENTITY_FIELDS):
            if key in chapter:
                entry[key] = chapter[key]
        stored_chapters.append(entry)

    source_ids: List[str] = []
    for chapter in stored_chapters:
        for cid in chapter['source_conversation_ids']:
            if cid not in source_ids:
                source_ids.append(cid)

    return {
        'date': day,
        'timezone': timezone_name,
        'chapters': stored_chapters,
        'source_conversation_ids': source_ids,
        'chapter_count': len(stored_chapters),
        'algo_version': ALGO_VERSION,
        'rollup_version': ROLLUP_VERSION,
        'model_config_version': MODEL_CONFIG_VERSION,
        'summary_fingerprint': summary_fingerprint,
        'query_version': RECORDING_QUERY_VERSION,
        'fingerprint': fingerprint,
        'computed_at': computed_at,
    }


def summarize_chapters(
    chapters: Sequence[Dict[str, Any]],
    convos: Sequence[Dict[str, Any]],
    previous: Optional[Dict[str, Any]] = None,
    language_hint: str = '',
    dependencies=None,
    batch_cache=None,
) -> List[Dict[str, Any]]:
    """Attach titles to chapters, reusing stored ones wherever they still apply.

    Two independent ways to avoid an LLM call, and both matter:

    * a chapter holding one conversation reuses that conversation's own summary
      (no call was ever needed — `rollup.summarize_chapter` handles this);
    * a chapter whose span, conversations and rendered prompt are unchanged reuses
      the summary already stored for it. Without this, one late-arriving
      conversation would re-summarize the entire day, which is the case batch sync
      produces constantly.

    Reuse is keyed on `rollup_key` (a hash of the rendered prompt) rather than on
    identity alone, so a re-summarized fragment or an edited prompt still forces a
    fresh call even when the boundaries did not move.
    """
    stored_by_identity: Dict[Tuple[Any, ...], Dict[str, Any]] = {}
    for chapter in (previous or {}).get('chapters') or []:
        stored_by_identity[_chapter_identity(chapter)] = chapter

    by_id = {convo.get('id'): convo for convo in convos}
    fragment_groups = [chapter_fragments(chapter, by_id) for chapter in chapters]
    requests = [prepare_rollup(fragments, language_hint=language_hint, dependencies=dependencies)
                for fragments in fragment_groups]
    validate_day_rollup_budget(requests)
    out: List[Dict[str, Any]] = []
    for chapter, fragments, request in zip(chapters, fragment_groups, requests):
        enriched = dict(chapter)
        if request is None:
            # 0 or 1 usable fragment: no rollup exists to cache.
            summary = summarize_chapter(fragments, language_hint=language_hint) or {}
            summary.setdefault('rollup_key', '')
        else:
            stored = stored_by_identity.get(_chapter_identity(chapter))
            key = request.cache_key
            if stored and stored.get('rollup_key') == key and stored.get('title') and stored.get('rollup') != 'failed':
                summary = {field: stored.get(field) for field in _SUMMARY_FIELDS if field in stored}
                summary['rollup_key'] = key
            else:
                summary = run_rollup(request, batch_cache=batch_cache) or {}
                summary['rollup_key'] = key

        for field in _SUMMARY_FIELDS:
            if field in summary:
                enriched[field] = summary[field]
        out.append(enriched)
    return out


def _clear_checked_dirty_marker(redis_db, key: str, checked) -> None:
    """Leave corrections written during summarization pending for the next read."""
    if checked is None:
        return
    client = getattr(redis_db, 'r', None)
    if client is not None:
        import base64
        redis_key = 'cache:' + base64.b64encode(key.encode()).decode()
        client.eval(
            "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end return 0",
            1, redis_key, json.dumps(checked, default=str),
        )
    elif redis_db.get_generic_cache(key) == checked:
        # In-memory adapters used by the offline regression suite.
        redis_db.delete_generic_cache(key)


def recompute_day(
    dev_db,
    redis_db,
    developer_id: str,
    external_user_id: str,
    day: date_cls,
    force: bool = False,
    now: Optional[datetime] = None,
    fail_on_summary_error: bool = False,
    dependencies=None,
) -> Dict[str, Any]:
    """Rebuild and store one day's chapters. The only writer of `timeline_days`.

    Returns `{'status': ..., 'document': ...}` where status is one of:

    * `unchanged` — the day's fingerprint matches what is stored; nothing was
      written and no LLM call was made.
    * `computed` — chapters were rebuilt and stored.
    * `locked` — another recompute of the same day holds the lock. It does *not*
      wait: the holder is computing the same thing from the same data, so waiting
      would buy a slightly fresher answer at the cost of blocking a request. The
      stored document is returned instead, and it is at most one recompute stale.

    `force` skips the fingerprint check only. It does not skip the lock — two
    forced recomputes of one day still interleave into a lost update, and "the user
    pulled to refresh twice" is exactly how that happens.
    """
    # Imported here rather than at module scope: `day_query` imports `chaptering`
    # and this module imports both, and keeping the store importable without the
    # query layer is what lets the unit tests drive it with fakes.
    from utils.timeline.day_query import _resolve_tz, get_day_conversations

    day_str = day.isoformat()
    lock_key = day_lock_key(developer_id, external_user_id, day_str)
    owner = uuid.uuid4().hex
    try:
        acquired = redis_db.acquire_owned_lock(lock_key, owner, ttl_seconds=LOCK_TTL_SECONDS)
    except Exception as error:
        raise TimelineLeaseUnavailable('Summary update unavailable; retry shortly') from error
    if not acquired:
        logger.info('[timeline] %s recompute skipped, lock held', day_str)
        return {'status': 'locked', 'document': dev_db.get_timeline_day(developer_id, external_user_id, day_str)}

    stop_heartbeat = threading.Event()
    lost_lease = threading.Event()

    def renew():
        try:
            if redis_db.renew_owned_lock(lock_key, owner, ttl_seconds=LOCK_TTL_SECONDS):
                return True
        except Exception as error:
            # A transport error does not prove loss. Retry on the next heartbeat,
            # and always compare-and-renew again immediately before persistence.
            logger.warning('[timeline] lease renewal unavailable for %s: %s', day_str, error)
            return None
        lost_lease.set()
        return False

    def heartbeat():
        while not stop_heartbeat.wait(LOCK_RENEW_SECONDS):
            if renew() is False:
                break

    def ensure_owned():
        for attempt in range(3):
            if lost_lease.is_set():
                raise TimelineLeaseUnavailable('Timeline lock ownership lost; existing summaries were preserved')
            renewed = renew()
            if renewed is True:
                return
            if renewed is None and attempt < 2:
                time.sleep(0.1 * (attempt + 1))
        raise TimelineLeaseUnavailable('Timeline lock ownership lost or unavailable; existing summaries were preserved')

    worker = threading.Thread(target=heartbeat, daemon=True, name='timeline-lease')
    worker.start()
    try:
        dirty_key = dirty_marker_key(developer_id, external_user_id, day_str)
        checked_marker = redis_db.get_generic_cache(dirty_key)
        tz_name = dev_db.get_user_timezone(developer_id, external_user_id) or 'UTC'
        tz = _resolve_tz(tz_name)
        tz_name = getattr(tz, 'key', str(tz))
        convos = get_day_conversations(dev_db, developer_id, external_user_id, day, tz=tz, require_complete=True)

        dependencies = dependencies or resolve_summary_dependencies()
        fingerprint = compute_fingerprint(convos, dependencies.fingerprint, tz_name)
        previous = dev_db.get_timeline_day(developer_id, external_user_id, day_str)
        if (not force and previous and previous.get('fingerprint') == fingerprint
                and not any(ch.get('rollup') == 'failed' for ch in (previous.get('chapters') or []))):
            # Clear the marker anyway: the day was checked, and leaving it dirty
            # would make every later trigger re-run this same comparison.
            ensure_owned()
            _clear_checked_dirty_marker(redis_db, dirty_key, checked_marker)
            return {'status': 'unchanged', 'document': previous}

        chapters = segment_day_into_chapters(convos, tz)
        # Resolve only tokens retained by manual prose, from the source query we
        # already performed. No transcript text or all-segment index is cached.
        # Lightweight offline adapters may omit the optional edits collection.
        from utils.timeline.edits import chapter_edit_id
        from utils.timeline.speakers import TOKEN, chapter_evidence
        from utils.timeline.summary_dependencies import digest
        edit_reader = getattr(dev_db, 'get_timeline_chapter_edits', None)
        edits = edit_reader(developer_id, external_user_id, day_str) if edit_reader else {}
        by_id = {convo['id']: convo for convo in convos}
        manual_identities = {}
        for chapter in chapters:
            edit = edits.get(chapter_edit_id(chapter)) or {}
            if not edit.get('overview_speaker_display'):
                continue
            tokens = set(TOKEN.findall(edit.get('overview') or ''))
            evidence = chapter_evidence(chapter, by_id)
            manual_identities[chapter_edit_id(chapter)] = {
                '_manual_overview_digest': digest(edit.get('overview')),
                '_manual_speaker_evidence': {
                    eid: {key: item[key] for key in ('speaker_id', 'is_user', 'person_id', 'status')}
                    for eid, item in evidence.items() if eid in tokens},
            }
        chapters = summarize_chapters(
            chapters, convos, previous=previous, dependencies=dependencies,
            batch_cache=BatchCache(getattr(redis_db, 'r', None), developer_id, external_user_id, day_str),
        )
        for chapter in chapters:
            chapter.update(manual_identities.get(chapter_edit_id(chapter)) or {})
        if fail_on_summary_error and any(ch.get('rollup') == 'failed' for ch in chapters):
            raise RuntimeError('Chapter summarization failed; the existing day was not overwritten')
        document = build_day_document(
            day=day_str,
            timezone_name=tz_name,
            chapters=chapters,
            fingerprint=fingerprint,
            computed_at=now or datetime.now(timezone.utc),
            summary_fingerprint=dependencies.fingerprint,
        )
        ensure_owned()
        stored = dev_db.store_timeline_day(developer_id, external_user_id, day_str, document)
        _clear_checked_dirty_marker(redis_db, dirty_key, checked_marker)
        logger.info('[timeline] %s recomputed: %d chapters from %d conversations',
                    day_str, len(chapters), len(convos))
        return {'status': 'computed', 'document': stored}
    finally:
        stop_heartbeat.set()
        worker.join(timeout=1)
        redis_db.release_owned_lock(lock_key, owner)


def mark_day_dirty(
    redis_db,
    developer_id: str,
    external_user_id: str,
    day: date_cls,
    now: Optional[datetime] = None,
    strict: bool = False,
    immediate: bool = False,
) -> None:
    """Record that a day needs recomputing, without recomputing it.

    Called from the conversation write paths. Deliberately does no work beyond one
    Redis write: it runs inside conversation processing, and a chapter cache must
    never be able to slow down or fail the recording pipeline.

    The marker keeps the *first* dirty time, not the latest. Refreshing it on every
    write would let a batch sync push the due time forever ahead of itself — 480
    files arriving every few seconds would mean the day is never due at all.
    """
    key = dirty_marker_key(developer_id, external_user_id, day.isoformat())
    stamp = (now or datetime.now(timezone.utc)).isoformat()
    payload = {'dirty_since': stamp}
    if immediate:
        # A human correction must be visible on the next read, including when an
        # older recording marker already exists. Each correction replaces it.
        payload.update(immediate=True, revision=uuid.uuid4().hex)
    client = getattr(redis_db, 'r', None)
    if strict or client is not None:
        import base64
        redis_key = 'cache:' + base64.b64encode(key.encode()).decode()
        # SET NX prevents a recording write from overwriting a concurrent manual
        # correction. SET with expiry is atomic; legacy cache wrappers aren't.
        redis_db.r.set(redis_key, json.dumps(payload), ex=DIRTY_TTL_SECONDS, nx=not immediate)
        return
    existing = redis_db.get_generic_cache(key)
    if not immediate and isinstance(existing, dict) and existing.get('dirty_since'):
        return
    redis_db.set_generic_cache(key, payload, ttl=DIRTY_TTL_SECONDS)


def mark_conversation_day_dirty(developer_id: str, external_user_id: str, started_at: Any, *, raise_on_error: bool = False, immediate: bool = False) -> None:
    """Mark the local day a just-finished conversation belongs to.

    The call-site-facing wrapper around `mark_day_dirty`: it resolves the user's
    timezone and swallows everything. Call it from the conversation write paths.

    Never raises. A chapter cache is a convenience built on top of conversations;
    if marking fails, the day is simply recomputed the next time it is read with no
    cache present, whereas an exception escaping here would abort conversation
    processing — trading a stale card for lost audio.

    Attribution is by `started_at` in the user's timezone, matching
    `filter_convos_for_local_day`. A conversation that ran 23:40–00:20 belongs
    wholly to the day it began, so only that one day is marked.
    """
    try:
        import database.developer_data as dev_db
        from database import redis_db

        from utils.timeline.chaptering import _as_utc
        from utils.timeline.day_query import _resolve_tz

        started = _as_utc(started_at)
        if started is None:
            return
        tz = _resolve_tz(dev_db.get_user_timezone(developer_id, external_user_id))
        mark_day_dirty(redis_db, developer_id, external_user_id, started.astimezone(tz).date(), strict=raise_on_error, immediate=immediate)
    except Exception as e:
        if raise_on_error:
            raise
        logger.warning('[timeline] failed to mark day dirty for %s/%s: %s', developer_id, external_user_id, e)


def _parse_stamp(value: Any) -> Optional[datetime]:
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def should_recompute_now(
    redis_db,
    developer_id: str,
    external_user_id: str,
    day: date_cls,
    now: Optional[datetime] = None,
) -> bool:
    """Whether a dirty day has waited out the debounce window.

    A day with no marker returns False: not dirty, nothing to do. A marker that
    cannot be parsed returns True — an unreadable marker means the day is dirty and
    its age is unknown, and recomputing an already-current day is cheap (the
    fingerprint check catches it) while never recomputing a dirty one is not.
    """
    key = dirty_marker_key(developer_id, external_user_id, day.isoformat())
    marker = redis_db.get_generic_cache(key)
    if not marker:
        return False
    if isinstance(marker, dict) and marker.get('immediate') is True:
        return True
    since = _parse_stamp(marker.get('dirty_since') if isinstance(marker, dict) else marker)
    if since is None:
        return True
    elapsed = ((now or datetime.now(timezone.utc)) - since).total_seconds()
    return elapsed >= DEBOUNCE_MINUTES * 60
