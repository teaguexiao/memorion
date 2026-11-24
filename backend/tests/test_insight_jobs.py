"""洞察改走队列（`defer` → journal worker）之后的接线（2026-10-28）。

一轮洞察在用户看得见的地方写两次：释放的那张卡、那张卡的推送。任务可能在任意两步之间
死掉，所以这里钉住的是「每个任务至多释放一张、至多推一次，而且不丢」：

- 引擎在第一次写账本之前确认租约（`before_write`）。被顶替的那一份什么都不写，否则账本
  里多出一批重复条目，两份都释放还会推两次。
- 释放的卡带着任务 id（`released_by_job`）。重试时认出它就直接去推送；重新跑引擎只会被
  自己刚发的卡挡在疲劳窗口里，那张卡就再也推不出去了。
- 推送前先在卡上记 `push_started_at`，记过的卡不再推。宁可丢一次推送，也不让同一张卡来两遍。
- 引擎出错只重试一次：第二天那一轮看的还是同一个 60 天窗口，多试一次就多付一整轮提名的钱。

走真实的引擎、处理器和 worker，只把 Firestore、两个 LLM 调用和推送换成假的。

Run: cd backend && python3 -m pytest tests/test_insight_jobs.py
"""

import asyncio
import copy
import json
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import routers.developer_insights as insights  # noqa: E402
import utils.daily_journal_jobs.insight_processor as insight_processor  # noqa: E402
import utils.daily_journal_jobs.processor as processor  # noqa: E402
import utils.daily_journal_jobs.store as job_store  # noqa: E402
import utils.insights.engine as engine  # noqa: E402
from utils.audio_jobs import state  # noqa: E402
from utils.audio_jobs.state import JobFailure, LeaseLost  # noqa: E402
from utils.daily_journal_jobs.worker import JournalWorker  # noqa: E402
from test_daily_journal_deferred import MemoryJobs  # noqa: E402

DEV, UID = 'dev', 'user-1'
JOB_ID = 'c3f1a2b4-0000-4000-8000-000000000003'
CID = '3f9a1c2e-7b4d-4a11-9c8e-1d2f3a4b5c6d'
QUOTE = '我还是觉得要先把合规这块想清楚，不然后面推不动'


class FakeInsightDb:
    """developer_data as the engine, the processor and the router use it for one user."""

    def __init__(self, events, ledger=None):
        self.events = events
        self.insights = {row['id']: dict(row) for row in (ledger or [])}

    def get_conversations(self, **kwargs):
        return [{'id': CID}]

    def get_user_timezone(self, developer_id, uid):
        return 'Asia/Shanghai'

    def get_user_effective_timezone(self, developer_id, uid):
        return 'Asia/Shanghai'

    def get_first_conversation_date(self, developer_id, uid):
        return datetime(2026, 9, 1, tzinfo=timezone.utc)

    def list_insights(self, developer_id, uid, limit=50, **kwargs):
        return [copy.deepcopy(row) for row in self.insights.values()][:limit]

    def get_known_topic_keys(self, developer_id, uid):
        return {row['topic_key']: row['status'] for row in self.insights.values() if row.get('topic_key')}

    def upsert_insight(self, developer_id, uid, insight):
        self.events.append(('write', insight.get('status') or sorted(set(insight) - {'id'})[0]))
        self.insights.setdefault(insight['id'], {}).update(copy.deepcopy(insight))
        return insight

    def find_insight_released_by(self, developer_id, uid, job_id):
        hits = [row for row in self.insights.values() if row.get('released_by_job') == job_id]
        return copy.deepcopy(hits[0]) if hits else None


