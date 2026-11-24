from datetime import datetime, timezone
from enum import Enum
from typing import List, Optional, Dict

from pydantic import BaseModel, Field, field_validator

from models.chat import Message
from models.other import Person
from models.transcript_segment import TranscriptSegment


class CategoryEnum(str, Enum):
    personal = 'personal'
    education = 'education'
    health = 'health'
    finance = 'finance'
    legal = 'legal'
    philosophy = 'philosophy'
    spiritual = 'spiritual'
    science = 'science'
    entrepreneurship = 'entrepreneurship'
    parenting = 'parenting'
    romance = 'romantic'
    travel = 'travel'
    inspiration = 'inspiration'
    technology = 'technology'
    business = 'business'
    social = 'social'
    work = 'work'
    sports = 'sports'
    politics = 'politics'
    literature = 'literature'
    history = 'history'
    architecture = 'architecture'
    # Added at 2024-01-23
    music = 'music'
    weather = 'weather'
    news = 'news'
    entertainment = 'entertainment'
    psychology = 'psychology'
    real = 'real'
    design = 'design'
    family = 'family'
    economics = 'economics'
    environment = 'environment'
    other = 'other'


class UpdateConversation(BaseModel):
    title: Optional[str] = None
    overview: Optional[str] = None


class CaptureMode(str, Enum):
    """How the photo was captured"""
    manual = 'manual'       # User pressed capture button
    voice = 'voice'         # Triggered by voice command
    auto = 'auto'           # Automatic periodic capture
    context = 'context'     # Triggered by audio context detection


class PhotoSource(str, Enum):
    """Source of the photo"""
    realtime = 'realtime'   # Real-time BLE streaming
    sd_card = 'sd_card'     # Synced from device SD card


class ConversationPhoto(BaseModel):
    id: Optional[str] = None
    base64: str
    description: Optional[str] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    discarded: bool = False
    data_protection_level: Optional[str] = None
    # New fields for enhanced photo metadata
    capture_mode: CaptureMode = CaptureMode.manual
    resolution: Optional[str] = None  # e.g., "640x480", "1280x720"
    source: PhotoSource = PhotoSource.realtime
    local_timestamp: Optional[datetime] = None  # Original capture time from device

    @staticmethod
    def photos_as_string(photos: List['ConversationPhoto'], include_timestamps: bool = False) -> str:
        if not photos:
            return 'None'
        descriptions = []
        for p in photos:
            if p.description and p.description.strip():
                timestamp_str = ''
                if include_timestamps:
                    timestamp_str = f"[{p.created_at.strftime('%H:%M:%S')}] "
                descriptions.append(f'- {timestamp_str}"{p.description}"')

        if not descriptions:
            return 'None'
        return '\n'.join(descriptions)


# TODO: remove this class when the app is updated to use apps_results
class PluginResult(BaseModel):
    plugin_id: Optional[str]
    content: str


class AppResult(BaseModel):
    app_id: Optional[str]
    content: str


class ActionItem(BaseModel):
    description: str = Field(description="The action item to be completed")
    completed: bool = False
    # LLM 提取的待办要用户确认后才进 to-do list。新生成的一律 False，用户
    # 「加入待办」置 True、「不是待办」直接删。默认 True 是为了让确认态上线前
    # 的历史 action_items 继续照旧显示，而不是集体退回待确认。
    confirmed: bool = True
    # 截止时间拆成两个字段：机器能用的 + 人说的原话。
    # due_date 只在能确定到具体日期时才填，"本周内/尽快"这类模糊说法只进 due_hint
    # ——不强行推算，否则会往苹果提醒事项里写精确的假时间、在错的时间弹提醒。
    due_date: Optional[datetime] = Field(
        description="Deadline as an absolute datetime, ONLY when a specific date is determinable",
        default=None,
    )
    due_hint: str = Field(
        description="The timing as actually spoken, e.g. 'this week' / '尽快'. Empty if none.",
        default='',
    )

    @staticmethod
    def actions_to_string(action_items: List['ActionItem']) -> str:
        if not action_items:
            return 'None'
        return '\n'.join(
            [f"- {item.description} ({'completed' if item.completed else 'pending'})" for item in action_items]
        )


