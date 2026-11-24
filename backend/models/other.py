from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, Field


class SaveFcmTokenRequest(BaseModel):
    fcm_token: str
    time_zone: str


class SaveNotificationPreferencesRequest(BaseModel):
    """通知偏好同步（字段与 App 端开关一一对应，全部可选，只更新传入的）。"""
    daily_moment: Optional[bool] = None
    task_reminder: Optional[bool] = None
    pause_reminder: Optional[bool] = None
    milestone: Optional[bool] = None
    quiet_hours_enabled: Optional[bool] = None
    quiet_hours_start_minutes: Optional[int] = None
    quiet_hours_end_minutes: Optional[int] = None


class UploadProfile(BaseModel):
    bytes: List[List[int]]
    duration: int


class CreatePerson(BaseModel):
    name: str = Field(min_length=2, max_length=40)


class Person(BaseModel):
    id: str
    name: str
    created_at: datetime
    updated_at: datetime
    speech_samples: List[str] = []
