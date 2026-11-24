import os
import datetime
import random
import re
import threading
import traceback
import uuid
from datetime import timezone
from typing import Union, Tuple, List, Optional

from fastapi import HTTPException

from database import redis_db
import database.developer_data as dev_db
from database.vector_db import upsert_vector2, update_vector_metadata
from models.memories import MemoryDB, Memory
from models.conversation import *
from models.conversation import (
    ExternalIntegrationCreateConversation,
    Conversation,
    CreateConversation,
    ConversationSource,
)
from models.other import Person
from models.trend import Trend
from utils.llm.conversation_processing import (
    get_transcript_structure,
    should_discard_conversation,
    get_reprocess_transcript_structure,
    extract_people_from_conversation,
    clear_action_items_if_user_absent,
    merge_discard_verdict,
)
from utils.analytics import record_usage
from utils.llm.memories import extract_memories_from_text, new_memories_extractor
from utils.llm.external_integrations import summarize_experience_text
from utils.llm.trends import trends_extractor
from utils.llm.chat import (
    retrieve_metadata_from_text,
    retrieve_metadata_from_message,
    retrieve_metadata_fields_from_transcript,
)
from utils.llm.external_integrations import get_message_structure
from utils.llm.embeddings import generate_embedding_document, structured_as_embedding_text
from utils.webhooks import conversation_created_webhook


# 这里原本有 `_OFFLINE_CAPTURE_SOURCES = {audio_upload, sdcard}`，用来推
# `speaker_attribution_available`：那两条路上文件到达时录音早已结束，没有任何一刻能让
# 用户标注说话人，所以 `user_segments == 0` 是结构上必然的、不是证据（2026-08-15 靠这个
# 名单救回了手表上传，13 条里有 11 条本来被丢）。
#
# 2026-08-22 连常量一起删了：判据换成「此刻 `is_user` 有没有真的被写上」之后 `source`
# 不再参与这个决定，常量就没有消费点了 —— 而按 source 推恰恰漏掉了实时链路，那里同样
# 结构上拿不到 `is_user`。见下面 `should_discard_conversation` 调用处与
# evaluation/discard/README.md。


def _mark_action_items_unconfirmed(structured: Structured) -> Structured:
    """LLM 刚提取的待办都是「待确认」，用户在 app 里点「加入待办」才进 to-do list。

    `ActionItem.confirmed` 默认 True 是为了兼容确认态上线前的历史数据，所以每个
    新鲜出炉的 structured 都要显式盖成 False。
    """
    if structured and structured.action_items:
        for item in structured.action_items:
            item.confirmed = False
    return structured


