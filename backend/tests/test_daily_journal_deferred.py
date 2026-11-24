"""每日日志改走队列（`defer`）之后的接线（2026-10-28）。

cron 改成发 `defer: true`：API 只做便宜的检查、把任务写进 Firestore outbox、回 202；真正的
写作由 journal worker 执行（`utils/daily_journal_jobs`）。这里钉住两半：

- 接口：`defer` 时不写、不推送；已写好 / 没有对话的那一天照旧当场回 200 / 404；不带 `defer`
  的调用和以前完全一样（含 500 的映射）。
- worker 的执行（`processor.run_job`）：执行前重新规划，所以重复投递、期间被别人写好的那一天
  都是空操作，绝不写第二遍、推第二次；租约丢了就什么都不写；只有确定性的失败才不重试。

走真实的 handler 和 `run_job`，只把 LLM / 图片 / 推送 / Firestore 换成假的
（`test_daily_summary_catch_up.Harness`）。

Run: cd backend && python3 -m pytest tests/test_daily_journal_deferred.py
"""

import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi import HTTPException  # noqa: E402

import routers.developer_daily_summary as daily  # noqa: E402
import utils.daily_journal_jobs.processor as processor  # noqa: E402
import utils.daily_journal_jobs.store as job_store  # noqa: E402
from utils.audio_jobs import state  # noqa: E402
from utils.audio_jobs.state import JobFailure, LeaseLost  # noqa: E402
from utils.daily_journal_jobs.worker import JournalWorker  # noqa: E402
from utils.llm.daily_journal_evidence import EvidenceBudgetExceeded  # noqa: E402
from utils.llm.daily_summary import DailySummaryGenerationError  # noqa: E402
from test_daily_summary_catch_up import DAY, DEV, UID, WRITTEN_AT, Harness, convo, local  # noqa: E402


class FakeJobStore:
    """The outbox as the endpoint uses it."""

    def __init__(self):
        self.enqueued = []

    def __call__(self):
        return self

    def enqueue(self, developer_id, uid, date_str, **kw):
        self.enqueued.append((developer_id, uid, date_str, kw))
        return {'id': 'b7e0a35c-0000-4000-8000-000000000001', 'status': 'queued'}


def written(text='journal of morning', ids=('morning',)):
    return {'id': f'summary_{DAY}', 'date': DAY, 'summary_text': text, 'conversation_ids': list(ids),
            'conversations_count': len(ids), 'created_at': WRITTEN_AT, 'image_url': 'https://img/old.png'}


def job(mode='evening'):
    return {'id': 'job', 'kind': 'daily_journal', 'developer_id': DEV, 'uid': UID, 'date': DAY,
            'include_image': True, 'catch_up': mode == 'catch_up', 'force_regenerate': mode == 'force'}