class Event(BaseModel):
    title: str = Field(description="The title of the event")
    description: str = Field(description="A brief description of the event", default='')
    start: datetime = Field(description="The start date and time of the event")
    duration: int = Field(description="The duration of the event in minutes", default=30)
    created: bool = False

    def as_dict_cleaned_dates(self):
        event_dict = self.dict()
        event_dict['start'] = event_dict['start'].isoformat()
        return event_dict

    @staticmethod
    def events_to_string(events: List['Event']) -> str:
        if not events:
            return 'None'
        # Format the datetime for better readability in the prompt
        return '\n'.join(
            [
                f"- {event.title} (Starts: {event.start.strftime('%Y-%m-%d %H:%M:%S %Z')}, Duration: {event.duration} mins)"
                for event in events
            ]
        )


class Structured(BaseModel):
    title: str = Field(description="A title/name for this conversation", default='')
    overview: str = Field(
        description="A source-grounded overview appropriate to the content. For work or meetings, detailed notes with substantive facts, discussion, decisions, risks and follow-ups organized by topic. For everyday life, direct natural paragraphs with concrete moments and a restrained warm tone. Length follows information density; never invent facts or pad to a word minimum.",
        default='',
        # No max_length constraint
    )
    emoji: str = Field(description="An emoji to represent the conversation", default='🧠')
    category: CategoryEnum = Field(description="A category for this conversation", default=CategoryEnum.other)
    action_items: List[ActionItem] = Field(description="A list of action items from the conversation", default=[])
    events: List[Event] = Field(
        description="A list of events extracted from the conversation, that the user must have on his calendar.",
        default=[],
    )
    emotion: str = Field(
        description="Emotion label for the overall conversation mood. MUST be one of: happy, angry, sad, surprised, calm",
        default='calm',
    )
    first_person_observation: str = Field(
        description=(
            "ONE concise timeline description: for work/meetings, a factual main issue, result "
            "or next step; for everyday life, an optional restrained and grounded companion aside. "
            "Do not invent feelings, preach or cheerlead. "
            "Under ~24 characters (CJK) / ~15 words. In {output_language}. Empty string if nothing "
            "worth noting."
        ),
        default='',
    )
    highlights: List[str] = Field(
        description=(
            "0 to 3 memorable quotes from one speaker's actual words in the transcript, in their "
            "ORIGINAL spoken language. Do not translate, paraphrase, polish, add speaker names, "
            "or combine speakers/recordings. Only correct individual ASR word errors when local "
            "context unambiguously supports the intended word; use matching user vocabulary "
            "for spelling, never force a term. Preserve all other wording, negation, uncertainty "
            "and self-corrections. Never infer or change numbers, dates, commitments, identity "
            "or facts. Keep ambiguous words as transcribed, or omit a misleading quote. "
            "Pick only heartfelt, decisive, funny or touching lines, under ~30 words each. "
            "Prefer fewer; return [] when nothing stands out."
        ),
        default=[],
    )

    @field_validator('highlights', mode='before')
    @classmethod
    def clean_highlights(cls, v):
        """Coerce highlights into a clean list[str] (cap 3, drop empties/dupes).

        LLMs occasionally return a single string, dicts ({"quote": ...}), or
        stray whitespace/quote marks. Keep it defensive so a malformed value
        never fails the whole conversation parse.
        """
        if not v:
            return []
        if isinstance(v, str):
            v = [v]
        result = []
        seen = set()
        for item in v:
            if isinstance(item, dict):
                item = item.get('quote') or item.get('text') or item.get('highlight') or ''
            if not isinstance(item, str):
                continue
            s = item.strip().strip('「」""\'')
            if s and s not in seen:
                seen.add(s)
                result.append(s)
            if len(result) >= 3:
                break
        return result

    @field_validator('category', mode='before')
    @classmethod
    def set_category_default_on_error(cls, v: any) -> 'CategoryEnum':
        if isinstance(v, CategoryEnum):
            return v
        try:
            return CategoryEnum(v)
        except ValueError:
            return CategoryEnum.other

    @field_validator('action_items', mode='before')
    @classmethod
    def convert_action_items(cls, v):
        """Convert string action items to ActionItem objects.

        Some LLM models return action_items as a list of strings instead of
        ActionItem objects. This validator handles both formats.
        """
        if not v:
            return []
        result = []
        for item in v:
            if isinstance(item, str):
                # If it's a string, convert to ActionItem object
                result.append(ActionItem(description=item, completed=False))
            elif isinstance(item, dict):
                result.append(ActionItem(**item))
            elif isinstance(item, ActionItem):
                result.append(item)
        return result

    @field_validator('events', mode='before')
    @classmethod
    def convert_events(cls, v):
        """Handle events validation with proper error handling.

        Skip malformed events instead of failing the entire parsing.
        """
        if not v:
            return []
        result = []
        for item in v:
            try:
                if isinstance(item, dict):
                    result.append(Event(**item))
                elif isinstance(item, Event):
                    result.append(item)
            except Exception:
                # Skip malformed events
                continue
        return result

    def __str__(self):
        result = (
            f"{str(self.title).capitalize()} ({str(self.category.value).capitalize()})\n"
            f"{str(self.overview).capitalize()}\n"
        )

        if self.action_items:
            result += f"Action Items:\n{ActionItem.actions_to_string(self.action_items)}\n"

        if self.events:
            result += f"Events:\n{Event.events_to_string(self.events)}\n"
        return result.strip()


