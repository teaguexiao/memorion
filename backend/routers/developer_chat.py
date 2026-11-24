"""
Developer API - Chat endpoints

v2 flat message chat with agent-based retrieval (`/v2/messages` + `/v2/chat/sessions/*`).

v1 的 session 式 chat（`/v1/chat/sessions/*`，无检索的纯 LLM 路径）已于 2026-08-09 删除
——生产最后一次调用是 2026-03-02，且那批调用来自后来拆掉的 relay 功能。存量的
`chat_sessions` / `messages` 集合数据保留未动（见 `docs/chat-agent-overhaul-plan.md` §12）。

All data is tenant-isolated under developer_data/{developer_id}/users/{external_user_id}/
"""

import base64
import logging
import uuid
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Body, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

import database.developer_data as dev_db
from models.chat import (
    ChatSession,
    Message,
    SendMessageRequest,
    ResponseMessage,
    MessageConversation,
    resolve_cited_conversations,
)
from models.conversation import Conversation
from utils.llm.chat import initial_chat_message, generate_session_title
from utils.other import endpoints as auth
from utils.retrieval.graph import execute_graph_chat_stream
from utils.retrieval.conversation_context import load_conversation_context

logger = logging.getLogger(__name__)

router = APIRouter()


class TitleUpdateBody(BaseModel):
    title: str = Field(..., description="New session title")


# ******************************************************
# ****************** V2 CHAT (agent retrieval) *********
# ******************************************************


class V2ChatSessionCreate(BaseModel):
    title: Optional[str] = Field(None, description="Session title")
    context_conversation_ids: List[str] = Field(default_factory=list, max_length=100)


def acquire_chat_session(developer_id: str, uid: str, chat_session_id: Optional[str] = None):
    if chat_session_id:
        chat_session = dev_db.get_v2_chat_session_by_id(developer_id, uid, chat_session_id)
        return chat_session

    chat_session = dev_db.get_v2_chat_session(developer_id, uid, app_id=None)
    if chat_session is None:
        chat_session = dev_db.create_v2_new_chat_session(developer_id, uid, app_id=None)
    return chat_session


def shared_chat_sessions(developer_id: str, uid: str, default_id: str) -> list:
    """Default app history plus former chapter sessions; explicit chats stay separate."""
    return [session for session in dev_db.get_v2_chat_sessions(developer_id, uid, app_id=None)
            if session.get('id') == default_id or session.get('context_conversation_ids')]


def shared_chat_messages(developer_id: str, uid: str, default_id: str, **kwargs):
    sessions = shared_chat_sessions(developer_id, uid, default_id)
    scopes = {session['id']: session.get('context_conversation_ids', []) for session in sessions}
    messages = dev_db.get_v2_messages(developer_id, uid, app_id=None,
                                     chat_session_ids=list(dict.fromkeys([default_id, *scopes])), **kwargs)
    for message in messages:
        if message.get('sender') == 'human' and not message.get('context_conversation_ids'):
            message['context_conversation_ids'] = scopes.get(message.get('chat_session_id'), [])
    return messages


def initial_message_util(developer_id: str, uid: str, chat_session_id: Optional[str] = None):
    chat_session = acquire_chat_session(developer_id, uid, chat_session_id=chat_session_id)
    if chat_session is None:
        raise HTTPException(status_code=404, detail='Chat session not found')
    if chat_session.get('context_conversation_ids'):
        raise HTTPException(status_code=409, detail='Linked sessions use contextual messages')

    prev_messages = list(reversed(dev_db.get_v2_messages(
        developer_id, uid, limit=5, app_id=None, chat_session_id=chat_session['id']
    )))

    prev_messages_str = ''
    if prev_messages:
        prev_messages_str = 'Previous conversation history:\n'
        prev_messages_str += Message.get_messages_as_string([Message(**msg) for msg in prev_messages])
    text = initial_chat_message(uid, None, prev_messages_str)

    ai_message = Message(
        id=str(uuid.uuid4()),
        text=text,
        created_at=datetime.now(timezone.utc),
        sender='ai',
        app_id=None,
        from_external_integration=False,
        type='text',
        memories_id=[],
        chat_session_id=chat_session['id'],
    )
    dev_db.add_v2_message(developer_id, uid, ai_message.dict())
    dev_db.add_v2_message_to_chat_session(developer_id, uid, chat_session['id'], ai_message.id)
    return ai_message


