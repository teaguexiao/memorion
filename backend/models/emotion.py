from enum import Enum
from typing import Optional
from pydantic import BaseModel, Field


class EmotionCategory(str, Enum):
    """用户情绪分类（与 Avatar 五情绪对齐）"""
    happy = 'happy'              # 开心、积极、愉悦、兴奋
    angry = 'angry'              # 愤怒、生气、沮丧、不满
    sad = 'sad'                  # 悲伤、低落、失落、难过
    surprised = 'surprised'      # 惊讶、震惊、意外
    calm = 'calm'                # 平静、放松、专注、中性（默认）


# 触发通知的情绪类型：强烈负向 + 突发情绪
TRIGGER_EMOTIONS = {
    EmotionCategory.angry,
    EmotionCategory.sad,
    EmotionCategory.surprised,
}


class EmotionDetectionResult(BaseModel):
    """情绪检测结果"""
    primary_emotion: EmotionCategory = Field(description="检测到的主要情绪")
    confidence: float = Field(description="置信度 0-1", ge=0, le=1)
    should_notify: bool = Field(description="是否应该发送通知")
    emotion_summary: str = Field(description="情绪背景简述")