class Harness:
    """The real engine and processor around a fake Firestore, fake model calls and a fake push."""

    def __init__(self, test, ledger=None, nominations=None):
        self.events = []
        self.db = FakeInsightDb(self.events, ledger)
        self.pushes = []
        self.nominations = nominations if nominations is not None else [{
            'topic_key': 'compliance-first',
            'headline': '你总是先想合规',
            'body': '你推进一件新事情之前，总会先把合规这一块想清楚，再往下走。',
            'depth': '这像是一种对后果的敬畏：你宁可慢一点，也不愿意走到一半才发现路不通。',
            'worth': 70, 'confidence': 80,
            'evidence': [{'quote': QUOTE, 'conversation_id': CID, 'date': '2026-10-20'}],
        }]
        patches = [
            mock.patch.object(engine, 'dev_db', self.db),
            mock.patch.object(insight_processor, 'dev_db', self.db),
            mock.patch.object(insights, 'dev_db', self.db),
            mock.patch.object(engine.facts_mod, 'build_fact_sheet', return_value={
                'days_with_data': 20, 'conversation_count': 40,
                'window_start': '2026-08-29', 'window_end': '2026-10-28'}),
            mock.patch.object(engine.facts_mod, 'companion_days', return_value=57),
            mock.patch.object(engine.facts_mod, 'collect_user_quotes', return_value=[
                {'text': QUOTE, 'date': '2026-10-20', 'conversation_id': CID}]),
            mock.patch.object(engine.facts_mod, 'collect_conversation_digest', return_value=[
                {'conversation_id': CID, 'title': '周会', 'overview': '讨论新产品的上线节奏', 'date': '2026-10-20'}]),
            mock.patch.object(engine.llm_engine, 'nominate', side_effect=self._nominate),
            mock.patch.object(engine.llm_engine, 'judge', side_effect=self._judge),
            mock.patch.object(insight_processor, 'get_user_effective_language', return_value=('zh', 'test')),
            mock.patch.object(insights, '_send_insight_push', side_effect=self._push),
        ]
        for patch in patches:
            patch.start()
            test.addCleanup(patch.stop)

    def _nominate(self, **kwargs):
        self.events.append(('nominate',))
        return copy.deepcopy(self.nominations)

    def _judge(self, nomination, fact_sheet, language_code='zh'):
        self.events.append(('judge', nomination['topic_key']))
        return {'verdict': 'pass', 'reason': '证据充分', 'confidence_after': 80, 'depth_verdict': 'keep'}

    def _push(self, developer_id, uid, card):
        self.events.append(('push', card['id']))
        self.pushes.append(card['id'])
        return True

    def released(self):
        return [row for row in self.db.insights.values() if row.get('status') == 'released']


def job(**overrides):
    return {'id': JOB_ID, 'kind': 'insight', 'developer_id': DEV, 'uid': UID, 'date': '2026-10-28',
            'window_days': 60, 'dry_run': False, 'send_push': True, 'stage_attempts': 1, **overrides}


class EngineWriteFenceTests(unittest.TestCase):
    def test_fence_comes_after_the_model_calls_and_before_any_write(self):
        h = Harness(self)
        fence = lambda: h.events.append(('fence',))  # noqa: E731
        result = engine.run_insight_engine(DEV, UID, before_write=fence, released_by_job=JOB_ID)
        kinds = [event[0] for event in h.events]
        self.assertEqual(['nominate', 'judge', 'fence', 'write', 'write'], kinds)
        self.assertEqual([('write', 'mature'), ('write', 'released')], h.events[-2:])
        self.assertEqual(JOB_ID, result['released']['released_by_job'])
        self.assertEqual([JOB_ID], [row['released_by_job'] for row in h.released()])

    def test_overtaken_run_writes_nothing(self):
        h = Harness(self)

        def lost():
            raise LeaseLost()

        with self.assertRaises(LeaseLost):
            engine.run_insight_engine(DEV, UID, before_write=lost, released_by_job=JOB_ID)
        self.assertEqual({}, h.db.insights)

    def test_dry_run_writes_nothing_and_needs_no_fence(self):
        h = Harness(self)
        fence = mock.Mock()
        result = engine.run_insight_engine(DEV, UID, dry_run=True, before_write=fence, released_by_job=JOB_ID)
        fence.assert_not_called()
        self.assertEqual({}, h.db.insights)
        self.assertEqual('compliance-first', result['released']['topic_key'])

    def test_sync_callers_are_unchanged(self):
        # POST /v1/insights/run without defer passes neither: same writes, no job stamp.
        h = Harness(self)
        result = engine.run_insight_engine(DEV, UID)
        self.assertNotIn('released_by_job', result['released'])
        self.assertEqual([('write', 'mature'), ('write', 'released')], [e for e in h.events if e[0] == 'write'])


