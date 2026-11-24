from datetime import datetime, timezone
from typing import List

from pydantic import BaseModel, Field


class HomeModuleUpdate(BaseModel):
    module: str = Field(description='mood | self | memory')
    detail: str = Field(description='Short human-readable update line')
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class HomeModuleUpdatesResponse(BaseModel):
    items: List[HomeModuleUpdate]
