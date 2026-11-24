"""每日日志按用户本地日取对话 + 早上补写（catch_up）的不变式（2026-10-27）。

生产上的事故形态：日志把 cron 传来的本地日期当成 **UTC** 的 00:00–23:59、按 `created_at`
查对话，而 cron 在本地 22:00 就跑。UTC+8 的用户实际只覆盖本地 08:00–22:00：22:00 以后和凌晨
的对话落进一个「cron 已经跑过」的窗口，哪一篇也进不去。一个用户 122 条对话丢了 58 条，四天
明明录了音却拿到 404「没有对话」。

这里钉住的是接线，全部走真实的 `create_daily_summary` handler，只把 LLM / 图片 / 推送 /
Firestore 换成假的：

- 哪些对话属于某一天：`started_at` 的本地日期，和首页时间线同一个判据；
- 补写只在「缺了 / 漏了对话」时才写，从不推送，保留已有配图，更新原卡片而不是再加一张；
- 晚上那一轮照旧：已有就原样返回，首次生成才推送。

Run: cd backend && python3 tests/test_daily_summary_catch_up.py
"""

import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest import mock
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi import HTTPException  # noqa: E402

import database.developer_data as dev_db_module  # noqa: E402
import routers.developer_daily_summary as daily  # noqa: E402

DEV, UID, DAY = 'dev', 'user-1', '2026-10-25'
SHANGHAI = ZoneInfo('Asia/Shanghai')
WRITTEN_AT = datetime(2026, 10, 25, 14, 0, 30, tzinfo=timezone.utc)


def local(day, hour, minute=0):
    return datetime(2026, 10, day, hour, minute, tzinfo=SHANGHAI).astimezone(timezone.utc)


def convo(cid, started, status='completed', discarded=False):
    return {
        'id': cid, 'started_at': started, 'created_at': started + timedelta(minutes=20),
        'status': status, 'discarded': discarded, 'source': 'app', 'language': 'zh',
        'structured': {'title': cid, 'overview': cid}, 'transcript_segments': [],
    }


class FakeDevDb:
    """developer_data as the handler uses it; recording-time queries filter on started_at."""

    def __init__(self, convos, entries=None, tz_name='Asia/Shanghai'):
        self.convos, self.tz_name = list(convos), tz_name
        self.entries = dict(entries or {})
        self.writes = []

    def get_user_effective_timezone(self, developer_id, external_user_id):
        return self.tz_name

    def get_daily_summary(self, developer_id, external_user_id, date_str):
        entry = self.entries.get(date_str)
        return dict(entry) if entry else None

    def create_daily_summary(self, **kw):
        self.writes.append(kw)
        entry = {
            'id': f"summary_{kw['date_str']}", 'date': kw['date_str'], 'summary_text': kw['summary_text'],
            'emotion_title': kw.get('emotion_title'), 'image_url': kw.get('image_url'),
            'language': kw.get('language'), 'conversations_count': kw.get('conversations_count'),
            'conversation_ids': kw.get('conversation_ids'), 'moment_id': kw.get('moment_id'),
            'created_at': kw.get('created_at') or WRITTEN_AT,
        }
        self.entries[kw['date_str']] = entry
        return entry

    def get_conversations_by_recording_time(self, developer_id, external_user_id, start_date=None, end_date=None,
                                            limit=500, include_transcript_segments=True):
        return [dict(c) for c in self.convos
                if (start_date is None or c['started_at'] >= start_date)
                and (end_date is None or c['started_at'] <= end_date)]

    def get_conversations(self, developer_id, external_user_id, limit=100, offset=0, statuses=None,
                          start_date=None, end_date=None, **kwargs):
        # The created_at query the endpoint used to make; kept so a regression to it fails on
        # membership instead of on a missing method.
        return [dict(c) for c in self.convos
                if (not statuses or c['status'] in statuses) and not c['discarded']
                and (start_date is None or c['created_at'] >= start_date)
                and (end_date is None or c['created_at'] <= end_date)]

    def get_people_by_ids(self, *args, **kwargs):
        return []


class FakeMessageRef:
    def __init__(self, store, doc_id):
        self._store, self.id = store, doc_id

    def get(self):
        return SimpleNamespace(exists=self.id in self._store)

    def set(self, data):
        self._store[self.id] = dict(data)

    def update(self, data):
        self._store[self.id].update(data)


class FakeMessages:
    def __init__(self, store):
        self._store = store

    def document(self, doc_id):
        return FakeMessageRef(self._store, doc_id)

    def where(self, filter):
        hits = [SimpleNamespace(id=key, reference=FakeMessageRef(self._store, key), to_dict=lambda v=value: dict(v))
                for key, value in self._store.items() if value.get(filter.field_path) == filter.value]
        return SimpleNamespace(stream=lambda: iter(hits))


class FakeFirestore:
    """Only the path cards live on: developer_data/{dev}/users/{uid}/messages."""

    def __init__(self, messages=None):
        self.messages = dict(messages or {})

    def collection(self, name):
        return _FakePath(self)

    def document(self, name):
        return self


