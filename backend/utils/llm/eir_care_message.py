"""
EIR Care Message Generator

Generates personalized emotional care messages for the Developer API
based on detected emotions and conversation content.
"""

from typing import Optional

from .clients import coerce_llm_text_content, llm_mini
from .prompt_registry import PromptSpec, get_prompt, resolve_llm

# Fallback templates (registry keys 'eir.care_message.zh' / 'eir.care_message.en').
_CARE_MESSAGE_ZH = PromptSpec(content="""你是一个体贴、温暖的朋友。

用户刚刚完成了一段对话，表现出 {{emotion}} 的情绪。
情绪背景: {{emotion_summary}}

对话记录:
{{transcript}}

根据对话内容，给用户一条简短温暖的关怀消息（情绪取值仅可能是 happy / angry / sad / surprised / calm 之一）。
- 如果是 angry / sad，给予理解、安抚、鼓励和支持
- 如果是 surprised，回应惊讶并一起感受这份意外
- 如果是 happy，一起分享喜悦
- 如果是 calm，自然轻松地陪伴一句即可

消息要简短温暖，不超过50个字，用中文回复。
直接输出消息内容，不要加任何前缀或解释。""")

_CARE_MESSAGE_EN = PromptSpec(content="""You are a thoughtful and caring friend.

The user just finished a conversation and expressed {{emotion}}.
Context: {{emotion_summary}}

Conversation:
{{transcript}}

The emotion will always be one of: happy / angry / sad / surprised / calm. Based on the conversation, send a short caring message.
- For angry / sad: offer understanding, comfort, encouragement, and support
- For surprised: acknowledge the unexpected moment and share the reaction
- For happy: celebrate together
- For calm: keep it light and companionable

Keep it warm and brief, no more than 30 words.
Output only the message content, no prefixes or explanations.""")


def generate_eir_care_message(
    emotion: str,
    emotion_summary: str,
    transcript: str,
    output_language: Optional[str] = None,
) -> str:
    """
    Use LLM to generate a personalized care message based on detected emotion.

    Args:
        emotion: Detected emotion type. One of: happy, angry, sad, surprised, calm.
        emotion_summary: Summary of the emotional context from EIR detection
        transcript: Conversation transcript text
        output_language: Preferred language code from user.language. If provided
            and not English, instructs the LLM to respond in that language. When
            None, falls back to legacy heuristic detection on the transcript.

    Returns:
        LLM-generated personalized care message
    """
    from utils.locales import (
        base_language,
        language_name_for_prompt,
        get_eir_fallback_message,
    )

    # Truncate transcript if too long
    truncated_transcript = transcript[:1500] if len(transcript) > 1500 else transcript

    # Decide which language family to write in. Priority:
    #   1) explicit user.language (output_language) when provided
    #   2) fallback heuristic: Chinese-character ratio in transcript
    if output_language:
        is_chinese = base_language(output_language) == 'zh'
    else:
        chinese_chars = sum(1 for c in transcript if '一' <= c <= '鿿')
        is_chinese = chinese_chars > len(transcript) * 0.1

    # Build the base prompt (registry-backed; zh and en variants are separate keys)
    if is_chinese:
        resolved = get_prompt('eir.care_message.zh', fallback=_CARE_MESSAGE_ZH)
    else:
        resolved = get_prompt('eir.care_message.en', fallback=_CARE_MESSAGE_EN)

    prompt = resolved.render(
        emotion=emotion,
        emotion_summary=emotion_summary,
        transcript=truncated_transcript,
    )

    if not is_chinese:
        # Append explicit language hint for non-English/non-Chinese users so
        # the assistant respects user.language (e.g. ja, ko, es, ...).
        if output_language and base_language(output_language) not in ('en', 'zh'):
            prompt += f"\n\nRespond in {language_name_for_prompt(output_language)}."

    try:
        response = resolve_llm(resolved, llm_mini).invoke(prompt)
        message = coerce_llm_text_content(response)
        # Clean up any quotes that might wrap the response
        message = message.strip('"\'')
        return message
    except Exception as e:
        print(f"Error generating EIR care message: {e}")
        # Fallback messages, localized when possible
        if output_language:
            return get_eir_fallback_message(output_language)
        if is_chinese:
            return get_eir_fallback_message('zh')
        return get_eir_fallback_message('en')
