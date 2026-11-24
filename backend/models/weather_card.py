from datetime import datetime, timezone

from pydantic import BaseModel, Field


class WeatherSnapshot(BaseModel):
    condition: str = Field(description='Condition key: sunny/cloudy/rain/snow/storm/wind')
    temperature_c: int = Field(description='Rounded Celsius temperature')
    is_fallback: bool = Field(default=False, description='True when no precise geo-backed weather was available')
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
