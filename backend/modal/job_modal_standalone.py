import json
import os
import sys
import asyncio
import concurrent.futures
import math
import threading
import uuid
from datetime import datetime, time, timezone
from typing import List, Tuple

import firebase_admin
import pytz
from firebase_admin import messaging, firestore
from google.cloud.firestore_v1.base_query import FieldFilter

from modal import Image, App, Secret, Cron
from pydantic import BaseModel, Field
from typing import Optional

# Define the app
app = App(
    name='omi-notifications-standalone',
    secrets=[Secret.from_name("gcp-credentials"), Secret.from_name('envs')],
)

# Create the image with necessary dependencies
image = (
    Image.debian_slim()
    .apt_install('ffmpeg', 'git', 'unzip')
    .pip_install("pytz", "firebase-admin", "google-cloud-firestore", "google-cloud-storage", "pydantic", "langchain-core", "langchain-openai", "langchain-community", "langchain-aws", "langchain-google-genai", "tiktoken", "redis", "pinecone-client", "google-genai", "pillow")
    .env({"PYTHONPATH": "/root"})
    .add_local_dir("utils", remote_path="/root/utils")
    .add_local_dir("models", remote_path="/root/models")
    .add_local_dir("database", remote_path="/root/database")
    .add_local_file("config/llm_models.json", remote_path="/root/config/llm_models.json")
)

# Notification content delegated to utils.locales for centralized i18n.
# Imported lazily inside functions to avoid hard import errors at module load.


def get_localized_daily_summary_title(language_code: str) -> str:
    """Get localized title for daily summary push notification."""
    try:
        from utils.locales import get_localized_daily_summary_title as _impl
        return _impl(language_code)
    except Exception as e:
        print(f"[locales] Failed to load utils.locales, falling back to English: {e}")
        return 'Daily Highlights'


def get_localized_morning_alert(language_code: str) -> Tuple[str, str]:
    """Get (title, body) for the morning push notification, localized."""
    try:
        from utils.locales import get_localized_morning_alert as _impl
        return _impl(language_code)
    except Exception as e:
        print(f"[locales] Failed to load utils.locales, falling back to English: {e}")
        return ('Memorion', 'A new morning · your story is being heard, attentively.')


# In-process cache of uid -> developer_id (helps when many users share one dev).
_UID_TO_DEVELOPER_ID_CACHE: dict = {}


def get_developer_id_from_uid(uid: str) -> Optional[str]:
    """
    Reverse-lookup: find which developer owns this external_user_id.

    Source of truth for user.language is developer_data/{developer_id}/users/{uid},
    so we need to know the developer_id before we can read the user's language.

    Strategy: scan all developers in developer_data and check if this uid exists
    under any of them. We cache the result in-process. For the platform deployment
    this is essentially the single Memorion developer, so the scan is cheap.
    """
    if not uid:
        return None
    if uid in _UID_TO_DEVELOPER_ID_CACHE:
        return _UID_TO_DEVELOPER_ID_CACHE[uid]

    db = firestore.client()
    try:
        # List developers (top level docs of developer_data)
        for dev_doc in db.collection('developer_data').list_documents():
            user_ref = dev_doc.collection('users').document(uid)
            if user_ref.get().exists:
                _UID_TO_DEVELOPER_ID_CACHE[uid] = dev_doc.id
                return dev_doc.id
    except Exception as e:
        print(f"[get_developer_id_from_uid] error for {uid}: {e}")
    return None


def get_user_language(uid: str) -> Optional[str]:
    """
    Read user language from developer_data/{developer_id}/users/{uid}.language
    (the single source of truth). Returns None if not set.
    """
    db = firestore.client()
    dev_id = get_developer_id_from_uid(uid)
    if dev_id:
        try:
            doc = (
                db.collection('developer_data')
                .document(dev_id)
                .collection('users')
                .document(uid)
                .get()
            )
            if doc.exists:
                lang = doc.to_dict().get('language')
                if lang:
                    return lang
        except Exception as e:
            print(f"[get_user_language] error for {uid}: {e}")
    return None


def get_conversation_language(uid: str, memories: List[dict]) -> str:
    """
    Resolve language code with fallback strategy:
      1. user.language at developer_data/{developer_id}/users/{uid}.language
      2. memory.language from the conversations
      3. 'en'
    """
    user_language = get_user_language(uid)
    if user_language:
        return user_language

    for memory in memories:
        if 'language' in memory and memory['language']:
            return memory['language']

    return 'en'