def _get_structured(
    uid: str,
    language_code: str,
    conversation: Union[Conversation, CreateConversation, ExternalIntegrationCreateConversation],
    force_process: bool = False,
    people: List[Person] = None,
    output_language: str = None,
    developer_id: str = None,
) -> Tuple[Structured, bool]:
    try:
        tz = dev_db.get_user_time_zone(developer_id, uid) if developer_id else None
        # Custom vocabulary as a proper-noun correction hint (best-effort; empty
        # when the user has none or developer_id is missing → prompt unchanged).
        vocabulary_terms = dev_db.get_vocabulary_terms(developer_id, uid)
        if (
            conversation.source == ConversationSource.workflow
            or conversation.source == ConversationSource.external_integration
        ):
            if conversation.text_source == ExternalIntegrationConversationSource.audio:
                structured = get_transcript_structure(conversation.text, conversation.started_at, language_code, tz, output_language=output_language, vocabulary_terms=vocabulary_terms)
                return structured, False

            if conversation.text_source == ExternalIntegrationConversationSource.message:
                structured = get_message_structure(
                    conversation.text, conversation.started_at, language_code, tz, conversation.text_source_spec,
                    output_language=output_language,
                )
                return structured, False

            if conversation.text_source == ExternalIntegrationConversationSource.other:
                structured = summarize_experience_text(conversation.text, conversation.text_source_spec)
                return structured, False

            # not supported conversation source
            raise HTTPException(status_code=400, detail=f'Invalid conversation source: {conversation.text_source}')

        # 🚨 No `user_name=` here on purpose. `segments_as_string` falls back to the
        # literal "User" when it's absent, and that literal is what every consumer
        # of `transcript_text` below matches on: the summarizer prompt hardcodes
        # it at `utils/llm/conversation_processing.py` :390 / :419 / :585, and :419
        # is a *negative* test — "the \"User\" label never appears in the transcript
        # (only \"Speaker N\") — this strongly suggests the user was not speaking,
        # just listening to media". Threading the display name through here made
        # that branch read as true whenever the wearer spoke, so their own words got
        # summarized as someone else's and could be discarded as media playback.
        # Memory extraction keeps the name (`utils/prompts.py:10` interpolates
        # {user_name} and tells the model to ignore speaker attribution) — it builds
        # its own transcript in `new_memories_extractor`, so it is unaffected.
        transcript_text = conversation.get_transcript(False, people=people)

        # For re-processing, we don't discard, just re-structure.
        if force_process:
            # reprocess endpoint
            return (
                get_reprocess_transcript_structure(
                    transcript_text,
                    conversation.started_at,
                    language_code,
                    tz,
                    conversation.structured.title,
                    photos=conversation.photos,
                    output_language=output_language,
                    vocabulary_terms=vocabulary_terms,
                ),
                False,
            )

        # Determine whether to discard the conversation based on its content (transcript and/or photos).
        #
        # ⚠️ 判据是「此刻 `is_user` **有没有真的被写上**」，不是「这条路径将来会不会有」。
        # 这里原本按 `source not in _OFFLINE_CAPTURE_SOURCES` 推，那等于对 `source='app'`
        # 恒传 True —— 而走到这里的 `POST /v1/conversations/{id}/reprocess` 完全可能是一条
        # 声纹从没认出人的真实对话（覆盖率实测约 36%）。那时模型又会收到「没人被标成 User
        # ⇒ 强媒体信号」这条零信息量的"证据"，把一条本来留着的对话翻成丢弃。
        # 同样的判据也让离线上传更准：首次处理时没有 is_user（False，与旧行为一致），而
        # reprocess 一条已经声纹过的上传时是 True —— 旧写法在那种情形下会白白丢掉
        # 「用户确实参与了」这个正面证据。
        # 完整数据见 evaluation/discard/README.md，另两个调用点的同一处修复见
        # `developer_listen` / `developer_conversations`。
        discarded = should_discard_conversation(
            transcript_text, conversation.photos,
            started_at=conversation.started_at, finished_at=conversation.finished_at,
            transcript_segments=conversation.transcript_segments,
            speaker_attribution_available=any(
                getattr(s, 'is_user', False)
                for s in (conversation.transcript_segments or [])
            ),
        )
        if discarded:
            return Structured(emoji=random.choice(['🧠', '🎉'])), True

        # If not discarded, proceed to generate the structured summary from transcript and/or photos.
        structured = get_transcript_structure(
            transcript_text, conversation.started_at, language_code, tz, photos=conversation.photos,
            output_language=output_language, vocabulary_terms=vocabulary_terms,
        )
        return structured, merge_discard_verdict(False, structured)
    except Exception as e:
        print(e)
        raise HTTPException(status_code=500, detail="Error processing conversation, please try again later")


def _get_conversation_obj(
    uid: str,
    structured: Structured,
    conversation: Union[Conversation, CreateConversation, ExternalIntegrationCreateConversation],
    developer_id: str = None,
    discarded: Optional[bool] = None,
):
    if discarded is None:
        discarded = structured.title == ''
    if isinstance(conversation, CreateConversation):
        conversation = Conversation(
            id=str(uuid.uuid4()),
            uid=uid,
            structured=structured,
            **conversation.dict(),
            created_at=datetime.now(timezone.utc),
            discarded=discarded,
        )
        if conversation.photos and developer_id:
            dev_db.store_conversation_photos(developer_id, uid, conversation.id, conversation.photos)
    elif isinstance(conversation, ExternalIntegrationCreateConversation):
        create_conversation = conversation
        conversation = Conversation(
            id=str(uuid.uuid4()),
            **conversation.dict(),
            created_at=datetime.now(timezone.utc),
            structured=structured,
            discarded=discarded,
        )
        conversation.external_data = create_conversation.dict()
        conversation.app_id = create_conversation.app_id
    else:
        conversation.structured = structured
        conversation.discarded = discarded

    return conversation


def _trigger_apps(
    uid: str,
    conversation: Conversation,
    is_reprocess: bool = False,
    app_id: Optional[str] = None,
    language_code: str = 'en',
    people: List[Person] = None,
    output_language: str = None,
):
    # App marketplace has been removed. Clear existing app results.
    conversation.apps_results = []


def _extract_memories(developer_id: str, uid: str, conversation: Conversation):
    if not developer_id:
        print('_extract_memories: developer_id is required')
        return
    dev_db.delete_memories_for_conversation(developer_id, uid, conversation.id)

    new_memories: List[Memory] = []

    output_language = dev_db.get_user_language(developer_id, uid)

    if conversation.source == ConversationSource.external_integration:
        text_content = conversation.external_data.get('text')
        if text_content and len(text_content) > 0:
            text_source = conversation.external_data.get('text_source', 'other')
            new_memories = extract_memories_from_text(
                uid, text_content, text_source, output_language=output_language
            )
    else:
        new_memories = new_memories_extractor(
            uid, conversation.transcript_segments, output_language=output_language
        )

    new_memories, superseded_ids = _dedupe_against_stored_facts(developer_id, uid, new_memories)

    parsed_memories = []
    for memory in new_memories:
        parsed_memories.append(MemoryDB.from_memory(memory, uid, conversation.id, False))

    if len(parsed_memories) == 0:
        print(f"No memories extracted for conversation {conversation.id}")
        return

    print(f"Saving {len(parsed_memories)} memories for conversation {conversation.id}")
    dev_db.save_memories_batch(developer_id, uid, [fact.dict() for fact in parsed_memories])
    _retire_superseded_facts(developer_id, uid, superseded_ids)

    if len(parsed_memories) > 0:
        record_usage(uid, memories_created=len(parsed_memories), developer_id=developer_id)


