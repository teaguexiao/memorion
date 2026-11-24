from typing import List, Optional

from models.other import Person
from models.transcript_segment import TranscriptSegment
from utils.llm.clients import llm_mini
from utils.llm.prompt_registry import PromptSpec, get_prompt, resolve_llm

# Fallback template (registry key 'followup.question').
_FOLLOWUP_QUESTION = PromptSpec(content="""You will be given the transcript of an in-progress conversation.
Your task as an engaging, fun, and curious conversationalist, is to suggest the next follow-up question to keep the conversation engaging.

Conversation Transcript:
{{transcript_str}}

Output your response in plain text, without markdown.
Output only the question, without context, be concise and straight to the point.""")


def followup_question_prompt(
    segments: List[TranscriptSegment],
    people: Optional[List[Person]] = None,
    output_language: Optional[str] = None,
):
    transcript_str = TranscriptSegment.segments_as_string(segments, include_timestamps=False, people=people)
    words = transcript_str.split()
    w_count = len(words)
    if w_count < 10:
        return ''
    elif w_count > 100:
        # trim to last 500 words
        transcript_str = ' '.join(words[-100:])

    resolved = get_prompt('followup.question', fallback=_FOLLOWUP_QUESTION)
    # Legacy behavior: 4-space runs are stripped from the interpolated prompt
    # (the template itself is pre-de-indented, so this only affects variables).
    prompt = resolved.render(transcript_str=transcript_str).replace('    ', '').strip()

    if output_language:
        from utils.locales import llm_output_language_instruction
        instr = llm_output_language_instruction(output_language)
        if instr:
            prompt = f"{prompt}\n\n{instr}"

    return resolve_llm(resolved, llm_mini).invoke(prompt).content
