from datetime import datetime, timezone
from typing import List

from pydantic import BaseModel, Field

PDP_TRAIT_KEYS = ['control', 'expression', 'caution', 'warmth', 'balance']
PDP_ANIMAL_KEYS = ['tiger', 'peacock', 'owl', 'koala', 'lizard']


class PdpMetric(BaseModel):
    key: str = Field(description='Trait key, e.g. control')
    score: int = Field(description='Current score 0-100', ge=0, le=100)
    delta: int = Field(description='Daily drift against baseline, signed integer')


class PdpTrajectoryEntry(BaseModel):
    date: str = Field(description='YYYY-MM-DD')
    animal_key: str = Field(description='One of tiger/peacock/owl/koala/lizard')


class PdpSnapshot(BaseModel):
    date: str = Field(description='YYYY-MM-DD')
    language: str = Field(description='Language used for free-text fields')
    engine_version: int = Field(default=2, description='Server-side generation version for cache invalidation')
    primary_animal_key: str = Field(description='Animal key for the strongest baseline trait')
    secondary_animal_key: str = Field(description='Animal key for the second strongest baseline trait')
    primary_trait_key: str = Field(description='Trait key for the strongest baseline trait')
    secondary_trait_key: str = Field(description='Trait key for the second strongest baseline trait')
    hero_animal_key: str = Field(description='Animal key emphasized for today')
    hero_summary: str = Field(description='Large headline-style sentence for the hero card')
    insight_lines: List[str] = Field(description='Exactly three short insight lines')
    metrics: List[PdpMetric] = Field(description='Five trait metrics')
    trajectory: List[PdpTrajectoryEntry] = Field(description='Seven-day animal trajectory, oldest to newest')
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
