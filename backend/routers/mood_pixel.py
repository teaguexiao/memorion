import copy
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException

import database.developer_data as dev_db
from database.redis_db import get_generic_cache, set_generic_cache
from models.mood_pixel import MOOD_PIXEL_KEYS, MoodPixelState, UpdateMoodPixelStateRequest
from utils.other import endpoints as auth

router = APIRouter()

_CACHE_TTL = 86400
_GRID_SIZE = 15
_LEGACY_BOARD_ID = 'weekly_v1'
_BOARD_DEFS = [
    {
        'id': 'weekly_v2_heart',
        'pattern': [
            '...............',
            '...###...###...',
            '..#####.#####..',
            '.#############.',
            '###############',
            '###############',
            '###############',
            '.#############.',
            '..###########..',
            '...#########...',
            '....#######....',
            '.....#####.....',
            '......###......',
            '.......#.......',
            '...............',
        ],
    },
    {
        'id': 'weekly_v2_butterfly',
        'pattern': [
            '.......#.......',
            '..###.###.###..',
            '.#####.#.#####.',
            '###############',
            '.#############.',
            '..###########..',
            '....#######....',
            '.....#####.....',
            '....#######....',
            '..###########..',
            '.#############.',
            '###############',
            '.#####.#.#####.',
            '..###.###.###..',
            '.......#.......',
        ],
    },
    {
        'id': 'weekly_v2_tree',
        'pattern': [
            '.......#.......',
            '......###......',
            '.....#####.....',
            '....#######....',
            '...#########...',
            '..###########..',
            '.....#####.....',
            '....#######....',
            '...#########...',
            '..###########..',
            '.#############.',
            '......###......',
            '......###......',
            '......###......',
            '......###......',
        ],
    },
    {
        'id': 'weekly_v2_umbrella',
        'pattern': [
            '.......#.......',
            '.....#####.....',
            '....#######....',
            '...#########...',
            '..###########..',
            '.#############.',
            '###############',
            '......###......',
            '......###......',
            '......###......',
            '......###......',
            '....#######....',
            '...............',
            '...............',
            '...............',
        ],
    },
    {
        'id': 'weekly_v2_rocket',
        'pattern': [
            '.......#.......',
            '......###......',
            '.....#####.....',
            '....#######....',
            '......###......',
            '......###......',
            '......###......',
            '.....#####.....',
            '....#######....',
            '....#######....',
            '....#######....',
            '....###.###....',
            '...###...###...',
            '..##.......##..',
            '...............',
        ],
    },
    {
        'id': 'weekly_v2_star',
        'pattern': [
            '.......#.......',
            '......###......',
            '..##.#####.##..',
            '...#########...',
            '.#############.',
            '..###########..',
            '....#######....',
            '###############',
            '....#######....',
            '..###########..',
            '.#############.',
            '...#########...',
            '..##.#####.##..',
            '......###......',
            '.......#.......',
        ],
    },
    {
        'id': 'weekly_v2_gift',
        'pattern': [
            '...............',
            '......###......',
            '.....#####.....',
            '....#######....',
            '###############',
            '###############',
            '..###########..',
            '..###########..',
            '..###########..',
            '..###########..',
            '..###########..',
            '..###########..',
            '..###########..',
            '...............',
            '...............',
        ],
    },
    {
        'id': 'weekly_v2_sun_rays',
        'pattern': [
            '.......#.......',
            '..#....#....#..',
            '...#...#...#...',
            '....#######....',
            '#..#########..#',
            '...###########.',
            '.#############.',
            '###############',
            '.#############.',
            '...###########.',
            '#..#########..#',
            '....#######....',
            '...#...#...#...',
            '..#....#....#..',
            '.......#.......',
        ],
    },
    {
        'id': 'weekly_v2_diamond',
        'pattern': [
            '.......#.......',
            '......###......',
            '.....#####.....',
            '....#######....',
            '...#########...',
            '..###########..',
            '.#############.',
            '###############',
            '.#############.',
            '..###########..',
            '...#########...',
            '....#######....',
            '.....#####.....',
            '......###......',
            '.......#.......',
        ],
    },
    {
        'id': 'weekly_v2_smile',
        'pattern': [
            '...............',
            '....#######....',
            '..###########..',
            '.#############.',
            '###.###.###.###',
            '###.###.###.###',
            '###############',
            '###############',
            '###.#######.###',
            '.###.#####.###.',
            '..###########..',
            '...#########...',
            '....#######....',
            '.....#####.....',
            '...............',
        ],
    },
]
_BOARD_INDEX = {board['id']: index for index, board in enumerate(_BOARD_DEFS)}
_BOARD_BY_ID = {board['id']: board for board in _BOARD_DEFS}


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)



