"""
Developer API - Daily Summary endpoints

Generate and manage daily text summaries and images from a user's conversations.
Data is stored under developer_data/{developer_id}/users/{external_user_id}/daily_summaries/{date}
"""

import os
from dataclasses import dataclass
from datetime import datetime, time, timezone, date
from typing import Any, List, Optional
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from google.cloud.firestore_v1 import FieldFilter
from pydantic import BaseModel, Field

import database.developer_data as dev_db
from database._client import db
from dependencies import get_developer_id_from_api_key
from models.conversation import Conversation, ConversationSource
from utils.llm.daily_summary import extract_daily_summary_body, generate_daily_journal
from utils.llm.daily_journal_identity import get_confirmed_background_facts, get_confirmed_identity_facts
from utils.llm.daily_journal_sources import build_daily_journal_history, parse_daily_journal_people
from utils.llm.emotion_title import generate_emotion_title
from utils.llm.image_generation import generate_daily_summary_image_with_retry, get_daily_illustration_facts
from utils.other.storage import upload_daily_summary_image
from utils.runtime.credentials import materialize_gcp_credentials_from_env
from utils.timeline.day_query import _resolve_tz, get_day_conversations

router = APIRouter()


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************


class DailySummaryRequest(BaseModel):
    date: Optional[str] = Field(
        None,
        description="Date in YYYY-MM-DD format, in the user's local timezone. Defaults to the user's local today.",
        example="2026-02-03"
    )
    include_image: bool = Field(
        default=True,
        description="Whether to generate a cartoon-style image for the summary"
    )
    force_regenerate: bool = Field(
        default=False,
        description="Force regeneration even if summary exists for this date"
    )
    catch_up: bool = Field(
        default=False,
        description=(
            "Catch-up for a day that has ended: write the entry if it is missing, rewrite it if it leaves out "
            "conversations of that day, otherwise return it unchanged. Never sends a push and keeps an existing image."
        ),
    )
    defer: bool = Field(
        default=False,
        description=(
            "Queue the writing instead of doing it in this request. The cheap checks still run here: an entry that "
            "needs no work is returned as usual (200) and an empty day is still 404. Otherwise the job is queued and "
            "the response is 202 with its id; the journal worker writes the entry (and sends the evening push)."
        ),
    )


class DailySummaryResponse(BaseModel):
    id: str = Field(..., description="Unique summary identifier")
    date: str = Field(..., description="Date in YYYY-MM-DD format")
    summary_text: str = Field(..., description="Generated daily summary in markdown format")
    emotion_title: Optional[str] = Field(None, description="One-line emotional headline for the day")
    image_url: Optional[str] = Field(None, description="URL to the generated summary image")
    language: str = Field(..., description="Language code of the summary")
    conversations_count: int = Field(..., description="Number of conversations included")
    created_at: datetime = Field(..., description="When the summary was created")


class DailySummariesResponse(BaseModel):
    summaries: List[DailySummaryResponse]
    total: int
    has_more: bool


# ******************************************************
# ****************** HELPERS ***************************
# ******************************************************


def _parse_date(date_str: Optional[str]) -> date:
    """Parse date string or return today's date."""
    if date_str:
        try:
            return datetime.strptime(date_str, "%Y-%m-%d").date()
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")
    return datetime.now(timezone.utc).date()


def _get_language_from_conversations(conversations: List[dict]) -> str:
    """Extract language from conversations, defaulting to 'en'."""
    for conv in conversations:
        lang = conv.get('language')
        if lang:
            return lang
    return 'en'


def _user_timezone(developer_id: str, uid: str):
    """The user's timezone (see `dev_db.get_user_effective_timezone`), UTC when neither field is set.

    ⚠️ The cron mirrors this rule (`effective_time_zone` in `modal/memorion_daily_summary.py`, a
    separate Modal runtime that cannot import it). The cron decides when it is 22:00 and which date
    to ask for; this decides which conversations belong to that date. If the two disagree, part of
    the day falls between two entries and is never written.
    """
    return _resolve_tz(dev_db.get_user_effective_timezone(developer_id, uid))