@router.post('/v2/chat/sessions', tags=['chat'], response_model=ChatSession, status_code=201)
def create_v2_chat_session(
    data: Optional[V2ChatSessionCreate] = Body(None),
    title: Optional[str] = Query(None),
    context: tuple = Depends(auth.get_current_user_context),
):
    developer_id, uid = context
    requested_title = data.title if data and data.title is not None else title
    ids = list(dict.fromkeys(data.context_conversation_ids)) if data else []
    if ids:
        load_conversation_context(developer_id, uid, ids)
    return dev_db.create_v2_new_chat_session(
        developer_id, uid, app_id=None, title=requested_title, context_conversation_ids=ids
    )


@router.get('/v2/chat/sessions', tags=['chat'], response_model=List[ChatSession])
def list_v2_chat_sessions(context: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = context
    return dev_db.get_v2_chat_sessions(developer_id, uid, app_id=None)


@router.get('/v2/chat/sessions/{chat_session_id}', tags=['chat'], response_model=ChatSession)
def get_v2_chat_session(chat_session_id: str, context: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = context
    chat_session = dev_db.get_v2_chat_session_by_id(developer_id, uid, chat_session_id)
    if not chat_session:
        raise HTTPException(status_code=404, detail='Chat session not found')
    return chat_session


@router.put('/v2/chat/sessions/{chat_session_id}/title', tags=['chat'])
def update_v2_chat_session_title(
    chat_session_id: str,
    body: TitleUpdateBody,
    context: tuple = Depends(auth.get_current_user_context),
):
    developer_id, uid = context
    chat_session = dev_db.get_v2_chat_session_by_id(developer_id, uid, chat_session_id)
    if not chat_session:
        raise HTTPException(status_code=404, detail='Chat session not found')
    dev_db.update_v2_chat_session_title(developer_id, uid, chat_session_id, body.title)
    return {"message": "Title updated successfully"}


@router.delete('/v2/chat/sessions/{chat_session_id}', tags=['chat'])
def delete_v2_chat_session(chat_session_id: str, context: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = context
    chat_session = dev_db.get_v2_chat_session_by_id(developer_id, uid, chat_session_id)
    if not chat_session:
        raise HTTPException(status_code=404, detail='Chat session not found')

    dev_db.clear_v2_chat(developer_id, uid, app_id=None, chat_session_id=chat_session_id)
    dev_db.delete_v2_chat_session(developer_id, uid, chat_session_id)
    return {"message": "Chat session deleted successfully"}


@router.post('/v2/messages', tags=['chat'], response_model=ResponseMessage)
def send_message_v2(
    data: SendMessageRequest, chat_session_id: Optional[str] = None,
    context: tuple = Depends(auth.get_current_user_context)
):
    developer_id, uid = context
    # ⚠️ **不打提问原文。** 这里原来是 `print('send_message', data.text, uid)`，于是每一次
    # 提问的原文都进了 CloudWatch（2026-08-12 在生产日志里实测到整句）。这跟 span 那一侧
    # 「只记元数据」的口径是同一件事，而它就在 span 装饰的函数入口上方——只护住 span 等于
    # 没护住。要复现一次请求走过哪些工具，看同一 trace 的 span（`memorion.spans`）。
    logger.info("send_message uid=%s chars=%d session=%s",
                uid, len(data.text or ""), chat_session_id or "-")

    if chat_session_id:
        chat_session = dev_db.get_v2_chat_session_by_id(developer_id, uid, chat_session_id)
        if not chat_session:
            raise HTTPException(status_code=404, detail='Chat session not found')
        chat_session = ChatSession(**chat_session) if chat_session else None
    else:
        chat_session = acquire_chat_session(developer_id, uid)
        chat_session = ChatSession(**chat_session) if chat_session else None

    # Validate the entire scope again before writing a turn. Deleted/inaccessible
    # sources fail closed; never silently fall back to global retrieval.
    context_ids = list(dict.fromkeys(data.context_conversation_ids)) or (
        chat_session.context_conversation_ids if chat_session else []
    )
    scoped_conversations = load_conversation_context(
        developer_id, uid, context_ids
    ) if context_ids else None

    message = Message(
        id=str(uuid.uuid4()),
        text=data.text,
        created_at=datetime.now(timezone.utc),
        sender='human',
        type='text',
        app_id=None,
        context_conversation_ids=context_ids,
    )
    if chat_session:
        message.chat_session_id = chat_session.id
        dev_db.add_v2_message_to_chat_session(developer_id, uid, chat_session.id, message.id)

    dev_db.add_v2_message(developer_id, uid, message.dict())

    if (chat_session and
        hasattr(chat_session, 'title') and
        chat_session.title and
        (chat_session.title.startswith('New Chat') or not chat_session.title.strip()) and
        data.text and len(data.text.strip()) > 5):

        try:
            session_messages = dev_db.get_v2_messages(developer_id, uid, limit=10, chat_session_id=chat_session.id)
            user_messages = [msg for msg in session_messages if msg.get('sender') == 'human']

            if len(user_messages) <= 1:
                user_language = dev_db.get_user_language(developer_id, uid)
                new_title = generate_session_title(data.text, output_language=user_language)
                if new_title and new_title != "New Chat":
                    dev_db.update_v2_chat_session_title(developer_id, uid, chat_session.id, new_title)

        except Exception as e:
            print(f"Failed to generate title for session {chat_session.id}: {e}")

    app = None
    app_id = None

    # 80-turn window (was 10). Sonnet 5.5 has 1M context; the history tail is now
    # cached via a second breakpoint in _to_lc_messages, so raising this restores
    # in-session continuity without re-reading the whole tail at full price.
    history = (dev_db.get_v2_messages(developer_id, uid, limit=80, app_id=None,
                                      chat_session_id=chat_session.id)
               if chat_session_id else shared_chat_messages(developer_id, uid, chat_session.id, limit=80))
    messages = list(reversed([Message(**msg) for msg in history]))

    def process_message(response: str, callback_data: dict):
        memories = callback_data.get('memories_found', [])
        ask_for_nps = callback_data.get('ask_for_nps', False)

        # Strips the `[n]` markers, resolves them to conversations in citation
        # order, and caps the list — one function so `memories_id` (stored) and
        # `ai_message.memories` (displayed) can never disagree about the count.
        response, memories = resolve_cited_conversations(response, memories)

        memories_id = []
        if memories:
            converted_memories = []
            for m in memories:
                if isinstance(m, dict):
                    converted_memories.append(Conversation(**m))
                else:
                    converted_memories.append(m)
            memories_id = [m.id for m in converted_memories]

        ai_message = Message(
            id=str(uuid.uuid4()),
            text=response,
            created_at=datetime.now(timezone.utc),
            sender='ai',
            app_id=app_id,
            type='text',
            memories_id=memories_id,
        )
        if chat_session:
            ai_message.chat_session_id = chat_session.id
            dev_db.add_v2_message_to_chat_session(developer_id, uid, chat_session.id, ai_message.id)

        dev_db.add_v2_message(developer_id, uid, ai_message.dict())
        ai_message.memories = [MessageConversation(**m) for m in memories]

        return ai_message, ask_for_nps

    async def generate_stream():
        callback_data = {}
        async for chunk in execute_graph_chat_stream(
            uid, messages, app, cited=True, callback_data=callback_data, chat_session=chat_session,
            developer_id=developer_id, scoped_conversations=scoped_conversations
        ):
            if chunk:
                msg = chunk.replace("\n", "__CRLF__")
                yield f'{msg}\n\n'
            else:
                response = callback_data.get('answer')
                if response:
                    ai_message, ask_for_nps = process_message(response, callback_data)
                    ai_message_dict = ai_message.dict()
                    response_message = ResponseMessage(**ai_message_dict)
                    response_message.ask_for_nps = ask_for_nps
                    data = base64.b64encode(bytes(response_message.model_dump_json(), 'utf-8')).decode('utf-8')
                    yield f"done: {data}\n\n"

    return StreamingResponse(generate_stream(), media_type="text/event-stream")


@router.post('/v2/messages/{message_id}/report', tags=['chat'], response_model=dict)
def report_message_v2(message_id: str, context: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = context
    message_data, msg_doc_id = dev_db.get_v2_message(developer_id, uid, message_id)
    if message_data is None:
        raise HTTPException(status_code=404, detail='Message not found')
    message = Message(**message_data)
    if message.sender != 'ai':
        raise HTTPException(status_code=400, detail='Only AI messages can be reported')
    if message.reported:
        raise HTTPException(status_code=400, detail='Message already reported')
    dev_db.report_v2_message(developer_id, uid, msg_doc_id)
    return {'message': 'Message reported'}


@router.delete('/v2/messages', tags=['chat'], response_model=Message)
def clear_chat_messages_v2(chat_session_id: Optional[str] = None, context: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = context
    explicit_session = bool(chat_session_id)
    if not explicit_session:
        chat_session = acquire_chat_session(developer_id, uid)
        chat_session_id = chat_session['id']
        for session in shared_chat_sessions(developer_id, uid, chat_session_id):
            if session['id'] != chat_session_id:
                dev_db.clear_v2_chat(developer_id, uid, app_id=None, chat_session_id=session['id'])
                dev_db.delete_v2_chat_session(developer_id, uid, session['id'])

    dev_db.clear_v2_chat(developer_id, uid, app_id=None, chat_session_id=chat_session_id)

    # Keep the emptied normal session as the default. Deleting it would select
    # an older independent session on the next load and resurrect its history.
    if chat_session_id is not None and explicit_session:
        dev_db.delete_v2_chat_session(developer_id, uid, chat_session_id)

    return initial_message_util(developer_id, uid, chat_session_id=None)


@router.post('/v2/initial-message', tags=['chat'], response_model=Message)
def create_initial_message_v2(chat_session_id: Optional[str] = None, context: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = context
    return initial_message_util(developer_id, uid, chat_session_id)


@router.get('/v2/messages', response_model=List[Message], tags=['chat'])
def get_messages_v2(chat_session_id: Optional[str] = None, context: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = context
    shared = not chat_session_id
    if shared:
        chat_session = acquire_chat_session(developer_id, uid)
        chat_session_id = chat_session['id']
    elif not dev_db.get_v2_chat_session_by_id(developer_id, uid, chat_session_id):
        raise HTTPException(status_code=404, detail='Chat session not found')

    messages = (shared_chat_messages(developer_id, uid, chat_session_id, limit=100, include_conversations=True)
                if shared else dev_db.get_v2_messages(
                    developer_id, uid, limit=100, include_conversations=True, app_id=None,
                    chat_session_id=chat_session_id))
    if not messages:
        if chat_session_id:
            session = dev_db.get_v2_chat_session_by_id(developer_id, uid, chat_session_id)
            if session and session.get('context_conversation_ids'):
                return []
        return [initial_message_util(developer_id, uid, chat_session_id)]
    return messages


