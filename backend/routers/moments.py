from typing import List
from fastapi import APIRouter, Depends

from models.chat import Message
from utils.other import endpoints as auth

router = APIRouter()


def get_moments(uid: str, limit: int = 20, offset: int = 0, developer_id: str = None) -> List[dict]:
    from google.cloud.firestore_v1 import FieldFilter
    from database._client import db

    if developer_id:
        user_ref = db.collection('developer_data').document(developer_id).collection('users').document(uid)
    else:
        return []

    messages_ref = (
        user_ref.collection('messages')
        .where(filter=FieldFilter('type', '==', 'day_summary'))
    )

    all_messages = []
    for doc in messages_ref.stream():
        message = doc.to_dict()
        if message.get('reported') is True:
            continue
        message['memories'] = []
        all_messages.append(message)

    all_messages.sort(key=lambda x: x.get('created_at') or '', reverse=True)

    return all_messages[offset:offset + limit]


@router.get('/v1/moments', tags=['moments'], response_model=List[Message])
def get_moments_endpoint(
    limit: int = 20,
    offset: int = 0,
    ctx: tuple = Depends(auth.get_current_user_context),
):
    developer_id, uid = ctx
    moments = get_moments(uid, limit=limit, offset=offset, developer_id=developer_id)
    return moments
