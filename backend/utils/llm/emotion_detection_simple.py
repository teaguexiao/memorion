"""
Simplified emotion detection for Developer API.

This module provides a simpler interface for emotion detection that works
directly with transcript text, without requiring a full Conversation object.
"""

from typing import Optional

from pydantic import BaseModel, Field

from models.emotion import EmotionDetectionResult, EmotionCategory, TRIGGER_EMOTIONS
from utils.llm.clients import llm_mini
from utils.llm.prompt_registry import get_prompt, resolve_llm, single_brace_spec


class EmotionAnalysis(BaseModel):
    """LLM emotion analysis output structure."""
    primary_emotion: EmotionCategory = Field(description="Detected primary emotion")
    confidence: float = Field(description="Confidence score 0-1", ge=0, le=1)
    emotion_summary: str = Field(description="Brief emotion context summary", max_length=500)


def detect_emotion_from_transcript(
    transcript: str,
    min_length: int = 30,
) -> Optional[EmotionDetectionResult]:
    """
    Detect emotion from transcript text.

    Args:
        transcript: The transcript text to analyze
        min_length: Minimum transcript length to analyze

    Returns:
        EmotionDetectionResult or None if detection fails
    """
    if not transcript or len(transcript.strip()) < min_length:
        return None

    # Truncate if too long
    transcript = transcript[:3000]

    prompt_template = '''
    Analyze the emotional state of the speaker in this transcript.

    Transcript:
    ```
    {transcript}
    ```

    Based on tone, word choice, and topics discussed, determine the primary emotion (must be exactly one of these five):
    - happy: Happy, positive, joyful, excited, satisfied, pleased (celebration, achievement, good news, positive experiences, enthusiasm, contentment)
    - angry: Angry, frustrated, upset, irritated, annoyed, stressed (arguments, conflict, complaints, pressure, dissatisfaction, problems)
    - sad: Sad, down, disappointed, worried, concerned, grieving (loss, regret, melancholy, anxiety, uncertainty, setbacks)
    - surprised: Surprised, shocked, unexpected, amazed, curious (sudden events, surprising news, new discoveries, strong reactions)
    - calm: Calm, relaxed, neutral, matter-of-fact (purely factual discussion, routine updates, no emotional undertone)

    Guidelines:
    1. Be sensitive to emotional nuances — even mild emotional expressions should be captured (not defaulted to calm)
    2. Look for emotional keywords, tone markers, and context clues (exclamation marks, repetition, intensity words)
    3. Only select "calm" when the conversation is genuinely neutral/factual with no emotional coloring
    4. Confidence should reflect how clearly the emotion is expressed (0.5-0.7 for subtle emotions, 0.7-1.0 for clear emotions)
    5. You MUST output exactly one of the five enum values above; do not invent new categories

    Output confidence (0-1) and a brief description of the emotional context.
    '''.strip()

    resolved = get_prompt('eir.emotion_simple', fallback=single_brace_spec(prompt_template))
    prompt = resolved.render(transcript=transcript)
    llm = resolve_llm(resolved, llm_mini)

    try:
        result: EmotionAnalysis = llm.with_structured_output(EmotionAnalysis).invoke(prompt)
        if result is None:
            return None

        # Only trigger notification for strong emotions with confidence >= 0.7
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
        print(f"[EIR] Emotion detection failed: {e}")
        return None