def _extract_and_create_people(uid: str, conversation: Conversation, developer_id: str = None):
    """Extract people names from conversation transcript using LLM and create new People entries.

    Writes to the developer data path. Deduplicates against existing People (case-insensitive).

    这些人只是**被提到过**，从没说过话，所以一律标 source='mention'，默认不出现在人物名单里。
    和 `developer_listen.py` 的 `_extract_people_background` 是同一个提取器的另一个调用点
    （这条走 reprocess / 音频上传 / SD 卡同步），两处要一起改。
    """
    import database.developer_data as _dev_db
    from utils.people import create_person, get_platform_developer_id

    transcript = conversation.get_transcript(include_timestamps=False)
    if not transcript:
        return

    extracted_names = extract_people_from_conversation(transcript)
    if not extracted_names:
        return

    dev_id = developer_id or get_platform_developer_id()
    if not dev_id:
        print(f'[PEOPLE] Cannot resolve developer_id, skipping people extraction for uid={uid}')
        return

    # ⚠️ 去重要看到全部人物（含已归档的），而且不能截断 —— 见 get_people_name_index。
    # 被归档的名字必须仍算「已存在」，否则被提到一次就复活，清理白做。
    name_index = _dev_db.get_people_name_index(dev_id, uid)

    created_count = 0
    for name in extracted_names:
        if name.lower() in name_index:
            continue
        create_person(uid, name, developer_id=dev_id, source=_dev_db.PERSON_SOURCE_MENTION)
        name_index[name.lower()] = {'id': None, 'deleted': False, 'source': _dev_db.PERSON_SOURCE_MENTION}
        created_count += 1

    if created_count > 0:
        print(f'[PEOPLE] Created {created_count} new people from conversation {conversation.id} for uid={uid}')


def _extract_trends(developer_id: str, uid: str, conversation: Conversation):
    if not developer_id:
        print('_extract_trends: developer_id is required')
        return
    extracted_items = trends_extractor(uid, conversation)
    parsed = [Trend(category=item.category, topics=[item.topic], type=item.type) for item in extracted_items]
    dev_db.save_trends(developer_id, uid, conversation.id, parsed)


def save_structured_vector(uid: str, conversation: Conversation, update_only: bool = False, developer_id: str = None):
    vector = None
    if not update_only:
        embedded = generate_embedding_document(structured_as_embedding_text(conversation.structured))
        if embedded.truncated:
            print(
                f'[EMBEDDING] WARNING: conversation {conversation.id} exceeded the embedding token limit '
                f'and was truncated ({embedded.token_count} tokens) — the tail is not searchable'
            )
        vector = embedded.values
    tz = dev_db.get_user_time_zone(developer_id, uid) if developer_id else None

    # 事件时间 = 录音开始时刻，这是检索该看的时间。`created_at` 是**文档写入时刻**
    # （`developer_data.create_conversation` 和 `audio_upload.py` 都写 now()），
    # 批量同步的音频两者能差 16 小时以上（2026-08-18 实测 audio_upload p90 16.03h、
    # max 20.17h）。这条路径服务音频上传 / SD 卡同步 / reprocess，全都是「先录后传」。
    # `or` 分支留给 omi 迁移数据 —— 它们的 started_at 可能是空的。
    event_time = conversation.started_at or conversation.created_at

    metadata = {}

    # Extract metadata based on conversation source
    if conversation.source == ConversationSource.external_integration:
        text_source = conversation.external_data.get('text_source')
        text_content = conversation.external_data.get('text')
        if text_content and len(text_content) > 0 and text_content and len(text_content) > 0:
            text_source_spec = conversation.external_data.get('text_source_spec')
            if text_source == ExternalIntegrationConversationSource.message.value:
                metadata = retrieve_metadata_from_message(uid, event_time, text_content, tz, text_source_spec)
            elif text_source == ExternalIntegrationConversationSource.other.value:
                metadata = retrieve_metadata_from_text(uid, event_time, text_content, tz, text_source_spec)
    else:
        # For regular conversations with transcript segments
        segments = [t.dict() for t in conversation.transcript_segments]
        # ⚠️ 这个时间参数是 prompt 里的 `today`（`utils/llm/chat.py:768`），对话里说的
        # 「明天」是相对录音那一刻，不是相对上传那一刻 —— 传 created_at 会跨天算错。
        metadata = retrieve_metadata_fields_from_transcript(
            uid, event_time, segments, tz, photos=conversation.photos
        )

    metadata['created_at'] = int(event_time.timestamp())
    metadata['indexed_at'] = int(datetime.now(timezone.utc).timestamp())

    if not update_only:
        print('save_structured_vector creating vector')
        upsert_vector2(uid, conversation, vector, metadata)
    else:
        print('save_structured_vector updating metadata')
        update_vector_metadata(uid, conversation.id, metadata)