def _day_conversations(developer_id: str, uid: str, day: date, tz) -> List[dict]:
    """Completed, kept conversations recorded on `day` in the user's timezone.

    Membership is the timeline's (`started_at` local date, `get_day_conversations`), so a diary
    card covers the conversations the home timeline shows under the same date.

    🚨 Not `dev_db.get_conversations`: it ranges over `created_at`, and this endpoint used to call it
    with the date's UTC midnight-to-midnight. For a UTC+8 user the 22:00 cron then only saw what was
    created 08:00–22:00 local; anything from 22:00 to 08:00 landed in a window whose cron had already
    run and reached no entry at all (2026-10-27: 58 of one user's 122 conversations, and four days
    answered 404 "no conversations" although she had recorded on each of them).
    """
    return [
        convo for convo in get_day_conversations(dev_db, developer_id, uid, day, tz=tz)
        if convo.get('status') == 'completed' and not convo.get('discarded')
    ]


def _entry_misses_conversations(entry: dict, conversations: List[dict]) -> bool:
    """Does a stored entry leave out any of the day's conversations?

    Entries written before `conversation_ids` was stored only kept a count, taken over the old UTC
    window. A larger count now is the only evidence they offer, and it is the case that matters:
    what that window missed is exactly what a catch-up exists to add.
    """
    current = {convo.get('id') for convo in conversations}
    covered = entry.get('conversation_ids')
    if covered is None:
        return len(current) > (entry.get('conversations_count') or 0)
    return bool(current - set(covered))


def _get_localized_push_title(language_code: str) -> str:
    from utils.locales import get_localized_daily_summary_title
    return get_localized_daily_summary_title(language_code)


_fcm_credentials = None
materialize_gcp_credentials_from_env()
_FCM_CRED_PATH = os.environ.get('FCM_GOOGLE_APPLICATION_CREDENTIALS', '')

def _get_fcm_access_token() -> str:
    """Get OAuth2 access token for FCM V1 API."""
    global _fcm_credentials
    import google.auth.transport.requests
    from google.oauth2 import service_account
    if _fcm_credentials is None:
        _fcm_credentials = service_account.Credentials.from_service_account_file(
            _FCM_CRED_PATH,
            scopes=['https://www.googleapis.com/auth/cloud-platform'],
        )
    if not _fcm_credentials.valid:
        _fcm_credentials.refresh(google.auth.transport.requests.Request())
    return _fcm_credentials.token


def _build_daily_summary_push_data(moment_id: Optional[str]) -> dict:
    """Build the FCM `data` payload for a daily-summary push.

    `navigate_to` intentionally stays '/moments' for backward compatibility: older
    app builds only know that route, so they keep their current behavior. Newer builds
    read `moment_id` to deep-link straight to the day's diary detail page; when it is
    missing they fall back to the (light-mode) home shell timeline.
    """
    data = {
        'id': str(uuid.uuid4()),
        'type': 'day_summary',
        'notification_type': 'daily_summary',
        'navigate_to': '/moments',
    }
    if moment_id:
        data['moment_id'] = moment_id
    return data


def _user_local_now(developer_id: str, uid: str) -> Optional[datetime]:
    """用户本地时区的当前时间，用于静默时段判断；拿不到时区返回 None（跳过静默判断）。"""
    try:
        import pytz
        tz_name = dev_db.get_user_effective_timezone(developer_id, uid) if developer_id else None
        if not tz_name:
            return None
        return datetime.now(pytz.timezone(tz_name))
    except Exception:
        return None


def _send_fcm_push(
    developer_id: str,
    uid: str,
    summary_text: str,
    language_code: str,
    lang_source: str = 'unknown',
    moment_id: Optional[str] = None,
) -> None:
    """Send FCM push notification via direct HTTP to FCM V1 API."""
    import json as _json

    # 尊重用户本地「每日一刻」开关 + 静默时段（偏好由 App 同步到服务端）
    from utils.notification_gate import should_send_push
    user_local_now = _user_local_now(developer_id, uid)
    if not should_send_push(developer_id, uid, 'daily_moment', user_local_now):
        print(f"[daily_summary] {uid[:8]} skipped by notification preference")
        return

    if not os.path.exists(_FCM_CRED_PATH):
        print(f"[daily_summary] {uid[:8]} FCM credentials not found, skipping push")
        return

    fcm_token = dev_db.get_user_fcm_token(developer_id, uid) if developer_id else None
    if not fcm_token:
        print(f"[daily_summary] {uid[:8]} no FCM token, skipping push")
        return

    try:
        import requests
        access_token = _get_fcm_access_token()
        title = _get_localized_push_title(language_code)
        body_source = extract_daily_summary_body(summary_text, language_code)
        body = body_source[:100] + "..." if len(body_source) > 100 else body_source

        with open(_FCM_CRED_PATH) as f:
            project_id = _json.load(f)['project_id']

        resp = requests.post(
            f'https://fcm.googleapis.com/v1/projects/{project_id}/messages:send',
            headers={'Authorization': f'Bearer {access_token}', 'Content-Type': 'application/json'},
            json={'message': {
                'token': fcm_token,
                'notification': {'title': title, 'body': body},
                'data': _build_daily_summary_push_data(moment_id),
            }},
            timeout=30,
        )
        if resp.status_code == 200:
            print(f"[daily_summary] {uid[:8]} lang={language_code} (source={lang_source}) sent=ok")
        else:
            print(f"[daily_summary] {uid[:8]} lang={language_code} (source={lang_source}) sent=fail status={resp.status_code}")
    except Exception as e:
        print(f"[daily_summary] {uid[:8]} lang={language_code} (source={lang_source}) sent=fail error={e}")


