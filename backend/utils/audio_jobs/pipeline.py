"""Checkpointed processing; completed STT is never repeated for a summary error."""
import tempfile
from datetime import datetime, timedelta, timezone

from .artifacts import Artifacts
from .soniox import Soniox
from .state import JobFailure


class Pipeline:
    def __init__(self, store, artifacts=None, soniox=None):
        self.store = store
        self.artifacts = artifacts or Artifacts()
        self.soniox = soniox or Soniox()

    def __call__(self, job, token):
        job_id = job['id']

        def save(values, next_stage=None):
            updated = self.store.checkpoint(job_id, token, values, next_stage)
            job.update(updated)

        def artifact(name, value, next_stage):
            reference = self.artifacts.put(job_id, token, name, value)
            save({name: reference}, next_stage)

        if job.get('parent_id'):
            self.followup(job, token, save)
            self.store.complete(job_id, token)
            return

        if job['stage'] not in {'validate', 'transcribe', 'speakers', 'summarize', 'publish'}:
            raise JobFailure('unknown_stage', retryable=False)
        with tempfile.TemporaryDirectory(prefix='audio-job-') as folder:
            audio_path = f'{folder}/audio.wav'
            if job['stage'] in {'validate', 'transcribe'}:
                self.artifacts.download_audio(job['audio'], audio_path)
            if job['stage'] == 'validate':
                self.validate(job, audio_path)
                save({'validated': True}, 'transcribe')
            if job['stage'] == 'transcribe':
                result = self.soniox.transcribe(audio_path, job['language'], job['checkpoints'], save)
                artifact('transcript', result, 'speakers')
            if job['stage'] == 'speakers':
                transcript = self.artifacts.get(job['checkpoints']['transcript'])
                self.attribute(job, transcript)
                artifact('attributed_transcript', transcript, 'summarize')
            if job['stage'] == 'summarize':
                conversation = self.summarize(job)
                artifact('conversation', conversation.dict(), 'publish')
            if job['stage'] == 'publish':
                from models.conversation import Conversation
                self.artifacts.ensure_playback(job)
                conversation = Conversation(**self.artifacts.get(job['checkpoints']['conversation']))
                children = ['timeline', 'provider_cleanup']
                if job['auto_process'] and not conversation.discarded:
                    children += ['memories', 'people', 'search', 'webhooks', 'emotion', 'pdp']
                self.store.publish(job_id, token, conversation.dict(), children)

    def validate(self, job, path):
        from utils.stt.vad import vad_is_empty_streaming
        if job.get('use_vad') and vad_is_empty_streaming(path):
            raise JobFailure('no_speech', retryable=False)

    def release_failed_usage(self, job):
        # Legacy/corrupt jobs cannot own a current metered reservation when the
        # tenant identity is absent. Treat them as nothing to refund so they can
        # still progress to the DLQ instead of retrying a deterministic KeyError.
        if not job.get('developer_id') or not job.get('uid') or not job.get('id'):
            return
        from utils.subscription import release_transcription_credits_developer
        release_transcription_credits_developer(
            job['developer_id'],
            job['uid'],
            job.get('usage_event_id') or f"audio-upload:{job['id']}",
            failed_job_id=job['id'],
            job_collection=self.store.collection.id,
        )

    def release_stale_upload_usage(self, job):
        """Refund a process-death reservation while its upload fence is intact."""
        if job.get('usage_committed'):
            return
        if not job.get('developer_id') or not job.get('uid') or not job.get('id'):
            return
        from utils.subscription import release_transcription_credits_developer
        release_transcription_credits_developer(
            job['developer_id'],
            job['uid'],
            job.get('usage_event_id') or f"audio-upload:{job['id']}",
            reservation_owner=job.get('upload_token'),
            upload_job_id=job['id'],
            upload_token=job.get('upload_token'),
            job_collection=self.store.collection.id,
        )

    def attribute(self, job, transcript):
        from utils.stt.speech_profile import identify_developer_speakers
        # Match before summarizing so user-dependent verdicts see attribution.
        identify_developer_speakers(
            developer_id=job['developer_id'], external_user_id=job['uid'],
            session_id=f"upload:{job['id']}", segments=transcript['segments'],
            audio_gcs_path=job['audio']['path'], audio_kept_intervals=[], audio_wait_attempts=1,
            protected_speaker_keys=set())

    def summarize(self, job):
        from models.conversation import Conversation, ConversationSource, ConversationStatus, Structured
        from models.transcript_segment import TranscriptSegment
        from utils.conversations.process_conversation import process_conversation_developer
        transcript = self.artifacts.get(job['checkpoints']['attributed_transcript'])
        started_at = datetime.fromisoformat(job['started_at'])
        conversation = Conversation(
            id=job['conversation_id'], created_at=datetime.fromtimestamp(job['created_at'], timezone.utc),
            started_at=started_at, finished_at=started_at + timedelta(seconds=job['duration_seconds']),
            source=ConversationSource.audio_upload, language=transcript['language'],
            structured=Structured(title='', overview=''),
            transcript_segments=[TranscriptSegment(**segment) for segment in transcript['segments']],
            audio_path=f"{job['uid']}/{job['conversation_id']}.wav", status=ConversationStatus.completed)
        if job['auto_process']:
            conversation = process_conversation_developer(job['developer_id'], job['uid'],
                                                          transcript['language'], conversation, prepare_only=True)
        return conversation

    def followup(self, job, token, save):
        if job['stage'] == 'provider_cleanup':
            parent = self.store.get(job['parent_id'])
            if parent:
                self.soniox.cleanup(parent['checkpoints'])
            return
        from models.conversation import Conversation
        from database import developer_data as db
        from utils.conversations import process_conversation as processing
        data = db.get_conversation(job['developer_id'], job['uid'], job['conversation_id'])
        if not data:
            # A deleted conversation must not be resurrected by follow-up work.
            return
        conversation = Conversation(**data)
        if job['stage'] == 'timeline':
            # Call the store directly: legacy wrapper catches exceptions.
            from utils.timeline.store import mark_conversation_day_dirty
            mark_conversation_day_dirty(job['developer_id'], job['uid'], conversation.started_at, raise_on_error=True)
        elif job['stage'] == 'search':
            processing.save_structured_vector(job['uid'], conversation, developer_id=job['developer_id'])
        elif job['stage'] == 'pdp':
            from routers.pdp import invalidate_pdp_cache
            from zoneinfo import ZoneInfo
            zone = ZoneInfo(db.get_user_timezone(job['developer_id'], job['uid']) or 'UTC')
            invalidate_pdp_cache(job['developer_id'], job['uid'], datetime.now(zone).strftime('%Y-%m-%d'))
        elif job['stage'] == 'people':
            self.people(job, token, save, conversation)
        elif job['stage'] == 'memories':
            self.memories(job, token, save, conversation)
        elif job['stage'] in {'webhooks', 'emotion'}:
            from .webhooks import deliver
            deliver(job, self.store, self.artifacts, token, save, conversation)
        else:
            raise JobFailure('unknown_stage', retryable=False)

    def memories(self, job, token, save, conversation):
        from utils.conversations import process_conversation as processing
        from database import developer_data as db
        from google.api_core.exceptions import AlreadyExists
        import uuid
        if 'memories' not in job['checkpoints']:
            language = db.get_user_language(job['developer_id'], job['uid'])
            memories = processing.new_memories_extractor(job['uid'], conversation.transcript_segments, output_language=language)
            memories, superseded = processing._dedupe_against_stored_facts(job['developer_id'], job['uid'], memories)
            value = {'items': [memory.dict() for memory in memories], 'superseded': superseded}
            save({'memories': self.artifacts.put(job['id'], token, 'memories', value)})
        value = self.artifacts.get(job['checkpoints']['memories'])
        user = db._get_user_ref(job['developer_id'], job['uid'])
        for i, item in enumerate(value['items']):
            self.store.renew(job['id'], token)
            memory_id = str(uuid.uuid5(uuid.UUID(job['id']), str(i)))
            now = datetime.now(timezone.utc)
            # Tenant memories use developer_data.create_memory's schema, not
            # the legacy top-level users/{uid}/memories MemoryDB schema.
            payload = {'id': memory_id, 'content': item['content'], 'category': item['category'],
                       'tags': [], 'metadata': {'conversation_id': conversation.id}, 'visibility': 'private',
                       'reviewed': False, 'user_review': None, 'manually_added': False,
                       'deleted': False, 'created_at': now, 'updated_at': now}
            try:
                user.collection('memories').document(memory_id).create(payload)
            except AlreadyExists:
                pass
        if value['superseded']:
            db.soft_delete_memories(job['developer_id'], job['uid'], value['superseded'])

    def people(self, job, token, save, conversation):
        import uuid
        from google.api_core.exceptions import AlreadyExists
        from utils.conversations import process_conversation as processing
        from database import developer_data as db
        if 'people' not in job['checkpoints']:
            names = processing.extract_people_from_conversation(conversation.get_transcript(include_timestamps=False))
            save({'people': self.artifacts.put(job['id'], token, 'people', names)})
        names = self.artifacts.get(job['checkpoints']['people'])
        existing = db.get_people_name_index(job['developer_id'], job['uid'])
        user = db._get_user_ref(job['developer_id'], job['uid'])
        for name in names:
            normalized = name.strip().lower()
            if not normalized or normalized in existing:
                continue
            self.store.renew(job['id'], token)
            person_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{job['owner_key']}:mention:{normalized}"))
            now = datetime.now(timezone.utc)
            try:
                user.collection('people').document(person_id).create({
                    'id': person_id, 'name': name.strip(), 'metadata': {}, 'source': db.PERSON_SOURCE_MENTION,
                    'created_at': now, 'updated_at': now})
            except AlreadyExists:
                pass
