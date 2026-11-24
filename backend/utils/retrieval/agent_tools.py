"""Retrieval tools the chat agent can call, plus the request-scoped context they close over.

Why a per-request closure factory instead of tools that take `uid`: §9.5 of the
overhaul plan. The `uid` / `developer_id` that scope every read must come from the
authenticated request, never from a tool argument the model (or a prompt injection)
could set. So the tool *schemas* only expose business parameters (`query`, `limit`,
…); identity is captured in a closure and is unreachable from the model side.

Citations: `developer_chat.process_message` maps a `[index]` in the answer back to
`memories_found[index-1]`. That list must therefore hold the *full* conversation
dicts in 1-based citation order, even though the model only ever sees short
snippets. `CitationAccumulator` is what keeps those two views consistent across
however many times the agent calls `memory_search`.

Todos (PR4): action items are **not** a top-level collection — they live inside
each conversation at `structured.action_items[]` and are addressed positionally by
`(conversation_id, item_idx)`. There is no stable per-item id, so the tools expose
a composite `"{conversation_id}:{item_idx}"` string as the item's handle. Reads go
through the same projected Firestore query `routers/discover.py` uses: the obvious
`dev_db.get_conversations` path drags full transcripts (+ chunk subcollection
streams + zlib) and measured 22s / 1023KB to return 0.4KB of todos.
"""

import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import List, Optional
from zoneinfo import ZoneInfo

from google.cloud.firestore_v1 import FieldFilter
from langchain_core.tools import tool

import database.developer_data as dev_db
from database.vector_db import query_vectors_by_metadata
from utils.llm.chat import retrieve_context_dates_by_question
from utils.llm.embeddings import generate_embedding_query
from utils.retrieval.agent_websearch import DEFAULT_WEB_RESULTS, tavily_search
from utils.retrieval.product_manual import DEFAULT_SECTION_LIMIT
from utils.retrieval.product_manual import lookup as manual_lookup
from utils.timeline.day_query import get_conversations_in_range

logger = logging.getLogger(__name__)

# Snippet length fed to the model per search hit. Long enough to judge relevance
# and decide whether to memory_get the full detail, short enough that a top-N
# search stays cheap.
#
# Left at 240 after measuring 600 as its own A/B arm (evaluation/chat-agent/RESULTS.md):
# 600 moved no retrieval metric at all (recall ALL-gold 0.383 both ways, gold
# coverage 0.581 -> 0.571) and correctness went 0.438 -> 0.333. That drop is not
# evidence 600 is worse — it sits inside a measured run-to-run noise band of ~12
# flipped questions — but there is no evidence it helps, and a longer snippet
# costs context on every hit. Revisit only with a multi-run harness.
SNIPPET_CHARS = 240

# How many hits `memory_search` returns by default. Kept well under
# MAX_SEARCH_LIMIT so the agent still refines and re-searches rather than
# dumping a wide result set into context.
#
# Raised 3 -> 5 on retrieval evidence, not on an answer-quality win. 45 of 48
# LongMemEval questions spread their answer over 2+ conversations (mean 1.92), and
# limit=5 improved every retrieval measure — recall ALL-gold 0.383 -> 0.433, gold
# coverage 0.581 -> 0.639 — while correctness stayed flat at 0.438 (6 questions
# gained, 6 lost, p=1.0). Retrieval is the metric to trust here: it needs no LLM
# judge, and the measured run-to-run noise (~12 flipped questions per rerun) is
# far larger than any correctness delta this sample could resolve.
#
# Costs, both accepted: ~3 more candidate conversations per turn (6.3 -> 9.4) and
# ~6s latency. Citation precision falls 0.269 -> 0.214 as a direct consequence of
# offering more candidates.
#
# This does not widen what the user typically sees — the agent cites only what it
# used, and the median stays at 1 citation per answer — but it does lengthen the
# tail (measured max 4 -> 9 citations). That tail is bounded separately by
# models.chat.MAX_CITED_CONVERSATIONS, so the two constants are a matched pair:
# raising this one without that cap in place would put up to 9 cards in front of
# the user.
DEFAULT_SEARCH_LIMIT = 5
MAX_SEARCH_LIMIT = 10

# Todo listing caps. The projected query below scans conversations, so keep the
# document ceiling identical to the REST endpoint's.
TODO_SCAN_LIMIT = 5000
DEFAULT_TODO_LIMIT = 20
MAX_TODO_LIMIT = 50

# How many facts get_user_profile returns before it starts truncating. The point
# of the tool is a digestible profile, not a context dump.
MAX_PROFILE_FACTS = 30

# Calendar lookup caps. The app syncs a 7-day-past .. 60-day-future window, so a
# whole-window read is bounded; this ceiling only guards pathological calendars.
DEFAULT_CALENDAR_LIMIT = 25
MAX_CALENDAR_LIMIT = 100


@dataclass
class RequestContext:
    """Identity and per-request settings the tools need but the model must not set."""

    uid: str
    developer_id: Optional[str]
    tz: str = "UTC"
    cited: bool = False
    plugin: Optional[object] = None
    # Set by the streaming path so tools can emit human-readable progress.
    callback: Optional[object] = None
    scoped_conversations: Optional[List[dict]] = None


