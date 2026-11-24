from typing import List
from pydantic import BaseModel, Field

import utils.people as people_helper
from models.conversation import Conversation
from models.other import Person
from models.trend import (
    TrendEnum,
    ceo_options,
    company_options,
    software_product_options,
    hardware_product_options,
    ai_product_options,
    TrendType,
)
from utils.llm.clients import llm_mini
from utils.llm.prompt_registry import PromptSpec, get_prompt, resolve_llm


# Fallback template (registry key 'trends.extract'). The legacy prompt was
# de-indented via .replace('    ', ''); this template is pre-de-indented.
_TRENDS_EXTRACT = PromptSpec(content='''You will be given a finished conversation transcript.
You are responsible for extracting the topics of the conversation and classifying each one within one the following categories: {{categories}}.
You must identify if the perception is positive or negative, and classify it as "best" or "worst".

For the specific topics here are the options available, you must classify the topic within one of these options:
- ceo_options: {{ceo_options}}
- company_options: {{company_options}}
- software_product_options: {{software_product_options}}
- hardware_product_options: {{hardware_product_options}}
- ai_product_options: {{ai_product_options}}

For example,
If you identify the topic "Tesla stock has been going up incredibly", you should output:
- Category: company
- Type: best
- Topic: Tesla

Conversation:
{{transcript}}''')


class Item(BaseModel):
    category: TrendEnum = Field(description="The category identified")
    type: TrendType = Field(description="The sentiment identified")
    topic: str = Field(description="The specific topic corresponding the category")


class ExpectedOutput(BaseModel):
    items: List[Item] = Field(default=[], description="List of items.")


def trends_extractor(uid: str, memory: Conversation) -> List[Item]:
    person_ids = [s.person_id for s in memory.transcript_segments if s.person_id]
    people = []
    if person_ids:
        people_data = people_helper.get_people_by_ids(uid, list(set(person_ids)))
        people = [Person(**p) for p in people_data]

    transcript = memory.get_transcript(False, people=people)
    if len(transcript) == 0:
        return []

    resolved = get_prompt('trends.extract', fallback=_TRENDS_EXTRACT)
    prompt = resolved.render(
        categories=str([e.value for e in TrendEnum]).strip("[]"),
        ceo_options=", ".join(ceo_options),
        company_options=", ".join(company_options),
        software_product_options=", ".join(software_product_options),
        hardware_product_options=", ".join(hardware_product_options),
        ai_product_options=", ".join(ai_product_options),
        transcript=transcript,
    )
    # Legacy behavior: 4-space runs are stripped from the interpolated prompt
    # (the template itself is pre-de-indented, so this only affects variables).
    prompt = prompt.replace('    ', '').strip()
    try:
        with_parser = resolve_llm(resolved, llm_mini).with_structured_output(ExpectedOutput)
        response: ExpectedOutput = with_parser.invoke(prompt)
        if response is None or response.items is None:
            print('trends_extractor: LLM returned None')
            return []
        filtered = []
        for item in response.items:
            if item.topic not in [
                e
                for e in (
                    ceo_options
                    + company_options
                    + software_product_options
                    + hardware_product_options
                    + ai_product_options
                )
            ]:
                continue
            filtered.append(item)
        return filtered

    except Exception as e:
        print(f'Error determining memory discard: {e}')
        return []