class RunInsightJobTests(unittest.TestCase):
    def run_job(self, h, **overrides):
        return processor.run_job(job(**overrides), lambda: h.events.append(('fence',)))

    def test_release_then_push_once(self):
        h = Harness(self)
        result = self.run_job(h)
        [card] = h.released()
        self.assertEqual({'outcome': 'released', 'card_id': card['id'], 'topic_key': 'compliance-first',
                          'pushed': True, 'nominations': 1,
                          'verdicts': [{'topic_key': 'compliance-first', 'verdict': 'pass'}]}, result)
        self.assertEqual([card['id']], h.pushes)
        # The push is marked on the card, behind a fence, before it is sent.
        kinds = [event[0] for event in h.events]
        self.assertEqual(['fence', 'write', 'push'], kinds[-3:])
        self.assertEqual(('write', 'push_started_at'), h.events[-2])
        self.assertIsNotNone(h.db.insights[card['id']]['push_started_at'])

    def test_run_that_died_after_releasing_only_pushes(self):
        # The previous attempt released the card and died before pushing it.
        h = Harness(self)
        released = {'id': 'insight_a', 'topic_key': 'compliance-first', 'headline': '你总是先想合规',
                    'body': '……', 'status': 'released', 'released_by_job': JOB_ID,
                    'released_at': datetime.now(timezone.utc) - timedelta(minutes=3)}
        h.db.insights[released['id']] = released
        result = self.run_job(h)
        self.assertNotIn(('nominate',), h.events, 'running the engine again would hit its own fatigue window')
        self.assertEqual(['insight_a'], h.pushes)
        self.assertEqual({'outcome': 'released', 'card_id': 'insight_a', 'topic_key': 'compliance-first',
                          'pushed': True, 'resumed': True}, result)

    def test_card_already_marked_is_never_pushed_again(self):
        h = Harness(self)
        h.db.insights['insight_a'] = {'id': 'insight_a', 'topic_key': 't', 'status': 'released',
                                      'released_by_job': JOB_ID, 'push_started_at': datetime.now(timezone.utc)}
        result = self.run_job(h)
        self.assertEqual([], h.pushes)
        self.assertIsNone(result['pushed'])

    def test_lost_lease_before_the_push_sends_nothing(self):
        h = Harness(self)
        h.db.insights['insight_a'] = {'id': 'insight_a', 'topic_key': 't', 'status': 'released',
                                      'released_by_job': JOB_ID}

        def lost():
            raise LeaseLost()

        with self.assertRaises(LeaseLost):
            processor.run_job(job(), lost)
        self.assertEqual([], h.pushes)
        self.assertNotIn('push_started_at', h.db.insights['insight_a'])

    def test_nothing_worth_saying_is_a_skip(self):
        h = Harness(self, nominations=[])
        self.assertEqual({'outcome': 'skipped', 'skipped_reason': 'no_nominations', 'nominations': 0,
                          'verdicts': []}, self.run_job(h))
        self.assertEqual(([], []), (h.pushes, h.released()))

    def test_fatigue_window_is_a_skip_without_model_calls(self):
        recent = {'id': 'insight_old', 'topic_key': 'old', 'status': 'released',
                  'released_at': datetime.now(timezone.utc) - timedelta(days=2)}
        h = Harness(self, ledger=[recent])
        result = self.run_job(h)
        self.assertEqual(('skipped', 'fatigue_window'), (result['outcome'], result['skipped_reason']))
        self.assertNotIn(('nominate',), h.events)

    def test_dry_run_releases_and_pushes_nothing(self):
        h = Harness(self)
        result = self.run_job(h, dry_run=True, send_push=False)
        self.assertEqual(('dry_run', 'compliance-first'), (result['outcome'], result['would_release']))
        self.assertEqual(({}, []), (h.db.insights, h.pushes))

    def test_release_without_push_when_not_asked(self):
        h = Harness(self)
        result = self.run_job(h, send_push=False)
        self.assertEqual((True, False), (bool(h.released()), result['pushed']))
        self.assertEqual([], h.pushes)

    def test_engine_failure_is_retried_once(self):
        h = Harness(self)
        with mock.patch.object(insight_processor, 'run_insight_engine', side_effect=TimeoutError('read timed out')):
            for attempt, retryable in ((1, True), (2, False)):
                with self.assertRaises(JobFailure) as ctx:
                    self.run_job(h, stage_attempts=attempt)
                self.assertEqual(('engine_failed', retryable), (ctx.exception.code, ctx.exception.retryable))

    def test_unknown_kind_fails_for_good(self):
        with self.assertRaises(JobFailure) as ctx:
            processor.run_job(job(kind='something-else'), lambda: None)
        self.assertEqual(('unknown_kind', False), (ctx.exception.code, ctx.exception.retryable))


