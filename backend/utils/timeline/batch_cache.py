"""Short-lived, owner-scoped inference results; never part of a Firestore day.

Keys hash exact inference inputs. Entries have an atomic 24-hour expiry and do
not extend their lifetime on reads. Redis failure only forfeits reuse, never a
successfully generated result. Callers validate output before using or storing it.
"""

import json
import logging

from utils.timeline.summary_dependencies import digest

logger = logging.getLogger(__name__)
CACHE_TTL_SECONDS = 24 * 60 * 60
MAX_ENTRY_BYTES = 256 * 1024
CACHE_VERSION = 1


class BatchCache:
    def __init__(self, redis_client, developer_id: str, user_id: str, day: str):
        if not all(isinstance(part, str) and part for part in (developer_id, user_id, day)):
            raise ValueError('Batch cache requires developer, user and day scope')
        self.redis = redis_client
        self.prefix = f'timeline:batch:v{CACHE_VERSION}:{digest([developer_id, user_id, day])}:'

    def _key(self, stage: str, fingerprint: str) -> str:
        if stage not in ('draft', 'grounded'):
            raise ValueError('Unknown summary stage')
        return f'{self.prefix}{stage}:{fingerprint}'

    def get(self, stage: str, fingerprint: str):
        key = self._key(stage, fingerprint)
        if self.redis is None:
            return None
        try:
            raw = self.redis.get(key)
            if raw is None:
                logger.info('[timeline_batch_cache] stage=%s outcome=miss', stage)
                return None
            size = len(raw.encode('utf-8')) if isinstance(raw, str) else len(raw)
            if size > MAX_ENTRY_BYTES:
                raise ValueError('Oversized cache entry')
            entry = json.loads(raw)
            if (entry.get('version') != CACHE_VERSION or entry.get('stage') != stage
                    or entry.get('fingerprint') != fingerprint or not isinstance(entry.get('result'), dict)):
                raise ValueError('Invalid cache envelope')
            return entry['result']
        except (ValueError, TypeError, AttributeError):
            logger.warning('[timeline_batch_cache] stage=%s outcome=invalid', stage)
        except Exception as error:
            logger.warning('[timeline_batch_cache] stage=%s outcome=read_error type=%s', stage, type(error).__name__)
        return None

    def put(self, stage: str, fingerprint: str, result: dict) -> None:
        key = self._key(stage, fingerprint)
        if self.redis is None:
            return
        try:
            raw = json.dumps({'version': CACHE_VERSION, 'stage': stage, 'fingerprint': fingerprint,
                              'result': result}, ensure_ascii=False).encode('utf-8')
            if len(raw) > MAX_ENTRY_BYTES:
                logger.info('[timeline_batch_cache] stage=%s outcome=oversized', stage)
                return
            self.redis.set(key, raw, ex=CACHE_TTL_SECONDS)
        except Exception as error:
            logger.warning('[timeline_batch_cache] stage=%s outcome=write_error type=%s', stage, type(error).__name__)