class DeferredEndpointTests(unittest.TestCase):
    def setUp(self):
        self.jobs = FakeJobStore()
        patch = mock.patch.object(job_store, 'JournalJobStore', self.jobs)
        patch.start()
        self.addCleanup(patch.stop)

    def call(self, h, **kw):
        request = daily.DailySummaryRequest(date=DAY, defer=True, **kw)
        return daily.create_daily_summary(request, external_user_id=UID, developer_id=DEV)

    def test_evening_is_queued_not_written(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        response = self.call(h)
        self.assertEqual(202, response.status_code)
        self.assertEqual({'status': 'queued', 'job_id': 'b7e0a35c-0000-4000-8000-000000000001',
                          'job_status': 'queued', 'date': DAY}, json.loads(response.body))
        self.assertEqual([(DEV, UID, DAY, {'catch_up': False, 'include_image': True, 'force_regenerate': False})],
                         self.jobs.enqueued)
        self.assertEqual(([], [], []), (h.generated, h.pushes, h.dev_db.writes))

    def test_catch_up_of_a_day_with_new_conversations_is_queued(self):
        h = Harness(self, [convo('morning', local(25, 9)), convo('late-evening', local(25, 23, 30))],
                    entries={DAY: written()})
        self.assertEqual(202, self.call(h, catch_up=True).status_code)
        self.assertEqual(True, self.jobs.enqueued[0][3]['catch_up'])

    def test_written_evening_returns_the_entry_without_a_job(self):
        h = Harness(self, [convo('morning', local(25, 9))], entries={DAY: written()})
        self.assertEqual('journal of morning', self.call(h)['summary_text'])
        self.assertEqual([], self.jobs.enqueued)

    def test_complete_day_returns_the_entry_without_a_job(self):
        h = Harness(self, [convo('morning', local(25, 9))], entries={DAY: written()})
        self.assertEqual('journal of morning', self.call(h, catch_up=True)['summary_text'])
        self.assertEqual([], self.jobs.enqueued)

    def test_empty_day_is_still_404(self):
        h = Harness(self, [])
        with self.assertRaises(HTTPException) as ctx:
            self.call(h)
        self.assertEqual(404, ctx.exception.status_code)
        self.assertEqual([], self.jobs.enqueued)


class InlineEndpointTests(unittest.TestCase):
    """Without `defer` nothing changed: written in the request, 500 on failure, no job."""

    def setUp(self):
        patch = mock.patch.object(job_store, 'JournalJobStore', side_effect=AssertionError('queued without defer'))
        patch.start()
        self.addCleanup(patch.stop)

    def test_written_and_pushed_in_the_request(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        entry = h.call()
        self.assertEqual('journal of morning', entry['summary_text'])
        self.assertEqual(['day_summary_2026-10-25'], h.pushes)

    def test_generation_failure_is_a_500(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        with mock.patch.object(daily, '_generate_developer_summary', side_effect=TimeoutError('read timed out')):
            with self.assertRaises(HTTPException) as ctx:
                h.call()
        self.assertEqual(500, ctx.exception.status_code)
        self.assertEqual('Failed to generate summary: read timed out', ctx.exception.detail)
        self.assertEqual(([], []), (h.dev_db.writes, h.pushes))

    def test_unreadable_conversations_are_a_500(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        with mock.patch.object(daily, '_convert_to_conversation_objects', return_value=[]):
            with self.assertRaises(HTTPException) as ctx:
                h.call()
        self.assertEqual(500, ctx.exception.status_code)
        self.assertEqual('Failed to process conversations for summary generation', ctx.exception.detail)


class RunJobTests(unittest.TestCase):
    def run_job(self, mode='evening', fence=None):
        self.fences = []
        return processor.run_job(job(mode), fence or (lambda: self.fences.append(1)))

    def test_evening_job_writes_and_pushes_once(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        self.assertEqual({'outcome': 'written', 'conversations': 1, 'image': True}, self.run_job())
        self.assertEqual(['day_summary_2026-10-25'], h.pushes)
        self.assertEqual([1], self.fences)

    def test_replayed_job_finds_its_entry_and_does_nothing(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        self.run_job()
        self.assertEqual({'outcome': 'unchanged'}, self.run_job())
        self.assertEqual((1, 1), (len(h.generated), len(h.pushes)))

    def test_catch_up_job_rewrites_silently_keeping_the_picture(self):
        h = Harness(self, [convo('morning', local(25, 9)), convo('late-evening', local(25, 23, 30))],
                    entries={DAY: written()})
        self.assertEqual('written', self.run_job('catch_up')['outcome'])
        self.assertEqual([], h.pushes)
        self.assertEqual([], h.images)
        self.assertEqual('https://img/old.png', h.dev_db.entries[DAY]['image_url'])

    def test_day_emptied_since_queueing_finishes_as_nothing_to_do(self):
        Harness(self, [])
        self.assertEqual({'outcome': 'no_conversations'}, self.run_job())

    def test_lost_lease_uploads_writes_and_pushes_nothing(self):
        h = Harness(self, [convo('morning', local(25, 9))])

        def lost():
            raise LeaseLost()

        with mock.patch.object(daily, 'upload_daily_summary_image') as upload, self.assertRaises(LeaseLost):
            self.run_job(fence=lost)
        # The picture's object is the same for every run of the day: uploading it here would
        # replace the picture of the entry the run that took over wrote.
        upload.assert_not_called()
        self.assertEqual(1, len(h.images), 'the picture is drawn before the check, just not stored')
        self.assertEqual(([], [], {}), (h.dev_db.writes, h.pushes, h.firestore.messages))

    def test_evening_written_meanwhile_is_not_written_again_or_pushed(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        generate = h._write

        def someone_else_writes_while_this_generates(**kw):
            h.dev_db.entries[DAY] = written('the other writer')
            return generate(**kw)

        with mock.patch.object(daily, '_generate_developer_summary', side_effect=someone_else_writes_while_this_generates), \
                mock.patch.object(daily, 'upload_daily_summary_image') as upload:
            self.assertEqual({'outcome': 'written_meanwhile'}, self.run_job())
        upload.assert_not_called()
        self.assertEqual(([], []), (h.dev_db.writes, h.pushes))
        self.assertEqual('the other writer', h.dev_db.entries[DAY]['summary_text'])

    def test_catch_up_still_replaces_an_entry_written_meanwhile(self):
        # Rewriting is what a catch-up is for, and it never pushes, so nothing to guard there.
        h = Harness(self, [convo('morning', local(25, 9))])
        generate = h._write

        def someone_else_writes_while_this_generates(**kw):
            h.dev_db.entries[DAY] = written('the other writer', ids=())
            return generate(**kw)

        with mock.patch.object(daily, '_generate_developer_summary', side_effect=someone_else_writes_while_this_generates):
            self.assertEqual('written', self.run_job('catch_up')['outcome'])
        self.assertEqual('journal of morning', h.dev_db.entries[DAY]['summary_text'])
        self.assertEqual([], h.pushes)

    def assertFailure(self, raised, code, retryable, attempt=1):
        h = Harness(self, [convo('morning', local(25, 9))])
        with mock.patch.object(daily, '_generate_developer_summary', side_effect=raised):
            with self.assertRaises(JobFailure) as ctx:
                processor.run_job({**job(), 'stage_attempts': attempt}, lambda: None)
        self.assertEqual((code, retryable), (ctx.exception.code, ctx.exception.retryable))
        self.assertEqual(([], []), (h.dev_db.writes, h.pushes))

    def test_transient_generation_failure_is_retried(self):
        self.assertFailure(TimeoutError('read timed out'), 'generation_failed', True)
        self.assertFailure(DailySummaryGenerationError('grounding check returned nothing'), 'generation_failed', True)

    def test_over_budget_day_gets_one_more_try_then_fails_for_good(self):
        # As raised in production: wrapped by generate_daily_journal, then by write_daily_summary.
        try:
            try:
                raise EvidenceBudgetExceeded('daily journal evidence exceeds writing context budget')
            except EvidenceBudgetExceeded as cause:
                raise DailySummaryGenerationError('daily journal evidence preparation failed') from cause
        except DailySummaryGenerationError as error:
            wrapped = error
        self.assertFailure(wrapped, 'evidence_over_budget', True, attempt=1)
        self.assertFailure(wrapped, 'evidence_over_budget', False, attempt=2)

    def test_unreadable_conversations_fail_for_good(self):
        Harness(self, [convo('morning', local(25, 9))])
        with mock.patch.object(daily, '_convert_to_conversation_objects', return_value=[]):
            with self.assertRaises(JobFailure) as ctx:
                processor.run_job(job(), lambda: None)
        self.assertEqual(('conversations_unreadable', False), (ctx.exception.code, ctx.exception.retryable))


class MemoryJobs(job_store.JournalJobStore):
    """The real record transitions, kept in a dict instead of Firestore (that is the emulator suite's job)."""

    def __init__(self):
        self.jobs, self.now = {}, [1000.0]
        self.clock = lambda: self.now[0]

    def change(self, job_id, transition):
        return transition(self.jobs.get(job_id), self.clock())


JOB_ID = 'b7e0a35c-0000-4000-8000-000000000002'


class WorkerToWriterTests(unittest.TestCase):
    """The worker, `run_job` and the endpoint's writer joined up: the fence must actually reach the write."""

    def setUp(self):
        self.jobs = MemoryJobs()
        self.jobs.jobs[JOB_ID] = {**job(), 'id': JOB_ID, 'status': 'queued', 'stage': 'generate', 'attempts': 0,
                                  'stage_attempts': 0, 'next_attempt_at': 0, 'lease_token': None, 'lease_until': 0,
                                  'history': [], 'checkpoints': {}}
        self.sqs = mock.Mock()
        self.worker = JournalWorker(self.jobs, self.sqs, 'queue', 'dlq', processor.run_job, clock=self.jobs.clock)

    def deliver(self):
        self.worker.handle({'ReceiptHandle': 'receipt', 'Body': json.dumps({'job_id': JOB_ID})})

    def test_delivery_writes_pushes_and_completes_once(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        self.deliver()
        self.deliver()
        record = self.jobs.jobs[JOB_ID]
        self.assertEqual('completed', record['status'])
        self.assertEqual('written', record['result']['outcome'])
        self.assertEqual((1, ['day_summary_2026-10-25']), (len(h.dev_db.writes), h.pushes))
        self.assertEqual(2, self.sqs.delete_message.call_count)

    def test_run_overtaken_while_generating_writes_nothing(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        generate = h._write

        def slow_generation(**kw):
            # The lease ran out mid-generation and a redelivery took the job over.
            self.jobs.now[0] += state.LEASE_SECONDS + 1
            self.assertTrue(self.jobs.claim(JOB_ID, 'successor'))
            return generate(**kw)

        with mock.patch.object(daily, '_generate_developer_summary', side_effect=slow_generation), \
                mock.patch.object(daily, 'upload_daily_summary_image') as upload:
            self.deliver()
        upload.assert_not_called()
        self.assertEqual(([], []), (h.dev_db.writes, h.pushes))
        self.assertEqual('successor', self.jobs.jobs[JOB_ID]['lease_token'])
        self.sqs.delete_message.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
