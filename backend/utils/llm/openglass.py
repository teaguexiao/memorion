from typing import List, Optional

from models.conversation import ConversationPhoto, Structured
from utils.llm.clients import llm_mini
from utils.llm.prompt_registry import PromptSpec, get_prompt, resolve_llm

# Fallback template (registry key 'openglass.image_description'). This is the
# text part of a vision call; the image_url message structure stays in code.
_IMAGE_DESCRIPTION = PromptSpec(content=(
    "You are my AI assistant, seeing the world through my smart glasses. In a single, descriptive paragraph, "
    "tell me what's happening from a first-person perspective. Focus on the most important aspects of the scene: "
    "the people, their actions, the key objects, and the overall environment. What is the general mood or atmosphere?"
))


async def describe_image(base64_data: str, output_language: Optional[str] = None) -> str:
    """
    Generates a description for a base64 encoded image using a vision model via LangChain.

    Args:
        base64_data: Image data, base64-encoded.
        output_language: User's preferred language (BCP-47). If non-English,
            instructs the model to write the description in that language.
    """
    resolved = get_prompt('openglass.image_description', fallback=_IMAGE_DESCRIPTION)
    prompt = resolved.render()

    if output_language:
        from utils.locales import llm_output_language_instruction
        instr = llm_output_language_instruction(output_language)
        if instr:
            prompt = f"{prompt}\n\n{instr}"

    message = {
        "role": "user",
        "content": [
            {"type": "text", "text": prompt},
            {
                "type": "image_url",
                "image_url": {"url": f"data:image/jpeg;base64,{base64_data}"},
            },
        ],
    }

    response = await resolve_llm(resolved, llm_mini).ainvoke([message], config={"max_tokens": 150})
    description = response.content
    return description.strip() if description is not None and description != '""' else ""
