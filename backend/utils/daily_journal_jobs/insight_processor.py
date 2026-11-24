"""Run one queued insight job with the engine POST /v1/insights/run uses inline.

A run writes twice where the user can see it: the card it releases, and that card's push. A
job can die between any two steps, so both writes say which job made them:

- The released card carries the job id (`released_by_job`). A retry that finds it skips the
  engine and goes straight to the push. Running the engine again would find the card inside
  its own fatigue window, skip, and the card would never be pushed.
- The push is marked on the card (`push_started_at`) before it is sent, and a marked card is
  never pushed again. A lost push is better than the same card arriving twice.
"""
from datetime import datetime, timezone

import database.developer_data as dev_db
import routers.developer_insights as insights
from utils.audio_jobs.state import JobFailure, LeaseLost
from utils.insights.engine import run_insight_engine
from utils.locales import get_user_effective_language


def _summary(result):
    return {
        'nominations': len(result.get('nominations') or []),
        'verdicts': [{'topic_key': v.get('topic_key'), 'verdict': v.get('verdict')}
                     for v in result.get('verdicts') or []],
    }


def run_insight_job(job, fence):
    """Release the day's card (if the engine finds one) and push it. Returns the job's result.

    `fence` raises `LeaseLost` once another run may own the job; it is called before the
    engine's first write and again before the push.
    """
    developer_id, uid = job['developer_id'], job['uid']
    dry_run, send_push = bool(job.get('dry_run')), bool(job.get('send_push', True))
    card = None if dry_run else dev_db.find_insight_released_by(developer_id, uid, job['id'])
    summary = {'resumed': True}
    if card is None:
        language_code, _ = get_user_effective_language(
            developer_id=developer_id, uid=uid, fallback_conversations=None)
        try:
            result = run_insight_engine(
                developer_id=developer_id, external_user_id=uid, window_days=job['window_days'],
                language_code=language_code or 'en', dry_run=dry_run,
                before_write=fence, released_by_job=job['id'],
            )
        except LeaseLost:
            raise
        except Exception as error:
            # Tomorrow's run reads the same 60 days, so a single retry covers a passing outage;
            # more would each pay for a whole round of nomination again.
            raise JobFailure('engine_failed', retryable=job.get('stage_attempts', 1) < 2) from error
        summary = _summary(result)
        card = result.get('released')
        if card is None:
            return {'outcome': 'skipped', 'skipped_reason': result.get('skipped_reason'), **summary}
        if dry_run:
            return {'outcome': 'dry_run', 'would_release': card.get('topic_key'), **summary}

    outcome = {'outcome': 'released', 'card_id': card.get('id'), 'topic_key': card.get('topic_key'), **summary}
    if not send_push:
        return {**outcome, 'pushed': False}
    if card.get('push_started_at'):
        # An earlier attempt got as far as sending it; whether FCM took it is unknown.
        return {**outcome, 'pushed': None}
    fence()
    dev_db.upsert_insight(developer_id, uid, {'id': card['id'], 'push_started_at': datetime.now(timezone.utc)})
    return {**outcome, 'pushed': insights._send_insight_push(developer_id, uid, card)}
