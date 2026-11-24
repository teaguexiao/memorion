from typing import Optional, List

from pydantic import BaseModel, Field

from models.emotion import EmotionDetectionResult, EmotionCategory, TRIGGER_EMOTIONS
from models.conversation import Conversation
from models.other import Person
from utils.llm.clients import llm_mini


class EmotionAnalysis(BaseModel):
    """LLM 情绪分析输出结构"""
    primary_emotion: EmotionCategory = Field(description="检测到的主要情绪")
    confidence: float = Field(description="置信度 0-1", ge=0, le=1)
    emotion_summary: str = Field(description="情绪背景简述", max_length=500)


def _get_primary_speaker_segments(conversation: Conversation) -> tuple[list, bool]:
    """
    获取主要说话者的 segments。

    优先使用 is_user=True 的 segments，如果没有则假设说话最多的 speaker 是用户
    （因为 Omi 设备戴在用户身上，离用户最近，通常能捕获更多用户的声音）。

    Returns:
        tuple: (segments 列表, 是否确定是用户)
    """
    # 首先尝试获取明确标记为用户的 segments
    user_segments = [s for s in conversation.transcript_segments if s.is_user]
    if user_segments:
        return user_segments, True

    # 没有 is_user 标记，使用 fallback：找说话最多的 speaker
    if not conversation.transcript_segments:
        return [], False

    # 统计每个 speaker 的总字数
    speaker_word_counts = {}
    for seg in conversation.transcript_segments:
        speaker = seg.speaker or "unknown"
        word_count = len(seg.text) if seg.text else 0
        speaker_word_counts[speaker] = speaker_word_counts.get(speaker, 0) + word_count

    if not speaker_word_counts:
        return [], False

    # 找出说话最多的 speaker
    primary_speaker = max(speaker_word_counts, key=speaker_word_counts.get)
    primary_segments = [s for s in conversation.transcript_segments if s.speaker == primary_speaker]

    return primary_segments, False


def detect_emotion_from_conversation(
    uid: str,
    conversation: Conversation,
    people: List[Person] = None,
    output_language: Optional[str] = None,
) -> Optional[EmotionDetectionResult]:
    """
    基于对话内容检测用户情绪状态。

    Args:
        uid: 用户ID
        conversation: 对话对象
        people: 对话中涉及的人员列表
        output_language: 用户偏好语言（来自 user.language）。该参数仅决定
            emotion_summary 字段的语言；primary_emotion 始终是英文枚举值。

    Returns:
        EmotionDetectionResult 或 None（如果无法检测）
    """
    # 获取主要说话者的发言
    primary_segments, is_confirmed_user = _get_primary_speaker_segments(conversation)
    if not primary_segments:
        print(f"[EmotionalCare] No segments found in conversation {conversation.id}")
        return None

    user_transcript = "\n".join([s.text for s in primary_segments])

    # 对话太短，无法准确判断情绪
    if len(user_transcript.strip()) < 30:
        print(f"[EmotionalCare] Transcript too short ({len(user_transcript)} chars) for conversation {conversation.id}")
        return None

    speaker_label = "用户" if is_confirmed_user else "主要说话者（可能是用户）"
    print(f"[EmotionalCare] Analyzing {len(primary_segments)} segments as {speaker_label} for conversation {conversation.id}")

    # 获取完整对话上下文
    transcript = conversation.get_transcript(include_timestamps=False, people=people)

    # 根据 user.language 决定 emotion_summary 应该使用哪种语言。primary_emotion
    # 始终是英文枚举（happy / angry / sad / surprised / calm），因为它对应代码
    # 中的 enum 值；emotion_summary 是给用户/下游 webhook 看的自由文本。
    summary_language_hint = ''
    try:
        from utils.locales import base_language, language_name_for_prompt
        if output_language:
            base = base_language(output_language)
            if base != 'zh':
                summary_language_hint = (
                    f"\n    重要：emotion_summary 字段必须用 {language_name_for_prompt(output_language)} 输出"
                    f"（用户偏好语言）。primary_emotion 仍然是英文枚举值。"
                )
    except Exception:
        pass

    from utils.llm.prompt_registry import PromptSpec, get_prompt, resolve_llm

    fallback = PromptSpec(content='''分析对话中{{speaker_label}}的情绪状态。

{{speaker_label}}发言:
```
{{user_transcript}}
```

完整对话上下文:
```
{{transcript}}
```

根据语气、用词、讨论话题，判断{{speaker_label}}的主要情绪（必须从以下五类中选择一个）:
- happy: 开心、积极、愉悦、兴奋（庆祝、成就、好消息、明显正面情绪）
- angry: 愤怒、生气、沮丧、不满（争执、冲突、压力高峰、不耐烦）
- sad: 悲伤、低落、失落、难过（失去、失望、伤感、消沉）
- surprised: 惊讶、震惊、意外（突发事件、出乎意料的消息、强烈反应）
- calm: 平静、放松、专注、中性（日常对话、普通讨论、没有明显情绪倾向 —— 默认归类）

注意：
1. 只有当情绪非常明显时才选择 happy / angry / sad / surprised；普通日常对话应归为 calm
2. 置信度反映你对判断的确信程度，普通对话即便选了强烈情绪，置信度也应较低
3. 必须严格输出上面五个英文枚举之一，不允许输出其他值
{{summary_language_hint}}

输出置信度(0-1)和简短的情绪背景描述。''')

    resolved = get_prompt('eir.emotion', fallback=fallback)
    prompt = resolved.render(
        speaker_label=speaker_label,
        user_transcript=user_transcript[:2000],
        transcript=transcript[:1500],
        summary_language_hint=summary_language_hint,
    )
    llm = resolve_llm(resolved, llm_mini)

    try:
        result: EmotionAnalysis = llm.with_structured_output(EmotionAnalysis).invoke(prompt)
        if result is None:
            print(f"[EmotionalCare] LLM returned None for conversation {conversation.id}")
            return None

        # 只有强烈情绪且置信度 >= 0.7 才触发通知
        should_notify = (
            result.primary_emotion in TRIGGER_EMOTIONS
            and result.confidence >= 0.7
        )

        return EmotionDetectionResult(
            primary_emotion=result.primary_emotion,
            confidence=result.confidence,
            should_notify=should_notify,
            emotion_summary=result.emotion_summary
        )
    except Exception as e:
        print(f"[EmotionalCare] Emotion detection failed for conversation {conversation.id}: {e}")
        return None