class WorkerTests(unittest.TestCase):
    """Through the worker: the queue, the real dispatch, the engine and the push joined up."""

    def setUp(self):
        self.jobs = MemoryJobs()
        self.jobs.jobs[JOB_ID] = {**job(), 'status': 'queued', 'stage': 'generate', 'attempts': 0,
                                  'stage_attempts': 0, 'next_attempt_at': 0, 'lease_token': None,
                                  'lease_until': 0, 'history': [], 'checkpoints': {}}
        self.sqs = mock.Mock()
        self.worker = JournalWorker(self.jobs, self.sqs, 'queue', 'dlq', processor.run_job, clock=self.jobs.clock)

    def deliver(self):
        self.worker.handle({'ReceiptHandle': 'receipt', 'Body': json.dumps({'job_id': JOB_ID})})

    def test_one_card_one_push_however_often_it_is_delivered(self):
        h = Harness(self)
        self.deliver()
        self.deliver()
        record = self.jobs.jobs[JOB_ID]
        self.assertEqual(('completed', 'released', True),
                         (record['status'], record['result']['outcome'], record['result']['pushed']))
        self.assertEqual(1, len(h.released()))
        self.assertEqual(1, len(h.pushes))

    def test_run_that_dies_between_release_and_push_pushes_on_retry(self):
        h = Harness(self)
        renew = self.jobs.renew
        renewals = []

        def renew_failing_once_after_release(job_id, token):
            renewals.append(token)
            if h.released() and len(renewals) == 2:
                raise ConnectionError('Firestore unavailable')  # the fence before the push
            return renew(job_id, token)

        with mock.patch.object(self.jobs, 'renew', side_effect=renew_failing_once_after_release):
            self.deliver()
        record = self.jobs.jobs[JOB_ID]
        self.assertEqual(('retry_wait', 1, 0), (record['status'], len(h.released()), len(h.pushes)))
        self.jobs.now[0] = record['next_attempt_at'] + 1
        self.deliver()
        record = self.jobs.jobs[JOB_ID]
        self.assertEqual(('completed', True, True),
                         (record['status'], record['result']['resumed'], record['result']['pushed']))
        self.assertEqual((1, 1), (len(h.released()), len(h.pushes)))
        self.assertEqual(1, sum(event == ('nominate',) for event in h.events))

    def test_run_overtaken_while_nominating_writes_nothing(self):
        h = Harness(self)
        nominate = h._nominate

        def slow_nomination(**kwargs):
            # The lease ran out during the model call and a redelivery took the job over.
            self.jobs.now[0] += state.LEASE_SECONDS + 1
            self.assertTrue(self.jobs.claim(JOB_ID, 'successor'))
            return nominate(**kwargs)

        with mock.patch.object(engine.llm_engine, 'nominate', side_effect=slow_nomination):
            self.deliver()
        self.assertEqual(({}, []), (h.db.insights, h.pushes))
        self.assertEqual('successor', self.jobs.jobs[JOB_ID]['lease_token'])
        self.sqs.delete_message.assert_not_called()


class FakeJobStore:
    def __init__(self):
        self.enqueued = []

    def __call__(self):
        return self

    def enqueue_insight(self, developer_id, uid, date_str, **kwargs):
        self.enqueued.append((developer_id, uid, date_str, kwargs))
        return {'id': JOB_ID, 'status': 'queued'}


class EndpointTests(unittest.TestCase):
    def call(self, **body):
        request = insights.InsightRunRequest(**body)
        return asyncio.run(insights.run_insights(request, external_user_id=UID, developer_id=DEV))

    def test_deferred_run_is_queued_for_the_users_local_day(self):
        Harness(self)
        jobs = FakeJobStore()
        with mock.patch.object(job_store, 'JournalJobStore', jobs), \
                mock.patch.object(insights, 'run_insight_engine', side_effect=AssertionError('ran inline')), \
                mock.patch.object(insights, 'datetime', wraps=datetime) as clock:
            # 2026-10-27 18:30 UTC is already the 28th in Shanghai.
            clock.now.side_effect = lambda tz=None: datetime(2026, 10, 27, 18, 30, tzinfo=timezone.utc).astimezone(tz)
            response = self.call(defer=True)
        self.assertEqual(202, response.status_code)
        self.assertEqual({'status': 'queued', 'job_id': JOB_ID, 'job_status': 'queued', 'date': '2026-10-28'},
                         json.loads(response.body))
        self.assertEqual([(DEV, UID, '2026-10-28', {'window_days': 60, 'dry_run': False, 'send_push': True})],
                         jobs.enqueued)

    def test_without_defer_the_run_happens_in_the_request(self):
        h = Harness(self)
        with mock.patch.object(job_store, 'JournalJobStore', side_effect=AssertionError('queued without defer')), \
                mock.patch('utils.locales.get_user_effective_language', return_value=('zh', 'test')):
            result = self.call()
        self.assertEqual('compliance-first', result['released']['topic_key'])
        self.assertTrue(result['pushed'])
        self.assertEqual(1, len(h.pushes))
        self.assertNotIn('released_by_job', h.released()[0])


class StoreTests(unittest.TestCase):
    def test_insight_run_ids_are_per_user_day_and_kind_of_run(self):
        ids = {
            'run': job_store.job_id(DEV, UID, '2026-10-28', 'insight'),
            'dry_run': job_store.job_id(DEV, UID, '2026-10-28', 'insight_dry_run'),
            'next_day': job_store.job_id(DEV, UID, '2026-10-29', 'insight'),
            'journal': job_store.job_id(DEV, UID, '2026-10-28', 'evening'),
        }
        self.assertEqual(4, len(set(ids.values())))


if __name__ == '__main__':
    unittest.main(verbosity=2)
