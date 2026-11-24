from datetime import datetime, timezone
from typing import Dict, List, Optional

from pydantic import BaseModel, Field

MOOD_PIXEL_KEYS = ['happy', 'angry', 'sad', 'surprised', 'calm']


class MoodPixelState(BaseModel):
    board_id: str = Field(description='Stable identifier for the current board state')
    sample_index: int = Field(description='0-based index of the active template')
    total_samples: int = Field(description='How many templates are currently preloaded on the backend')
    pattern: List[str] = Field(description='15x15 pixel template rows, # = occupied, . = outside')
    fills: List[Optional[str]] = Field(description='Length 225 fill payload, values are mood keys or null')
    remaining: Dict[str, int] = Field(description='Remaining inventory for each mood key')
    selected_mood: Optional[str] = Field(default=None, description='Currently highlighted mood key')
    is_complete: bool = Field(default=False, description='Whether all fillable cells are already colored')
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class UpdateMoodPixelStateRequest(BaseModel):
    board_id: Optional[str] = Field(default=None, description='Optional active board identifier echoed back by the app')
    fills: List[Optional[str]] = Field(description='Full fill payload for the active board')
    selected_mood: Optional[str] = Field(default=None, description='Current selected mood key')
