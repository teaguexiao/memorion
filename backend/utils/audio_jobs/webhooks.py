"""Replayable delivery with a stable event id for downstream deduplication."""
import uuid

from .state import JobFailure


def deliver(job, store, artifacts, token, save, conversation):
    from database import developer_eir_webhooks as db
    from utils.developer_eir_events import create_event_payload, should_deliver_event, deliver_webhook
    from models.developer_eir_webhook import DeveloperEventType
    event_type = (DeveloperEventType.eir_emotion_detected if job['stage'] == 'emotion'
                  else DeveloperEventType.conversation_completed)
    if 'deliveries' not in job['checkpoints']:
        if job['stage'] == 'emotion':
            from utils.llm.emotion_detection import detect_emotion_from_conversation
            from database import developer_data
            result = detect_emotion_from_conversation(
                uid=job['uid'], conversation=conversation, people=None,
                output_language=developer_data.get_user_language(job['developer_id'], job['uid']))
            if result is None:
                save({'deliveries': artifacts.put(job['id'], token, 'deliveries', {'payload': {}, 'hooks': []})})
                return
            data = {'conversation_id': conversation.id, 'eir_primary_emotion': result.primary_emotion.value,
                    'eir_confidence': result.confidence, 'eir_should_notify': result.should_notify,
                    'eir_emotion_summary': result.emotion_summary}
        else:
            data = {'conversation_id': conversation.id, 'title': conversation.structured.title,
                    'overview': conversation.structured.overview,
                    'duration_seconds': job['duration_seconds'],
                    'category': getattr(conversation.structured.category, 'value', None),
                    'action_items_count': len(conversation.structured.action_items)}
        payload = create_event_payload(job['developer_id'], job['uid'], event_type, data)
        payload['id'] = f"evt_audio_{job['id']}"
        ids = [hook['id'] for hook in db.get_active_webhooks_for_event(job['developer_id'], event_type.value)
               if should_deliver_event(hook, event_type.value, data)]
        save({'deliveries': artifacts.put(job['id'], token, 'deliveries', {'payload': payload, 'hooks': ids})})
    deliveries = artifacts.get(job['checkpoints']['deliveries'])
    for hook_id in deliveries['hooks']:
        marker = f'delivered_{uuid.uuid5(uuid.NAMESPACE_URL, hook_id).hex}'
        if job['checkpoints'].get(marker):
            continue
        hook = db.get_webhook_with_secret(job['developer_id'], hook_id)
        if not hook or hook.get('status') != 'active':
            save({marker: True})
            continue
        store.renew(job['id'], token)
        success, status, _ = deliver_webhook(hook['url'], hook['secret'], deliveries['payload'])
        if not success:
            raise JobFailure('workflow_delivery_failed', retryable=status == 0 or status >= 500 or status in (408, 429))
        # The destination must deduplicate X-Memorion-Event-ID if response/ack is lost.
        save({marker: True})