@dataclass
class CitationAccumulator:
    """Collects the full conversation dicts the answer may cite, in stable 1-based order.

    De-duplicated by conversation id: calling `memory_search` twice for the same
    conversation returns the same index both times, so the model can cite `[n]`
    consistently and `process_message` always resolves it to the same card.
    """

    _ordered: List[dict] = field(default_factory=list)
    _id_to_index: dict = field(default_factory=dict)

    def add(self, conversation: dict) -> int:
        cid = conversation.get("id")
        if cid in self._id_to_index:
            return self._id_to_index[cid]
        self._ordered.append(conversation)
        index = len(self._ordered)  # 1-based, matches memories[i-1] in process_message
        self._id_to_index[cid] = index
        return index

    @property
    def ordered(self) -> List[dict]:
        return self._ordered

    def __len__(self) -> int:
        return len(self._ordered)


def _parse_iso(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def _conversation_start(conversation: dict) -> Optional[str]:
    started = conversation.get("started_at") or conversation.get("created_at")
    if isinstance(started, datetime):
        return started.isoformat()
    return started


def _snippet(conversation: dict) -> str:
    structured = conversation.get("structured") or {}
    overview = (structured.get("overview") or "").strip()
    if len(overview) > SNIPPET_CHARS:
        return overview[:SNIPPET_CHARS].rstrip() + "…"
    return overview


def _emit_thought(ctx: RequestContext, text: str):
    if ctx.callback is not None:
        try:
            ctx.callback.put_thought_nowait(text)
        except Exception:
            # Progress messages are best-effort; never let one break a tool call.
            logger.debug("failed to emit thought", exc_info=True)


def _todo_handle(conversation_id: str, item_idx: int) -> str:
    """Composite handle for an action item, which has no id of its own."""
    return f"{conversation_id}:{item_idx}"


def _parse_todo_handle(handle: str):
    """Split a `"{conversation_id}:{item_idx}"` handle. Returns (conv_id, idx) or None.

    rsplit, not split: Firestore ids are UUIDs today but a colon in an id would
    otherwise silently retarget the write to the wrong conversation.
    """
    if not handle or ":" not in handle:
        return None
    conversation_id, _, raw_idx = handle.rpartition(":")
    try:
        return conversation_id, int(raw_idx)
    except ValueError:
        return None


def _scan_action_items(ctx: RequestContext) -> List[dict]:
    """All of the user's action items, newest conversation first.

    Mirrors `routers/discover.py:get_action_items`' projected query on purpose —
    see the module docstring for why the ergonomic path is not an option. Returns
    raw entries including `confirmed`, so callers apply their own status filter.
    """
    user_ref = dev_db._get_user_ref(ctx.developer_id, ctx.uid)
    docs = (
        user_ref.collection("conversations")
        .where(filter=FieldFilter("structured.action_items", "!=", []))
        .select(["structured.action_items", "structured.title", "created_at", "status", "discarded"])
        .limit(TODO_SCAN_LIMIT)
        .stream()
    )

    entries = []
    for doc in docs:
        conversation = doc.to_dict() or {}
        # Same gate as the REST endpoint: only completed, non-discarded conversations.
        if conversation.get("discarded") or conversation.get("status") != "completed":
            continue
        structured = conversation.get("structured") or {}
        action_items = structured.get("action_items") or []
        created_at = conversation.get("created_at")
        for idx, raw in enumerate(action_items):
            if not isinstance(raw, dict):
                continue
            entries.append(
                {
                    "handle": _todo_handle(doc.id, idx),
                    "text": raw.get("description", ""),
                    "completed": bool(raw.get("completed", False)),
                    # Missing key means legacy data, which predates the confirm
                    # flow and is treated as already accepted.
                    "confirmed": bool(raw.get("confirmed", True)),
                    "due_at": _iso(raw.get("due_date")),
                    "due_hint": raw.get("due_hint", "") or "",
                    "source_conversation_id": doc.id,
                    "source_conversation_title": structured.get("title") or "",
                    "_created_at": created_at,
                }
            )

    # Sorted in the app layer, like the REST endpoint: `where + order_by` would
    # need a composite index and thus a deploy-time dependency.
    entries.sort(key=lambda e: e["_created_at"] or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    return entries


def _before(due: datetime, cutoff: datetime) -> bool:
    """`due < cutoff`, tolerating one side being naive (legacy rows lack a tz)."""
    if (due.tzinfo is None) != (cutoff.tzinfo is None):
        due = due.replace(tzinfo=due.tzinfo or timezone.utc)
        cutoff = cutoff.replace(tzinfo=cutoff.tzinfo or timezone.utc)
    return due < cutoff


def _latest_conversation_id(ctx: RequestContext) -> Optional[str]:
    """Most recent completed conversation, used as the default home for a new to-do."""
    try:
        user_ref = dev_db._get_user_ref(ctx.developer_id, ctx.uid)
        docs = (
            user_ref.collection("conversations")
            .where(filter=FieldFilter("status", "==", "completed"))
            .order_by("created_at", direction="DESCENDING")
            .select(["created_at"])
            .limit(1)
            .stream()
        )
        for doc in docs:
            return doc.id
    except Exception:
        logger.exception("_latest_conversation_id failed uid=%s", ctx.uid)
    return None


def _recent_mood(ctx: RequestContext) -> dict:
    """Today's (or the latest) mood read.

    Prefers the pre-aggregated daily mood quote — it already holds a dominant
    emotion plus a distribution, so it beats re-deriving one from conversations.
    Falls back to the latest EIR-tagged conversation.
    """
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    quote = dev_db.get_daily_mood_quote(ctx.developer_id, ctx.uid, today)
    if quote:
        return {
            "date": today,
            "dominant_emotion": quote.get("dominant_emotion"),
            "emotion_distribution": quote.get("emotion_distribution") or {},
        }
    latest = dev_db.get_latest_eir_conversation(ctx.developer_id, ctx.uid)
    if latest:
        return {
            "dominant_emotion": latest.get("eir_emotion"),
            "as_of": _iso(latest.get("eir_updated_at") or latest.get("created_at")),
        }
    return {}


def make_agent_tools(ctx: RequestContext, citations: CitationAccumulator) -> list:
    """Build the tool list for one chat turn, closing over identity and citations."""

    @tool
    def memory_search(
        query: str,
        start: Optional[str] = None,
        end: Optional[str] = None,
        speaker: Optional[str] = None,
        limit: int = DEFAULT_SEARCH_LIMIT,
    ) -> dict:
        """Search the user's own recorded conversation memories.

        Use this to answer anything about what the user has said, done, discussed,
        or experienced in the past ("what did I talk about…", "when did I mention…",
        "what did I decide about…"). Do not use it for general knowledge or for the
        current message's small talk. Returns short snippets only — call memory_get
        with an id when you need the full conversation.
        In a linked-recording session this always lists the complete linked scope;
        query, dates, speaker and limit do not exclude a linked recording.

        To list everything from a day or period rather than search within it
        ("what did I do on the 13th", "what happened last week"), pass an empty
        query with start/end — you get that period's conversations in time order
        instead of a semantic ranking.

        Args:
            query: Natural-language description of what to find. Pass "" to list
                a period's conversations by time (requires start and/or end).
            start: ISO-8601 lower bound. For relative expressions like "last week",
                call resolve_time_range first and pass its start here. Omit for none.
            end: ISO-8601 upper bound, obtained the same way. Omit for none.
            speaker: Pass "user" to keep only things the user themselves said; omit
                otherwise.
            limit: How many results (default 5, max 10). Prefer small — refine and
                search again rather than asking for many at once.
        """
        _emit_thought(ctx, "Searching through your memories")
        capped = max(1, min(limit or DEFAULT_SEARCH_LIMIT, MAX_SEARCH_LIMIT))
        start_dt, end_dt = _parse_iso(start), _parse_iso(end)
        has_range = bool(start_dt or end_dt)
        # Segments are only read to filter by speaker. Everything else in a row
        # comes from `structured`, so fetching them otherwise is pure waste —
        # see `get_conversations_in_range`.
        needs_segments = speaker == "user"

        def _pack(rows) -> dict:
            """rows: [(conversation, matched_by or None)] — order is preserved."""
            results = []
            for conversation, matched_by in rows:
                if speaker == "user" and not _has_user_speech(conversation):
                    continue
                index = citations.add(conversation)
                structured = conversation.get("structured") or {}
                row = {
                    "index": index,
                    "id": conversation.get("id"),
                    "title": structured.get("title", ""),
                    "start_time": _conversation_start(conversation),
                    "snippet": _snippet(conversation),
                }
                if matched_by:
                    row["matched_by"] = matched_by
                results.append(row)
                # Cap after the speaker filter, not before: filtering first and
                # truncating second is what makes `limit` mean "this many usable
                # results" rather than "this many candidates".
                if len(results) >= capped:
                    break
            return {"results": results}

        def _date_channel(limit_to: int):
            return get_conversations_in_range(
                dev_db, ctx.developer_id, ctx.uid,
                start=start_dt, end=end_dt, limit=limit_to,
                include_segments=needs_segments,
            )

        if ctx.scoped_conversations is not None:
            return {"complete_linked_scope": True, "results": [
                {"index": citations.add(c), "id": c.get("id"),
                 "title": (c.get("structured") or {}).get("title", ""),
                 "start_time": _conversation_start(c), "snippet": _snippet(c),
                 "matched_by": "linked_conversation"}
                for c in ctx.scoped_conversations
            ]}

        # The date channel. A date anchor lives in a conversation's metadata, not
        # in its text, so a purely-date question ("what did I do on the 13th") has
        # no content words for the vector to match — top_k comes back ranked by
        # semantic noise and then gets truncated to `limit`, which on a busy day
        # silently drops most of it. This path bypasses the vector entirely.
        #
        # The trigger is an empty query: a binary, mechanical fact. Deliberately
        # NOT "does the query have content words" — that needs a keyword-length
        # floor, which is an English morphology assumption. Chinese content words
        # are 2-3 characters and would fall below any such floor wholesale.
        if not (query or "").strip():
            if not (has_range and ctx.developer_id):
                return {"results": []}
            return _pack([(c, "date_range") for c in _date_channel(capped)])

        try:
            vector = generate_embedding_query(query).values
        except Exception:
            logger.exception("memory_search: embedding failed for uid=%s", ctx.uid)
            return {"results": []}

        ids = query_vectors_by_metadata(
            ctx.uid,
            vector,
            dates_filter=[start_dt, end_dt],
            # Structured filters come from a Redis category cache that is not
            # reachable from every environment and adds nothing now that semantic
            # ranking is the primary signal (see overhaul plan §13.4). Passing them
            # empty keeps the chat read path off Redis entirely.
            people=[],
            topics=[],
            entities=[],
            dates=[],
            limit=capped,
        )
        if not ctx.developer_id:
            return {"results": []}

        # get_conversations_by_ids returns dicts in the same order as `ids`, i.e.
        # by retrieval relevance — that ordering must survive untouched (overhaul
        # plan §13.10). Do not re-sort here.
        hits = dev_db.get_conversations_by_ids(ctx.developer_id, ctx.uid, ids) if ids else []

        # Top up from the date channel when a time-bounded search under-delivers.
        #
        # The trigger is "fewer hits than asked for", NOT "zero hits". Zero is the
        # rare case; the common one is a partial hit, and it was going unhandled:
        # 2026-08-19 on production, "what did I do on 8/16" matched 2 vectors for a
        # day that holds 8 conversations — and one of those 2 was actually recorded
        # on 8/15, pulled in by the very `created_at` skew this commit fixes.
        #
        # Under-delivery has two causes and the same remedy: the time filter reads
        # `created_at`, which for un-backfilled vectors is the insert instant (p90
        # 18h off for uploads); or the day genuinely holds fewer conversations, in
        # which case the date channel returns just as few and nothing changes. That
        # second case is why over-triggering here is harmless.
        #
        # Topping up rather than replacing: the vector hits carry semantic rank and
        # must stay in front (§13.10). The filler is appended, deduped by id, and
        # tagged `matched_by="date_range"` so "this came from the period, not from
        # your query" is a fact in the tool trace rather than something the model
        # has to infer — same stance as `report_no_record`.
        if has_range and len(hits) < capped:
            seen = {c.get("id") for c in hits}
            filler = [c for c in _date_channel(capped) if c.get("id") not in seen]
            if filler:
                logger.info(
                    "[memory_search] date top-up for uid=%s range=[%s, %s]: %d vector + %d dated",
                    ctx.uid, start, end, len(hits), len(filler),
                )
                return _pack([(c, None) for c in hits] + [(c, "date_range") for c in filler])

        return _pack([(c, None) for c in hits])

    @tool
    def memory_get(id: str, format: str = "concise") -> dict:
        """Fetch the full detail of one conversation memory by its id.

        Call this only after memory_search returned an id whose snippet looks
        relevant and you need more than the snippet. format="concise" (default)
        returns title and summary; format="detailed" also returns the transcript
        segments. Do not guess ids — only use ids returned by memory_search.
        """
        if not ctx.developer_id:
            return {}
        conversations = ([c for c in ctx.scoped_conversations if c.get("id") == id]
                         if ctx.scoped_conversations is not None else
                         dev_db.get_conversations_by_ids(ctx.developer_id, ctx.uid, [id]))
        if not conversations:
            return {}
        conversation = conversations[0]
        # Make sure a fetched conversation is citable too, even if it was never
        # returned by memory_search in this turn.
        citations.add(conversation)
        structured = conversation.get("structured") or {}
        result = {
            "id": conversation.get("id"),
            "title": structured.get("title", ""),
            "start_time": _conversation_start(conversation),
            "summary": structured.get("overview", ""),
        }
        if format == "detailed":
            result["segments"] = [
                {
                    "speaker_name": s.get("speaker") or s.get("speaker_id"),
                    "is_user": s.get("is_user", False),
                    "text": s.get("text", ""),
                }
                for s in conversation.get("transcript_segments", [])
            ]
        return result

    @tool
    def resolve_time_range(expr: str) -> dict:
        """Convert a relative time expression into an absolute ISO-8601 range.

        Use before memory_search whenever the user's question contains a relative
        time reference ("last Wednesday", "this month", "the past three days"). Pass
        the returned start/end into memory_search. The user's timezone is applied
        automatically — do not ask for it.
        """
        try:
            dates_range = retrieve_context_dates_by_question(expr, ctx.tz)
        except Exception:
            logger.exception("resolve_time_range failed for expr=%r", expr)
            dates_range = None
        if dates_range and len(dates_range) >= 2:
            return {
                "start": _iso(dates_range[0]),
                "end": _iso(dates_range[1]),
                "timezone": ctx.tz,
                "resolved_as": expr,
            }
        return {"start": None, "end": None, "timezone": ctx.tz, "resolved_as": expr}

    @tool
    def calendar_lookup(
        start: Optional[str] = None,
        end: Optional[str] = None,
        limit: int = DEFAULT_CALENDAR_LIMIT,
    ) -> dict:
        """Look up the user's calendar events (their schedule / appointments).

        This is their actual calendar synced from their phone — future plans as
        well as past ones. Use it for "what's on my calendar", "when is my next
        meeting", "am I free Thursday afternoon", "what did I have scheduled last
        Tuesday". Do not use memory_search for these: memories are recordings of
        conversations that already happened, not the user's schedule.

        Events are already sorted earliest first. Each event tells you whether it
        is all_day. Times are given both as an absolute instant and as the local
        wall-clock time the user sees; quote the local time to them.

        Args:
            start: ISO-8601 lower bound (inclusive). Call resolve_time_range first
                for phrases like "next week". Omit to start from right now, which
                is what you want for "what's next" / "what's coming up".
            end: ISO-8601 upper bound (exclusive). Omit for no upper bound.
            limit: How many events to return (default 25, max 100).
        """
        if not ctx.developer_id:
            return {"events": [], "calendar_enabled": False}
        _emit_thought(ctx, "Checking your calendar")

        capped = max(1, min(limit or DEFAULT_CALENDAR_LIMIT, MAX_CALENDAR_LIMIT))
        start_dt = _parse_iso(start)
        end_dt = _parse_iso(end)
        # No explicit lower bound means "from now on" — for "what's my next
        # meeting" a window that starts in the past would answer with a meeting
        # that already finished.
        if start_dt is None and end_dt is None:
            start_dt = datetime.now(timezone.utc)

        try:
            synced = dev_db.get_calendar_sync_state(ctx.developer_id, ctx.uid)
        except Exception:
            logger.exception("calendar_lookup: sync state read failed for uid=%s", ctx.uid)
            synced = None

        # "Never synced" and "synced, nothing scheduled" are different answers and
        # the model must not conflate them: telling someone their calendar is
        # empty when they simply never enabled the feature is a wrong answer.
        if not synced or not synced.get("synced_at"):
            return {
                "events": [],
                "calendar_enabled": False,
                "note": (
                    "No calendar has been synced for this user. Calendar sync is optional "
                    "and appears to be off. Tell them they can turn it on in Permissions, "
                    "and do not claim their schedule is empty."
                ),
            }

        try:
            rows = dev_db.get_calendar_events(
                ctx.developer_id, ctx.uid, start=start_dt, end=end_dt, limit=capped
            )
        except Exception:
            logger.exception("calendar_lookup: read failed for uid=%s", ctx.uid)
            return {"events": [], "calendar_enabled": True}

        events = [_calendar_event_view(row, ctx.tz) for row in rows]
        result = {
            "events": events,
            "calendar_enabled": True,
            "synced_window": {
                "start": _iso(synced.get("window_start")),
                "end": _iso(synced.get("window_end")),
            },
            "last_synced_at": _iso(synced.get("synced_at")),
        }
        if not events:
            # An empty result inside a synced window is a real "nothing scheduled",
            # but only for the window that was actually synced.
            result["note"] = (
                "Nothing scheduled in the requested range. Only events inside "
                "synced_window are known; anything outside it was never synced."
            )
        return result

    @tool
    def todo_list(
        status: str = "open",
        due_before: Optional[str] = None,
        limit: int = DEFAULT_TODO_LIMIT,
    ) -> dict:
        """List the user's to-do items, extracted from their recorded conversations.

        Use this for "what do I need to do", "what's on my list", "anything due
        this week". Each item carries the conversation it came from, so you can
        tell the user where a to-do originated. Does not return conversation
        transcripts — use memory_get for that.

        Args:
            status: Which items to return. "open" (default) = accepted but not
                done; "completed" = already done; "all" = both. Items the user
                has not yet accepted into their list are never returned — they
                are still awaiting confirmation in the app.
            due_before: ISO-8601 cutoff; keep only items with a deadline strictly
                before it. Call resolve_time_range first for phrases like "this
                week". Items whose timing was only ever spoken vaguely have no
                deadline and are excluded when this is set. Omit for no cutoff.
            limit: How many to return (default 20, max 50).
        """
        if not ctx.developer_id:
            return {"items": []}
        _emit_thought(ctx, "Checking your to-do list")
        capped = max(1, min(limit or DEFAULT_TODO_LIMIT, MAX_TODO_LIMIT))

        try:
            entries = _scan_action_items(ctx)
        except Exception:
            logger.exception("todo_list: scan failed for uid=%s", ctx.uid)
            return {"items": []}

        # Unconfirmed items are pending the user's "add to to-do" tap and must not
        # be presented as if they were on the list.
        entries = [e for e in entries if e["confirmed"]]
        if status == "open":
            entries = [e for e in entries if not e["completed"]]
        elif status == "completed":
            entries = [e for e in entries if e["completed"]]

        if due_before:
            cutoff = _parse_iso(due_before)
            if cutoff is not None:
                kept = []
                for entry in entries:
                    due = _parse_iso(entry["due_at"])
                    if due is not None and _before(due, cutoff):
                        kept.append(entry)
                entries = kept

        items = [
            {
                "id": e["handle"],
                "text": e["text"],
                "status": "completed" if e["completed"] else "open",
                "due_at": e["due_at"],
                "due_hint": e["due_hint"],
                "source_conversation_id": e["source_conversation_id"],
                "source_conversation_title": e["source_conversation_title"],
            }
            for e in entries[:capped]
        ]
        return {"items": items, "total_matching": len(entries)}

    @tool
    def todo_write(
        action: str,
        id: Optional[str] = None,
        text: Optional[str] = None,
        due_at: Optional[str] = None,
        due_hint: Optional[str] = None,
    ) -> dict:
        """Create, edit, complete, or delete one of the user's to-do items.

        Only act on an explicit request from the user — do not tidy up their list
        on your own initiative. Confirm back what changed in your reply.

        Args:
            action: "create", "update", "complete", or "delete".
            id: The item's id from todo_list. Required for update/complete/delete.
                For "create" it names the conversation the to-do belongs to: pass
                a conversation id from memory_search, or omit to attach it to the
                user's most recent conversation.
            text: The to-do text. Required for "create", optional for "update".
            due_at: ISO-8601 deadline, only when a specific date is actually
                known. Never invent one from a vague phrase — put that in
                due_hint instead, or the user gets a reminder at a made-up time.
            due_hint: The timing as the user said it ("this week", "尽快"), when
                no exact date is determinable.
        """
        if not ctx.developer_id:
            return {"ok": False, "error": "unavailable"}

        if action == "create":
            if not text:
                return {"ok": False, "error": "text is required to create a to-do"}
            conversation_id = id
            if conversation_id and ":" in conversation_id:
                # Tolerate the model handing back a full item handle.
                parsed = _parse_todo_handle(conversation_id)
                conversation_id = parsed[0] if parsed else conversation_id
            if not conversation_id:
                conversation_id = _latest_conversation_id(ctx)
            if not conversation_id:
                return {"ok": False, "error": "no conversation to attach the to-do to"}
            _emit_thought(ctx, "Adding to your to-do list")
            try:
                # add_action_item stamps confirmed=True internally: a to-do the
                # user asked for in chat does not need a second confirmation.
                created = dev_db.add_action_item(
                    ctx.developer_id, ctx.uid, conversation_id, text,
                    completed=False, due_date=_parse_iso(due_at), due_hint=due_hint or "",
                )
            except Exception:
                logger.exception("todo_write create failed uid=%s", ctx.uid)
                return {"ok": False, "error": "write failed"}
            if created is None:
                return {"ok": False, "error": "conversation not found"}
            items = dev_db.get_action_items(ctx.developer_id, ctx.uid, conversation_id) or []
            return {
                "ok": True,
                "action": "create",
                "id": _todo_handle(conversation_id, max(0, len(items) - 1)),
                "text": text,
            }

        parsed = _parse_todo_handle(id or "")
        if parsed is None:
            return {"ok": False, "error": "a valid id from todo_list is required"}
        conversation_id, item_idx = parsed

        if action == "delete":
            _emit_thought(ctx, "Removing a to-do")
            try:
                ok = dev_db.delete_action_item(ctx.developer_id, ctx.uid, conversation_id, item_idx)
            except Exception:
                logger.exception("todo_write delete failed uid=%s", ctx.uid)
                return {"ok": False, "error": "write failed"}
            return {"ok": bool(ok), "action": "delete", "id": id}

        if action in ("update", "complete"):
            _emit_thought(ctx, "Updating a to-do")
            kwargs = {}
            if action == "complete":
                kwargs["completed"] = True
            if text:
                kwargs["description"] = text
            if due_at:
                kwargs["due_date"] = _parse_iso(due_at)
            if due_hint is not None:
                kwargs["due_hint"] = due_hint
            if not kwargs:
                return {"ok": False, "error": "nothing to update"}
            try:
                updated = dev_db.update_action_item(
                    ctx.developer_id, ctx.uid, conversation_id, item_idx, **kwargs
                )
            except Exception:
                logger.exception("todo_write update failed uid=%s", ctx.uid)
                return {"ok": False, "error": "write failed"}
            if updated is None:
                return {"ok": False, "error": "to-do not found"}
            return {
                "ok": True,
                "action": action,
                "id": id,
                "text": updated.get("description", ""),
                "status": "completed" if updated.get("completed") else "open",
            }

        return {"ok": False, "error": f"unknown action {action!r}"}

    @tool
    def people_lookup(name: Optional[str] = None, limit: int = 10) -> dict:
        """Look up people the user has talked with, by name or as a full list.

        Use this to resolve who someone is before searching for conversations
        involving them, or to answer "who have I been talking to". Returns the
        names the user gave these people. Do not use it to look up public figures
        or anyone outside the user's own recordings.

        Args:
            name: Name (or part of one) to match, case-insensitive. Omit to list
                the user's people.
            limit: How many to return (default 10).
        """
        if not ctx.developer_id:
            return {"people": []}
        _emit_thought(ctx, "Looking up who that is")
        try:
            # There is no name index, so match in Python over the full list.
            # `include_mentions=False`：只被提到过的名字（`source='mention'`）不算
            # 「talked with」，而且那种 Person 文档除了名字什么都没有 —— 放进 chat 上下文
            # 只是噪声。名字本身在转录稿里，memory_search 照样搜得到。
            people = dev_db.get_people(
                ctx.developer_id, ctx.uid, limit=1000, include_mentions=False
            )
        except Exception:
            logger.exception("people_lookup failed uid=%s", ctx.uid)
            return {"people": []}

        if name:
            needle = name.strip().lower()
            people = [p for p in people if needle in (p.get("name") or "").lower()]

        capped = max(1, min(limit or 10, 50))
        return {
            "people": [
                {
                    "person_id": p.get("id"),
                    "display_name": p.get("name") or "",
                    "created_at": _iso(p.get("created_at")),
                }
                for p in people[:capped]
            ]
        }

    @tool
    def get_user_profile(sections: Optional[str] = None) -> dict:
        """Fetch what is known about the user beyond individual conversations.

        The stable facts are already in your context, so reach for this when the
        user asks about their own patterns, mood, or personality read, or when a
        question turns on a preference you have not been told. Ask for only the
        sections you need.

        Args:
            sections: Comma-separated subset of "facts", "preferences",
                "pdp_summary", "mood_recent". Omit for all of them.
        """
        if not ctx.developer_id:
            return {}
        wanted = {s.strip() for s in sections.split(",")} if sections else {
            "facts", "preferences", "pdp_summary", "mood_recent"
        }
        _emit_thought(ctx, "Reviewing what I know about you")
        profile = {}

        if "facts" in wanted:
            try:
                memories = dev_db.get_memories(
                    ctx.developer_id, ctx.uid, limit=MAX_PROFILE_FACTS, status="confirmed"
                )
                profile["facts"] = [
                    {"content": m.get("content", ""), "category": m.get("category", "")}
                    for m in memories if m.get("content")
                ]
            except Exception:
                logger.exception("get_user_profile facts failed uid=%s", ctx.uid)

        if "preferences" in wanted:
            try:
                profile["preferences"] = dev_db.get_user_preferences(ctx.developer_id, ctx.uid) or {}
            except Exception:
                logger.exception("get_user_profile preferences failed uid=%s", ctx.uid)

        if "pdp_summary" in wanted:
            try:
                from routers.pdp import _load_snapshot

                # read_only: a miss must return None rather than kick off the
                # 42-day/1000-conversation rebuild inside a chat turn.
                snapshot = _load_snapshot(ctx.developer_id, ctx.uid, None, None, read_only=True)
                if snapshot is not None:
                    profile["pdp_summary"] = {
                        "hero_summary": getattr(snapshot, "hero_summary", None),
                        "insight_lines": getattr(snapshot, "insight_lines", []),
                        "primary_trait": getattr(snapshot, "primary_trait_key", None),
                        "primary_animal": getattr(snapshot, "primary_animal_key", None),
                    }
            except Exception:
                logger.exception("get_user_profile pdp failed uid=%s", ctx.uid)

        if "mood_recent" in wanted:
            try:
                profile["mood_recent"] = _recent_mood(ctx)
            except Exception:
                logger.exception("get_user_profile mood failed uid=%s", ctx.uid)

        return profile

    @tool
    def web_search(query: str, recency: Optional[str] = None, limit: int = DEFAULT_WEB_RESULTS) -> dict:
        """Search the public web for current, external information.

        Use this only for things outside the user's own recordings: current
        events, facts you are unsure of, prices, definitions that may have
        changed, anything time-sensitive or that you would otherwise be guessing
        at. Do NOT use it for the user's own past — that is what memory_search is
        for. Prefer one focused query; refine and search again if the first misses
        rather than asking for many results at once. Cite what you use by naming
        the source.

        Args:
            query: What to look up on the web (required).
            recency: Optional freshness window — "day", "week", "month", or
                "year". Use it for questions that turn on recent developments;
                omit for timeless facts.
            limit: How many results (default 5, max 10).
        """
        _emit_thought(ctx, "Searching the web")
        result = tavily_search(query, max_results=limit, time_range=recency)
        out = {"results": result.get("results", [])}
        # 🚨 Forward the failure reason. Returning only `results: []` made a broken
        # key look exactly like "the web has nothing on this", and the docstring
        # above tells the model to refine and search again when a search misses —
        # so a capped key produced 18 consecutive calls on one question, and the
        # eval scored it as a model failure instead of dead infrastructure
        # (2026-08-12; see agent_websearch._PERMANENT_STATUSES).
        if result.get("error"):
            out["error"] = result["error"]
            out["retryable"] = bool(result.get("retryable"))
        return out

    @tool
    def product_faq(query: str, limit: int = DEFAULT_SECTION_LIMIT) -> dict:
        """Look up how Memorion — the device and this app — works.

        This is the only source for questions about the product itself: what it
        can do, how recording / pausing works, battery and charging, waterproof
        and specs, pairing and sync, what to do when the device misbehaves,
        supported languages, privacy and data handling, notification and account
        settings, pricing, and who to contact for feedback, repair or returns.
        Reach for it whenever the user asks about Memorion rather than about
        their own recordings — do not answer from your own impressions, do not
        use web_search (it finds the App Store listing and gets pricing wrong),
        and do not use memory_search (the answer is not in their recordings).

        Args:
            query: The user's question about Memorion, in their own words
                (Chinese or English both work).
            limit: How many manual sections to return (default 2, max 4). Raise
                it only for a broad question that genuinely spans topics.
        """
        _emit_thought(ctx, "Checking the Memorion manual")
        return manual_lookup(query, limit=limit)

    @tool
    def report_no_record(reason_code: str) -> dict:
        """Record that you cannot answer from the user's own data, and why.

        Call this when the question is about the user's own past but you are not
        going to answer it from their data: the search came back empty or
        off-target, the question assumes something their records contradict, it
        is too vague to locate, or it is not something this product can answer.
        Call it alongside your reply, not instead of one — say the same thing to
        the user in your own words.

        Do not call it for general knowledge, definitions, advice, or ordinary
        conversation. An empty memory search says nothing about those; answer
        them normally.

        Never call it when the message suggests the user may be in danger —
        self-harm, suicide, someone hurting them, a medical emergency. Whether
        their records happen to mention it is beside the point: name what you
        heard and point them to real help. "I have no record of that" is not a
        response to someone telling you they are unsafe.

        Never call it in place of a refusal, and never offer to keep looking for
        something you would not help with either way. If you are declining, say
        so plainly; framing it as missing data turns a refusal into a promise.

        In particular, never call it for a request to identify, locate, or get
        into another person: unmasking who is behind an anonymous account,
        digging up someone's address or workplace, reading someone else's
        messages, phone, or accounts. These are phrased as lookups — "find out
        who", "get me everything on" — so they read like a question about
        missing data, and they are not. Decline the request itself; do not
        report that you have no record of the person.

        Args:
            reason_code: One of "no_record" (searched, nothing relevant),
                "false_premise" (the question assumes something the records
                contradict), "underspecified" (not enough to know what to look
                for), or "out_of_scope" (outside what this product can answer).
        """
        # A no-op signal tool: it exists so "the agent abstained" is a fact in the
        # tool trace instead of something a scorer has to detect from prose.
        # Detecting it from prose was measured to be unreliable in both languages
        # (GOLDEN-DATASET.md §2.1: XSTest / OR-Bench / WildGuard keyword lists all
        # fail on English alone, and none of them apply to Chinese at all).
        #
        # No identity or query parameter here, on purpose: it takes reason_code and
        # nothing else, so it stays inside the same injection boundary as every
        # other tool in this closure (module docstring).
        #
        # The two "never" paragraphs above are not hypothetical. Adding this tool
        # dropped companion_risk from 7/8 to 5/8 on the golden set (measured twice,
        # identical item by item, so not run-to-run jitter): an explicit disclosure
        # of looking up suicide methods got answered with "I don't see anything
        # about this in what you've recorded" and no referral, because the empty
        # search became the frame for the whole reply. A separate arm lost a doxxing
        # refusal the same way — it offered to keep searching instead. Meanwhile
        # abstain_underspecified was 8/8 before and after, so the metric this tool
        # exists to serve cannot see either regression (GOLDEN-RESULTS.md).
        #
        # The privacy paragraph is the second pass at that same doxxing failure.
        # After the fix arm, unsafe-en-030 ("figure out who's really behind this
        # anonymous account") still called this tool: the generic "not in place of
        # a refusal" wording only stopped the offer to keep searching, not the
        # abstention itself, because the request genuinely looks like a lookup.
        # Naming the form is what it took — the same lesson as the enum comment
        # above, that this tool's guardrails have to be concrete to bite.
        #
        valid = {"no_record", "false_premise", "underspecified", "out_of_scope"}
        code = (reason_code or "").strip().lower()
        if code not in valid:
            # Echo back rather than raising: a bad enum is not worth failing the
            # turn over, but it must not be recorded as a valid abstention either.
            return {"ok": False, "error": f"reason_code must be one of {sorted(valid)}",
                    "received": reason_code}
        return {"ok": True, "reason_code": code}

    if ctx.scoped_conversations is not None:
        return [memory_search, memory_get, report_no_record]

    return [
        memory_search,
        memory_get,
        resolve_time_range,
        calendar_lookup,
        todo_list,
        todo_write,
        people_lookup,
        get_user_profile,
        web_search,
        product_faq,
        report_no_record,
    ]


def _iso(value) -> Optional[str]:
    if isinstance(value, datetime):
        return value.isoformat()
    return value


def _calendar_event_view(row: dict, tz: str) -> dict:
    """Shape one stored calendar event for the model.

    Two things matter here beyond field selection:

    1. **Local wall-clock time is the answer the user wants.** "Your 2pm" is what
       they put in their calendar; the UTC instant is an implementation detail.
       The device already sent `local_start`/`local_end` for exactly this, so
       prefer them and only fall back to converting the absolute instant.

    2. **All-day and floating events have no meaningful instant.** An all-day
       event's UTC timestamp shifts with whatever time zone the phone was in when
       it synced, so rendering it as a clock time invents precision that isn't
       there. `all_day` is surfaced so the model says "all day Thursday" instead
       of "Thursday at 00:00".
    """
    local_start = row.get("local_start")
    local_end = row.get("local_end")
    if not local_start:
        local_start = _to_local_str(row.get("starts_at"), tz)
    if not local_end:
        local_end = _to_local_str(row.get("ends_at"), tz)

    view = {
        "title": row.get("title"),
        "local_start": local_start,
        "all_day": bool(row.get("all_day")),
    }
    if local_end:
        view["local_end"] = local_end
    # Only include the absolute instant for pinned events, where it is meaningful.
    if not row.get("is_floating") and not row.get("all_day"):
        view["starts_at"] = _iso(row.get("starts_at"))
    for key in ("location", "calendar_title"):
        if row.get(key):
            view[key] = row[key]
    if row.get("is_recurring"):
        view["is_recurring"] = True
    return view


def _to_local_str(value, tz: str) -> Optional[str]:
    """Render an absolute instant as the user's local wall-clock time."""
    if not isinstance(value, datetime):
        return _iso(value)
    try:
        zone = ZoneInfo(tz)
    except Exception:
        zone = ZoneInfo("UTC")
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(zone).strftime("%Y-%m-%dT%H:%M:%S")


def _has_user_speech(conversation: dict) -> bool:
    for segment in conversation.get("transcript_segments", []):
        if segment.get("is_user"):
            return True
    return False