class Geolocation(BaseModel):
    google_place_id: Optional[str] = None
    latitude: float
    longitude: float
    address: Optional[str] = None
    location_type: Optional[str] = None


class ConversationSource(str, Enum):
    friend = 'friend'
    omi = 'omi'
    openglass = 'openglass'
    screenpipe = 'screenpipe'
    workflow = 'workflow'
    sdcard = 'sdcard'
    external_integration = 'external_integration'
    audio_upload = 'audio_upload'
    app = 'app'


class PostProcessingStatus(str, Enum):
    not_started = 'not_started'
    in_progress = 'in_progress'
    completed = 'completed'
    canceled = 'canceled'
    failed = 'failed'


class ConversationStatus(str, Enum):
    in_progress = 'in_progress'
    processing = 'processing'
    completed = 'completed'
    failed = 'failed'


class PostProcessingModel(str, Enum):
    soniox_async = 'soniox_async'
    # Nothing writes this enum (`Conversation` has no `post_processing` field, so no
    # Firestore document has ever carried it), but `fal_whisperx` stays as a free
    # defense in case some document somewhere does.
    fal_whisperx = 'fal_whisperx'


class ConversationPostProcessing(BaseModel):
    status: PostProcessingStatus
    model: PostProcessingModel
    fail_reason: Optional[str] = None