def _moment_doc_ref(developer_id: str, uid: str, date_str: str, entry: Optional[dict]):
    """The diary card (`day_summary` message) of `date_str`, existing or to be created.

    A rewrite must update the card the user already has rather than add a second one beside it.
    Cards written from now on carry the date in their id and the entry records it as `moment_id`;
    older cards have a random id, but their text is the entry's text verbatim, so that match is exact.
    """
    messages = db.collection('developer_data').document(developer_id).collection('users').document(uid).collection('messages')
    if entry:
        if entry.get('moment_id'):
            return messages.document(entry['moment_id'])
        for doc in messages.where(filter=FieldFilter('type', '==', 'day_summary')).stream():
            if (doc.to_dict() or {}).get('text') == entry.get('summary_text'):
                return doc.reference
    return messages.document(f'day_summary_{date_str}')


def _upsert_moments_message(
    moment_ref,
    tz,
    summary_text: str,
    image_url: Optional[str],
    date_str: str,
    emotion_title: Optional[str] = None,
) -> str:
    """
    Write the day's card into developer_data/{developer_id}/users/{uid}/messages, which the moments
    endpoint returns. An existing card keeps its id and `created_at` (22:00 local on its date, which
    the App sorts and dates cards by), so a morning rewrite neither moves nor duplicates it.

    Returns the message id so the caller can deep-link the push straight to it.
    """
    if moment_ref.get().exists:
        moment_ref.update({'text': summary_text, 'summary_image_url': image_url, 'emotion_title': emotion_title})
        print(f"Updated moments message {moment_ref.id} on {date_str}")
        return moment_ref.id

    local_22 = datetime.combine(datetime.strptime(date_str, "%Y-%m-%d").date(), time(22, 0))
    local_22 = tz.localize(local_22) if hasattr(tz, 'localize') else local_22.replace(tzinfo=tz)
    created_at = local_22.astimezone(timezone.utc)

    message_data = {
        'id': moment_ref.id,
        'text': summary_text,
        'created_at': created_at,
        'sender': 'ai',
        'app_id': None,
        'plugin_id': None,
        'from_external_integration': False,
        'type': 'day_summary',
        'memories_id': [],
        'reported': False,
        'report_reason': None,
        'files_id': [],
        'chat_session_id': None,
        'data_protection_level': None,
        'summary_image_url': image_url,
        'emotion_title': emotion_title,
    }

    moment_ref.set(message_data)
    print(f"Created moments message {moment_ref.id} on {date_str}")
    return moment_ref.id


def _sanitize_transcript_segments(segments: list) -> list:
    """Sanitize transcript segments to fix common data issues from Firestore."""
    if not segments:
        return []
    sanitized = []
    for seg in segments:
        if not isinstance(seg, dict):
            continue
        # Fix speaker_id: convert string like 'SPEAKER_01' to int
        sid = seg.get('speaker_id')
        if isinstance(sid, str):
            try:
                seg['speaker_id'] = int(sid.split('_')[-1])
            except (ValueError, IndexError):
                seg['speaker_id'] = 0
        sanitized.append(seg)
    return sanitized