def get_localized_fallback_summary(language_code: str, conversation_count: int) -> str:
    """
    Get localized fallback summary when AI generation fails.
    """
    normalized_code = language_code.lower() if language_code else 'en'
    base_lang = normalized_code.split('-')[0]

    # Chinese (Simplified)
    if base_lang == 'zh':
        return f"""对话概览
您今天共有 {conversation_count} 段对话。
点击查看摘要。

**技术说明**
由于技术问题，AI 详细摘要生成暂时不可用。这是基于对话元数据的基本摘要。

**后续步骤**
• 在应用中查看您的对话以获取详细信息
• 稍后再来查看 AI 生成的摘要
"""

    # Japanese
    elif base_lang == 'ja':
        return f"""会話の概要
本日は {conversation_count} 件の会話がありました。
クリックして概要を表示。

**技術的な注意**
技術的な問題により、AI による詳細な要約生成は現在利用できません。これは会話メタデータに基づく基本的な要約です。

**次のステップ**
• アプリで会話を確認して詳細を確認してください
• 技術的な問題が解決されたら、AI 生成の要約を確認してください
"""

    # Korean
    elif base_lang == 'ko':
        return f"""대화 개요
오늘 {conversation_count}개의 대화가 있었습니다.
요약을 보려면 클릭하세요.

**기술 참고**
기술적 문제로 인해 AI 기반 상세 요약 생성을 현재 사용할 수 없습니다. 이것은 대화 메타데이터를 기반으로 한 기본 요약입니다.

**다음 단계**
• 앱에서 대화를 검토하여 자세한 내용을 확인하세요
• 기술 문제가 해결되면 AI 생성 요약을 다시 확인하세요
"""

    # Spanish
    elif base_lang == 'es':
        return f"""Resumen de conversaciones
Tuviste {conversation_count} conversaciones hoy.
Haz clic para ver el resumen.

**Nota técnica**
La generación de resúmenes detallados con IA no está disponible temporalmente debido a problemas técnicos. Este es un resumen básico basado en los metadatos de la conversación.

**Próximos pasos**
• Revisa tus conversaciones en la app para obtener información detallada
• Vuelve más tarde para ver los resúmenes generados por IA
"""

    # French
    elif base_lang == 'fr':
        return f"""Aperçu des conversations
Vous avez eu {conversation_count} conversations aujourd'hui.
Cliquez pour voir le résumé.

**Note technique**
La génération de résumés détaillés par IA est temporairement indisponible en raison de problèmes techniques. Ceci est un résumé de base basé sur les métadonnées de conversation.

**Prochaines étapes**
• Consultez vos conversations dans l'application pour plus de détails
• Revenez plus tard pour les résumés générés par l'IA
"""

    # German
    elif base_lang == 'de':
        return f"""Gesprächsübersicht
Sie hatten heute {conversation_count} Gespräche.
Klicken Sie, um die Zusammenfassung anzuzeigen.

**Technischer Hinweis**
Die KI-gestützte detaillierte Zusammenfassungserstellung ist aufgrund technischer Probleme vorübergehend nicht verfügbar. Dies ist eine grundlegende Zusammenfassung basierend auf Gesprächsmetadaten.

**Nächste Schritte**
• Überprüfen Sie Ihre Gespräche in der App für detaillierte Einblicke
• Schauen Sie später wieder vorbei für KI-generierte Zusammenfassungen
"""

    # Portuguese
    elif base_lang == 'pt':
        return f"""Visão geral das conversas
Você teve {conversation_count} conversas hoje.
Clique para ver o resumo.

**Nota técnica**
A geração de resumos detalhados por IA está temporariamente indisponível devido a problemas técnicos. Este é um resumo básico baseado nos metadados da conversa.

**Próximos passos**
• Revise suas conversas no app para obter informações detalhadas
• Volte mais tarde para ver os resumos gerados por IA
"""

    # Russian
    elif base_lang == 'ru':
        return f"""Обзор разговоров
Сегодня у вас было {conversation_count} разговоров.
Нажмите, чтобы увидеть сводку.

**Техническое примечание**
Генерация подробных сводок с помощью ИИ временно недоступна из-за технических проблем. Это базовая сводка на основе метаданных разговора.

**Следующие шаги**
• Просмотрите свои разговоры в приложении для получения подробной информации
• Вернитесь позже для просмотра сводок, созданных ИИ
"""

    # Default: English
    else:
        return f"""Conversation Overview
You had {conversation_count} conversations today.
Click to see the summary.

**Technical Note**
Detailed AI-powered summary generation is currently unavailable due to technical issues. This is a basic summary based on conversation metadata.

**Next Steps**
• Review your conversations in the app for detailed insights
• Check back later for AI-generated summaries once the technical issue is resolved
"""


