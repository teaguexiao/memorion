"""Owner-scoped, complete source records for a chapter's Ask session."""

import json
from concurrent.futures import ThreadPoolExecutor

from fastapi import HTTPException

import database.developer_data as dev_db


# Evidence fields only. Storage IDs, processing flags and empty optional values
# can outweigh the transcript on recordings with thousands of short segments.
# Keep speaker uncertainty, both timestamp axes and translations when present.
_TRANSCRIPT_CONTEXT_FIELDS = (
    "text", "speaker", "speaker_id", "is_user", "person_id", "speaker_status",
    "speaker_assignment_source", "start", "end", "original_start", "original_end",
    "timestamp_axis", "translations",
)


def _context_segment(segment: dict) -> dict:
    return {
        key: segment[key]
        for key in _TRANSCRIPT_CONTEXT_FIELDS
        if key in segment and segment[key] is not None and segment[key] != "" and segment[key] != []
    }


def context_records(conversations: list) -> list:
    """Keep recording/speaker boundaries and original transcript timestamps."""
    return [
        {
            "index": i + 1,
            "id": c["id"],
            "started_at": c.get("started_at") or c.get("created_at"),
            "finished_at": c.get("finished_at"),
            "structured": c.get("structured") or {},
            "transcript_segments": [_context_segment(s) for s in c.get("transcript_segments") or []],
        }
        for i, c in enumerate(conversations)
    ]


def serialize_context_records(conversations: list) -> str:
    """The exact evidence payload used by both the capacity check and prompt."""
    return json.dumps(context_records(conversations), ensure_ascii=False, default=str, separators=(",", ":"))


def load_conversation_context(developer_id: str, uid: str, ids: list) -> list:
    for cid in ids:
        if not cid.strip() or '/' in cid:
            raise HTTPException(status_code=422, detail="Invalid conversation id")
    def fetch(cid):
        c = dev_db.get_conversation(developer_id, uid, cid, include_photos=False)
        if not c or c.get("deleted"):
            raise HTTPException(status_code=404, detail="Linked conversation unavailable")
        return {**c, "id": cid}
    # Firestore's client supports threads. Bounded concurrent hydration avoids
    # one round-trip per source before SSE; executor.map preserves source order.
    with ThreadPoolExecutor(max_workers=8) as pool:
        conversations = list(pool.map(fetch, ids))
    # Bound the model input without dropping the tail of a recording. The caller
    # can surface this error and let the user open a smaller source recording.
    if len(serialize_context_records(conversations)) > 600_000:
        raise HTTPException(status_code=413, detail="Linked conversations exceed context capacity")
    return conversations