def _save_structured_vector_logged(uid: str, conversation: Conversation, **kwargs):
    """Thread entry point for save_structured_vector.

    A bare `threading.Thread(target=save_structured_vector)` discards any
    exception the target raises — Python prints it to stderr from the thread and
    the caller never learns. That is the second half of how the vector index
    went stale unnoticed. Catching and labelling it here makes the failure
    greppable in CloudWatch.
    """
    try:
        save_structured_vector(uid, conversation, **kwargs)
    except Exception as e:
        print(f'[EMBEDDING] ERROR: save_structured_vector failed for {conversation.id} uid={uid}: {e}')
        traceback.print_exc()


def save_vector_from_dict(
    uid: str,
    conversation_id: str,
    structured,
    event_time,
    segments: List[dict],
    developer_id: str = None,
):
    """Store embedding in Pinecone for a conversation represented as raw dicts.

    This is the dict-friendly counterpart of save_structured_vector, used by
    code paths (WS auto-process, App route) that don't build a full Conversation
    model object.

    `event_time` is the moment the conversation was **recorded** (`started_at`),
    not the moment it was written. The parameter used to be called `created_at`,
    which is the name of the wrong field on every conversation object — both
    callers already passed `started_at`, but the name invited the next caller to
    pass the document timestamp. See `save_structured_vector` for the skew data.
    """
    try:
        embedded = generate_embedding_document(structured_as_embedding_text(structured))
        if embedded.truncated:
            print(
                f'[EMBEDDING] WARNING: conversation {conversation_id} exceeded the embedding token limit '
                f'and was truncated ({embedded.token_count} tokens) — the tail is not searchable'
            )
        tz = dev_db.get_user_time_zone(developer_id, uid) if developer_id else None
        metadata = retrieve_metadata_fields_from_transcript(uid, event_time, segments, tz)
        metadata['created_at'] = int(event_time.timestamp())
        metadata['indexed_at'] = int(datetime.now(timezone.utc).timestamp())

        from database.vector_db import index as _pinecone_index
        from database.vector_db import _get_data
        data = _get_data(uid, conversation_id, embedded.values)
        data['metadata'].update(metadata)
        _pinecone_index.upsert(vectors=[data], namespace="ns1")
        print(f'save_vector_from_dict: upserted vector for {conversation_id}')
    except Exception as e:
        # Loud on purpose. This used to print a single line, which is how the
        # index silently went 36 days stale when the embedding provider started
        # failing: nothing distinguished it from ordinary log noise.
        print(f'[EMBEDDING] ERROR: save_vector_from_dict failed for {conversation_id}: {e}')
        traceback.print_exc()


def process_conversation(
    uid: str,
    language_code: str,
    conversation: Union[Conversation, CreateConversation, ExternalIntegrationCreateConversation],
    force_process: bool = False,
    is_reprocess: bool = False,
    app_id: Optional[str] = None,
    developer_id: str = None,
) -> Conversation:
    from utils.people import get_people_by_ids as people_get_by_ids
    person_ids = [segment.person_id for segment in conversation.transcript_segments if segment.person_id]
    people = []
    if person_ids:
        people_data = people_get_by_ids(uid, list(set(person_ids)), developer_id=developer_id)
        people = [Person(**p) for p in people_data]

    user_language = dev_db.get_user_language(developer_id, uid) if developer_id else None
    output_language = user_language if user_language else None

    structured, discarded = _get_structured(
        uid, language_code, conversation, force_process, people=people,
        output_language=output_language, developer_id=developer_id,
    )
    # Only keep action items when the user actually spoke (voiceprint-matched
    # is_user segments) — no leaking other people's tasks from meetings the
    # user merely sat in on.
    clear_action_items_if_user_absent(structured, conversation.transcript_segments)
    # After the gate: no point deduping to-dos that were just revoked.
    dedupe_action_items_in_place(conversation.id, structured)
    _mark_action_items_unconfirmed(structured)
    conversation = _get_conversation_obj(
        uid, structured, conversation, developer_id=developer_id, discarded=discarded,
    )

    if not discarded:
        insights_gained = 0
        if conversation.structured:
            for text in [conversation.structured.title, conversation.structured.overview]:
                if text:
                    sentences = re.split(r'[.!?]+', text)
                    for sentence in sentences:
                        if len(sentence.split()) > 5:
                            insights_gained += 1

            insights_gained += len(conversation.structured.action_items)
            insights_gained += len(conversation.structured.events)

        for app_result in conversation.apps_results:
            if app_result.content:
                sentences = re.split(r'[.!?]+', app_result.content)
                for sentence in sentences:
                    if len(sentence.split()) > 5:
                        insights_gained += 1

        if insights_gained > 0:
            record_usage(uid, insights_gained=insights_gained, developer_id=developer_id)

        _trigger_apps(
            uid, conversation, is_reprocess=is_reprocess, app_id=app_id, language_code=language_code, people=people,
            output_language=output_language,
        )
        if not is_reprocess:
            threading.Thread(
                target=_save_structured_vector_logged,
                args=(uid, conversation),
                kwargs={'developer_id': developer_id},
            ).start()
        threading.Thread(target=_extract_memories, args=(developer_id, uid, conversation)).start()
        threading.Thread(target=_extract_trends, args=(developer_id, uid, conversation)).start()
        threading.Thread(target=_extract_and_create_people, args=(uid, conversation, developer_id)).start()

    conversation.status = ConversationStatus.completed
    if developer_id:
        dev_db.upsert_conversation_full(developer_id, uid, conversation.dict())

    if not is_reprocess:
        threading.Thread(
            target=conversation_created_webhook, args=(uid, conversation),
        ).start()


    print('process_conversation completed conversation.id=', conversation.id)
    return conversation


