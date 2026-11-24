"""Exercise the production query function with an in-memory Firestore surface."""
import ast
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List
import unittest

from google.cloud.firestore_v1.base_query import FieldFilter


class Query:
    def __init__(self, documents):
        self.documents = documents
        self.filters = []
        self.sorted_field = None
        self.count = None

    def collection(self, name):
        assert name == 'conversations'
        return self

    def where(self, *, filter):
        self.filters.append(filter)
        return self

    def order_by(self, field, direction):
        self.sorted_field = field
        assert direction == 'DESCENDING'
        return self

    def limit(self, count):
        self.count = count
        return self

    def stream(self):
        rows = [d for d in self.documents if d.get(self.sorted_field) is not None]
        for f in self.filters:
            rows = [d for d in rows if (
                d[f.field_path] >= f.value if f.op_string == '>=' else d[f.field_path] <= f.value
            )]
        rows.sort(key=lambda d: d[self.sorted_field], reverse=True)
        return [SimpleNamespace(to_dict=lambda d=d: dict(d), reference=None) for d in rows[:self.count]]


def load_query(query):
    # Avoid importing live database/Redis/LLM clients in a query unit test.
    source = (Path(__file__).parents[1] / 'database/developer_data.py').read_text()
    node = next(n for n in ast.parse(source).body
                if isinstance(n, ast.FunctionDef) and n.name == 'get_conversations_by_recording_time')
    ns = {
        'datetime': datetime, 'List': List, 'Dict': Dict, 'Any': Any,
        'FieldFilter': FieldFilter,
        'firestore': SimpleNamespace(Query=SimpleNamespace(DESCENDING='DESCENDING')),
        '_get_user_ref': lambda dev, uid: query,
        '_prepare_conversation_for_read': lambda data, **kw: data,
    }
    exec(compile(ast.Module(body=[node], type_ignores=[]), '<recording-time-query>', 'exec'), ns)
    return ns[node.name]


class RecordingTimeDatabaseTests(unittest.TestCase):
    def test_late_upload_is_returned_and_other_recording_days_are_excluded(self):
        start = datetime(2026, 9, 7, 16, tzinfo=timezone.utc)
        query = Query([
            {'id': 'late', 'started_at': start, 'created_at': start + timedelta(days=8)},
            {'id': 'outside', 'started_at': start - timedelta(days=1), 'created_at': start},
            {'id': 'later', 'started_at': start + timedelta(minutes=2), 'created_at': start + timedelta(days=90)},
        ])
        result = load_query(query)('dev', 'uid', start_date=start, end_date=start + timedelta(hours=1))
        self.assertEqual([v['id'] for v in result], ['later', 'late'])
        self.assertTrue(all(v['photos'] == [] for v in result))

    def test_limit_uses_recording_time_not_upload_order(self):
        start = datetime(2026, 9, 7, tzinfo=timezone.utc)
        query = Query([
            {'id': 'old', 'started_at': start, 'created_at': start + timedelta(days=8)},
            {'id': 'new', 'started_at': start + timedelta(hours=1), 'created_at': start},
        ])
        result = load_query(query)('dev', 'uid', start_date=start, limit=1)
        self.assertEqual([v['id'] for v in result], ['new'])

    def test_unbounded_reads_are_rejected(self):
        with self.assertRaises(ValueError):
            load_query(Query([]))('dev', 'uid')


if __name__ == '__main__':
    unittest.main()