def _cache_key(uid: str, board_id: str) -> str:
    return f'mood_pixel:{uid}:{board_id}'



def _parse_datetime(value) -> Optional[datetime]:
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if isinstance(value, str) and value:
        try:
            parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        except Exception:
            return None
    return None



def _neighbors(row: int, col: int):
    if row > 0:
        yield row - 1, col
    if row < _GRID_SIZE - 1:
        yield row + 1, col
    if col > 0:
        yield row, col - 1
    if col < _GRID_SIZE - 1:
        yield row, col + 1



def _build_cell_types(pattern: List[str]) -> List[str]:
    occupied = [False] * (_GRID_SIZE * _GRID_SIZE)
    for row, line in enumerate(pattern):
        for col, char in enumerate(line):
            occupied[row * _GRID_SIZE + col] = char == '#'

    cell_types = ['outside'] * (_GRID_SIZE * _GRID_SIZE)
    for row in range(_GRID_SIZE):
        for col in range(_GRID_SIZE):
            index = row * _GRID_SIZE + col
            if not occupied[index]:
                continue
            is_edge = any(not occupied[n_row * _GRID_SIZE + n_col] for n_row, n_col in _neighbors(row, col))
            cell_types[index] = 'edge' if is_edge else 'fillable'
    return cell_types


_CELL_TYPES = {board['id']: _build_cell_types(board['pattern']) for board in _BOARD_DEFS}



def _inventory_from_conversations(developer_id: str, uid: str, days: int = 7) -> Dict[str, int]:
    """Calculate mood inventory based on actual EIR-detected emotions from conversations.

    This keeps the Mood Pixel game in sync with the Mood Trends chart — both now
    pull from the same data source (eir_emotion field on conversations).

    Results are cached in Redis for 5 minutes to avoid repeated queries within a single session.

    Args:
        developer_id: Developer ID
        uid: User ID
        days: Number of days to look back (default 7 for weekly boards)

    Returns:
        Dict mapping each mood key to the count of conversations with that emotion.
    """
    # Check cache first to avoid duplicate queries
    cache_key = f'mood_pixel_inventory:{uid}:{days}d'
    cached = get_generic_cache(cache_key)
    if cached and isinstance(cached, dict):
        return cached

    from models.conversation import Conversation

    # Import aggregate_day_emotions from discover to share the same logic
    # This ensures Mood Pixel and Mood Trends always stay in lockstep
    from routers.discover import VALID_EMOTIONS

    start_date = datetime.now(timezone.utc) - timedelta(days=days)

    # Use start_date parameter for server-side filtering to avoid missing
    # recent conversations when the user has >500 total conversations
    raw = dev_db.get_conversations(
        developer_id=developer_id,
        external_user_id=uid,
        limit=1000,  # Increased limit; server already filters by date
        offset=0,
        include_discarded=False,
        statuses=['completed'],
        start_date=start_date,
    )

    counts = defaultdict(int)
    for c in raw:
        try:
            convo = Conversation(**c) if isinstance(c, dict) else c
            emotion = (convo.eir_emotion or '').lower()
            if emotion in VALID_EMOTIONS:
                counts[emotion] += 1
        except (TypeError, AttributeError) as e:
            # Skip conversations with invalid eir_emotion
            import logging
            logging.getLogger(__name__).debug(f"Skipping conversation in inventory: {e}")
            continue

    # Ensure all mood keys are present (even with 0 count)
    result = {key: counts.get(key, 0) for key in MOOD_PIXEL_KEYS}

    # If no conversations found, provide minimal fallback (1 of each) so the game is playable
    if sum(result.values()) == 0:
        result = {key: 1 for key in MOOD_PIXEL_KEYS}

    # Cache for 5 minutes to avoid repeated queries
    set_generic_cache(cache_key, result, ttl=300)

    return result