def dedupe_action_items_in_place(conversation_id: Optional[str], structured) -> None:
    """就地合并 `structured.action_items` 里重复的条目。

    这条路径（reprocess / 音频上传 / SD 卡同步）的待办还没写库，所以直接改内存里的
    `Structured` 就行——不必像 listen 那条路径那样回写 Firestore。两条路径都要接：
    判重规则在 `utils.llm.deduplication` 里只有一份，但**调用点是两个**，这个模块的
    历史里漏接调用点已经害过一次（实时链路整条漏掉记忆提取）。

    Best-effort，绝不让一条对话因为判重失败而处理失败。
    """
    items = getattr(structured, 'action_items', None) or []
    if len(items) < 2:
        return
    try:
        from utils.llm.deduplication import resolve_action_item_duplicates

        drop = set(resolve_action_item_duplicates([it.description or '' for it in items]))
        if not drop:
            return
        structured.action_items = [it for i, it in enumerate(items) if i not in drop]
        print(f'[action-items] Merged {len(drop)} duplicate item(s) on {conversation_id}')
    except Exception as e:
        print(f'[action-items] Dedupe failed on {conversation_id}: {e}')


def _dedupe_against_stored_facts(
    developer_id: str,
    external_user_id: str,
    candidates: List[Memory],
) -> Tuple[List[Memory], List[str]]:
    """对候选事实做语义判重，返回 (应写入的候选, 应软删的旧事实 id)。

    为什么在写入方做而不是在 `new_memories_extractor` 里：判重要能指认「取代了哪一
    条」，而提取函数手里只有 `memories_str`（拼好的字符串，没有 id）。它也只有 uid，
    拿不到 developer_id。

    ⚠️ **三个写入点都必须调它**，它们段来源不同、从不互相调用：

      * `extract_memories_from_segments` —— 实时录音（listen 自动处理 + POST process）
      * `_extract_memories_developer` —— reprocess / 音频上传
      * `_extract_memories` —— SD 卡同步（`routers/sync.py` → `process_conversation`），
        这个只以 `threading.Thread(target=...)` 的形式被调用，所以 grep
        `_extract_memories(` **找不到它的调用者**，看起来像死代码。接判重时就是这么
        漏掉的，`save_memories_batch` 那条路径于是一度完全没有判重。

    只接一部分的后果这个模块吃过一次：实时链路整条漏掉记忆提取，`source='app'` 的对话
    2900+ 条产出 0 条记忆，而单测全绿。`tests/test_deduplication.py` 钉住这三个调用点。

    fail-open：任何异常都退化成「全部写入、不软删」。
    """
    if not candidates:
        return candidates, []
    try:
        from utils.llm.deduplication import resolve_fact_duplicates

        existing = dev_db.get_all_memories(developer_id, external_user_id, limit=400)
        result = resolve_fact_duplicates([m.content for m in candidates], existing)
        kept = [candidates[i] for i in result.kept_indexes]
        return kept, result.superseded_ids
    except Exception as e:
        print(f'[dedupe] facts: skipped ({e}) — writing all {len(candidates)} candidates')
        return candidates, []


