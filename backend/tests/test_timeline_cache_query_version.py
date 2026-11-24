"""Old chapter caches must be refreshed once after the recording-time query fix."""
import ast
from datetime import date
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).parents[1]))
from utils.timeline.day_query import RECORDING_QUERY_VERSION
from utils.timeline.rollup import ROLLUP_VERSION
from utils.timeline.chaptering import ALGO_VERSION
from utils.timeline.day_query import _resolve_tz
from utils.llm.model_config import MODEL_CONFIG_VERSION


class CacheQueryVersionTests(unittest.TestCase):
    def handler(self, cached):
        source = (Path(__file__).parents[1] / 'routers/timeline.py').read_text()
        node = next(n for n in ast.parse(source).body
                    if isinstance(n, ast.FunctionDef) and n.name == 'get_day_chapters')
        node.decorator_list = []
        updated = {'query_version': RECORDING_QUERY_VERSION, 'chapters': []}
        recompute = Mock(return_value={'status': 'computed', 'document': updated})
        ns = {
            'Query': lambda default, **kw: default,
            'Depends': lambda fn: None,
            'get_developer_id_from_api_key': object(),
            'parse_day': date.fromisoformat,
            'dev_db': SimpleNamespace(get_timeline_day=lambda *args: cached, get_user_timezone=lambda *args: 'UTC'),
            '_resolve_tz': _resolve_tz,
            'resolve_summary_dependencies': lambda: SimpleNamespace(fingerprint='summary-v1'),
            'redis_db': object(),
            'should_recompute_now': lambda *args: False,
            'recompute_day': recompute,
            '_serialize_day': lambda doc, day: doc,
            '_edited_day': lambda doc, day, *args: doc,
            'RECORDING_QUERY_VERSION': RECORDING_QUERY_VERSION,
            'ROLLUP_VERSION': ROLLUP_VERSION,
            'ALGO_VERSION': ALGO_VERSION,
            'MODEL_CONFIG_VERSION': MODEL_CONFIG_VERSION,
        }
        exec(compile(ast.Module(body=[node], type_ignores=[]), '<timeline-handler>', 'exec'), ns)
        return ns[node.name], recompute

    def test_old_clean_cache_recomputes_even_without_dirty_marker(self):
        handler, recompute = self.handler({'chapters': []})
        result = handler('2026-09-07', 'user', developer_id='dev')
        recompute.assert_called_once()
        self.assertFalse(recompute.call_args.kwargs['force'])
        self.assertEqual(result['cache_reason'], 'query_version')
        self.assertEqual(result['query_version'], RECORDING_QUERY_VERSION)

    def test_current_clean_cache_does_not_recompute(self):
        handler, recompute = self.handler({'query_version': RECORDING_QUERY_VERSION, 'rollup_version': ROLLUP_VERSION,
                                          'model_config_version': 'unrelated-old-config', 'algo_version': ALGO_VERSION,
                                          'summary_fingerprint': 'summary-v1', 'timezone': 'UTC', 'chapters': []})
        result = handler('2026-09-07', 'user', developer_id='dev')
        recompute.assert_not_called()
        self.assertEqual(result['cache'], 'hit')

    def test_old_summary_version_recomputes_without_a_dirty_marker(self):
        handler, recompute = self.handler({'query_version': RECORDING_QUERY_VERSION,
                                          'rollup_version': 'r1', 'chapters': []})
        result = handler('2026-10-12', 'user', developer_id='dev')
        recompute.assert_called_once()
        self.assertEqual(result['cache_reason'], 'summary_version')

    def test_prompt_or_effective_model_change_recomputes_clean_day(self):
        handler, recompute = self.handler({'query_version': RECORDING_QUERY_VERSION,
                                          'rollup_version': ROLLUP_VERSION, 'algo_version': ALGO_VERSION,
                                          'summary_fingerprint': 'old-model-or-prompt', 'timezone': 'UTC'})
        result = handler('2026-10-14', 'user', developer_id='dev')
        recompute.assert_called_once()
        self.assertEqual(result['cache_reason'], 'summary_version')
        self.assertEqual(recompute.call_args.kwargs['dependencies'].fingerprint, 'summary-v1')

    def test_timezone_change_rechecks_day_membership(self):
        handler, recompute = self.handler({'query_version': RECORDING_QUERY_VERSION,
                                          'rollup_version': ROLLUP_VERSION, 'algo_version': ALGO_VERSION,
                                          'summary_fingerprint': 'summary-v1', 'timezone': 'Asia/Shanghai'})
        result = handler('2026-10-14', 'user', developer_id='dev')
        recompute.assert_called_once()
        self.assertEqual(result['cache_reason'], 'timezone')

    def test_legacy_cache_without_model_provenance_is_checked_on_access(self):
        handler, recompute = self.handler({'query_version': RECORDING_QUERY_VERSION,
                                          'rollup_version': ROLLUP_VERSION, 'model_config_version': MODEL_CONFIG_VERSION})
        result = handler('2026-10-14', 'user', developer_id='dev')
        recompute.assert_called_once()
        self.assertEqual(result['cache_reason'], 'summary_version')


if __name__ == '__main__':
    unittest.main()
