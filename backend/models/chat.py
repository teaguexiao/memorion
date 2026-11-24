import re
from datetime import datetime
from enum import Enum
from typing import List, Optional, Any

from pydantic import BaseModel, Field, model_validator

# How many conversation cards one AI answer may carry. Lives here rather than in
# a router because two separate call sites cap the same list and drifted apart
# once already (one stored 5 while the other displayed 5 via different
# expressions), and a shared constant is what keeps them honest.
#
# Set to 3 because retrieval breadth and displayed cards are separate numbers but
# not unrelated: the agent cites only what it used, so the median stays at 1
# citation per answer regardless of the search limit — yet the tail does grow with
# it. Measured over 60 LongMemEval questions (evaluation/chat-agent/RESULTS.md), raising
# DEFAULT_SEARCH_LIMIT 3 -> 5 moved the max from 4 to 9 citations while leaving the
# median at 1. This cap is what bounds that tail; it bites on 5/60 answers either
# way.
MAX_CITED_CONVERSATIONS = 3


def resolve_cited_conversations(response: str, memories: list) -> tuple:
    """Map the `[n]` markers in an answer back to conversations, capped.

    Returns `(clean_response, conversations)`. Lives here, as one function, because
    three call sites used to re-implement it and two of them sliced the list with
    different expressions — so changing the cap in one place stored a different
    number of citations than the app displayed.

    Order follows the answer's first mention of each index, not retrieval rank: a
    `set` (the previous shape) sorts by index, which silently means "keep the
    highest-ranked" once the cap starts dropping entries. `memories[i - 1]`
    matches the 1-based index `CitationAccumulator` handed the model.
    """
    ordered_idxs = list(dict.fromkeys(int(i) for i in re.findall(r'\[(\d+)\]', response or '')))
    if ordered_idxs:
        response = re.sub(r'\[\d+\]', '', response)
    cited = [memories[i - 1] for i in ordered_idxs if 0 < i <= len(memories)]
    return response, cited[:MAX_CITED_CONVERSATIONS]


class MessageSender(str, Enum):
    ai = 'ai'
    human = 'human'


class MessageType(str, Enum):
    text = 'text'
    day_summary = 'day_summary'


class MessageConversationStructured(BaseModel):
    title: str
    emoji: str


class MessageConversation(BaseModel):
    id: str
    structured: MessageConversationStructured
    created_at: datetime


class Message(BaseModel):
    id: str
    text: str
    created_at: datetime
    sender: MessageSender
    app_id: Optional[str] = None
    # TODO: remove plugin_id after migration
    plugin_id: Optional[str] = None
    from_external_integration: bool = False
    type: MessageType
    context_conversation_ids: List[str] = Field(default_factory=list)
    memories_id: List[str] = []  # used in db
    memories: List[MessageConversation] = []  # used front facing
    reported: bool = False
    report_reason: Optional[str] = None
    chat_session_id: Optional[str] = None
    data_protection_level: Optional[str] = None
    summary_image_url: Optional[str] = None  # URL for daily summary image
    emotion_title: Optional[str] = None  # 一句话情绪标题（day_summary），日记卡/详情 Hero 优先显示

    @model_validator(mode='before')
    @classmethod
    def _sync_app_and_plugin_ids(cls, data: Any) -> Any:
        if isinstance(data, dict):
            app_id_val = data.get('app_id')
            plugin_id_val = data.get('plugin_id')

            if app_id_val is not None:
                data['plugin_id'] = app_id_val
            elif plugin_id_val is not None:
                data['app_id'] = plugin_id_val
        return data

    @staticmethod
    def get_messages_as_string(
        messages: List['Message'], use_user_name_if_available: bool = False, use_plugin_name_if_available: bool = False
    ) -> str:
        sorted_messages = sorted(messages, key=lambda m: m.created_at)

        def get_sender_name(message: Message) -> str:
            if message.sender == 'human':
                return 'User'
            # elif use_plugin_name_if_available and message.app_id is not None:
            #     plugin = next((p for p in plugins if p.id == message.app_id), None)
            #     if plugin:
            #         return plugin.name RESTORE ME
            return message.sender.upper()  # TODO: use app id

        formatted_messages = [
            f"({message.created_at.strftime('%d %b %Y at %H:%M UTC')}) {get_sender_name(message)}: {message.text}"
            for message in sorted_messages
        ]

        return '\n'.join(formatted_messages)

    @staticmethod
    def get_messages_as_xml(
        messages: List['Message'], use_user_name_if_available: bool = False, use_plugin_name_if_available: bool = False
    ) -> str:
        sorted_messages = sorted(messages, key=lambda m: m.created_at)

        def get_sender_name(message: Message) -> str:
            if message.sender == 'human':
                return 'User'
            # elif use_plugin_name_if_available and message.app_id is not None:
            #     plugin = next((p for p in plugins if p.id == message.app_id), None)
            #     if plugin:
            #         return plugin.name RESTORE ME
            return message.sender.upper()  # TODO: use app id

        formatted_messages = [
            f"""
                <message>
                <created_at>
                    {message.created_at.strftime('%d %b %Y at %H:%M UTC')}
                </created_at>
                <sender>
                    {get_sender_name(message)}
                </sender>
                <content>
                    {message.text}
                </content>
                </message>
            """.replace(
                '    ', ''
            )
            .replace('\n\n\n', '\n\n')
            .strip()
            for message in sorted_messages
        ]

        return '\n'.join(formatted_messages)


class ResponseMessage(Message):
    ask_for_nps: Optional[bool] = False


class SendMessageRequest(BaseModel):
    text: str
    # Per-turn source scope lets chapter Ask share the default chat history.
    context_conversation_ids: List[str] = Field(default_factory=list, max_length=100)


class ChatSession(BaseModel):
    id: str
    context_conversation_ids: List[str] = []
    message_ids: Optional[List[str]] = []
    app_id: Optional[str] = None
    plugin_id: Optional[str] = None
    created_at: datetime
    title: Optional[str] = None

    @model_validator(mode='before')
    @classmethod
    def _sync_chat_session_app_and_plugin_ids(cls, data: Any) -> Any:
        if isinstance(data, dict):
            app_id_val = data.get('app_id')
            plugin_id_val = data.get('plugin_id')

            if app_id_val is not None:
                data['plugin_id'] = app_id_val
            elif plugin_id_val is not None:
                data['app_id'] = plugin_id_val
        return data


class UpdateChatSessionTitleRequest(BaseModel):
    title: str