class Conversation(BaseModel):
    id: str
    created_at: datetime
    started_at: Optional[datetime]
    finished_at: Optional[datetime]

    source: Optional[ConversationSource] = ConversationSource.omi
    language: Optional[str] = None  # applies only to Friend # TODO: once released migrate db to default 'en'

    structured: Structured
    transcript_segments: List[TranscriptSegment] = []
    transcript_segments_compressed: Optional[bool] = False
    geolocation: Optional[Geolocation] = None
    photos: List[ConversationPhoto] = []

    apps_results: List[AppResult] = []

    # TODO: plugins_results for backward compatibility with the old memories routes and app
    plugins_results: List[PluginResult] = []

    external_data: Optional[Dict] = None
    app_id: Optional[str] = None

    discarded: bool = False
    pinned: bool = False

    # TODO: processing_memory_id for backward compatibility with the old memories routes and app
    processing_memory_id: Optional[str] = None

    processing_conversation_id: Optional[str] = None

    status: Optional[ConversationStatus] = ConversationStatus.completed
    data_protection_level: Optional[str] = None

    # URL to audio recording in cloud storage (for playback when local audio is unavailable)
    # Deprecated: Use audio_path instead. audio_url contains signed URLs that expire.
    audio_url: Optional[str] = None

    # GCS path to audio recording (e.g., "conversations/{uid}/{conversation_id}/audio.wav")
    # Use this with the /audio-url endpoint to get a short-lived signed URL for download
    audio_path: Optional[str] = None

    # EIR (Emotion Intelligence Recognition) result for the user's emotion in this
    # conversation. Persisted so the mobile Avatar card can react to the latest emotion.
    eir_emotion: Optional[str] = None
    eir_confidence: Optional[float] = None
    eir_updated_at: Optional[datetime] = None

    def __init__(self, **data):
        super().__init__(**data)
        # Update plugins_results based on apps_results
        self.plugins_results = [PluginResult(plugin_id=app.app_id, content=app.content) for app in self.apps_results]
        self.processing_memory_id = self.processing_conversation_id

    @staticmethod
    def conversations_to_string(
        conversations: List['Conversation'],
        use_transcript: bool = False,
        include_timestamps: bool = False,
        people: List[Person] = None,
    ) -> str:
        result = []
        people_map = {p.id: p for p in people} if people else {}
        for i, conversation in enumerate(conversations):
            if isinstance(conversation, dict):
                conversation = Conversation(**conversation)
            formatted_date = conversation.created_at.astimezone(timezone.utc).strftime("%d %b %Y at %H:%M") + " UTC"
            conversation_str = (
                f"Conversation #{i + 1}\n"
                f"{formatted_date} ({str(conversation.structured.category.value).capitalize()})\n"
                f"{str(conversation.structured.title).capitalize()}\n"
                f"{str(conversation.structured.overview).capitalize()}\n"
            )

            # attendees
            if people_map:
                conv_person_ids = set(conversation.get_person_ids())
                if conv_person_ids:
                    attendees_names = [people_map[pid].name for pid in conv_person_ids if pid in people_map]
                    if attendees_names:
                        attendees = ", ".join(attendees_names)
                        conversation_str += f"Attendees: {attendees}\n"

            if conversation.structured.action_items:
                conversation_str += "Action Items:\n"
                for item in conversation.structured.action_items:
                    conversation_str += f"- {item.description}\n"

            if conversation.structured.events:
                conversation_str += "Events:\n"
                for event in conversation.structured.events:
                    conversation_str += f"- {event.title} ({event.start} - {event.duration} minutes)\n"

            if conversation.apps_results and len(conversation.apps_results) > 0:
                conversation_str += "Summarization:\n"
                conversation_str += f"{conversation.apps_results[0].content}"

            if use_transcript:
                conversation_str += f"\nTranscript:\n{conversation.get_transcript(include_timestamps=include_timestamps, people=people)}\n"
                # photos
                photo_descriptions = conversation.get_photos_descriptions(include_timestamps=include_timestamps)
                if photo_descriptions != 'None':
                    conversation_str += f"Photo Descriptions from a wearable camera:\n{photo_descriptions}\n"

            result.append(conversation_str.strip())

        return "\n\n---------------------\n\n".join(result).strip()

    def get_transcript(self, include_timestamps: bool, people: List[Person] = None, user_name: str = None) -> str:
        # Warn: missing transcript for workflow source, external integration source
        return TranscriptSegment.segments_as_string(
            self.transcript_segments, include_timestamps=include_timestamps, people=people, user_name=user_name
        )

    def get_photos_descriptions(self, include_timestamps: bool = False) -> str:
        return ConversationPhoto.photos_as_string(self.photos, include_timestamps=include_timestamps)

    def get_person_ids(self) -> List[str]:
        if not self.transcript_segments:
            return []
        return list(set(segment.person_id for segment in self.transcript_segments if segment.person_id))

    def as_dict_cleaned_dates(self):
        conversation_dict = self.dict()
        conversation_dict['structured']['events'] = [
            {**event, 'start': event['start'].isoformat()} for event in conversation_dict['structured']['events']
        ]

        if 'external_data' in conversation_dict and conversation_dict['external_data']:
            conversation_dict['external_data']['started_at'] = conversation_dict['started_at'].isoformat()
            conversation_dict['external_data']['finished_at'] = conversation_dict['finished_at'].isoformat()

        conversation_dict['created_at'] = conversation_dict['created_at'].isoformat()
        conversation_dict['started_at'] = (
            conversation_dict['started_at'].isoformat() if conversation_dict['started_at'] else None
        )
        conversation_dict['finished_at'] = (
            conversation_dict['finished_at'].isoformat() if conversation_dict['finished_at'] else None
        )

        return conversation_dict


