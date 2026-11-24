"""Recording-time queries include delayed uploads and respect local days."""

import os
import sys
import unittest
from datetime import date, datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")

from utils.timeline.day_query import (  # noqa: E402
    _local_day_utc_bounds,
    _resolve_tz,
    get_conversations_in_range,
    get_day_conversations,
    parse_day,
)


class FakeDevDb:
    """A stand-in for developer_data: records the query window, filters on started_at."""

    def __init__(self, convos, tz_name=None):
        self._convos = convos
        self._tz_name = tz_name
        self.last_query = None

    def get_user_timezone(self, dev, uid):
        return self._tz_name

    def get_conversations_by_recording_time(self, dev, uid, limit=100, start_date=None, end_date=None,
                          include_discarded=False, include_transcript_segments=True, **kw):
        self.last_query = {
            'start_date': start_date, 'end_date': end_date, 'limit': limit,
            'include_transcript_segments': include_transcript_segments,
        }
        out = []
        for c in self._convos:
            created = c.get('started_at')
            if created is None:
                continue
            if start_date and created < start_date:
                continue
            if end_date and created > end_date:
                continue
            out.append(c)
        return out


def _c(convo_id, started_at, created_at, source='app'):
    return {
        'id': convo_id,
        'source': source,
        'started_at': started_at,
        'created_at': created_at,
        'discarded': False,
        'transcript_segments': [{'start': 0, 'end': 5, 'text': 'hi'}],
    }


DAY = date(2026, 8, 6)


class RecordingTimeWindowTests(unittest.TestCase):
    def test_query_window_uses_exact_recording_time(self):
        """Query the local day on started_at without restricting upload time."""
        db = FakeDevDb([])
        get_day_conversations(db, 'dev', 'uid', DAY, tz=timezone.utc)
        start_utc, end_utc = _local_day_utc_bounds(DAY, timezone.utc)
        self.assertEqual(db.last_query['start_date'], start_utc)
        self.assertEqual(db.last_query['end_date'], end_utc)

    def test_late_uploaded_conversation_is_rescued(self):
        """录于本日午夜前、次日才上传的会话:created_at 错日但 started_at 在本日 → 保留。"""
        started = datetime(2026, 8, 6, 23, 30, tzinfo=timezone.utc)   # 本日录
        created = datetime(2026, 8, 7, 20, 0, tzinfo=timezone.utc)    # 次日才落库
        db = FakeDevDb([_c('late', started, created, source='sdcard')])
        kept = get_day_conversations(db, 'dev', 'uid', DAY, tz=timezone.utc)
        self.assertEqual([c['id'] for c in kept], ['late'])

    def test_soundcore_upload_eight_days_or_months_later_stays_on_recording_day(self):
        started = datetime(2026, 8, 6, 17, 12, tzinfo=timezone.utc)
        for delay in [8, 90]:
            with self.subTest(upload_delay_days=delay):
                db = FakeDevDb([_c('offline', started, started + timedelta(days=delay), source='audio_upload')])
                kept = get_day_conversations(db, 'dev', 'uid', DAY, tz=timezone.utc)
                self.assertEqual([c['id'] for c in kept], ['offline'])

    def test_next_midnight_is_not_part_of_previous_day(self):
        started = datetime(2026, 8, 7, tzinfo=timezone.utc)
        db = FakeDevDb([_c('next-day', started, started + timedelta(days=8))])
        self.assertEqual(get_day_conversations(db, 'dev', 'uid', DAY, tz=timezone.utc), [])

    def test_yesterdays_late_upload_not_pulled_into_today(self):
        """昨天录、今天上传的会话不能被拉进今天(started_at 决定归属)。"""
        started = datetime(2026, 8, 5, 22, 0, tzinfo=timezone.utc)    # 昨天录
        created = datetime(2026, 8, 6, 9, 0, tzinfo=timezone.utc)     # 今天上传
        db = FakeDevDb([_c('yesterday', started, created)])
        kept = get_day_conversations(db, 'dev', 'uid', DAY, tz=timezone.utc)
        self.assertEqual(kept, [])

    def test_results_sorted_by_started_at(self):
        db = FakeDevDb([
            _c('b', datetime(2026, 8, 6, 15, 0, tzinfo=timezone.utc), datetime(2026, 8, 6, 15, 0, tzinfo=timezone.utc)),
            _c('a', datetime(2026, 8, 6, 9, 0, tzinfo=timezone.utc), datetime(2026, 8, 6, 9, 0, tzinfo=timezone.utc)),
        ])
        kept = get_day_conversations(db, 'dev', 'uid', DAY, tz=timezone.utc)
        self.assertEqual([c['id'] for c in kept], ['a', 'b'])