class _FakePath:
    def __init__(self, root):
        self._root = root

    def document(self, name):
        return self

    def collection(self, name):
        return FakeMessages(self._root.messages) if name == 'messages' else self


class Harness:
    def __init__(self, test, convos, entries=None, messages=None):
        self.dev_db = FakeDevDb(convos, entries)
        self.firestore = FakeFirestore(messages)
        self.generated = []   # sorted conversation ids handed to the writer, per generation
        self.pushes = []      # moment ids pushed
        self.images = []      # summaries an image was drawn for
        patches = [
            mock.patch.object(daily, 'dev_db', self.dev_db),
            mock.patch.object(daily, 'db', self.firestore),
            mock.patch.object(daily, '_generate_developer_summary', side_effect=self._write),
            mock.patch.object(daily, 'generate_emotion_title', return_value='一句标题'),
            mock.patch.object(daily, 'generate_daily_summary_image_with_retry', side_effect=self._draw),
            mock.patch.object(daily, 'get_daily_illustration_facts', return_value=[]),
            mock.patch.object(daily, 'upload_daily_summary_image', return_value='https://img/new.png'),
            mock.patch.object(daily, '_send_fcm_push', side_effect=lambda *a, **k: self.pushes.append(k.get('moment_id'))),
            mock.patch('utils.locales.get_user_effective_language', return_value=('zh', 'test')),
        ]
        for patch in patches:
            patch.start()
            test.addCleanup(patch.stop)

    def _write(self, developer_id, external_user_id, conversations, language_code):
        ids = sorted(c.id for c in conversations)
        self.generated.append(ids)
        return 'journal of ' + ','.join(ids)

    def _draw(self, **kwargs):
        self.images.append(kwargs['summary_text'])
        return b'png'

    def call(self, catch_up=False, force=False):
        request = daily.DailySummaryRequest(date=DAY, catch_up=catch_up, force_regenerate=force)
        return daily.create_daily_summary(request, external_user_id=UID, developer_id=DEV)


