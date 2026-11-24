"""Run one queued job: a daily journal with the code POST /v1/daily-summary uses inline, or an
insight run (`insight_processor`).

Imported at worker start, not per job: a broken image then fails the task at boot, where
the ECS circuit breaker rolls it back, instead of failing every job.
"""
from fastapi import HTTPException

import routers.developer_daily_summary as daily
from utils.audio_jobs.state import JobFailure
from utils.llm.daily_journal_evidence import EvidenceBudgetExceeded

from .insight_processor import run_insight_job


def _caused_by(error, kind):
    seen = set()
    while error is not None and id(error) not in seen:
        if isinstance(error, kind):
            return True
        seen.add(id(error))
        error = error.__cause__ or error.__context__
    return False


class WrittenMeanwhile(Exception):
    """Another writer finished the evening's entry while this job was generating it."""


def run_journal_job(job, fence):
    """Write the job's entry, or find there is nothing to do. Returns the job's result.

    Planning runs again here rather than trusting the enqueue-time check: the entry may
    have been written meanwhile (a duplicate delivery, a manual run), and then this job
    must not write it, or push it, a second time. `fence` raises `LeaseLost` once another
    run may own the job, and is called right before the write.
    """
    request = daily.DailySummaryRequest(
        date=job['date'], include_image=job.get('include_image', True),
        force_regenerate=job.get('force_regenerate', False), catch_up=job.get('catch_up', False),
    )
    developer_id, uid = job['developer_id'], job['uid']
    try:
        planned = daily.plan_daily_summary(request, developer_id, uid)
    except HTTPException as error:
        if error.status_code == 404:
            return {'outcome': 'no_conversations'}
        raise JobFailure(f'plan_http_{error.status_code}', retryable=error.status_code >= 500)
    if not isinstance(planned, daily.DayPlan):
        return {'outcome': 'unchanged'}

    def before_write():
        fence()
        # Generating takes minutes; the evening's entry may have been written in the meantime
        # by someone outside this job (an API call without defer). Its push has gone out, so
        # this one would be a second push and would replace what the user may have opened.
        # A catch-up or a forced rewrite replaces entries by design and never pushes.
        if planned.existing is None and not (request.catch_up or request.force_regenerate):
            if daily.dev_db.get_daily_summary(developer_id=developer_id, external_user_id=uid,
                                              date_str=planned.date_str):
                raise WrittenMeanwhile()

    try:
        entry = daily.write_daily_summary(planned, request, developer_id, uid, before_write=before_write)
    except WrittenMeanwhile:
        return {'outcome': 'written_meanwhile'}
    except daily.NothingToWrite:
        raise JobFailure('conversations_unreadable', retryable=False)
    except daily.GenerationFailed as error:
        if _caused_by(error, EvidenceBudgetExceeded):
            # Evidence is selected by a model, so a day near the budget can land under it on
            # another try (two runs on one 120k-character day selected over 100k and 99k).
            # A day far over fails the same way every time; one retry bounds what that costs.
            raise JobFailure('evidence_over_budget', retryable=job.get('stage_attempts', 1) < 2)
        # Everything else seen so far (read timeouts, token limits, a fact-check that came
        # back short) is transient.
        raise JobFailure('generation_failed')
    return {'outcome': 'written', 'conversations': entry.get('conversations_count'),
            'image': bool(entry.get('image_url'))}


PROCESSORS = {'daily_journal': run_journal_job, 'insight': run_insight_job}


def run_job(job, fence):
    """The worker's processor: hand the job to the code for its kind."""
    processor = PROCESSORS.get(job.get('kind'))
    if processor is None:
        # A record this worker cannot run fails the same way however often it is retried.
        raise JobFailure('unknown_kind', retryable=False)
    return processor(job, fence)