def _inventory_fallback(board_id: str) -> Dict[str, int]:
    """Fallback inventory for when we can't fetch conversation data.

    This maintains the old behavior of evenly distributing fillable cells.
    """
    total = _CELL_TYPES[board_id].count('fillable')
    counts = {key: total // len(MOOD_PIXEL_KEYS) for key in MOOD_PIXEL_KEYS}
    for offset in range(total % len(MOOD_PIXEL_KEYS)):
        counts[MOOD_PIXEL_KEYS[offset]] += 1
    return counts


_DEFAULT_INVENTORY = {board['id']: _inventory_fallback(board['id']) for board in _BOARD_DEFS}

# Migration mapping from old keys to new keys
_LEGACY_KEY_MIGRATION = {
    'joy': 'happy',
    'spark': 'surprised',
    'focus': 'sad',
    # 'calm' stays the same
    # 'angry' is new (didn't exist before)
}



def _next_available_mood(remaining: Dict[str, int]) -> Optional[str]:
    for key in MOOD_PIXEL_KEYS:
        if remaining.get(key, 0) > 0:
            return key
    return None



def _blank_state(
    board_id: str,
    created_at: Optional[datetime] = None,
    inventory: Optional[Dict[str, int]] = None,
) -> MoodPixelState:
    """Create a blank mood pixel state with empty fills.

    Args:
        board_id: Board identifier
        created_at: Creation timestamp (defaults to now)
        inventory: Optional mood inventory. If None, uses fallback inventory.

    Returns:
        A new blank MoodPixelState
    """
    board = _BOARD_BY_ID[board_id]
    remaining = copy.deepcopy(inventory or _DEFAULT_INVENTORY[board_id])
    now = _now_utc()
    return MoodPixelState(
        board_id=board_id,
        sample_index=_BOARD_INDEX[board_id],
        total_samples=len(_BOARD_DEFS),
        pattern=copy.deepcopy(board['pattern']),
        fills=[None] * (_GRID_SIZE * _GRID_SIZE),
        remaining=remaining,
        selected_mood=_next_available_mood(remaining),
        is_complete=False,
        created_at=created_at or now,
        updated_at=now,
    )



def _rebuild_state(
    board_id: str,
    fills: List[Optional[str]],
    selected_mood: Optional[str],
    *,
    created_at: Optional[datetime] = None,
    updated_at: Optional[datetime] = None,
    inventory: Optional[Dict[str, int]] = None,
) -> MoodPixelState:
    """Rebuild mood pixel state from fills array and selected mood.

    Args:
        board_id: Board identifier
        fills: Array of 225 mood keys (or None for empty cells)
        selected_mood: Currently selected mood key
        created_at: Creation timestamp
        updated_at: Last update timestamp
        inventory: Optional mood inventory override. If None, uses fallback inventory.

    Returns:
        Normalized MoodPixelState with recalculated remaining counts.
    """
    board = _BOARD_BY_ID[board_id]
    cell_types = _CELL_TYPES[board_id]
    inventory = inventory or _DEFAULT_INVENTORY[board_id]

    normalized_fills: List[Optional[str]] = []
    counts_used = {key: 0 for key in MOOD_PIXEL_KEYS}
    for index, raw_value in enumerate(fills):
        cell_type = cell_types[index]
        if cell_type != 'fillable' or raw_value is None:
            normalized_fills.append(None)
            continue

        mood_key = str(raw_value).lower()
        if mood_key not in MOOD_PIXEL_KEYS:
            normalized_fills.append(None)
            continue

        normalized_fills.append(mood_key)
        counts_used[mood_key] += 1

    remaining = {key: max(inventory[key] - counts_used[key], 0) for key in MOOD_PIXEL_KEYS}
    normalized_selected = selected_mood.lower() if selected_mood else None
    if normalized_selected not in MOOD_PIXEL_KEYS or remaining.get(normalized_selected, 0) <= 0:
        normalized_selected = _next_available_mood(remaining)

    complete = all(cell_type != 'fillable' or normalized_fills[index] is not None for index, cell_type in enumerate(cell_types))

    return MoodPixelState(
        board_id=board_id,
        sample_index=_BOARD_INDEX[board_id],
        total_samples=len(_BOARD_DEFS),
        pattern=copy.deepcopy(board['pattern']),
        fills=normalized_fills,
        remaining=remaining,
        selected_mood=normalized_selected,
        is_complete=complete,
        created_at=created_at or _now_utc(),
        updated_at=updated_at or _now_utc(),
    )



def _normalize_state(
    board_id: str,
    data: Dict,
    inventory: Optional[Dict[str, int]] = None,
) -> MoodPixelState:
    """Normalize stored mood pixel state data.

    Args:
        board_id: Board identifier
        data: Raw state data from cache or database
        inventory: Optional mood inventory. If None, uses fallback.

    Returns:
        Normalized MoodPixelState
    """
    fills = data.get('fills') if isinstance(data.get('fills'), list) else []
    if len(fills) != _GRID_SIZE * _GRID_SIZE:
        fills = [None] * (_GRID_SIZE * _GRID_SIZE)

    # Migrate legacy mood keys in fills array
    migrated_fills = []
    for fill in fills:
        if fill and isinstance(fill, str):
            migrated_fills.append(_LEGACY_KEY_MIGRATION.get(fill, fill))
        else:
            migrated_fills.append(fill)

    created_at = _parse_datetime(data.get('created_at')) or _parse_datetime(data.get('updated_at')) or _now_utc()
    updated_at = _parse_datetime(data.get('updated_at')) or created_at
    selected_mood = data.get('selected_mood')

    # Migrate legacy selected_mood key
    if selected_mood and isinstance(selected_mood, str):
        selected_mood = _LEGACY_KEY_MIGRATION.get(selected_mood, selected_mood)

    return _rebuild_state(
        board_id,
        migrated_fills,
        selected_mood if isinstance(selected_mood, str) or selected_mood is None else None,
        created_at=created_at,
        updated_at=updated_at,
        inventory=inventory,
    )



def _persist_state(developer_id: str, uid: str, state: MoodPixelState) -> MoodPixelState:
    payload = state.model_dump(mode='json')
    if developer_id:
        dev_db.store_mood_pixel_state(developer_id, uid, state.board_id, payload)
    set_generic_cache(_cache_key(uid, state.board_id), payload, ttl=_CACHE_TTL)
    return state



def _read_state(developer_id: str, uid: str, board_id: str) -> MoodPixelState:
    """Read mood pixel state from cache or database.

    This function now calculates mood inventory from actual conversations (EIR emotions)
    so the Mood Pixel game stays in sync with the Mood Trends chart.

    Args:
        developer_id: Developer ID
        uid: User ID
        board_id: Board identifier

    Returns:
        MoodPixelState with inventory calculated from recent conversations
    """
    # Calculate inventory from recent conversations (past 7 days for weekly boards)
    inventory = None
    if developer_id:
        try:
            inventory = _inventory_from_conversations(developer_id, uid, days=7)
        except Exception as e:
            # Log but don't fail — fall back to default inventory
            import logging
            logging.getLogger(__name__).warning(
                f"Failed to calculate conversation-based inventory for {uid}: {e}"
            )

    cached = get_generic_cache(_cache_key(uid, board_id))
    if cached:
        return _normalize_state(board_id, cached, inventory=inventory)

    stored = dev_db.get_mood_pixel_state(developer_id, uid, board_id) if developer_id else None
    if stored is None and board_id == _BOARD_DEFS[0]['id'] and developer_id:
        legacy = dev_db.get_mood_pixel_state(developer_id, uid, _LEGACY_BOARD_ID)
        if legacy:
            stored = dict(legacy)
            stored['board_id'] = board_id

    if stored:
        state = _normalize_state(board_id, stored, inventory=inventory)
        return _persist_state(developer_id, uid, state)

    state = _blank_state(board_id, inventory=inventory)
    return _persist_state(developer_id, uid, state)



def _local_date(dt: datetime, tz_name: Optional[str]):
    if tz_name:
        try:
            import pytz

            return dt.astimezone(pytz.timezone(tz_name)).date()
        except Exception:
            pass
    return dt.astimezone(timezone.utc).date()



def _active_board_index(states: List[MoodPixelState], tz_name: Optional[str]) -> int:
    first_started = states[0].created_at or states[0].updated_at or _now_utc()
    weekly_unlock_index = min(
        len(states) - 1,
        max(0, (_local_date(_now_utc(), tz_name) - _local_date(first_started, tz_name)).days // 7),
    )

    active_index = 0
    for index in range(len(states) - 1):
        if states[index].is_complete or weekly_unlock_index > index:
            active_index = index + 1
        else:
            break
    return active_index



def _resolve_active_state(developer_id: str, uid: str) -> MoodPixelState:
    tz_name = dev_db.get_user_timezone(developer_id, uid) if developer_id else None
    states = [_read_state(developer_id, uid, board['id']) for board in _BOARD_DEFS]
    return states[_active_board_index(states, tz_name)]


@router.get('/v1/mood/pixel-state', tags=['mood'], response_model=MoodPixelState)
def get_mood_pixel_state(ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    return _resolve_active_state(developer_id, uid)


@router.get('/v1/mood/pixel-states/all', tags=['mood'], response_model=List[MoodPixelState])
def get_all_mood_pixel_states(ctx: tuple = Depends(auth.get_current_user_context)):
    """Get all mood pixel board states (current and historical)"""
    developer_id, uid = ctx
    states = [_read_state(developer_id, uid, board['id']) for board in _BOARD_DEFS]
    # Filter out None values in case any board state fails to load
    return [s for s in states if s is not None]


@router.put('/v1/mood/pixel-state', tags=['mood'], response_model=MoodPixelState)
def update_mood_pixel_state(data: UpdateMoodPixelStateRequest, ctx: tuple = Depends(auth.get_current_user_context)):
    """Update mood pixel state with user's fills and selected mood.

    The inventory (remaining counts) is recalculated from recent conversations
    each time, so the available moods stay in sync with the Mood Trends chart.
    """
    developer_id, uid = ctx

    if len(data.fills) != _GRID_SIZE * _GRID_SIZE:
        raise HTTPException(status_code=400, detail='fills must contain exactly 225 cells')

    current_state = _resolve_active_state(developer_id, uid)
    board_id = (data.board_id or current_state.board_id).strip()
    if board_id not in _BOARD_BY_ID:
        raise HTTPException(status_code=400, detail='unknown board_id')

    # _read_state calls _inventory_from_conversations internally.
    # We need the inventory for _rebuild_state, so we call it once here.
    # The Redis cache (5-min TTL) ensures we don't hit the DB twice.
    inventory = None
    if developer_id:
        try:
            inventory = _inventory_from_conversations(developer_id, uid, days=7)
        except Exception as e:
            import logging
            logging.getLogger(__name__).warning(
                f"Failed to calculate inventory during update for {uid}: {e}"
            )

    stored_state = _read_state(developer_id, uid, board_id)

    # Both _read_state and this call use _inventory_from_conversations,
    # but the Redis cache ensures only one DB query happens
    next_state = _rebuild_state(
        board_id,
        data.fills,
        data.selected_mood,
        created_at=stored_state.created_at,
        updated_at=_now_utc(),
        inventory=inventory,
    )
    _persist_state(developer_id, uid, next_state)
    return next_state