class CreateConversation(BaseModel):
    started_at: datetime
    finished_at: datetime
    transcript_segments: List[TranscriptSegment]
    geolocation: Optional[Geolocation] = None

    photos: List[ConversationPhoto] = []

    source: ConversationSource = ConversationSource.omi
    language: Optional[str] = None

    processing_conversation_id: Optional[str] = None

    def get_transcript(self, include_timestamps: bool, people: List[Person] = None, user_name: str = None) -> str:
        return TranscriptSegment.segments_as_string(
            self.transcript_segments, include_timestamps=include_timestamps, people=people, user_name=user_name
        )

    def get_person_ids(self) -> List[str]:
        if not self.transcript_segments:
            return []
        return list(set(segment.person_id for segment in self.transcript_segments if segment.person_id))


class ExternalIntegrationConversationSource(str, Enum):
    audio = 'audio_transcript'
    message = 'message'
    other = 'other_text'


class ExternalIntegrationCreateConversation(BaseModel):
    started_at: Optional[datetime] = None
    finished_at: Optional[datetime] = None
    text: str
    text_source: ExternalIntegrationConversationSource = ExternalIntegrationConversationSource.audio
    text_source_spec: Optional[str] = None
    geolocation: Optional[Geolocation] = None

    source: ConversationSource = ConversationSource.workflow
    language: Optional[str] = None

    app_id: Optional[str] = None

    def get_transcript(self, include_timestamps: bool) -> str:
        return self.text


class CreateConversationResponse(BaseModel):
    conversation: Conversation
    messages: List[Message] = []


# MIGRATE: For backward compatibility with the old memories routes and app
class CreateMemoryResponse(BaseModel):
    memory: Conversation
    messages: List[Message] = []


class SetConversationEventsStateRequest(BaseModel):
    events_idx: List[int]
    values: List[bool]


class SetConversationActionItemsStateRequest(BaseModel):
    items_idx: List[int]
    values: List[bool]


class BulkAssignSegmentsRequest(BaseModel):
    segment_ids: List[str]
    assign_type: str
    value: Optional[str] = None


class DeleteActionItemRequest(BaseModel):
    description: str
    completed: bool


class UpdateActionItemDescriptionRequest(BaseModel):
    old_description: str
    description: str


class SearchRequest(BaseModel):
    query: str
    page: Optional[int] = 1
    per_page: Optional[int] = 10
    include_discarded: Optional[bool] = True
    start_date: Optional[str] = None  # ISO format datetime string
    end_date: Optional[str] = None  # ISO format datetime string


class TestPromptRequest(BaseModel):
    prompt: str
