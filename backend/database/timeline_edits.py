"""Durable corrections under the owning user, alongside timeline_days.

This sibling collection survives projection replacement and is included in the
existing account deletion sweep (which deletes immediate user subcollections).
Firestore field merges allow simultaneous title/body edits without lost updates.
"""

from datetime import datetime, timezone

import database.developer_data as dev_db


def _collection(developer_id: str, external_user_id: str):
    return (dev_db._get_user_ref(developer_id, external_user_id)
            .collection('timeline_edits'))


def get_chapter_edits(developer_id: str, external_user_id: str, day: str) -> dict:
    query = _collection(developer_id, external_user_id).where('date', '==', day)
    return {doc.id.removeprefix(f'{day}_'): doc.to_dict() for doc in query.stream()}


def save_chapter_edit(developer_id: str, external_user_id: str, day: str,
                      edit_id: str, fields: dict) -> dict:
    ref = _collection(developer_id, external_user_id).document(f'{day}_{edit_id}')
    payload = {**fields, 'date': day, 'updated_at': datetime.now(timezone.utc)}
    # Replace map-valued fields atomically; recursive merge retains a previous
    # operation's enrollment receipt and can make undo target the wrong sample.
    ref.set(payload, merge=list(payload))
    return ref.get().to_dict()
