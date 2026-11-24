import base64
import uuid
from datetime import datetime, timezone
from typing import List, AsyncGenerator

import database.developer_data as dev_db
from models.chat import MAX_CITED_CONVERSATIONS, Message, ResponseMessage, MessageConversation
from models.conversation import Conversation
from models.transcript_segment import TranscriptSegment
from utils.retrieval.graph import execute_graph_chat, execute_graph_chat_stream
from utils.stt.pre_recorded import soniox_transcribe_file

# ⚠️ Nothing imports this module today — it is the voice-message half of the deleted
# v1 chat path. It is kept transcribing-capable rather than deleted because the
# `MAX_CITED_CONVERSATIONS` note below shows the intent is to be able to revive it.
#
# Soniox takes a local path, so the GCS round-trip these three functions used to do
# (`get_syncing_file_temporal_signed_url` + a thread that slept 480s before deleting
# the temporal file) is gone along with FAL.


def transcribe_voice_message_segment(path: str):
    transcript_segments: List[TranscriptSegment]
    transcript_segments, language = soniox_transcribe_file(path)
    if not transcript_segments:
        print('failed to get soniox segments')
        return None

    text = " ".join([segment.text for segment in transcript_segments]).strip()
    if len(text) == 0:
        print('voice message text is empty')
        return None

    return text


def process_voice_message_segment(path: str, uid: str, developer_id: str = None):
    transcript_segments: List[TranscriptSegment]
    transcript_segments, language = soniox_transcribe_file(path)
    if not transcript_segments:
        print('failed to get soniox segments')
        return []

    text = " ".join([segment.text for segment in transcript_segments]).strip()
    if len(text) == 0:
        print('voice message text is empty')
        return []

    message = Message(
        id=str(uuid.uuid4()), text=text, created_at=datetime.now(timezone.utc), sender='human', type='text'
    )
    if developer_id:
        dev_db.add_v2_message(developer_id, uid, message.dict())

    app = None
    app_id = None

    if developer_id:
        # 80-turn window (was 10); tail cached via second breakpoint (graph._to_lc_messages).
        messages = list(reversed([Message(**msg) for msg in dev_db.get_v2_messages(developer_id, uid, limit=80, app_id=None)]))
    else:
        messages = []
    response, ask_for_nps, memories = execute_graph_chat(uid, messages, app, developer_id=developer_id)
    memories = memories[:MAX_CITED_CONVERSATIONS]
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
    if developer_id:
        dev_db.add_v2_message(developer_id, uid, ai_message.dict())
    ai_message.memories = memories

    ai_message_resp = ai_message.dict()
    ai_message_resp['ask_for_nps'] = ask_for_nps


    return [message.dict(), ai_message_resp]


async def process_voice_message_segment_stream(path: str, uid: str, developer_id: str = None) -> AsyncGenerator[str, None]:
    transcript_segments: List[TranscriptSegment]
    transcript_segments, language = soniox_transcribe_file(path)
    if not transcript_segments:
        print('failed to get soniox segments')
        return

    text = " ".join([segment.text for segment in transcript_segments]).strip()
    if len(text) == 0:
        print('voice message text is empty')
        return

    message = Message(
        id=str(uuid.uuid4()), text=text, created_at=datetime.now(timezone.utc), sender='human', type='text'
    )
    if developer_id:
        dev_db.add_v2_message(developer_id, uid, message.dict())

    mdata = base64.b64encode(bytes(message.model_dump_json(), 'utf-8')).decode('utf-8')
    yield f"message: {mdata}\n\n"

    app = None
    app_id = None

    def process_message(response: str, callback_data: dict):
        memories = callback_data.get('memories_found', [])
        ask_for_nps = callback_data.get('ask_for_nps', False)
        # Same bound as the live v2 path (routers/developer_chat.py); kept in sync
        # so reviving this voice-message path cannot silently reintroduce the old
        # cap of 5.
        memories = memories[:MAX_CITED_CONVERSATIONS]

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
        if developer_id:
            dev_db.add_v2_message(developer_id, uid, ai_message.dict())
        ai_message.memories = [MessageConversation(**m) for m in memories]

        return ai_message, ask_for_nps

    if developer_id:
        # 80-turn window (was 10); tail cached via second breakpoint (graph._to_lc_messages).
        messages = list(reversed([Message(**msg) for msg in dev_db.get_v2_messages(developer_id, uid, limit=80, app_id=None)]))
    else:
        messages = []
    callback_data = {}
    async for chunk in execute_graph_chat_stream(uid, messages, app, cited=False, callback_data=callback_data, developer_id=developer_id):
        if chunk:
            data = chunk.replace("\n", "__CRLF__")
            yield f'{data}\n\n'

        else:
            response = callback_data.get('answer')
            if response:
                ai_message, ask_for_nps = process_message(response, callback_data)
                ai_message_dict = ai_message.dict()
                response_message = ResponseMessage(**ai_message_dict)
                response_message.ask_for_nps = ask_for_nps
                data = base64.b64encode(bytes(response_message.model_dump_json(), 'utf-8')).decode('utf-8')
                yield f"done: {data}\n\n"


    return
