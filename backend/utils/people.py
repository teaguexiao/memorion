"""
People helper module — all people lookups go through the Developer API data path.

The platform API key (MEMORION_API_KEY env var) is used to resolve the
developer_id so that internal utilities (chat, memories, trends, RAG, etc.)
can call dev_db.get_people_by_ids(developer_id, external_user_id, ...) without
every caller needing to thread developer_id through manually.
"""
import os
from typing import List, Dict, Any, Optional

import database.developer_data as dev_db
from database.developers import get_developer_id_by_api_key

_cached_developer_id: Optional[str] = None


def get_platform_developer_id() -> Optional[str]:
    """Resolve the developer_id from the platform MEMORION_API_KEY."""
    global _cached_developer_id
    if _cached_developer_id:
        return _cached_developer_id

    api_key = os.getenv("MEMORION_API_KEY")
    if not api_key:
        return None

    developer_id = get_developer_id_by_api_key(api_key)
    if developer_id:
        _cached_developer_id = developer_id
    return developer_id


def get_people_by_ids(
    uid: str,
    person_ids: List[str],
    developer_id: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Fetch people from the developer data path.

    Args:
        uid: Used as external_user_id in the developer path.
        person_ids: List of person document IDs.
        developer_id: If provided, used directly. Otherwise resolved from
                      the platform API key.
    """
    if not person_ids:
        return []

    if not developer_id:
        developer_id = get_platform_developer_id()

    if not developer_id:
        return []

    return dev_db.get_people_by_ids(developer_id, uid, person_ids)


def get_people(
    uid: str,
    developer_id: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Fetch all people from the developer data path.

    Args:
        uid: Used as external_user_id in the developer path.
        developer_id: If provided, used directly. Otherwise resolved from
                      the platform API key.
    """
    if not developer_id:
        developer_id = get_platform_developer_id()

    if not developer_id:
        return []

    return dev_db.get_people(developer_id, uid, limit=1000)


def create_person(
    uid: str,
    name: str,
    developer_id: Optional[str] = None,
    source: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    """Create a person in the developer data path.

    Args:
        uid: Used as external_user_id in the developer path.
        name: Person's name.
        developer_id: If provided, used directly. Otherwise resolved from
                      the platform API key.
        source: Provenance — dev_db.PERSON_SOURCE_*。别省，缺了就永远分不清这个人是
                真说话人还是只被提到过（见 dev_db.PERSON_SOURCE_MENTION 的注释）。
    """
    if not developer_id:
        developer_id = get_platform_developer_id()

    if not developer_id:
        return None

    return dev_db.create_person(developer_id, uid, name, source=source)
