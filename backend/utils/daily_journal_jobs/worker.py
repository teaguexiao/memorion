"""Journal worker: Firestore outbox -> SQS -> a few jobs at a time (daily journals, insight runs).

The delivery semantics are the audio worker's (`utils/audio_jobs/worker.py`): send before
marking dispatched, ack only after the record is durable, a lost lease leaves the message
for redelivery, and the Firestore record decides whether a delivery still has work to do.
What differs: no usage accounting, `concurrency` jobs run at once, and the entry is written
only after a renewal that proves the lease (the `fence` handed to the processor). A long day
takes 8-10 minutes, and one at a time would push the last of a busy 22:00 into the night.
The limit stays small: pictures are drawn one at a time anyway (the illustration model's
quota, see `image_generation._ILLUSTRATION_SLOT`), and the text models are shared with the API.
"""
import json
import logging
import os
import random
import signal
import threading
import time
import uuid
from pathlib import Path

from utils.audio_jobs import state

log = logging.getLogger(__name__)

HEALTH_FILE = Path('/tmp/journal-worker-health')
HEARTBEAT_SECONDS = 20
# Far beyond a real day (8-10 minutes). A job still running at this point is stuck; exiting
# lets ECS replace the task, and the job's lease expires into a counted retry.
JOB_HARD_LIMIT_SECONDS = 1800


class JournalWorker:
    def __init__(self, store, sqs, queue_url, dlq_url, processor, concurrency=2, clock=time.time):
        self.store, self.sqs, self.queue_url, self.dlq_url = store, sqs, queue_url, dlq_url
        self.processor, self.concurrency, self.clock = processor, max(1, int(concurrency)), clock
        self.stop = threading.Event()

    def dispatch(self):
        for job in self.store.due():
            if job['status'] == 'completed':
                continue
            dead = job['status'] == 'failed'
            self.sqs.send_message(QueueUrl=self.dlq_url if dead else self.queue_url,
                                  MessageBody=json.dumps({'job_id': job['id']}))
            # Send before marking: a crash duplicates delivery rather than losing work.
            self.store.dispatched(job, dead_letter=dead)

    def handle(self, message):
        receipt = message['ReceiptHandle']
        try:
            job_id = str(uuid.UUID(json.loads(message['Body'])['job_id']))
        except (ValueError, KeyError, TypeError):
            # Keep malformed messages for diagnosis, without logging their contents.
            self.sqs.send_message(QueueUrl=self.dlq_url, MessageBody=json.dumps({'error': 'invalid_message'}))
            self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=receipt)
            return
        token = uuid.uuid4().hex
        job = self.store.claim(job_id, token)
        if not job:
            # Finished, leased by a live worker, or not due yet: the record decides, and this
            # delivery has nothing to do. Reconciliation re-sends whatever is still owed.
            self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=receipt)
            return
        done = threading.Event()
        lost = threading.Event()
        started = self.clock()

        def heartbeat():
            while not done.wait(HEARTBEAT_SECONDS):
                if self.clock() - started > JOB_HARD_LIMIT_SECONDS:
                    log.error('journal_job_stuck job=%s', job_id)
                    os._exit(70)
                try:
                    self.store.renew(job_id, token)
                except state.LeaseLost:
                    lost.set()
                    return
                except Exception as error:
                    # Unlike the audio worker, one failed renewal does not give the job up: the
                    # lease outlasts several more attempts, and the write is fenced on its own.
                    log.warning('journal_job_heartbeat_failed job=%s type=%s', job_id, type(error).__name__)
                    continue
                try:
                    self.sqs.change_message_visibility(QueueUrl=self.queue_url, ReceiptHandle=receipt,
                                                       VisibilityTimeout=120)
                except Exception as error:
                    # If the message reappears, whoever receives it finds the lease held and drops
                    # it; the record, not the message, carries the job.
                    log.warning('journal_job_visibility_failed job=%s type=%s', job_id, type(error).__name__)
                HEALTH_FILE.touch()

        def fence():
            # Called right before the entry is written (and the evening push sent). Renewing
            # proves the lease is still this run's and holds it LEASE_SECONDS more, far longer
            # than the write takes: a run that lost its lease (and so may have a successor)
            # stops here instead of writing and pushing a second time.
            self.store.renew(job_id, token)

        thread = threading.Thread(target=heartbeat, daemon=True)
        thread.start()
        try:
            try:
                result = self.processor(job, fence)
            finally:
                # Recording the outcome needs no heartbeat: the lease outlasts the last renewal
                # by over a minute, and a renewal racing the final write would only conflict.
                done.set()
                thread.join(timeout=2)
            self.store.finish(job_id, token, result)
            log.info('journal_job_completed job=%s outcome=%s', job_id, (result or {}).get('outcome'))
        except state.LeaseLost:
            lost.set()
        except Exception as error:
            failure = error if isinstance(error, state.JobFailure) else state.JobFailure('processing_unavailable')
            log.warning('journal_job_failed job=%s code=%s retryable=%s type=%s',
                        job_id, failure.code, failure.retryable, type(error).__name__)
            try:
                self.store.fail(job_id, token, failure, jitter=random.uniform(0, 10))
            except state.LeaseLost:
                lost.set()
        if not lost.is_set():
            # The outcome is durable before the ack; a lost ack only produces a harmless replay.
            self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=receipt)

    def consume(self):
        while not self.stop.is_set():
            HEALTH_FILE.touch()
            try:
                messages = self.sqs.receive_message(QueueUrl=self.queue_url, MaxNumberOfMessages=1,
                                                    WaitTimeSeconds=20, VisibilityTimeout=120).get('Messages', [])
                for message in messages:
                    if self.stop.is_set():
                        return
                    self.handle(message)
            except Exception as error:
                log.error('journal_worker_unavailable type=%s', type(error).__name__)
                self.stop.wait(5)

    def run(self):
        def reconcile():
            while not self.stop.is_set():
                try:
                    self.dispatch()
                except Exception as error:
                    log.error('journal_outbox_unavailable type=%s', type(error).__name__)
                self.stop.wait(15)
        threading.Thread(target=reconcile, daemon=True).start()
        consumers = [threading.Thread(target=self.consume, daemon=True) for _ in range(self.concurrency)]
        for consumer in consumers:
            consumer.start()
        for consumer in consumers:
            consumer.join()


