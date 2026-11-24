"""Offline Ask regressions with production credentials and sockets disabled."""
import os
from pathlib import Path
import sys
import time
from unittest.mock import patch

BACKEND = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(BACKEND), str(BACKEND / 'tests')]


def main():
    for key in ('PINECONE_API_KEY', 'SERVICE_ACCOUNT_JSON', 'FCM_SERVICE_ACCOUNT_JSON',
                'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'):
        os.environ.pop(key, None)
    os.environ.update(OPENAI_API_KEY='test', OPENROUTER_API_KEY='test', LLM_PROVIDER='openrouter',
                      GOOGLE_CLOUD_PROJECT='demo-ask', FIRESTORE_EMULATOR_HOST='127.0.0.1:8787',
                      GOOGLE_APPLICATION_CREDENTIALS='/nonexistent/ask-tests.json',
                      FCM_GOOGLE_APPLICATION_CREDENTIALS='/nonexistent/ask-tests-fcm.json',
                      AWS_EC2_METADATA_DISABLED='true', AWS_ACCESS_KEY_ID='test', AWS_SECRET_ACCESS_KEY='test')
    from run_timeline_tests import _run_tests
    with patch('dotenv.load_dotenv', return_value=False):
        from utils.llm import prompt_registry
        prompt_registry._cache['chat.agent_system:production'] = {'data': None, 'fetched_at': time.time() + 3600}
        return _run_tests([str(BACKEND / 'tests' / name) for name in
                           ('test_chapter_ask_context.py', 'test_chat_agent_loop.py')] +
                          ['-q', '--tb=short', '--disable-warnings', *sys.argv[1:]])


if __name__ == '__main__':
    raise SystemExit(main())
