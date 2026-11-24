from datetime import datetime
from database import user_usage as user_usage_db


def record_usage(
    uid: str,
    transcription_seconds: int = 0,
    words_transcribed: int = 0,
    insights_gained: int = 0,
    memories_created: int = 0,
    developer_id: str = None,
):
    """Records hourly usage stats for a user."""
    now = datetime.utcnow()
    updates = {
        'transcription_seconds': transcription_seconds,
        'words_transcribed': words_transcribed,
        'insights_gained': insights_gained,
        'memories_created': memories_created,
    }
    user_usage_db.update_hourly_usage(uid, now, updates, developer_id=developer_id)


def record_usage_developer(
    developer_id: str,
    external_user_id: str,
    transcription_seconds: int = 0,
    words_transcribed: int = 0,
    insights_gained: int = 0,
    memories_created: int = 0,
):
    """Records hourly usage stats for a developer API user."""
    from database import developer_data as dev_db
    now = datetime.utcnow()
    updates = {
        'transcription_seconds': transcription_seconds,
        'words_transcribed': words_transcribed,
        'insights_gained': insights_gained,
        'memories_created': memories_created,
    }
    dev_db.update_hourly_usage(developer_id, external_user_id, now, updates)