def _retire_superseded_facts(developer_id: str, external_user_id: str, memory_ids: List[str]) -> None:
    """软删被更完整版本取代的旧事实。写在新事实入库**之后**：反过来的话，中间失败
    会把旧事实删掉而新的没写进去，用户那条记忆就凭空消失了。"""
    if not memory_ids:
        return
    try:
        removed = dev_db.soft_delete_memories(developer_id, external_user_id, memory_ids)
        if removed:
            print(f'[dedupe] facts: retired {removed} superseded fact(s)')
    except Exception as e:
        print(f'[dedupe] facts: failed to retire superseded facts: {e}')


def _extract_memories_developer(developer_id: str, external_user_id: str, conversation: Conversation):
    """
    Extract memories from conversation and store in developer data path.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation: The conversation to extract memories from
    """
    new_memories: List[Memory] = []

    output_language = dev_db.get_user_language(developer_id, external_user_id)

    # Extract memories based on conversation source
    if conversation.source == ConversationSource.external_integration:
        text_content = conversation.external_data.get('text') if conversation.external_data else None
        if text_content and len(text_content) > 0:
            text_source = conversation.external_data.get('text_source', 'other')
            new_memories = extract_memories_from_text(
                external_user_id, text_content, text_source, output_language=output_language
            )
    else:
        # For regular conversations with transcript segments
        new_memories = new_memories_extractor(
            external_user_id, conversation.transcript_segments, output_language=output_language
        )

    if len(new_memories) == 0:
        print(f"No memories extracted for developer conversation {conversation.id}")
        return

    new_memories, superseded_ids = _dedupe_against_stored_facts(
        developer_id, external_user_id, new_memories
    )
    if len(new_memories) == 0:
        print(f"All extracted memories were duplicates for conversation {conversation.id}")
        return

    print(f"Saving {len(new_memories)} memories for developer conversation {conversation.id}")

    # Store each memory in developer data path
    for memory in new_memories:
        dev_db.create_memory(
            developer_id=developer_id,
            external_user_id=external_user_id,
            content=memory.content,
            category=memory.category.value if hasattr(memory.category, 'value') else str(memory.category),
            metadata={"conversation_id": conversation.id},
        )

    _retire_superseded_facts(developer_id, external_user_id, superseded_ids)


def extract_memories_from_segments(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    segments: List[dict],
) -> int:
    """Extract memories from raw segment dicts and store them.

    The real-time paths (`developer_listen._auto_process_conversation` and
    `POST /v1/conversations/process`) build conversations from plain dicts and
    never construct a `Conversation`, so they can't call
    `_extract_memories_developer`. Without this, recordings made by the app
    produced zero memories — every memory in production with a
    `conversation_id` came from the Omi-era migration or from
    reprocess/upload/SD-sync. See CLAUDE.md「实时录音链路不生成 memory」.

    Returns the number of memories written (0 on any failure — memory
    extraction must never break conversation processing).
    """
    try:
        # Let TranscriptSegment derive `speaker` from speaker_id — passing an
        # explicit label would make its __init__ re-derive speaker_id from the
        # string, and a None speaker_id would blow up the f-string.
        transcript_segments = [
            TranscriptSegment(
                id=seg.get('id') or str(uuid.uuid4()),
                text=seg.get('text') or '',
                speaker_id=seg.get('speaker_id') or 0,
                is_user=bool(seg.get('is_user', False)),
                person_id=seg.get('person_id'),
                start=seg.get('start') or 0.0,
                end=seg.get('end') or 0.0,
            )
            for seg in segments
            if (seg.get('text') or '').strip()
        ]
        if not transcript_segments:
            return 0

        output_language = dev_db.get_user_language(developer_id, external_user_id)
        new_memories = new_memories_extractor(
            external_user_id, transcript_segments, output_language=output_language
        )
        if not new_memories:
            print(f"[MEMORY] No memories extracted for conversation {conversation_id}")
            return 0

        new_memories, superseded_ids = _dedupe_against_stored_facts(
            developer_id, external_user_id, new_memories
        )
        if not new_memories:
            print(f"[MEMORY] All extracted memories were duplicates for {conversation_id}")
            return 0

        for memory in new_memories:
            dev_db.create_memory(
                developer_id=developer_id,
                external_user_id=external_user_id,
                content=memory.content,
                category=memory.category.value if hasattr(memory.category, 'value') else str(memory.category),
                metadata={"conversation_id": conversation_id},
            )
        _retire_superseded_facts(developer_id, external_user_id, superseded_ids)
        print(f"[MEMORY] Saved {len(new_memories)} memories for conversation {conversation_id}")
        return len(new_memories)
    except Exception as e:
        print(f"[MEMORY] Error extracting memories for conversation {conversation_id}: {e}")
        return 0


