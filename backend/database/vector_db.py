import json
import os
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from typing import List

from pinecone import Pinecone

from models.conversation import Conversation
from utils.llm.embeddings import generate_embedding_query

if os.getenv('PINECONE_API_KEY') is not None:
    pc = Pinecone(api_key=os.getenv('PINECONE_API_KEY', ''))
    index = pc.Index(os.getenv('PINECONE_INDEX_NAME', ''))
else:
    index = None


def _get_data(uid: str, conversation_id: str, vector: List[float]):
    """Base vector payload. Callers with real metadata must override `created_at`.

    ⚠️ `created_at` here means **when the conversation happened** (the recording's
    `started_at`), not when this vector was written — that one is `indexed_at`.
    The time filter in `query_vectors_by_metadata` / `memory_search` reads
    `created_at`, so writing the insert instant into it relocates a recording to
    the moment it was uploaded: 2026-08-18 measurements put `audio_upload` at p90
    16.03h / max 20.17h of skew, which silently drops the conversation out of any
    "what did I do on the 13th" query.

    The `now()` below is only a fallback for the two no-metadata helpers
    (`upsert_vector` / `upsert_vectors`, neither of which has a production caller).
    Both real write paths — `upsert_vector2` and `save_vector_from_dict` — always
    overwrite it from the conversation's `started_at`.
    """
    now = int(datetime.now(timezone.utc).timestamp())
    return {
        "id": f'{uid}-{conversation_id}',
        "values": vector,
        'metadata': {
            'uid': uid,
            'memory_id': conversation_id,
            'created_at': now,
            'indexed_at': now,
        },
    }


def upsert_vector(uid: str, conversation: Conversation, vector: List[float]):
    res = index.upsert(vectors=[_get_data(uid, conversation.id, vector)], namespace="ns1")
    print('upsert_vector', res)


def upsert_vector2(uid: str, conversation: Conversation, vector: List[float], metadata: dict):
    data = _get_data(uid, conversation.id, vector)
    data['metadata'].update(metadata)
    res = index.upsert(vectors=[data], namespace="ns1")
    print('upsert_vector', res)


def update_vector_metadata(uid: str, conversation_id: str, metadata: dict):
    metadata['uid'] = uid
    metadata['memory_id'] = conversation_id
    return index.update(f'{uid}-{conversation_id}', set_metadata=metadata, namespace="ns1")


def upsert_vectors(uid: str, vectors: List[List[float]], conversations: List[Conversation]):
    data = [_get_data(uid, conversation.id, vector) for conversation, vector in zip(conversations, vectors)]
    res = index.upsert(vectors=data, namespace="ns1")
    print('upsert_vectors', res)


def query_vectors(query: str, uid: str, starts_at: int = None, ends_at: int = None, k: int = 5) -> List[str]:
    filter_data = {'uid': uid}
    if starts_at is not None:
        filter_data['created_at'] = {'$gte': starts_at, '$lte': ends_at}

    # print('filter_data', filter_data)
    xq = generate_embedding_query(query).values
    xc = index.query(vector=xq, top_k=k, include_metadata=False, filter=filter_data, namespace="ns1")
    # print(xc)
    return [item['id'].replace(f'{uid}-', '') for item in xc['matches']]


def query_vectors_by_metadata(
    uid: str,
    vector: List[float],
    dates_filter: List[datetime],
    people: List[str],
    topics: List[str],
    entities: List[str],
    dates: List[str],
    limit: int = 5,
):
    filter_data = {
        '$and': [
            {'uid': {'$eq': uid}},
        ]
    }
    or_conditions = []
    if people:
        or_conditions.append({'people': {'$in': people}})
    if topics:
        or_conditions.append({'topics': {'$in': topics}})
    if entities:
        or_conditions.append({'entities': {'$in': entities}})
    if or_conditions:
        filter_data['$and'].append({'$or': or_conditions})
    if dates_filter and len(dates_filter) == 2 and dates_filter[0] and dates_filter[1]:
        print('dates_filter', dates_filter)
        filter_data['$and'].append(
            {'created_at': {'$gte': int(dates_filter[0].timestamp()), '$lte': int(dates_filter[1].timestamp())}}
        )

    print('query_vectors_by_metadata:', json.dumps(filter_data))

    def _query(top_k: int, current_filter: dict):
        """One Pinecone query, retrying smaller when the response is too large.

        Pinecone caps a query response at 4MB. `include_metadata=True` makes
        each match carry its people/topics/entities lists, so a wide top_k can
        cross that limit and raise — which previously propagated up and failed
        the whole chat turn. Stepping top_k down and retrying degrades the
        result set instead of losing the answer.
        """
        ladder = [k for k in (top_k, top_k // 4, 100) if 0 < k <= top_k]
        for attempt_top_k in dict.fromkeys(ladder):
            try:
                return index.query(
                    vector=vector,
                    filter=current_filter,
                    namespace="ns1",
                    include_values=False,
                    include_metadata=True,
                    top_k=attempt_top_k,
                )
            except Exception as e:
                print(f'query_vectors_by_metadata: query failed at top_k={attempt_top_k}: {e}')
        return None

    xc = _query(10000, filter_data)
    if xc is None:
        return []
    if not xc['matches']:
        if len(filter_data['$and']) == 3:
            filter_data['$and'].pop(1)
            print('query_vectors_by_metadata retrying without structured filters:', json.dumps(filter_data))
            xc = _query(20, filter_data)
            if xc is None:
                return []
        else:
            return []

    conversation_id_to_matches = defaultdict(int)
    for item in xc['matches']:
        metadata = item['metadata']
        conversation_id = metadata['memory_id']
        for topic in topics:
            if topic in metadata.get('topics', []):
                conversation_id_to_matches[conversation_id] += 1
        for entity in entities:
            if entity in metadata.get('entities', []):
                conversation_id_to_matches[conversation_id] += 1
        for person in people:
            if person in metadata.get('people', []):
                conversation_id_to_matches[conversation_id] += 1

    conversations_id = [item['id'].replace(f'{uid}-', '') for item in xc['matches']]
    conversations_id.sort(key=lambda x: conversation_id_to_matches[x], reverse=True)
    print('query_vectors_by_metadata result:', conversations_id)
    return conversations_id[:limit] if len(conversations_id) > limit else conversations_id


def delete_vector(uid: str, conversation_id: str):
    """Delete a conversation's vector.

    The id must be built the same way `_get_data` builds it (`{uid}-{id}`) —
    passing the bare conversation_id deletes nothing and leaves a vector the
    retrieval path can still return, pointing at a conversation that no longer
    exists in Firestore. `memory_search` then resolves those ids against
    Firestore, gets nothing back, and the agent answers "I found nothing"
    while the index keeps reporting hits.
    """
    result = index.delete(ids=[f'{uid}-{conversation_id}'], namespace="ns1")
    print('delete_vector', uid, conversation_id, result)
