"""SQS delivery + Firestore outbox reconciliation. One large job per process."""
import json
import logging
import os
import random
import signal
import threading
import time
import uuid
from pathlib import Path

from . import state

log = logging.getLogger(__name__)


class Worker:
    def __init__(self, store, sqs, queue_url, dlq_url, processor, clock=time.time):
        self.store, self.sqs, self.queue_url, self.dlq_url = store, sqs, queue_url, dlq_url
        self.processor, self.clock = processor, clock
        self.stop = threading.Event()

    def _release_failed_usage(self, job):
        release_usage = getattr(self.processor, 'release_failed_usage', None)
        if (
            job
            and job.get('status') == 'failed'
            and job.get('is_root')
            and job.get('stage') in {'validate', 'transcribe'}
            and release_usage
        ):
            release_usage(job)

    def _release_stale_upload_usage(self, job):
        release_usage = getattr(self.processor, 'release_stale_upload_usage', None)
        if release_usage:
            release_usage(job)
            return
        if job.get('usage_committed'):
            return
        # Keep cleanup correct for lightweight processors used by maintenance
        # commands/tests. Production Pipeline supplies the same operation.
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

    def dispatch(self):
        for job in self.store.due():
            if job['status'] == 'uploading':
                try:
                    self._release_stale_upload_usage(job)
                    discarded = self.store.discard_upload(job['id'], job.get('upload_token'))
                    if not discarded:
                        # A replacement token normally already carries a future
                        # dispatch_at. For any other fenced no-op, advance the
                        # unchanged snapshot so it cannot stay hot in due().
                        self.store.dispatched(job)
                except Exception as error:
                    # Leave the placeholder due. The release is idempotent and
                    # its Firestore fence prevents refunding a replacement upload.
                    log.warning(
                        'audio_upload_usage_release_failed job=%s type=%s',
                        job['id'],
                        type(error).__name__,
                    )
                    self.store.dispatched(job)
                continue
            if job['status'] in {'completed', 'cancelled'}:
                continue
            dead = job['status'] == 'failed'
            if dead:
                try:
                    self._release_failed_usage(job)
                except Exception as error:
                    # Keep this failed job due so the next reconciliation can
                    # retry its idempotent refund, but do not let one Firestore
                    # outage block every later outbox record.
                    log.warning(
                        'audio_job_usage_release_failed job=%s type=%s',
                        job['id'],
                        type(error).__name__,
                    )
                    self.store.dispatched(job)
                    continue
            self.sqs.send_message(QueueUrl=self.dlq_url if dead else self.queue_url,
                                  MessageBody=json.dumps({'job_id': job['id']}))
            # Send before marking: a crash duplicates delivery rather than losing work.
            self.store.dispatched(job, dead_letter=dead)

    def handle(self, message):
        receipt = message['ReceiptHandle']
        try:
            job_id = str(uuid.UUID(json.loads(message['Body'])['job_id']))
        except (ValueError, KeyError, TypeError):
            # Preserve malformed messages for diagnosis, without logging their contents.
            self.sqs.send_message(QueueUrl=self.dlq_url, MessageBody=json.dumps({'error': 'invalid_message'}))
            self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=receipt)
            return
        token = uuid.uuid4().hex
        job = self.store.claim(job_id, token)
        if not job:
            try:
                self._release_failed_usage(self.store.get(job_id))
            except Exception as error:
                # A terminal job remains due in the Firestore outbox. Ack this
                # stale SQS delivery and let reconciliation retry the refund,
                # rather than poisoning the queue with the same message.
                log.warning('audio_job_usage_release_failed job=%s type=%s', job_id, type(error).__name__)
            self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=receipt)
            return
        done = threading.Event()
        lost = threading.Event()
        started = self.clock()

        def heartbeat():
            while not done.wait(20):
                try:
                    # Limit stuck calls too. ECS restarts this dedicated worker; lease recovery follows.
                    if self.clock() - started > 1800:
                        os._exit(70)
                    self.store.renew(job_id, token)
                    self.sqs.change_message_visibility(QueueUrl=self.queue_url, ReceiptHandle=receipt, VisibilityTimeout=120)
                    Path('/tmp/audio-worker-health').touch()
                except Exception:
                    lost.set()
                    return

        thread = threading.Thread(target=heartbeat, daemon=True)
        thread.start()
        try:
            self.processor(job, token)
            if self.store.get(job_id)['status'] == 'processing':
                raise state.JobFailure('incomplete_stage')
        except state.LeaseLost:
            lost.set()
        except Exception as error:
            failure = error if isinstance(error, state.JobFailure) else state.JobFailure('processing_unavailable')
            log.warning('audio_job_failed job=%s stage=%s code=%s type=%s', job_id, job['stage'], failure.code, type(error).__name__)
            try:
                updated = self.store.fail(job_id, token, failure, jitter=random.uniform(0, 10))
                try:
                    self._release_failed_usage(updated)
                except Exception as release_error:
                    # ``store.fail`` has already made a terminal job due. The
                    # reconciler owns durable refund retries from this point.
                    log.warning(
                        'audio_job_usage_release_failed job=%s type=%s',
                        job_id,
                        type(release_error).__name__,
                    )
            except state.LeaseLost:
                lost.set()
        finally:
            done.set()
            thread.join(timeout=2)
        if not lost.is_set():
            # Status/checkpoint is durable before ack; lost ack only produces a harmless replay.
            self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=receipt)

    def run(self):
        def reconcile():
            while not self.stop.is_set():
                try:
                    self.dispatch()
                except Exception as error:
                    log.error('audio_outbox_unavailable type=%s', type(error).__name__)
                self.stop.wait(15)
        threading.Thread(target=reconcile, daemon=True).start()
        while not self.stop.is_set():
            Path('/tmp/audio-worker-health').touch()
            try:
                messages = self.sqs.receive_message(QueueUrl=self.queue_url, MaxNumberOfMessages=1,
                                                   WaitTimeSeconds=20, VisibilityTimeout=120).get('Messages', [])
                for message in messages:
                    if self.stop.is_set():
                        return
                    self.handle(message)
            except Exception as error:
                log.error('audio_worker_unavailable type=%s', type(error).__name__)
                self.stop.wait(5)


def main():
    import boto3
    from .store import JobStore
    from .pipeline import Pipeline
    logging.basicConfig(level=logging.INFO)
    store = JobStore()
    worker = Worker(store, boto3.client('sqs', region_name=os.getenv('AUDIO_JOBS_AWS_REGION', 'us-east-1')),
                    os.environ['AUDIO_JOBS_QUEUE_URL'], os.environ['AUDIO_JOBS_DLQ_URL'], Pipeline(store))
    signal.signal(signal.SIGTERM, lambda *_: worker.stop.set())
    signal.signal(signal.SIGINT, lambda *_: worker.stop.set())
    worker.run()


if __name__ == '__main__':
    main()