def process_conversation_developer(
    developer_id: str,
    external_user_id: str,
    language_code: str,
    conversation: Conversation,
    force_process: bool = False,
    prepare_only: bool = False,
) -> Conversation:
    """
    Process a conversation for Developer API usage.

    This function handles conversation processing when called via Developer API,
    storing all data in the developer_data Firestore path for proper retrieval.

    Args:
        developer_id: The developer's ID (from API key)
        external_user_id: The external user's ID
        language_code: Language code for processing
        conversation: The Conversation object to process
        force_process: If True, skip discard check and use reprocess prompt

    Returns:
        The processed Conversation object with LLM-generated summary
    """
    # Use user's preferred language for LLM output if set
    user_language = dev_db.get_user_language(developer_id, external_user_id)
    output_language = user_language if user_language else None

    # Resolve segment.person_id -> Person so the LLM transcript uses real
    # names (e.g. "Alice") instead of the default "Speaker N" labels.
    people: List[Person] = []
    person_ids = conversation.get_person_ids()
    if person_ids:
        try:
            people_docs = dev_db.get_people_by_ids(
                developer_id=developer_id,
                external_user_id=external_user_id,
                person_ids=person_ids,
            )
            people = [Person(**p) for p in people_docs]
        except Exception as e:
            print(f"process_conversation_developer: failed to load people: {e}")

    # Get structured summary from LLM (reuse existing logic).
    # ⚠️ Deliberately does not resolve the owner's display name — the summarizer
    # needs the wearer labelled with the literal "User". See `_get_structured`.
    structured, discarded = _get_structured(
        external_user_id,
        language_code,
        conversation,
        force_process=force_process,
        people=people,
        output_language=output_language,
        developer_id=developer_id,
    )

    # Update conversation with structured data. first_person_observation +
    # highlights now come from this same summary call (fields on Structured),
    # so conversation.dict() carries them — no extra LLM call, no injection.
    # Only keep action items when the user actually spoke (voiceprint-matched
    # is_user segments) — applies to reprocess too, so re-running an old
    # sat-in-on meeting drops its bogus tasks.
    clear_action_items_if_user_absent(structured, conversation.transcript_segments)
    dedupe_action_items_in_place(conversation.id, structured)
    # Reprocess 会整体重出 action_items，所以旧的确认结果无从保留，一律回到待确认。
    _mark_action_items_unconfirmed(structured)
    conversation.structured = structured
    conversation.discarded = discarded

    # Durable uploads checkpoint this result before publishing it atomically.
    # Their independently tracked follow-up jobs replace the threads below.
    if prepare_only:
        conversation.status = ConversationStatus.completed
        return conversation

    if not discarded:
        # Extract memories in background thread
        threading.Thread(
            target=_extract_memories_developer,
            args=(developer_id, external_user_id, conversation)
        ).start()

        # Extract people names from transcript and create in People list
        threading.Thread(
            target=_extract_and_create_people,
            args=(external_user_id, conversation, developer_id)
        ).start()

        # Store vector embedding in Pinecone for RAG retrieval
        threading.Thread(
            target=_save_structured_vector_logged,
            args=(external_user_id, conversation),
            kwargs={'developer_id': developer_id},
        ).start()

    # Update status to completed
    conversation.status = ConversationStatus.completed

    # Store in developer data path. structured (incl. first_person_observation
    # + highlights) is carried by conversation.dict().
    conversation_data = conversation.dict()
    dev_db.upsert_conversation_full(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_data=conversation_data,
    )

    # Emit webhook events for Developer API
    if not discarded:
        _emit_developer_conversation_events(
            developer_id, external_user_id, conversation
        )

    # Invalidate today's PDP cache so next view reflects this conversation
    if not discarded:
        threading.Thread(
            target=_invalidate_pdp_for_today,
            args=(developer_id, external_user_id),
        ).start()

    # Mark this conversation's day for chapter recomputation. Marked even when
    # discarded: a conversation that *becomes* discarded changes the day's chapters
    # too — it has to disappear from them.
    _mark_timeline_day_dirty(developer_id, external_user_id, conversation.started_at)

    print(f'process_conversation_developer completed conversation.id={conversation.id}')
    return conversation


def _mark_timeline_day_dirty(developer_id: str, external_user_id: str, started_at) -> None:
    """Flag the conversation's local day as needing a chapter recompute.

    Imported lazily and wrapped: the timeline layer pulls in the chaptering and
    query modules, and nothing about a cache of chapter cards may be able to fail
    conversation processing.
    """
    try:
        from utils.timeline.store import mark_conversation_day_dirty

        mark_conversation_day_dirty(developer_id, external_user_id, started_at)
    except Exception as e:
        print(f'process_conversation_developer: failed to mark timeline day dirty: {e}')


def _invalidate_pdp_for_today(developer_id: str, external_user_id: str) -> None:
    try:
        from routers.pdp import invalidate_pdp_cache
        tz_name = dev_db.get_user_timezone(developer_id, external_user_id)
        if tz_name:
            import pytz
            today_str = datetime.datetime.now(pytz.timezone(tz_name)).strftime('%Y-%m-%d')
        else:
            today_str = datetime.datetime.now(timezone.utc).strftime('%Y-%m-%d')
        invalidate_pdp_cache(developer_id, external_user_id, today_str)
    except Exception as e:
        print(f'_invalidate_pdp_for_today failed: {e}')