# Model classes needed for daily summary
class NotificationMessage(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    created_at: str = Field(default_factory=lambda: datetime.now(tz=timezone.utc).isoformat())
    sender: str = Field(default='ai')
    plugin_id: Optional[str] = None
    from_integration: str
    type: str
    notification_type: str
    text: Optional[str] = ""
    navigate_to: Optional[str] = None

    @staticmethod
    def get_message_as_dict(message: 'NotificationMessage') -> dict:
        message_dict = message.dict()

        # Remove 'plugin_id' if it is None
        if message.plugin_id is None:
            del message_dict['plugin_id']

        if message.navigate_to is None:
            del message_dict['navigate_to']

        return message_dict


class MessageSender:
    ai = 'ai'
    human = 'human'


class MessageType:
    text = 'text'
    day_summary = 'day_summary'


class Message(BaseModel):
    id: str
    text: str
    created_at: datetime
    sender: str
    app_id: Optional[str] = None
    plugin_id: Optional[str] = None
    from_external_integration: bool = False
    type: str
    memories_id: List[str] = []
    reported: bool = False
    report_reason: Optional[str] = None
    files_id: List[str] = []
    chat_session_id: Optional[str] = None
    data_protection_level: Optional[str] = None
    summary_image_url: Optional[str] = None


def get_or_create_chat_session(db, uid: str, app_id=None) -> dict:
    """Get existing chat session or create a new one for the user"""
    user_ref = db.collection('users').document(uid)

    # Try to find existing session with plugin_id matching app_id
    session_query = (
        user_ref.collection('chat_sessions')
        .where(filter=FieldFilter('plugin_id', '==', app_id))
        .limit(1)
    )

    for session_doc in session_query.stream():
        session_data = session_doc.to_dict()
        print(f"✅ Found existing chat session: {session_data.get('id')}")
        return session_data

    # No existing session, create a new one
    session_id = str(uuid.uuid4())
    session_data = {
        'id': session_id,
        'created_at': datetime.now(timezone.utc),
        'plugin_id': app_id,
        'app_id': app_id,
        'message_ids': [],
        'file_ids': [],
        'title': 'Chat'
    }
    user_ref.collection('chat_sessions').document(session_id).set(session_data)
    print(f"✅ Created new chat session: {session_id}")
    return session_data


def add_summary_message(text: str, uid: str, image_url: Optional[str] = None) -> Message:
    """Add a daily summary message to the user's main chat interface"""
    db = firestore.client()

    print(f"🔍 Adding daily summary to main chat for user {uid}...")

    user_ref = db.collection('users').document(uid)

    # Get or create a chat session for the user (with app_id=None for main chat)
    app_id_to_use = None
    chat_session = get_or_create_chat_session(db, uid, app_id=app_id_to_use)
    chat_session_id = chat_session['id']

    # Create the message with proper session association
    message_id = str(uuid.uuid4())
    ai_message = Message(
        id=message_id,
        text=text,
        created_at=datetime.now(timezone.utc),
        sender='ai',
        app_id=app_id_to_use,
        chat_session_id=chat_session_id,
        from_external_integration=False,
        type='day_summary',
        memories_id=[],
        summary_image_url=image_url,
    )

    # Add message to Firebase
    message_data = ai_message.dict()
    del message_data['memories_id']  # Remove memories field for storage
    user_ref.collection('messages').add(message_data)

    # Add message ID to chat session's message_ids list
    session_ref = user_ref.collection('chat_sessions').document(chat_session_id)
    session_ref.update({"message_ids": firestore.ArrayUnion([message_id])})

    print(f'[DEBUG] Successfully added daily summary message to Firebase for user {uid}')
    print(f"✅ Daily summary stored with chat_session_id: {chat_session_id}")
    if image_url:
        print(f"🖼️ Summary image URL: {image_url}")
    return ai_message


def filter_conversations_by_date(uid: str, start_date: datetime, end_date: datetime):
    """Filter conversations by date range"""
    db = firestore.client()
    user_ref = db.collection('users').document(uid)
    query = (
        user_ref.collection('conversations')
        .where(filter=FieldFilter('created_at', '>=', start_date))
        .where(filter=FieldFilter('created_at', '<=', end_date))
        .where(filter=FieldFilter('discarded', '==', False))
        .order_by('created_at', direction=firestore.Query.DESCENDING)
    )
    from utils.llm.daily_journal_sources import read_daily_journal_document

    conversations = [read_daily_journal_document(doc) for doc in query.stream()]
    return conversations


def get_localized_no_conversations_message(language_code: str) -> str:
    """Get localized 'no conversations' message."""
    normalized_code = language_code.lower() if language_code else 'en'
    base_lang = normalized_code.split('-')[0]

    messages = {
        'zh': '今天没有找到对话记录。',
        'ja': '本日の会話は見つかりませんでした。',
        'ko': '오늘 대화를 찾을 수 없습니다.',
        'es': 'No se encontraron conversaciones para hoy.',
        'fr': 'Aucune conversation trouvée pour aujourd\'hui.',
        'de': 'Keine Gespräche für heute gefunden.',
        'pt': 'Nenhuma conversa encontrada para hoje.',
        'ru': 'Разговоры за сегодня не найдены.',
        'en': 'No conversations found for today.',
    }

    return messages.get(base_lang, messages['en'])


def get_conversation_summary(uid: str, memories: List[dict]) -> str:
    """Generate detailed daily summary using the proper LLM integration"""
    if not memories:
        # Try to get user language for localized message
        language_code = get_conversation_language(uid, [])
        return get_localized_no_conversations_message(language_code)

    try:
        # Temporarily patch the database client to use Firebase Admin SDK
        import firebase_admin
        from firebase_admin import firestore as admin_firestore

        # Get the existing Firebase app
        app = firebase_admin.get_app()
        admin_db = admin_firestore.client(app)

        # Monkey patch the database module to use the admin client
        import sys
        import types

        # Create a mock database module that uses Firebase Admin
        mock_db_module = types.ModuleType('database._client')
        mock_db_module.db = admin_db

        def document_id_from_seed(seed: str):
            import hashlib
            import uuid
            seed_hash = hashlib.sha256(seed.encode('utf-8')).digest()
            generated_uuid = uuid.UUID(bytes=seed_hash[:16], version=4)
            return str(generated_uuid)

        mock_db_module.document_id_from_seed = document_id_from_seed

        # Temporarily replace the database._client module
        original_client = sys.modules.get('database._client')
        sys.modules['database._client'] = mock_db_module

        try:
            # Import the proper conversation summary function from utils
            from utils.llm.external_integrations import get_conversation_summary as get_detailed_conversation_summary

            # Convert dictionary data to Conversation objects to use the proper summary function
            from models.conversation import Conversation
            import zlib
            import json

            conversation_objects = []
            for memory_dict in memories:
                try:
                    # Handle compressed transcript_segments if present
                    if 'transcript_segments' in memory_dict and isinstance(memory_dict['transcript_segments'], bytes):
                        try:
                            # Decompress the transcript_segments
                            decompressed_data = zlib.decompress(memory_dict['transcript_segments'])
                            memory_dict['transcript_segments'] = json.loads(decompressed_data.decode('utf-8'))
                        except Exception as decomp_error:
                            print(f"Decompression failed: {decomp_error}")
                            memory_dict['transcript_segments'] = []

                    memory = Conversation(**memory_dict)
                    conversation_objects.append(memory)
                except Exception as e:
                    print(f"Error converting memory to Conversation object: {e}")
                    continue

            if not conversation_objects:
                language_code = get_conversation_language(uid, memories)
                return get_localized_no_conversations_message(language_code)

            # Use the proper detailed summary function from external_integrations
            return get_detailed_conversation_summary(uid, conversation_objects)
        finally:
            # Restore the original module
            if original_client:
                sys.modules['database._client'] = original_client
            elif 'database._client' in sys.modules:
                del sys.modules['database._client']

    except Exception as e:
        print(f"Error in get_conversation_summary: {e}")
        import traceback
        traceback.print_exc()

        # Get user language for localized fallback
        language_code = get_conversation_language(uid, memories)
        print(f"Using localized fallback for language: {language_code}")

        # Provide a localized fallback summary
        conversation_count = len(memories)
        return get_localized_fallback_summary(language_code, conversation_count)


def initialize_firebase_safely():
    """Initialize Firebase Admin SDK safely, checking if already initialized"""
    try:
        # Check if Firebase is already initialized
        firebase_admin.get_app()
        print('✅ Firebase already initialized, skipping initialization')
        return True
    except ValueError:
        # Firebase not initialized yet, proceed with initialization
        pass

    try:
        if os.environ.get('SERVICE_ACCOUNT_JSON'):
            service_account_info = json.loads(os.environ["SERVICE_ACCOUNT_JSON"])
            credentials = firebase_admin.credentials.Certificate(service_account_info)
            firebase_admin.initialize_app(credentials)
            print('✅ Firebase initialized with service account')
        else:
            firebase_admin.initialize_app()
            print('✅ Firebase initialized with default credentials')
        return True
    except Exception as e:
        print(f'❌ Firebase initialization error: {e}')
        return False


def should_run_job():
    """Check if we should run the job based on current time in different timezones"""
    current_utc = datetime.now(pytz.utc)
    target_hours = {8, 22}  # 8 AM and 10 PM
    print(f'should_run_job: Current UTC time: {current_utc}')

    matching_timezones = []
    for tz in pytz.all_timezones:
        try:
            local_time = current_utc.astimezone(pytz.timezone(tz))
            if local_time.hour in target_hours and local_time.minute == 0:
                matching_timezones.append(f"{tz} ({local_time.strftime('%H:%M')})")
        except Exception:
            # Skip invalid timezones
            continue

    if matching_timezones:
        print(f'should_run_job: Found {len(matching_timezones)} timezones at target hours: {matching_timezones[:5]}...')
        return True

    print('should_run_job: No timezones found at target hours (8 AM or 10 PM)')
    return False


def send_notification(token: str, title: str, body: str, data: dict = None):
    """Enhanced notification sending with improved error handling and logging"""
    print(f'📱 Enhanced send_notification to token: {token[:20]}...')

    # Truncate body for notification display (proven pattern from test scripts)
    notification_body = body[:100] + "..." if len(body) > 100 else body

    # Create basic notification
    notification = messaging.Notification(title=title, body=notification_body)

    # Create message with standard configuration
    message = messaging.Message(
        notification=notification,
        token=token
    )

    if data:
        message.data = data

    try:
        messaging.send(message)
        print('Daily summary notification accepted by FCM')
        return True
    except Exception as e:
        error_message = str(e)
        if "Requested entity was not found" in error_message:
            print('FCM registration token not found or invalid')
            print("💡 User may need to reinstall the app or re-login")
        elif "not a valid FCM registration token" in error_message:
            print(f'❌ Invalid FCM token format: {token[:20]}...')
        else:
            print(f'❌ Enhanced notification failed: {e}')

        print("🔍 Troubleshooting tips:")
        print("   1. Check if user has notifications enabled")
        print("   2. Verify FCM token is still valid")
        print("   3. Ensure app is installed and logged in")
        return False


async def send_bulk_notification(user_tokens: list, title: str, body: str):
    """Enhanced bulk notification sending with improved error handling and logging"""
    try:
        print(f"📤 Sending enhanced bulk notifications to {len(user_tokens)} users")

        batch_size = 500
        num_batches = math.ceil(len(user_tokens) / batch_size)

        # Truncate body for notification display (proven pattern from test scripts)
        notification_body = body[:100] + "..." if len(body) > 100 else body

        def send_batch(batch_users):
            """Send a batch of notifications with standard configuration"""
            messages = [
                messaging.Message(
                    notification=messaging.Notification(title=title, body=notification_body),
                    token=token
                )
                for token in batch_users
            ]

            try:
                response = messaging.send_each(messages)

                # Enhanced logging for delivery verification
                success_count = response.success_count
                failure_count = response.failure_count

                print(f"📊 Batch delivery results:")
                print(f"   ✅ Successful: {success_count}")
                print(f"   ❌ Failed: {failure_count}")

                return response

            except Exception as e:
                print(f"❌ Batch send failed: {e}")
                return None

        tasks = []
        for i in range(num_batches):
            start = i * batch_size
            end = start + batch_size
            batch_users = user_tokens[start:end]
            print(f"📦 Processing batch {i+1}/{num_batches} ({len(batch_users)} users)")
            task = asyncio.to_thread(send_batch, batch_users)
            tasks.append(task)

        results = await asyncio.gather(*tasks)

        # Calculate overall statistics
        total_success = sum(r.success_count for r in results if r)
        total_failure = sum(r.failure_count for r in results if r)

        print(f"🎯 Enhanced bulk notification summary:")
        print(f"   📊 Total users targeted: {len(user_tokens)}")
        print(f"   ✅ Successfully delivered: {total_success}")
        print(f"   ❌ Failed deliveries: {total_failure}")
        print(f"   📈 Success rate: {(total_success / len(user_tokens) * 100):.1f}%")

    except Exception as e:
        print(f"❌ Error in enhanced bulk notification: {e}")
        import traceback
        traceback.print_exc()


def get_timezones_at_time(target_time: str):
    """Get all timezones currently at the target time"""
    target_timezones = []
    for tz_name in pytz.all_timezones:
        try:
            tz = pytz.timezone(tz_name)
            current_time = datetime.now(tz).strftime("%H:%M")
            if current_time == target_time:
                target_timezones.append(tz_name)
        except Exception:
            continue
    return target_timezones


async def get_users_token_in_timezones(timezones: List[str]):
    """Get (uid, fcm_token) pairs for users in specific timezones.

    Returns a list of tuples so callers can resolve user-specific language for
    localized morning notifications. Older callers that just iterate strings
    will receive tuples; callers should switch to tuple unpacking.
    """
    if not timezones:
        return []

    db = firestore.client()
    users_ref = db.collection('users')
    user_entries = []

    # Split timezones into chunks of 30 (Firestore 'in' query limit)
    timezone_chunks = [timezones[i : i + 30] for i in range(0, len(timezones), 30)]

    async def query_chunk(chunk):
        def sync_query():
            results = []
            try:
                query = users_ref.where(filter=FieldFilter('time_zone', 'in', chunk))
                for doc in query.stream():
                    doc_data = doc.to_dict()
                    if 'fcm_token' in doc_data and doc_data['fcm_token']:
                        results.append((doc.id, doc_data['fcm_token']))
            except Exception as e:
                print(f"Error querying chunk {chunk}: {e}")
            return results

        return await asyncio.to_thread(sync_query)

    tasks = [query_chunk(chunk) for chunk in timezone_chunks]
    results = await asyncio.gather(*tasks)

    for chunk_entries in results:
        user_entries.extend(chunk_entries)

    return user_entries


async def get_users_id_in_timezones(timezones: List[str]):
    """Get user IDs and FCM tokens for users in specific timezones"""
    if not timezones:
        return []

    db = firestore.client()
    users_ref = db.collection('users')
    user_data = []

    # Split timezones into chunks of 30 (Firestore 'in' query limit)
    timezone_chunks = [timezones[i : i + 30] for i in range(0, len(timezones), 30)]

    async def query_chunk(chunk):
        def sync_query():
            chunk_data = []
            try:
                query = users_ref.where(filter=FieldFilter('time_zone', 'in', chunk))
                for doc in query.stream():
                    doc_data = doc.to_dict()
                    if 'fcm_token' in doc_data and doc_data['fcm_token']:
                        # Include time_zone so _send_summary_notification can compute
                        # the correct local-date range for conversation filtering
                        chunk_data.append((doc.id, doc_data['fcm_token'], doc_data.get('time_zone')))
            except Exception as e:
                print(f"Error querying chunk {chunk}: {e}")
            return chunk_data

        return await asyncio.to_thread(sync_query)

    tasks = [query_chunk(chunk) for chunk in timezone_chunks]
    results = await asyncio.gather(*tasks)

    for chunk_data in results:
        user_data.extend(chunk_data)

    return user_data


async def send_daily_notification():
    """Send morning notification at 8 AM (localized per-user)."""
    try:
        print("Starting send_daily_notification...")
        morning_target_time = "08:00"

        timezones_in_time = get_timezones_at_time(morning_target_time)
        user_entries = await get_users_token_in_timezones(timezones_in_time)

        if not user_entries:
            print("No users found for morning notification")
            return None

        await _send_localized_morning_notifications(user_entries)
        print(f"send_daily_notification completed. Users notified: {len(user_entries)}")
        return user_entries

    except Exception as e:
        print(f"Error in send_daily_notification: {e}")
        import traceback
        traceback.print_exc()
        return None


def _send_morning_to_user(uid: str, fcm_token: str) -> None:
    """Send a single localized morning push to one user."""
    try:
        from utils.locales import get_user_effective_language

        dev_id = get_developer_id_from_uid(uid)
        language_code, lang_source = get_user_effective_language(dev_id, uid, fallback_conversations=None)
        title, body = get_localized_morning_alert(language_code)
        send_notification(fcm_token, title, body)
        print(f"[morning] {uid[:8]} lang={language_code} (source={lang_source}) sent=ok")
    except Exception as e:
        print(f"[morning] {uid[:8]} failed: {e}")


async def _send_localized_morning_notifications(user_entries: list) -> None:
    """Dispatch morning notifications concurrently, one per user, in user's language."""
    loop = asyncio.get_running_loop()
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        tasks = [
            loop.run_in_executor(pool, _send_morning_to_user, uid, token)
            for (uid, token) in user_entries
        ]
        await asyncio.gather(*tasks)


def extract_notification_body(summary: str) -> str:
    """Extract body from the generated summary for FCM notification.
    Skips the first markdown header and returns the rest as the body."""
    print(f"\n📝 EXTRACTING NOTIFICATION BODY:")
    print(f"   - Original summary length: {len(summary)} characters")

    # Look for the first markdown header (e.g., "### 今日亮点" or "**每日亮点**")
    lines = summary.split('\n')
    extracted_body = summary  # Default fallback

    for i, line in enumerate(lines):
        line = line.strip()
        header_found = False

        # Check if line is a markdown ### header (e.g., "### 今日亮点")
        if line.startswith('###') and len(line) > 3:
            header_found = True
            print(f"   - Found ### header: '{line[3:].strip()}'")

        # Check if line is a markdown bold header (starts and ends with **)
        elif line.startswith('**') and line.endswith('**') and len(line) > 4:
            header_found = True
            print(f"   - Found ** header: '{line[2:-2].strip()}'")

        if header_found:
            # Extract the body (everything after this header)
            remaining_lines = lines[i+1:]
            # Skip empty lines after the header
            while remaining_lines and not remaining_lines[0].strip():
                remaining_lines = remaining_lines[1:]

            extracted_body = '\n'.join(remaining_lines).strip()
            print(f"   - Extracted body length: {len(extracted_body)} characters")
            print(f"   - Body preview: {extracted_body[:100]}...")
            break

    if extracted_body == summary:
        print(f"   - No header found, using full summary as body")

    return extracted_body


def _send_summary_notification(user_data: tuple):
    """Send individual daily summary notification with content and navigation"""
    uid = user_data[0]
    fcm_token = user_data[1]
    user_timezone_str = user_data[2] if len(user_data) > 2 else None

    print(f"📱 Processing enhanced summary notification for user {uid[:8]}...")

    try:
        # Compute today's date range in the user's local timezone (00:00 ~ 22:00 local),
        # then convert to UTC for Firestore query.
        # Fallback to UTC if timezone is missing or invalid.
        try:
            user_tz = pytz.timezone(user_timezone_str) if user_timezone_str else pytz.utc
        except Exception:
            print(f"⚠️ Invalid timezone '{user_timezone_str}' for user {uid[:8]}, falling back to UTC")
            user_tz = pytz.utc

        now_local = datetime.now(user_tz)
        # Start of today (00:00:00) in user's local timezone, converted to UTC.
        # Use user_tz.localize() on a naive datetime to correctly handle DST transitions
        # (plain replace() preserves the current UTC offset and can be wrong on DST days).
        naive_midnight = now_local.replace(tzinfo=None, hour=0, minute=0, second=0, microsecond=0)
        start_of_day_local = user_tz.localize(naive_midnight)
        start_of_day_utc = start_of_day_local.astimezone(pytz.utc)
        # End at current local time (22:00 when this runs), also in UTC
        end_of_day_utc = now_local.astimezone(pytz.utc)

        print(f"🕙 User timezone: {user_timezone_str}, local now: {now_local.strftime('%Y-%m-%d %H:%M')}")
        print(f"📅 Querying conversations from {start_of_day_utc.isoformat()} to {end_of_day_utc.isoformat()} UTC")

        # Get today's conversations for the user
        memories_data = filter_conversations_by_date(uid, start_of_day_utc, end_of_day_utc)

        if not memories_data:
            print(f"No conversations found for user {uid}, skipping notification")
            return

        # Resolve summary language from user profile first, then conversation fallback.
        summary_language = get_conversation_language(uid, memories_data)
        daily_summary_title = get_localized_daily_summary_title(summary_language)
        print(f"🌐 Resolved summary language: {summary_language}, using localized title: {daily_summary_title}")

        # Generate summary content
        summary = get_conversation_summary(uid, memories_data)

        print(f"Generated daily summary of {len(summary)} characters from {len(memories_data)} conversations")

        # Generate daily summary image
        image_url = None
        try:
            from utils.llm.image_generation import generate_daily_summary_image_with_retry
            from utils.other.storage import upload_daily_summary_image

            print("🎨 Generating daily summary image...")
            image_data = generate_daily_summary_image_with_retry(summary, summary_language)

            if image_data:
                date_str = datetime.now().strftime('%Y-%m-%d')
                image_url = upload_daily_summary_image(image_data, uid, date_str)
                print(f"✅ Successfully generated and uploaded summary image: {image_url}")
            else:
                print("⚠️ Image generation returned no data, continuing without image")
        except Exception as img_error:
            print(f"⚠️ Image generation failed, continuing without image: {img_error}")
            import traceback
            traceback.print_exc()

        # Store the FULL summary in the user's chat (database gets complete content)
        add_summary_message(summary, uid, image_url)

        # Extract body for FCM notification (title is already localized)
        notification_body = extract_notification_body(summary)

        # Truncate notification body for FCM data payload (max ~4KB limit)
        # Use 500 chars to leave room for other fields and ensure delivery
        truncated_body = notification_body[:500] + "..." if len(notification_body) > 500 else notification_body

        # Create notification message with navigation data (using truncated body)
        ai_message = NotificationMessage(
            text=truncated_body,  # Use truncated body for notification data
            from_integration='false',
            type='day_summary',
            notification_type='daily_summary',
            navigate_to="/chat/omi",  # This enables navigation to daily summary
        )

        # Send notification with localized title and truncated body
        send_notification(fcm_token, daily_summary_title, truncated_body, NotificationMessage.get_message_as_dict(ai_message))
        print(f"Daily summary notification sent to user {uid}")

    except Exception as e:
        print(f"Error sending summary notification to user {uid}: {e}")


async def _send_bulk_summary_notification(users: list):
    """Send daily summary notifications to multiple users"""
    loop = asyncio.get_running_loop()
    with concurrent.futures.ThreadPoolExecutor() as pool:
        tasks = [loop.run_in_executor(pool, _send_summary_notification, user_data) for user_data in users]
        await asyncio.gather(*tasks)


async def send_daily_summary_notification():
    """Send evening summary notification at 10 PM with proper navigation"""
    try:
        print("Starting send_daily_summary_notification...")
        daily_summary_target_time = "22:00"

        timezones_in_time = get_timezones_at_time(daily_summary_target_time)
        user_data = await get_users_id_in_timezones(timezones_in_time)

        if not user_data:
            print("No users found for daily summary notification")
            return None

        print(f"Found {len(user_data)} users for daily summary notification")
        await _send_bulk_summary_notification(user_data)
        print(f"send_daily_summary_notification completed. Users notified: {len(user_data)}")
        return user_data

    except Exception as e:
        print(f"Error in send_daily_summary_notification: {e}")
        import traceback
        traceback.print_exc()
        return None


async def start_cron_job():
    """Main cron job function"""
    print(f'start_cron_job called at {datetime.now(pytz.utc)}')
    if should_run_job():
        print('start_cron_job: should_run_job returned True, sending notifications...')
        try:
            await send_daily_notification()
            await send_daily_summary_notification()
            print('start_cron_job: All notifications sent successfully')
        except Exception as e:
            print(f'Error in start_cron_job: {e}')
            import traceback
            traceback.print_exc()
    else:
        print('start_cron_job: should_run_job returned False, no notifications to send')


@app.function(
    image=image,
    schedule=Cron('* * * * *'),
    timeout=300,
    memory=512,
)
async def notifications_cronjob():
    """Scheduled notification cron job"""
    print(f'Notification cron job started at {datetime.now(pytz.utc)}')

    # Initialize Firebase safely
    if not initialize_firebase_safely():
        return {"status": "error", "message": "Firebase initialization failed"}

    try:
        await start_cron_job()
        return {"status": "success", "message": "Cron job completed", "ran_at": str(datetime.now(pytz.utc))}
    except Exception as e:
        print(f'Error in notifications_cronjob: {e}')
        import traceback
        traceback.print_exc()
        return {"status": "error", "message": str(e), "ran_at": str(datetime.now(pytz.utc))}


@app.function(
    image=image,
    timeout=300,
    memory=512,
)
async def manual_notification_trigger():
    """Manual trigger for testing notifications"""
    print(f'Manual notification trigger started at {datetime.now(pytz.utc)}')

    # Initialize Firebase safely
    if not initialize_firebase_safely():
        return {"status": "error", "message": "Firebase initialization failed"}

    try:
        await start_cron_job()
        print('Manual notification trigger completed successfully')
        return {"status": "success", "message": "Manual notifications completed", "ran_at": str(datetime.now(pytz.utc))}
    except Exception as e:
        print(f'Error in manual notification trigger: {e}')
        import traceback
        traceback.print_exc()
        return {"status": "error", "message": str(e), "ran_at": str(datetime.now(pytz.utc))}


@app.function(
    image=image,
    timeout=300,
    memory=512,
)
async def manual_notification_trigger_no_timezone():
    """Manual trigger for testing notifications without timezone restrictions"""
    print(f'Manual notification trigger (no timezone check) started at {datetime.now(pytz.utc)}')

    # Initialize Firebase safely
    if not initialize_firebase_safely():
        return {"status": "error", "message": "Firebase initialization failed"}

    try:
        print('Bypassing timezone check - sending notifications to all users...')

        # Get all users with FCM tokens (no timezone filtering)
        db = firestore.client()
        users_ref = db.collection('users')

        # Get all users who have FCM tokens
        all_user_entries = []  # (uid, fcm_token) for morning notifications
        all_users_data = []    # (uid, fcm_token) for summary notifications

        print('Fetching all users with FCM tokens...')
        for doc in users_ref.stream():
            doc_data = doc.to_dict()
            if 'fcm_token' in doc_data and doc_data['fcm_token']:
                all_user_entries.append((doc.id, doc_data['fcm_token']))
                all_users_data.append((doc.id, doc_data['fcm_token']))

        print(f'Found {len(all_user_entries)} users with FCM tokens')

        # Send morning notifications to all users (localized per user)
        if all_user_entries:
            print('Sending localized morning notifications...')
            await _send_localized_morning_notifications(all_user_entries)

        # Send summary notifications to all users
        if all_users_data:
            print('Sending summary notifications...')
            await _send_bulk_summary_notification(all_users_data)

        print('Manual notification trigger (no timezone) completed successfully')
        return {
            "status": "success",
            "message": f"Manual notifications sent to {len(all_user_entries)} users (no timezone check)",
            "users_notified": len(all_user_entries),
            "ran_at": str(datetime.now(pytz.utc))
        }
    except Exception as e:
        print(f'Error in manual notification trigger (no timezone): {e}')
        import traceback
        traceback.print_exc()
        return {"status": "error", "message": str(e), "ran_at": str(datetime.now(pytz.utc))}