def main():
    logging.basicConfig(level=logging.INFO)
    import boto3
    import firebase_admin
    from .processor import run_job
    from .store import JournalJobStore
    # main.py initializes Firebase at import, and this process never imports main.py; the
    # journal's user-name lookup (database.auth) reads the default app.
    service_account = os.getenv('SERVICE_ACCOUNT_JSON')
    firebase_admin.initialize_app(
        firebase_admin.credentials.Certificate(json.loads(service_account)) if service_account else None)
    # The container's AWS_REGION points at Bedrock (us-west-2); the queue lives with the stack.
    sqs = boto3.client('sqs', region_name=os.getenv('DAILY_JOURNAL_JOBS_AWS_REGION', 'us-east-1'))
    worker = JournalWorker(JournalJobStore(), sqs, os.environ['DAILY_JOURNAL_JOBS_QUEUE_URL'],
                           os.environ['DAILY_JOURNAL_JOBS_DLQ_URL'], run_job,
                           concurrency=int(os.getenv('DAILY_JOURNAL_WORKER_CONCURRENCY', '2')))
    signal.signal(signal.SIGTERM, lambda *_: worker.stop.set())
    signal.signal(signal.SIGINT, lambda *_: worker.stop.set())
    log.info('journal_worker_started concurrency=%s', worker.concurrency)
    worker.run()


if __name__ == '__main__':
    main()
