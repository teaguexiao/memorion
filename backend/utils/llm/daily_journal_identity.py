"""Who people are in the user's life, from facts the user confirmed. Diary text and picture share it.

Neither may guess identity, and the notes can't supply it:

- **Gender.** In Chinese speech 他 and 她 are both "tā", so the transcript's choice is the speech
  recognizer's guess, not information. Writing pronouns from it made one user's only son 她 on most
  days, and the picture, with no fact saying the user is a father, drew the user as a woman
  (2026-10-25, 10-27).
- **Relationships and names.** "小草 is my son", "小名是小宝": a child saying 爸爸 may be talking to
  anyone in the room, but the user has said so themselves.

Only confirmed facts count (written by the user, or extracted and marked correct). An extracted fact
is a guess too, and the rejected ones are often exactly the wrong identity (「你有一个丈夫」 was rejected
by a father). Facts the user wrote come first, so when two disagree, the one they typed wins.
"""

import logging
import re
from typing import Iterable, List

logger = logging.getLogger(__name__)

# How many confirmed facts to read. The newest 100 used to be all the picture saw, and identity facts
# are often old: one user's 「你的妻子是……」 was nine months older than the 100th newest fact.
CONFIRMED_FACTS_LIMIT = 1000
MAX_IDENTITY_FACTS = 30
MAX_IDENTITY_CHARS = 3000

# A fact about who someone is names a relationship, a name, or a gender. Chinese and English only:
# other languages keep the facts the picture already received and the pronouns of their notes, which
# are not homophones there.
_IDENTITY_WORDS = re.compile(
    r'儿子|女儿|妻子|老婆|太太|丈夫|老公|伴侣|爱人|爸爸|父亲|妈妈|母亲|爷爷|奶奶|外公|外婆|姥姥|姥爷|'
    r'岳父|岳母|丈母娘|公公|婆婆|哥哥|弟弟|姐姐|妹妹|叔叔|阿姨|舅舅|姑姑|侄子|侄女|外甥|孙子|孙女|'
    r'男朋友|女朋友|未婚夫|未婚妻|男孩|女孩|名叫|小名|全名|英文名|昵称|'
    r'\b(?:son|daughter|wife|husband|partner|spouse|father|mother|dad|mom|mum|brother|sister|'
    r'grandson|granddaughter|grandfather|grandmother|grandpa|grandma|uncle|aunt|nephew|niece|'
    r'boyfriend|girlfriend|fianc[ée]e?|nickname|named)\b',
    re.IGNORECASE,
)
# The product is an "AI 伴侣" app; facts about building it are not about a partner.
_NOT_A_PERSON = re.compile(r'AI\s*伴侣', re.IGNORECASE)


def _is_confirmed(record: dict) -> bool:
    return (bool(record.get('manually_added')) or record.get('user_review') is True) \
        and record.get('user_review') is not False and not record.get('deleted')


def select_identity_facts(records: Iterable[dict]) -> List[str]:
    """Confirmed facts that say who someone is, user-written first, then newest first."""
    written, reviewed, seen = [], [], set()
    for position, record in enumerate(records):
        content = record.get('content')
        if not isinstance(content, str) or not _is_confirmed(record):
            continue
        text = ' '.join(content.split())
        if not text or text in seen or not _IDENTITY_WORDS.search(_NOT_A_PERSON.sub('', text)):
            continue
        seen.add(text)
        (written if record.get('manually_added') else reviewed).append((str(record.get('created_at') or ''), -position, text))
    facts, size = [], 0
    for group in (written, reviewed):
        for _, _, text in sorted(group, reverse=True):
            if len(facts) >= MAX_IDENTITY_FACTS or size + len(text) > MAX_IDENTITY_CHARS:
                return facts
            facts.append(text)
            size += len(text)
    return facts


def get_confirmed_facts(developer_id: str, external_user_id: str) -> List[dict]:
    """All confirmed facts, newest first. Raises when they can't be read; callers decide."""
    from database import developer_data

    return developer_data.get_memories(developer_id=developer_id, external_user_id=external_user_id,
                                       limit=CONFIRMED_FACTS_LIMIT, status='confirmed')


def get_confirmed_identity_facts(developer_id: str, external_user_id: str) -> List[str]:
    """Identity facts for the diary. Unreadable facts write the entry without them, as before."""
    try:
        return select_identity_facts(get_confirmed_facts(developer_id, external_user_id))
    except Exception:
        logger.warning('Daily journal identity facts unavailable; writing without them')
        return []


# Background for the diary: every confirmed fact, newest first, within a budget. One user's 139 facts
# came to 4,326 characters, so for now this is "all of them"; the budget keeps a long history from
# crowding the day's own notes.
MAX_BACKGROUND_CHARS = 6000


def select_background_facts(records: Iterable[dict]) -> List[str]:
    """Confirmed facts about the user's life (work, family, projects, worries), newest first.

    The diary uses them to say why a moment of the day matters to the writer, never as events of
    the day (`utils/llm/daily_summary.py`, "Background"). Writing only the moments, without knowing
    what they belong to, was half of why entries read as transcripts.
    """
    facts, seen, size = [], set(), 0
    ordered = sorted(enumerate(records), key=lambda item: (str(item[1].get('created_at') or ''), -item[0]),
                     reverse=True)
    for _, record in ordered:
        content = record.get('content')
        if not isinstance(content, str) or not _is_confirmed(record):
            continue
        text = ' '.join(content.split())
        if not text or text in seen:
            continue
        if size + len(text) > MAX_BACKGROUND_CHARS:
            break
        seen.add(text)
        facts.append(text)
        size += len(text)
    return facts


def get_confirmed_background_facts(developer_id: str, external_user_id: str) -> List[str]:
    """Background facts for the diary. Unreadable facts write the entry without them, as before."""
    try:
        return select_background_facts(get_confirmed_facts(developer_id, external_user_id))
    except Exception:
        logger.warning('Daily journal background facts unavailable; writing without them')
        return []
