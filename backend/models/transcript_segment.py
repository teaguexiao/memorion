from datetime import timedelta
from typing import Optional, List, Tuple
import uuid
import re
from pydantic import BaseModel, Field, field_validator

from models.other import Person


class Translation(BaseModel):
    lang: str
    text: str


def coerce_speaker_id(value, default=0):
    """Coerce a raw speaker identifier to an int.

    Accepts ints, numeric strings ("3"), and labeled strings
    ("SPEAKER_01", "speaker_1") — the numeric suffix is extracted.
    Falls back to ``default`` for anything unparsable (None, "garbage", ...).
    """
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        try:
            return int(value.split('_')[-1])
        except (ValueError, IndexError):
            return default
    return default


class TranscriptSegment(BaseModel):
    id: Optional[str] = None
    text: str
    speaker: Optional[str] = 'SPEAKER_00'
    speaker_id: Optional[int] = None
    is_user: bool
    person_id: Optional[str] = None
    speaker_status: Optional[str] = None
    speaker_assignment_source: Optional[str] = None
    start: float
    end: float
    original_start: Optional[float] = None
    original_end: Optional[float] = None
    timestamp_axis: Optional[str] = None
    translations: Optional[List[Translation]] = []
    speech_profile_processed: bool = False

    @field_validator('speaker_id', mode='before')
    @classmethod
    def parse_speaker_id(cls, v):
        # Coerce legacy string values ('SPEAKER_01', 'speaker_1', '3') to int.
        # Historical Firestore data stored speaker_id as a string; this keeps
        # API responses matching the documented integer type without a data
        # migration.
        if v is None:
            return v
        return coerce_speaker_id(v)

    def __init__(self, **data):
        has_explicit_speaker = 'speaker' in data and data['speaker'] is not None
        super().__init__(**data)
        if not self.id:
            self.id = str(uuid.uuid4())
        if has_explicit_speaker:
            try:
                self.speaker_id = int(self.speaker.split('_')[1]) if self.speaker and '_' in self.speaker else 0
            except (ValueError, IndexError):
                self.speaker_id = 0
        elif self.speaker_id is not None:
            self.speaker = f'SPEAKER_{str(self.speaker_id).zfill(2)}'
        else:
            self.speaker_id = 0

    def get_timestamp_string(self):
        start_duration = timedelta(seconds=int(self.start))
        end_duration = timedelta(seconds=int(self.end))
        return f'{str(start_duration).split(".")[0]} - {str(end_duration).split(".")[0]}'

    @staticmethod
    def segments_as_string(segments, include_timestamps=False, user_name: str = None, people: List[Person] = None):
        if not user_name:
            user_name = 'User'
        transcript = ''
        people_map = {person.id: person.name for person in people} if people else {}
        include_timestamps = include_timestamps and TranscriptSegment.can_display_seconds(segments)
        for segment in segments:
            segment_text = segment.text.strip()
            timestamp_str = f'[{segment.get_timestamp_string()}] ' if include_timestamps else ''
            speaker_name = user_name
            if not segment.is_user:
                if segment.person_id and segment.person_id in people_map:
                    speaker_name = people_map[segment.person_id]
                else:
                    speaker_name = f'Speaker {segment.speaker_id}'
            transcript += f'{timestamp_str}{speaker_name}: {segment_text}\n\n'

        return transcript.strip()

    @staticmethod
    def can_display_seconds(segments):
        for i in range(len(segments)):
            for j in range(i + 1, len(segments)):
                if segments[i].start > segments[j].end or segments[i].end > segments[j].start:
                    return False
        return True

    @staticmethod
    def combine_segments(segments: [], new_segments: List['TranscriptSegment'], delta_seconds: int = 0):
        if not new_segments or len(new_segments) == 0:
            return segments, (len(segments), len(segments))

        # By the first punctuation on text
        def _split(text: str) -> []:
            i = -1
            for m in ['.', '!', '?']:
                i = text.find(m)
                break
            if i == -1:
                return [text]

            parts = [text[: i + 1]]
            remaining = text[i + 1 :].strip()
            if remaining:
                parts.append(remaining)
            return parts

        # Refined new segments
        refined_segments = []
        for segment in new_segments:
            if segment.text and segment.text[0].islower() and re.search('[.?!]', segment.text):
                start = segment.start
                c_rate = (segment.end - segment.start) / len(segment.text)
                for text in _split(segment.text):
                    if not text:
                        continue
                    s = segment.copy(deep=True)
                    s.text = text

                    # Time alignment
                    s.start = start
                    s.end = start + c_rate * len(text)
                    if segment.original_start is not None and segment.original_end is not None:
                        if abs((segment.original_end - segment.original_start) - (segment.end - segment.start)) < 0.01:
                            s.original_start = segment.original_start + s.start - segment.start
                            s.original_end = segment.original_start + s.end - segment.start
                        else:
                            # A non-linear VAD map cannot be split by text length.
                            s.original_start = s.original_end = None
                    start = s.end
                    refined_segments.append(s)
            else:
                refined_segments.append(segment)

        new_segments = refined_segments

        # Combined
        def _merge(a, b: TranscriptSegment):
            if not a or not b:
                return a, b
            if a.timestamp_axis != b.timestamp_axis:
                return a, b
            a_original = a.original_start is not None and a.original_end is not None
            b_original = b.original_start is not None and b.original_end is not None
            if a_original != b_original:
                return a, b
            if a_original:
                offsets = (a.original_start - a.start, a.original_end - a.end,
                           b.original_start - b.start, b.original_end - b.end)
                if max(offsets) - min(offsets) >= 0.01:
                    return a, b
            if (
                (a.speaker == b.speaker or (a.is_user and b.is_user))
                and (b.start - a.end < 30)
                and a.speech_profile_processed == b.speech_profile_processed
            ):
                a.text += f' {b.text}'
                a.end = b.end
                a.original_end = b.original_end
                return a, None

            if (
                a.text
                and b.text
                and not a.text[-1] in [".", "?", "!"]
                and b.text[0].islower()
                and a.speech_profile_processed == b.speech_profile_processed
            ):
                a.text += f' {b.text}'
                a.end = b.end
                a.original_end = b.original_end
                return a, None

            return a, b

        # Updates range [starts, ends)
        starts = len(segments)
        ends = 0

        # Join
        joined_similar_segments = [segments[-1].copy(deep=True)] if segments else []
        for new_segment in new_segments:
            if delta_seconds > 0:
                if new_segment.timestamp_axis in ('audio', 'stream'):
                    if new_segment.timestamp_axis == 'stream' and (
                        new_segment.original_start is None or new_segment.original_end is None
                    ):
                        new_segment.original_start = new_segment.start
                        new_segment.original_end = new_segment.end
                    new_segment.timestamp_axis = 'display'
                new_segment.start += delta_seconds
                new_segment.end += delta_seconds

            a, b = _merge(joined_similar_segments[-1] if joined_similar_segments else None, new_segment)
            if a:
                joined_similar_segments[-1] = a
            if b:
                joined_similar_segments.append(b)

        if segments and segments[-1].id == joined_similar_segments[0].id:
            # having updates
            if segments[-1].text != joined_similar_segments[0].text:
                starts = len(segments) - 1
            segments.pop(-1)

        segments.extend(joined_similar_segments)
        ends = len(segments)

        # Speechmatics specific issue with punctuation
        for i, segment in enumerate(segments):
            segments[i].text = (
                segments[i].text.strip().replace('  ', ' ').replace(' ,', ',').replace(' .', '.').replace(' ?', '?')
            )

        return segments, (starts, ends)


class ImprovedTranscriptSegment(BaseModel):
    speaker_id: int = Field(..., description='The correctly assigned speaker id')
    text: str = Field(..., description='The corrected text of the segment')


class ImprovedTranscript(BaseModel):
    result: List[ImprovedTranscriptSegment]
