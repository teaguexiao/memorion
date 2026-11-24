"""Registry-routed Vertex AI image understanding, shared by all image endpoints."""

import base64
import json
import logging
from typing import Any, Dict, List

from langchain_core.messages import HumanMessage
from pydantic import BaseModel, Field

from .clients import coerce_llm_text_content, create_llm
from .model_config import MODEL_CONFIG

logger = logging.getLogger(__name__)


class ImageDescriptionObject(BaseModel):
    """Structured image description from VLM analysis"""
    objects: List[str] = Field(default=[], description="Objects detected in the image")
    people: List[Dict[str, Any]] = Field(default=[], description="People detected with attributes")
    text: List[str] = Field(default=[], description="Text/OCR content found in the image")
    scene: str = Field(default="", description="Overall scene description")
    environment: str = Field(default="", description="Environment type (indoor/outdoor/etc)")
    colors: List[str] = Field(default=[], description="Dominant colors")
    actions: List[str] = Field(default=[], description="Actions or activities happening")
    mood: str = Field(default="", description="Mood or atmosphere")
    tags: List[str] = Field(default=[], description="Relevant tags for categorization")
    summary: str = Field(default="", description="Brief one-sentence summary")


async def describe_image_with_gemini(base64_data: str) -> ImageDescriptionObject:
    """
    Generate structured image description using Gemini Vision model via Vertex AI.

    Args:
        base64_data: Base64 encoded image data

    Returns:
        ImageDescriptionObject with structured description
    """
    # The role pins Gemini even in the REST container (LLM_PROVIDER=openrouter).
    model = create_llm(**MODEL_CONFIG['image_description'])
    image_bytes = base64.b64decode(base64_data)
    mime_type = 'image/png' if image_bytes.startswith(b'\x89PNG\r\n\x1a\n') else 'image/jpeg'

    prompt = """Analyze this image and provide a structured JSON description.

Return ONLY a valid JSON object with the following structure (no markdown, no code blocks):
{
  "objects": ["list of objects detected in the image"],
  "people": [{"description": "person description", "position": "location in image", "activity": "what they are doing"}],
  "text": ["any text or writing visible in the image (OCR)"],
  "scene": "overall scene description",
  "environment": "indoor/outdoor/vehicle/etc",
  "colors": ["dominant colors in the image"],
  "actions": ["actions or activities happening"],
  "mood": "mood or atmosphere of the image",
  "tags": ["relevant tags for categorization"],
  "summary": "brief one-sentence summary of the image"
}

If a field has no relevant content, use an empty list [] or empty string "".
Respond with ONLY the JSON object, no additional text."""

    response = await model.ainvoke(
        [HumanMessage(content=[
            {'type': 'text', 'text': prompt},
            {'type': 'image_url', 'image_url': {'url': f'data:{mime_type};base64,{base64_data}'}},
        ])],
        response_mime_type='application/json',
        max_output_tokens=4096,
    )
    response_text = coerce_llm_text_content(response)

    # Clean markdown code blocks if present
    if response_text.startswith("```"):
        response_text = response_text.split("\n", 1)[1] if "\n" in response_text else response_text
        if response_text.endswith("```"):
            response_text = response_text[:-3]
        response_text = response_text.strip()

    try:
        description_dict = json.loads(response_text)
        return ImageDescriptionObject(**description_dict)
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse Gemini response as JSON: {e}")
        # Return a basic description with the raw text
        return ImageDescriptionObject(
            summary=response_text[:200] if response_text else "Failed to parse image",
            scene=response_text[:500] if response_text else ""
        )