class TimezoneTests(unittest.TestCase):
    def test_local_day_decides_membership(self):
        """UTC+8 用户:UTC 前一天 16:30 == 本地 8-06 00:30,归本地 8-06。"""
        tz = _resolve_tz('Asia/Shanghai')
        started = datetime(2026, 8, 5, 16, 30, tzinfo=timezone.utc)
        created = started
        db = FakeDevDb([_c('early', started, created)])
        kept = get_day_conversations(db, 'dev', 'uid', DAY, tz=tz)
        self.assertEqual([c['id'] for c in kept], ['early'])

    def test_unknown_timezone_falls_back_to_utc(self):
        self.assertEqual(_resolve_tz('Not/AZone'), timezone.utc)
        self.assertEqual(_resolve_tz(None), timezone.utc)


class ParseTests(unittest.TestCase):
    def test_parse_day(self):
        self.assertEqual(parse_day('2026-08-06'), DAY)

    def test_parse_day_rejects_junk(self):
        with self.assertRaises(ValueError):
            parse_day('not-a-date')


class RangeQueryTests(unittest.TestCase):
    """任意区间版(`memory_search` 的日期通道用),和单日版同一个陷阱、同一个解法。"""

    START = datetime(2026, 8, 6, 0, 0, tzinfo=timezone.utc)
    END = datetime(2026, 8, 6, 23, 59, 59, tzinfo=timezone.utc)

    def test_query_window_uses_exact_recording_time(self):
        """Use the requested recording-time bounds, without upload-time slack."""
        db = FakeDevDb([])
        get_conversations_in_range(db, 'dev', 'uid', start=self.START, end=self.END)
        self.assertEqual(db.last_query['start_date'], self.START)
        self.assertEqual(db.last_query['end_date'], self.END)

    def test_late_uploaded_conversation_is_rescued(self):
        """8-06 录、8-07 才上传:created_at 落在区间外,但 started_at 在区间内 → 保留。

        这正是手表那条路径的形态(实测 p90 偏移 16h),也是这个函数存在的理由。
        """
        started = datetime(2026, 8, 6, 23, 30, tzinfo=timezone.utc)
        created = datetime(2026, 8, 7, 20, 0, tzinfo=timezone.utc)
        db = FakeDevDb([_c('late', started, created, source='audio_upload')])
        kept = get_conversations_in_range(db, 'dev', 'uid', start=self.START, end=self.END)
        self.assertEqual([c['id'] for c in kept], ['late'])

    def test_old_recording_uploaded_today_remains_searchable_by_recording_date(self):
        db = FakeDevDb([_c('late', self.START, self.START + timedelta(days=8), source='audio_upload')])
        kept = get_conversations_in_range(db, 'dev', 'uid', start=self.START, end=self.END)
        self.assertEqual([c['id'] for c in kept], ['late'])

    def test_discarded_results_are_removed_before_result_limit(self):
        db = FakeDevDb([
            {**_c('discarded', self.START + timedelta(hours=2), self.START), 'discarded': True},
            _c('kept', self.START, self.START),
        ])
        kept = get_conversations_in_range(db, 'dev', 'uid', start=self.START, end=self.END, limit=1)
        self.assertEqual([c['id'] for c in kept], ['kept'])

    def test_conversation_outside_range_is_excluded(self):
        """created_at 在放宽后的粗筛窗口内,但 started_at 在区间外 → 必须排除。

        钉住「放宽只是为了多取,不是为了放行」——精筛丢了的话粗筛的 36h 会把邻近两天
        的对话一起塞进结果。
        """
        started = datetime(2026, 8, 5, 12, 0, tzinfo=timezone.utc)   # 区间外
        created = datetime(2026, 8, 6, 12, 0, tzinfo=timezone.utc)   # 粗筛窗口内
        db = FakeDevDb([_c('other-day', started, created)])
        kept = get_conversations_in_range(db, 'dev', 'uid', start=self.START, end=self.END)
        self.assertEqual(kept, [])

    def test_sorted_newest_first(self):
        base = datetime(2026, 8, 6, tzinfo=timezone.utc)
        db = FakeDevDb([
            _c('a', base + timedelta(hours=1), base + timedelta(hours=1)),
            _c('c', base + timedelta(hours=9), base + timedelta(hours=9)),
            _c('b', base + timedelta(hours=5), base + timedelta(hours=5)),
        ])
        kept = get_conversations_in_range(db, 'dev', 'uid', start=self.START, end=self.END)
        self.assertEqual([c['id'] for c in kept], ['c', 'b', 'a'])

    def test_limit_applied_after_sort(self):
        """截断必须发生在按时间排序之后,否则「最近 N 条」拿到的是任意 N 条。"""
        base = datetime(2026, 8, 6, tzinfo=timezone.utc)
        db = FakeDevDb([
            _c(f'c{i}', base + timedelta(hours=i), base + timedelta(hours=i)) for i in range(1, 6)
        ])
        kept = get_conversations_in_range(db, 'dev', 'uid', start=self.START, end=self.END, limit=2)
        self.assertEqual([c['id'] for c in kept], ['c5', 'c4'])

    def test_missing_started_at_is_skipped(self):
        """没有 started_at 就没有可信的事件时间 —— 跳过而不是回退到 created_at。"""
        db = FakeDevDb([_c('no-start', None, datetime(2026, 8, 6, 12, tzinfo=timezone.utc))])
        kept = get_conversations_in_range(db, 'dev', 'uid', start=self.START, end=self.END)
        self.assertEqual(kept, [])

    def test_no_bounds_returns_empty_without_querying(self):
        """两个边界都没有时不能退化成「拉取该用户全部历史」。"""
        db = FakeDevDb([_c('x', self.START, self.START)])
        self.assertEqual(get_conversations_in_range(db, 'dev', 'uid'), [])
        self.assertIsNone(db.last_query)

    def test_open_ended_range_is_allowed(self):
        """只给 start(或只给 end)是合法的:「从上周一以来」。"""
        started = datetime(2026, 8, 7, 10, tzinfo=timezone.utc)
        db = FakeDevDb([_c('after', started, started)])
        kept = get_conversations_in_range(db, 'dev', 'uid', start=self.START)
        self.assertEqual([c['id'] for c in kept], ['after'])
        self.assertIsNone(db.last_query['end_date'])

    def test_segments_are_not_fetched_by_default(self):
        """默认不取 segments:它们是 zlib 压缩的,长对话还在 transcript_chunks 子集合里
        ——每条一次额外查询,而这个窗口有 3 天多宽、上限 500 条。检索侧只在按说话人
        过滤时才需要。这正是 discover 那次 14.5s→0.6s 的同一个过度取数。"""
        db = FakeDevDb([])
        get_conversations_in_range(db, 'dev', 'uid', start=self.START, end=self.END)
        self.assertFalse(db.last_query['include_transcript_segments'])

    def test_segments_fetched_when_asked(self):
        db = FakeDevDb([])
        get_conversations_in_range(db, 'dev', 'uid', start=self.START, end=self.END,
                                   include_segments=True)
        self.assertTrue(db.last_query['include_transcript_segments'])

    def test_timeline_path_still_fetches_segments(self):
        """timeline 那条(chaptering)确实需要 segments,别被检索侧的默认值带走。"""
        db = FakeDevDb([])
        get_day_conversations(db, 'dev', 'uid', DAY, tz=timezone.utc)
        self.assertTrue(db.last_query['include_transcript_segments'])

    def test_naive_bounds_are_treated_as_utc(self):
        """调用方给 naive datetime 时不能抛 —— `_parse_iso` 解出的可能就是 naive。"""
        started = datetime(2026, 8, 6, 12, tzinfo=timezone.utc)
        db = FakeDevDb([_c('x', started, started)])
        kept = get_conversations_in_range(
            db, 'dev', 'uid',
            start=datetime(2026, 8, 6, 0, 0),
            end=datetime(2026, 8, 6, 23, 59),
        )
        self.assertEqual([c['id'] for c in kept], ['x'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
