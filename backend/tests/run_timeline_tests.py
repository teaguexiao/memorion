"""Offline timeline regression entrypoint (no credentials or external services).

Run from the repo root: python backend/tests/run_timeline_tests.py
Storage, HTTP/auth and inference tests supply their own fakes; fakeredis executes
the actual Redis Lua leases. The main-app smoke suite needs the full app runtime
and is separate from this focused suite. Outbound networking is denied here.
"""
import os
from pathlib import Path
import socket
import sys
import time
from urllib.parse import urlsplit
from unittest.mock import patch

BACKEND = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(BACKEND), str(BACKEND / 'tests')]


def main():
    os.environ.update(OPENAI_API_KEY='test', OPENROUTER_API_KEY='test', LLM_PROVIDER='openrouter',
                      GOOGLE_CLOUD_PROJECT='demo-memorion-cache', FIRESTORE_EMULATOR_HOST='127.0.0.1:8787',
                      GOOGLE_APPLICATION_CREDENTIALS='/nonexistent/timeline-tests.json',
                      FCM_GOOGLE_APPLICATION_CREDENTIALS='/nonexistent/timeline-tests-fcm.json',
                      AWS_EC2_METADATA_DISABLED='true', AWS_ACCESS_KEY_ID='test', AWS_SECRET_ACCESS_KEY='test')
    for key in ('SERVICE_ACCOUNT_JSON', 'FCM_SERVICE_ACCOUNT_JSON'):
        os.environ.pop(key, None)
    os.environ['PYTHON_DOTENV_DISABLED'] = '1'
    from utils.llm import prompt_registry
    for key in ('timeline.chapter_rollup', 'timeline.chapter_grounding', 'conversation.discard'):
        prompt_registry._cache[key + ':production'] = {'data': None, 'fetched_at': time.time() + 3600}
    files = sorted(str(p) for p in (BACKEND / 'tests').glob('test_timeline*.py')
                   if p.name != 'test_timeline_endpoint_smoke.py')
    files += [str(BACKEND / 'tests' / name) for name in
              ('test_model_config.py', 'test_bedrock_migration.py', 'test_recording_timeline_integrity.py',
               'test_llm_content_blocks.py', 'test_prompt_seed_declarations.py',
               'test_summary_content_policy.py', 'test_image_generation.py',
               'test_daily_illustration_sources.py', 'test_speech_sample_revocation.py',
               'test_speech_sample_collector_quality.py', 'test_daily_summary_catch_up.py',
               'test_daily_summary_cron_catch_up.py', 'test_daily_journal_grounding.py',
               'test_daily_journal_evidence.py', 'test_daily_journal_deferred.py',
               'test_insight_jobs.py', 'test_insights_run_timeout_and_eval_tenants.py',
               'test_insight_evidence_and_depth.py', 'test_insight_nominate_retry.py',
               'test_insight_sampling_and_freshness.py')]
    # CI may opt into an ephemeral loopback Redis. All other networking remains
    # forbidden, including production Redis, Firebase and model inference.
    redis_url = os.environ.get('TIMELINE_TEST_REDIS_URL')
    allowed = None
    if redis_url:
        target = urlsplit(redis_url)
        if target.scheme != 'redis' or target.hostname != '127.0.0.1':
            raise ValueError('TIMELINE_TEST_REDIS_URL must target ephemeral loopback Redis')
        allowed = ('127.0.0.1', target.port or 6379)
    with patch('dotenv.load_dotenv', return_value=False):
        return _run_tests([*files, '-q', *sys.argv[1:]], allowed)


def _run_tests(args, allowed=None):
    """Fail the suite even when application error handling swallows the guard."""
    import pytest
    blocked = []
    def guarded(original):
        def connect(sock, address):
            if allowed is not None and address == allowed:
                return original(sock, address)
            blocked.append(True)
            raise AssertionError('Offline suite attempted unapproved networking')
        return connect
    with patch.object(socket.socket, 'connect', guarded(socket.socket.connect)), \
            patch.object(socket.socket, 'connect_ex', guarded(socket.socket.connect_ex)):
        result = pytest.main(args)
    if blocked:
        print(f'FAIL: blocked {len(blocked)} unexpected socket connections (including swallowed errors)')
        return 1
    return result



if __name__ == '__main__':
    raise SystemExit(main())