def _convert_to_conversation_objects(conversations: List[dict]) -> List[Conversation]:
    """Convert raw conversation dicts to Conversation objects for LLM processing."""
    result = []
    for conv_data in conversations:
        try:
            # Normalize source field
            source_str = conv_data.get('source', 'audio_upload')
            try:
                source_enum = ConversationSource(source_str)
            except ValueError:
                source_enum = ConversationSource.audio_upload

            # Sanitize transcript segments before constructing Conversation
            segments = _sanitize_transcript_segments(conv_data.get('transcript_segments', []))

            # Create Conversation object with required fields
            conv = Conversation(
                id=conv_data.get('id', ''),
                created_at=conv_data.get('created_at', datetime.now(timezone.utc)),
                started_at=conv_data.get('started_at'),
                finished_at=conv_data.get('finished_at'),
                source=source_enum,
                language=conv_data.get('language', 'en'),
                structured=conv_data.get('structured', {'title': '', 'overview': ''}),
                transcript_segments=segments,
            )
            result.append(conv)
        except Exception as e:
            print(f"Error converting conversation {conv_data.get('id')}: {e}")
            continue
    return result


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.post("/v1/daily-summary", response_model=DailySummaryResponse, tags=["developer-api-daily-summary"])
def create_daily_summary(
    request: DailySummaryRequest,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Generate a daily summary from conversations for a specific date.

    This endpoint:
    1. Retrieves all completed conversations recorded on that date in the user's timezone
    2. Uses LLM to generate a comprehensive daily summary
    3. Optionally generates a cartoon-style image visualizing the day
    4. Stores the summary for later retrieval

    If a summary already exists for the date and force_regenerate=False,
    returns the existing summary. With catch_up=True it is rewritten only when it
    leaves out conversations of that day (see `DailySummaryRequest.catch_up`).

    ⚠️ The 22:00 run cannot see the rest of its evening, so the cron calls again the
    next morning with catch_up=True. That second call is also a failed evening's last
    chance — a day the evening run lost (LLM error, timeout) after the journal queue's
    own retries is written then.

    With defer=True (what the cron sends) the writing goes to the journal worker through
    the Firestore outbox and SQS (`utils/daily_journal_jobs`, `daily_journal_jobs.tf`).
    A long day takes 8-10 minutes, and a request held open that long fails on its own:
    the endpoint's 600s cap, and the caller's network dropping an idle connection. In
    both cases the entry was still written, but the caller recorded a failure.

    ⚠️ Sync `def` on purpose — see the note on
    `developer_conversations.process_conversation`. The generation path is a text
    LLM call plus (with `include_image`) an image generation and a GCS upload, all
    blocking, so `async def` held the event loop for the whole thing.
    """
    planned = plan_daily_summary(request, developer_id, external_user_id)
    if not isinstance(planned, DayPlan):
        return planned

    if request.defer:
        from utils.daily_journal_jobs.store import JournalJobStore
        job = JournalJobStore().enqueue(
            developer_id, external_user_id, planned.date_str,
            catch_up=request.catch_up, include_image=request.include_image, force_regenerate=request.force_regenerate,
        )
        print(f"[daily_summary] {external_user_id[:8]} date={planned.date_str} queued job={job['id'][:8]} "
              f"status={job['status']} catch_up={request.catch_up}")
        return JSONResponse(status_code=202, content={
            'status': 'queued', 'job_id': job['id'], 'job_status': job['status'], 'date': planned.date_str,
        })

    try:
        return write_daily_summary(planned, request, developer_id, external_user_id)
    except NothingToWrite:
        raise HTTPException(status_code=500, detail="Failed to process conversations for summary generation")
    except GenerationFailed as e:
        raise HTTPException(status_code=500, detail=f"Failed to generate summary: {e}")


@dataclass
class DayPlan:
    """What an entry for one day has to be written from (see `plan_daily_summary`)."""
    tz: Any
    date_str: str
    existing: Optional[dict]
    conversations: List[dict]


class NothingToWrite(RuntimeError):
    """None of the day's conversations could be read into a Conversation."""


class GenerationFailed(RuntimeError):
    """The entry's text could not be produced; `__cause__` says why."""


def plan_daily_summary(request: DailySummaryRequest, developer_id: str, external_user_id: str):
    """The cheap checks: the entry to return as it is, or a `DayPlan` for one that must be written.

    They run before a job is queued and again when the journal worker runs it, so a job
    that finds its work already done (a duplicate delivery, a rewrite meanwhile) ends as a
    no-op. Raises 404 when the day has nothing to write from.
    """
    tz = _user_timezone(developer_id, external_user_id)
    target_date = _parse_date(request.date) if request.date else datetime.now(tz).date()
    date_str = target_date.strftime("%Y-%m-%d")

    existing = dev_db.get_daily_summary(
        developer_id=developer_id,
        external_user_id=external_user_id,
        date_str=date_str,
    )
    if existing and not (request.force_regenerate or request.catch_up):
        # FCM was already sent when the summary was first created
        return existing

    conversations = _day_conversations(developer_id, external_user_id, target_date, tz)

    if existing and not request.force_regenerate and not _entry_misses_conversations(existing, conversations):
        print(f"[daily_summary] {external_user_id[:8]} date={date_str} catch_up=skip covered={len(conversations)}")
        return existing

    if not conversations:
        if existing:
            # Never replace an entry with nothing: its conversations were discarded or deleted since.
            return existing
        raise HTTPException(
            status_code=404,
            detail=f"No completed conversations found for date {date_str}"
        )
    return DayPlan(tz=tz, date_str=date_str, existing=existing, conversations=conversations)


def write_daily_summary(plan: DayPlan, request: DailySummaryRequest, developer_id: str, external_user_id: str,
                        before_write=None):
    """The expensive part: write the entry and its card, and push the evening's first entry.

    Generation errors leave as `GenerationFailed` with the original as `__cause__`, so the
    journal worker can tell a day that cannot fit (`EvidenceBudgetExceeded`) from one that
    is worth retrying. `before_write` runs after generating (picture included) and before
    anything is stored; whatever it raises leaves with nothing uploaded, written or pushed
    (the journal worker's lease check).
    """
    tz, date_str, existing, conversations = plan.tz, plan.date_str, plan.existing, plan.conversations

    # Resolve language using unified strategy
    from utils.locales import get_user_effective_language
    language_code, lang_source = get_user_effective_language(
        developer_id=developer_id,
        uid=external_user_id,
        fallback_conversations=conversations,
    )

    print(f"[daily_summary] {external_user_id[:8]} date={date_str} lang={language_code} (source={lang_source}) "
          f"convos={len(conversations)} catch_up={request.catch_up} rewrite={existing is not None}")

    # Convert to Conversation objects for LLM processing
    conversation_objects = _convert_to_conversation_objects(conversations)

    if not conversation_objects:
        raise NothingToWrite(date_str)

    # Generate summary using the shared daily-summary prompt/formatter
    try:
        summary_text = _generate_developer_summary(
            developer_id=developer_id,
            external_user_id=external_user_id,
            conversations=conversation_objects,
            language_code=language_code,
        )
    except Exception as e:
        print(f"Error generating summary: {e}")
        raise GenerationFailed(str(e)) from e

    # Generate a one-line emotional headline for the day (best-effort; None on failure)
    emotion_title = generate_emotion_title(summary_text, language_code)
    if emotion_title:
        print(f"[daily_summary] {external_user_id[:8]} emotion_title={emotion_title!r}")

    # A catch-up only adds the rest of the day to an entry the user may already have read
    # (and shared); keep the picture they saw instead of drawing a different one.
    image_url = existing.get('image_url') if (request.catch_up and existing) else None
    image_data = None
    if image_url is None and request.include_image and summary_text:
        try:
            image_data = generate_daily_summary_image_with_retry(
                summary_text=summary_text,
                language_code=language_code,
                max_retries=2,
                character_facts=get_daily_illustration_facts(developer_id, external_user_id),
            )
        except Exception as e:
            print(f"Error generating image: {e}")
            # Continue without image - don't fail the whole request

    # Before the upload too: a day's picture always goes to the same object, so a run that
    # lost its job would replace the picture of the entry its successor wrote.
    if before_write:
        before_write()

    if image_data:
        try:
            # Use composite UID for storage path
            storage_uid = f"dev_{developer_id}_{external_user_id}"
            image_url = upload_daily_summary_image(
                image_data=image_data,
                uid=storage_uid,
                date_str=date_str,
            )
        except Exception as e:
            print(f"Error uploading image: {e}")
            # Continue without image - don't fail the whole request

    # Store the summary in developer_data
    moment_ref = _moment_doc_ref(developer_id, external_user_id, date_str, existing)
    summary = dev_db.create_daily_summary(
        developer_id=developer_id,
        external_user_id=external_user_id,
        date_str=date_str,
        summary_text=summary_text,
        image_url=image_url,
        language=language_code,
        conversations_count=len(conversations),
        emotion_title=emotion_title,
        conversation_ids=[convo.get('id') for convo in conversations],
        moment_id=moment_ref.id,
        created_at=existing.get('created_at') if existing else None,
    )

    moment_id = _upsert_moments_message(
        moment_ref,
        tz,
        summary_text=summary_text,
        image_url=image_url,
        date_str=date_str,
        emotion_title=emotion_title,
    )

    # Push only the evening's first entry (deep-links to this day's diary detail via
    # moment_id). A catch-up or rewrite is not news, and at 06:00 it would wake the user.
    if not request.catch_up and not existing:
        _send_fcm_push(developer_id, external_user_id, summary_text, language_code, lang_source, moment_id=moment_id)

    return summary


@router.get("/v1/daily-summary", response_model=DailySummaryResponse, tags=["developer-api-daily-summary"])
async def get_daily_summary(
    external_user_id: str = Query(..., description="External user identifier"),
    date: str = Query(..., description="Date in YYYY-MM-DD format"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get an existing daily summary for a specific date.
    """
    # Validate date format
    target_date = _parse_date(date)
    date_str = target_date.strftime("%Y-%m-%d")

    summary = dev_db.get_daily_summary(
        developer_id=developer_id,
        external_user_id=external_user_id,
        date_str=date_str,
    )

    if not summary:
        raise HTTPException(status_code=404, detail=f"No summary found for date {date_str}")

    return summary


@router.get("/v1/daily-summaries", response_model=DailySummariesResponse, tags=["developer-api-daily-summary"])
async def list_daily_summaries(
    external_user_id: str = Query(..., description="External user identifier"),
    limit: int = Query(default=30, ge=1, le=100, description="Maximum summaries to return"),
    offset: int = Query(default=0, ge=0, description="Number of summaries to skip"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    List daily summaries for a user with pagination.

    Returns summaries ordered by date (newest first).
    """
    summaries = dev_db.list_daily_summaries(
        developer_id=developer_id,
        external_user_id=external_user_id,
        limit=limit + 1,  # Get one extra to check has_more
        offset=offset,
    )

    has_more = len(summaries) > limit
    if has_more:
        summaries = summaries[:limit]

    # Get total count
    total = dev_db.count_daily_summaries(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )

    return DailySummariesResponse(
        summaries=summaries,
        total=total,
        has_more=has_more,
    )


@router.delete("/v1/daily-summary", status_code=204, tags=["developer-api-daily-summary"])
async def delete_daily_summary(
    external_user_id: str = Query(..., description="External user identifier"),
    date: str = Query(..., description="Date in YYYY-MM-DD format"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete a daily summary for a specific date.
    """
    # Validate date format
    target_date = _parse_date(date)
    date_str = target_date.strftime("%Y-%m-%d")

    success = dev_db.delete_daily_summary(
        developer_id=developer_id,
        external_user_id=external_user_id,
        date_str=date_str,
    )

    if not success:
        raise HTTPException(status_code=404, detail=f"No summary found for date {date_str}")

    return


# ******************************************************
# ********** DEVELOPER SUMMARY GENERATION **************
# ******************************************************


def _generate_developer_summary(
    developer_id: str,
    external_user_id: str,
    conversations: List[Conversation],
    language_code: str,
) -> str:
    """
    Generate a daily summary for Developer API users.

    This is adapted from get_conversation_summary but works without
    Firebase user data (memories, user preferences, etc.)
    """
    from utils.llm.clients import llm_medium_journal, llm_large_journal

    # Build conversation history string
    person_ids = list({pid for conversation in conversations for pid in conversation.get_person_ids()})
    people = parse_daily_journal_people(dev_db.get_people_by_ids(developer_id, external_user_id, person_ids)) if person_ids else []
    conversation_history = build_daily_journal_history(conversations, people=people)

    # Get user name from Firebase Auth (fallback to 'you' to avoid exposing user ID)
    from database.auth import get_user_name
    user_name = get_user_name(external_user_id, use_default=False) or 'you'

    # Who people are (my son, my wife, …) only the user's confirmed facts know: the transcript's
    # 他/她 is a speech recognizer's guess between homophones.
    identity_facts = get_confirmed_identity_facts(developer_id, external_user_id)
    # What the user's life is about (work, family, projects, worries), so a moment can say what it is
    # to them. Never events of the day: both passes are told so, and the check enforces it.
    background_facts = get_confirmed_background_facts(developer_id, external_user_id)
    print(f"[daily_summary] {external_user_id[:8]} identity_facts={len(identity_facts)} "
          f"background_facts={len(background_facts)}")

    # Draft + fact-check pass; raises (⇒ 500, nothing stored, no push) if the check fails.
    # The journal clients allow the long first-token wait of whole-day prompts.
    return generate_daily_journal(
        llm_medium_journal,
        user_name=user_name,
        conversation_history=conversation_history,
        language_code=language_code,
        grounding_llm=llm_large_journal,
        identity_facts=identity_facts,
        background_facts=background_facts,
    )
