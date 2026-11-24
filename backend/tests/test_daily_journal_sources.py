"""Source retention and precedence, including facts omitted by old summaries."""

from datetime import datetime, timezone
from types import SimpleNamespace
import unittest

from utils.llm.daily_journal_sources import build_daily_journal_history, parse_daily_journal_people


def conversation(hour, transcript, overview='我们聊了很多，最后很开心。'):
    return SimpleNamespace(
        started_at=datetime(2026, 10, 23, hour, tzinfo=timezone.utc),
        created_at=datetime(2026, 10, 24, hour, tzinfo=timezone.utc),
        structured=SimpleNamespace(title='讨论', overview=overview, action_items=[], events=[]),
        get_transcript=lambda **kwargs: transcript,
    )


class JournalSourcesTests(unittest.TestCase):
    def test_invalid_historical_people_do_not_block_valid_names_or_transcripts(self):
        records = [
            {'id': 'old', 'name': '历史资料'},
            {'id': 'valid', 'name': '老师', 'created_at': datetime.now(timezone.utc), 'updated_at': datetime.now(timezone.utc)},
        ]
        people = parse_daily_journal_people(records)
        self.assertEqual(['valid'], [person.id for person in people])
        c = conversation(8, 'Speaker 1: 历史人物的原话。\n\nUser: 不能丢失。')
        self.assertIn('Speaker 1: 历史人物的原话。', build_daily_journal_history([c], people))

    def test_full_transcript_keeps_tail_and_quantities_not_derived_emotions(self):
        raw = 'User: 不要每月 600，只要一次 80。\n' + 'Speaker 1: 重复。\n' * 3000 + 'User: 最后还提了授权没批准。'
        result = build_daily_journal_history([conversation(12, raw)])
        self.assertIn(raw, result)
        self.assertNotIn('最后很开心', result)
        self.assertIn('User: 最后还提了授权没批准。', result)

    def test_chronological_order_uses_recording_time_not_upload_order(self):
        result = build_daily_journal_history([conversation(13, 'Speaker 2: 后段'), conversation(8, 'User: 前段')])
        self.assertLess(result.index('User: 前段'), result.index('Speaker 2: 后段'))
        self.assertIn('2026-10-23T08:00:00+00:00 UTC', result)
        self.assertNotIn('2026-10-24', result)

    def test_missing_transcript_keeps_fallback_and_explicitly_labels_it(self):
        c = conversation(8, '')
        c.structured.action_items = [SimpleNamespace(description='我答应明天确认 3 个报价')]
        c.structured.events = [SimpleNamespace(title='周五预约')]
        result = build_daily_journal_history([c])
        self.assertIn('no verbatim transcript available', result)
        self.assertIn('我答应明天确认 3 个报价', result)
        self.assertIn('周五预约', result)

    def test_distinct_speaker_labels_and_known_people_are_preserved(self):
        received = []
        c = conversation(8, '')
        c.get_transcript = lambda **kwargs: received.append(kwargs) or 'User: 我只提议。\n老师: 我决定改到周五。'
        people = [SimpleNamespace(id='person', name='老师')]
        result = build_daily_journal_history([c], people=people)
        self.assertEqual(people, received[0]['people'])
        self.assertIn('老师: 我决定改到周五。', result)

    def test_unknown_user_and_missing_metadata_are_explicit(self):
        c = conversation(8, 'Speaker 1: 我答应了。')
        c.started_at = c.created_at = None
        result = build_daily_journal_history([c])
        self.assertIn('No turn is identified as User', result)
        self.assertIn('Recording time unknown', result)
        c.get_transcript = lambda **_: ''
        c.structured = None
        self.assertIn('no verbatim transcript available', build_daily_journal_history([c]))

    def test_discarded_recording_is_not_evidence(self):
        c = conversation(8, 'User: 忽略这段。')
        c.discarded = True
        self.assertEqual('', build_daily_journal_history([c]))

    def test_empty_day_is_empty_not_placeholder_evidence(self):
        self.assertEqual('', build_daily_journal_history([]))


class ScheduledJournalDocumentTests(unittest.TestCase):
    def test_chunked_transcript_is_read_in_index_order_without_losing_tail(self):
        import json
        import zlib
        from types import SimpleNamespace
        from utils.llm.daily_journal_sources import read_daily_journal_document
        packed = zlib.compress(json.dumps([{'text': '开头'}, {'text': '末尾，只有一个孩子'}]).encode())
        chunks = [SimpleNamespace(to_dict=lambda: {'index': 1, 'data': packed[10:]}),
                  SimpleNamespace(to_dict=lambda: {'index': 0, 'data': packed[:10]})]
        ref = SimpleNamespace(collection=lambda name: SimpleNamespace(stream=lambda: chunks))
        doc = SimpleNamespace(id='long-recording', reference=ref,
                              to_dict=lambda: {'transcript_segments_chunked': True})
        result = read_daily_journal_document(doc)
        self.assertEqual('末尾，只有一个孩子', result['transcript_segments'][-1]['text'])
        self.assertEqual('long-recording', result['id'])

    def test_missing_chunk_fails_instead_of_substituting_summary(self):
        from types import SimpleNamespace
        from utils.llm.daily_journal_sources import read_daily_journal_document
        chunk = SimpleNamespace(to_dict=lambda: {'index': 1, 'data': b'partial'})
        ref = SimpleNamespace(collection=lambda name: SimpleNamespace(stream=lambda: [chunk]))
        doc = SimpleNamespace(id='broken', reference=ref, to_dict=lambda: {'transcript_segments_chunked': True})
        with self.assertRaises(ValueError):
            read_daily_journal_document(doc)

    def test_inline_compressed_transcript_and_plain_records(self):
        import json
        import zlib
        from types import SimpleNamespace
        from utils.llm.daily_journal_sources import read_daily_journal_document
        segments = [{'text': '完整原话'}]
        doc = SimpleNamespace(id='inline', to_dict=lambda: {'transcript_segments': zlib.compress(json.dumps(segments).encode())})
        self.assertEqual(segments, read_daily_journal_document(doc)['transcript_segments'])
        plain = SimpleNamespace(id='plain', to_dict=lambda: {'transcript_segments': segments})
        self.assertEqual(segments, read_daily_journal_document(plain)['transcript_segments'])

    def test_scheduled_query_hydrates_each_document(self):
        from pathlib import Path
        source = (Path(__file__).resolve().parents[1] / 'modal/job_modal_standalone.py').read_text()
        self.assertIn('conversations = [read_daily_journal_document(doc) for doc in query.stream()]', source)


if __name__ == '__main__':
    unittest.main()