class LocalDayMembershipTests(unittest.TestCase):
    def test_entry_covers_the_local_day_by_recording_time(self):
        h = Harness(self, [
            convo('morning', local(25, 9)),
            # 07:00 local = 23:00Z on the 24th: the old UTC window filed it under the 24th.
            convo('early-morning', local(25, 7)),
            # 23:30 local = 15:30Z: inside the old UTC window, but created after its cron had run.
            convo('late-evening', local(25, 23, 30)),
            # 00:30 on the 26th = 16:30Z on the 25th: in the old "2026-10-25" window, yet another day.
            convo('after-midnight', local(26, 0, 30)),
            convo('discarded', local(25, 12), discarded=True),
            convo('unfinished', local(25, 13), status='in_progress'),
        ])
        entry = h.call()
        self.assertEqual([['early-morning', 'late-evening', 'morning']], h.generated)
        self.assertEqual(['early-morning', 'late-evening', 'morning'], sorted(entry['conversation_ids']))
        self.assertEqual(3, entry['conversations_count'])

    def test_evening_card_is_dated_22_local_and_pushed_once(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        h.call()
        card = h.firestore.messages['day_summary_2026-10-25']
        self.assertEqual(local(25, 22), card['created_at'])
        self.assertEqual('day_summary', card['type'])
        self.assertEqual(['day_summary_2026-10-25'], h.pushes)
        self.assertEqual('day_summary_2026-10-25', h.dev_db.entries[DAY]['moment_id'])

    def test_evening_run_never_rewrites_an_existing_entry(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        h.call()
        h.dev_db.convos.append(convo('late-evening', local(25, 23, 30)))
        h.call()
        self.assertEqual(1, len(h.generated))
        self.assertEqual(1, len(h.pushes))


class CatchUpTests(unittest.TestCase):
    def test_rest_of_the_evening_rewrites_the_same_card_silently_keeping_its_picture(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        h.call()  # 22:00: only the morning exists yet
        evening_card = dict(h.firestore.messages['day_summary_2026-10-25'])
        h.dev_db.convos.append(convo('late-evening', local(25, 23, 30)))

        entry = h.call(catch_up=True)

        self.assertEqual(['late-evening', 'morning'], h.generated[-1])
        self.assertEqual(['day_summary_2026-10-25'], h.pushes, 'the catch-up must not push')
        self.assertEqual(['day_summary_2026-10-25'], list(h.firestore.messages), 'no second card')
        card = h.firestore.messages['day_summary_2026-10-25']
        self.assertEqual('journal of late-evening,morning', card['text'])
        self.assertEqual(evening_card['created_at'], card['created_at'])
        self.assertEqual(1, len(h.images), 'the picture drawn at 22:00 is kept')
        self.assertEqual('https://img/new.png', card['summary_image_url'])
        self.assertEqual(WRITTEN_AT, entry['created_at'])

    def test_complete_entry_is_left_alone(self):
        h = Harness(self, [convo('morning', local(25, 9))])
        h.call()
        writes = len(h.dev_db.writes)
        h.call(catch_up=True)
        self.assertEqual(1, len(h.generated))
        self.assertEqual(writes, len(h.dev_db.writes))
        self.assertEqual(1, len(h.pushes))

    def test_day_the_evening_lost_is_written_without_push(self):
        # The 22:00 run failed or found nothing yet; the morning writes the day, picture included.
        h = Harness(self, [convo('late-evening', local(25, 23, 30))])
        entry = h.call(catch_up=True)
        self.assertEqual([['late-evening']], h.generated)
        self.assertEqual([], h.pushes)
        self.assertEqual(['day_summary_2026-10-25'], list(h.firestore.messages))
        self.assertEqual(local(25, 22), h.firestore.messages['day_summary_2026-10-25']['created_at'])
        self.assertEqual('https://img/new.png', entry['image_url'])

    def test_empty_day_is_still_404(self):
        h = Harness(self, [convo('discarded', local(25, 12), discarded=True)])
        with self.assertRaises(HTTPException) as ctx:
            h.call(catch_up=True)
        self.assertEqual(404, ctx.exception.status_code)

    def test_entry_is_never_replaced_with_nothing(self):
        entry = {'id': 'summary_2026-10-25', 'date': DAY, 'summary_text': 'kept', 'conversation_ids': ['gone'],
                 'conversations_count': 1, 'created_at': WRITTEN_AT}
        h = Harness(self, [], entries={DAY: entry})
        self.assertEqual('kept', h.call(catch_up=True)['summary_text'])
        self.assertEqual([], h.generated)

    def test_legacy_entry_is_matched_to_its_card_by_text(self):
        # Before this change an entry kept a count instead of ids, and its card had a random id.
        legacy = {'id': 'summary_2026-10-25', 'date': DAY, 'summary_text': 'old journal', 'image_url': 'https://img/old.png',
                  'conversations_count': 1, 'created_at': WRITTEN_AT, 'language': 'zh'}
        cards = {
            '6b5c9511': {'id': '6b5c9511', 'type': 'day_summary', 'text': 'old journal', 'created_at': local(25, 22)},
            'c10583e3': {'id': 'c10583e3', 'type': 'day_summary', 'text': 'another day', 'created_at': local(24, 22)},
        }
        h = Harness(self, [convo('morning', local(25, 9)), convo('late-evening', local(25, 23, 30))],
                    entries={DAY: legacy}, messages=cards)
        h.call(catch_up=True)
        self.assertEqual({'6b5c9511', 'c10583e3'}, set(h.firestore.messages))
        self.assertEqual('journal of late-evening,morning', h.firestore.messages['6b5c9511']['text'])
        self.assertEqual('https://img/old.png', h.firestore.messages['6b5c9511']['summary_image_url'])
        self.assertEqual('another day', h.firestore.messages['c10583e3']['text'])
        self.assertEqual('6b5c9511', h.dev_db.entries[DAY]['moment_id'])
        self.assertEqual([], h.pushes)

    def test_legacy_entry_whose_count_still_matches_is_left_alone(self):
        legacy = {'id': 'summary_2026-10-25', 'date': DAY, 'summary_text': 'old journal',
                  'conversations_count': 2, 'created_at': WRITTEN_AT}
        h = Harness(self, [convo('morning', local(25, 9)), convo('noon', local(25, 12))], entries={DAY: legacy})
        h.call(catch_up=True)
        self.assertEqual([], h.generated)


class EffectiveTimezoneTests(unittest.TestCase):
    CASES = [
        ({'timezone': 'Asia/Shanghai'}, 'Asia/Shanghai'),
        ({'time_zone': 'Asia/Tokyo'}, 'Asia/Tokyo'),
        ({'timezone': 'America/Denver', 'time_zone': 'Asia/Shanghai'}, 'America/Denver'),
        ({'timezone': '', 'time_zone': 'Asia/Shanghai'}, 'Asia/Shanghai'),
        ({}, None),
    ]

    def test_preference_first_then_the_device_report(self):
        for data, expected in self.CASES:
            doc = SimpleNamespace(exists=True, to_dict=lambda data=data: dict(data))
            with self.subTest(data=data), mock.patch.object(
                    dev_db_module, '_get_user_ref', return_value=SimpleNamespace(get=lambda doc=doc: doc)):
                self.assertEqual(expected, dev_db_module.get_user_effective_timezone(DEV, UID))

    def test_device_only_user_gets_a_local_day_not_utc(self):
        # 30 users had only `time_zone`: `get_user_timezone` (the `timezone` field) is None for
        # them, and reading it alone put their day on UTC — where 07:00 local is the 24th.
        h = Harness(self, [convo('early-morning', local(25, 7))])
        h.dev_db.get_user_timezone = lambda *args: None
        h.call()
        self.assertEqual([['early-morning']], h.generated)


if __name__ == '__main__':
    unittest.main(verbosity=2)
