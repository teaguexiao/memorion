from datetime import datetime, timezone
from typing import Dict

from pydantic import BaseModel, Field


# ******************************************************
# ********** EMOTION -> COLOR AUTHORITY MAP ************
# ******************************************************
# 与 app/lib/backend/schema/avatar_emotion.dart 保持一致。
# 颜色由后端查表下发，不让 LLM 决定，保证前后端一致。

EMOTION_COLORS = {
    'happy': {'bg_color': '#FFF3D0', 'text_color': '#5C4A00'},
    'angry': {'bg_color': '#E8B4B8', 'text_color': '#5C1A1A'},
    'sad': {'bg_color': '#B8C8D8', 'text_color': '#2A3A4A'},
    'surprised': {'bg_color': '#D8F4E4', 'text_color': '#1A4A2A'},
    'calm': {'bg_color': '#F5F0E6', 'text_color': '#4A4540'},
}

# 仅这 5 类情绪参与统计（与 discover.py 的 VALID_EMOTIONS 对齐）。
VALID_EMOTIONS = set(EMOTION_COLORS.keys())


class MoodQuoteLLMOutput(BaseModel):
    """LLM 结构化输出的内部模型。

    LLM 只产出文艺诗意系的 title / body，颜色、dominant_emotion、日期等
    其它字段由后端按映射表填充。
    """

    title: str = Field(description='一句意象化短标题，≤12 字，像小诗的题目，不说教不鸡汤')
    body: str = Field(description='2~4 行短诗式安抚寄语，用 \\n 分行，留白、有节奏')


class DailyMoodQuote(BaseModel):
    """情绪页「每日一语」对外返回模型。"""

    date: str = Field(description="YYYY-MM-DD，用户本地时区当天")
    dominant_emotion: str = Field(description="当日权重最高（排除 calm）的情绪，兜底为 'calm'")
    emotion_distribution: Dict[str, int] = Field(
        default_factory=dict, description='当日 {emotion: count} 分布，留存供前端/调试'
    )
    bg_color: str = Field(description='卡片底色，如 "#FFF3D0"')
    text_color: str = Field(description='文字色，如 "#5C4A00"')
    title: str = Field(description='LLM 生成的短标题')
    body: str = Field(description='LLM 生成的安抚寄语正文（带换行）')
    language: str = Field(description="'zh' | 'en' 等语言代码")
    is_fallback: bool = Field(default=False, description='是否为兜底文案（无有效情绪）')
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