def _emit_developer_conversation_events(
    developer_id: str,
    external_user_id: str,
    conversation: Conversation,
):
    """
    Emit webhook events for a completed developer conversation.

    This emits:
    - conversation.completed event
    - eir.emotion_detected event (if emotion is detected with sufficient confidence)

    Events are emitted in background threads to avoid blocking.
    """
    try:
        from utils.developer_eir_events import emit_developer_event
        from models.developer_eir_webhook import DeveloperEventType

        # Calculate duration
        duration_seconds = 0.0
        if conversation.started_at and conversation.finished_at:
            duration_seconds = (conversation.finished_at - conversation.started_at).total_seconds()

        # Emit conversation.completed event
        emit_developer_event(
            developer_id=developer_id,
            external_user_id=external_user_id,
            event_type=DeveloperEventType.conversation_completed,
            data={
                "conversation_id": conversation.id,
                "title": conversation.structured.title if conversation.structured else "",
                "overview": conversation.structured.overview if conversation.structured else "",
                "duration_seconds": duration_seconds,
                "category": conversation.structured.category.value if conversation.structured and conversation.structured.category else None,
                "action_items_count": len(conversation.structured.action_items) if conversation.structured and conversation.structured.action_items else 0,
            }
        )

        # Emit eir.emotion_detected event
        _emit_eir_emotion_event(developer_id, external_user_id, conversation)

    except Exception as e:
        print(f"Error emitting developer events: {e}")


def _emit_eir_emotion_event(
    developer_id: str,
    external_user_id: str,
    conversation: Conversation,
):
    """
    Detect emotion from conversation and emit EIR webhook event.

    This runs emotion detection using LLM and emits eir.emotion_detected
    event to all subscribed webhooks. The webhook's filters will determine
    which emotions and confidence levels actually trigger delivery.
    """
    try:
        from utils.llm.emotion_detection import detect_emotion_from_conversation
        from utils.developer_eir_events import emit_developer_event
        from models.developer_eir_webhook import DeveloperEventType

        print(f"[EIR] Running emotion detection for developer conversation {conversation.id}")

        # Resolve user.language so emotion_summary respects user preference
        output_language = dev_db.get_user_language(developer_id, external_user_id) if developer_id else None

        # Detect emotion from conversation content
        eir_result = detect_emotion_from_conversation(
            uid=external_user_id,
            conversation=conversation,
            people=None,  # Developer API doesn't have people context yet
            output_language=output_language,
        )

        if eir_result is None:
            print(f"[EIR] No emotion detected for conversation {conversation.id}")
            return

        # Log the evidence behind the verdict so it stays inspectable even if the
        # conversation document is later deleted. We log only the model's
        # emotion_summary (its rationale), never the raw transcript text, to
        # avoid persisting user conversation content in CloudWatch.
        segments = getattr(conversation, "transcript_segments", []) or []
        time_range = ""
        starts = [s.start for s in segments if getattr(s, "start", None) is not None]
        ends = [s.end for s in segments if getattr(s, "end", None) is not None]
        if starts and ends:
            time_range = f", time={min(starts):.1f}-{max(ends):.1f}s"
        print(f"[EIR] Detected emotion: {eir_result.primary_emotion.value} "
              f"(confidence: {eir_result.confidence:.2f}) for conversation {conversation.id}")
        print(f"[EIR] Verdict basis for {conversation.id}: "
              f"segments={len(segments)}{time_range} | summary={eir_result.emotion_summary!r}")

        # Emit the event - webhook filters will handle delivery decisions
        emit_developer_event(
            developer_id=developer_id,
            external_user_id=external_user_id,
            event_type=DeveloperEventType.eir_emotion_detected,
            data={
                "conversation_id": conversation.id,
                "eir_primary_emotion": eir_result.primary_emotion.value,
                "eir_confidence": eir_result.confidence,
                "eir_should_notify": eir_result.should_notify,
                "eir_emotion_summary": eir_result.emotion_summary,
            }
        )

        print(f"[EIR] Emitted eir.emotion_detected event for conversation {conversation.id}")

    except Exception as e:
        print(f"[EIR] Error in emotion detection for conversation {conversation.id}: {e}")


def retrieve_in_progress_conversation(uid, developer_id: str = None):
    conversation_id = redis_db.get_in_progress_conversation_id(uid)
    existing = None

    if conversation_id and developer_id:
        existing = dev_db.get_conversation(developer_id, uid, conversation_id)
        if existing and existing['status'] != 'in_progress':
            existing = None

    if not existing and developer_id:
        existing = dev_db.get_in_progress_conversation(developer_id, uid)
    return existing
