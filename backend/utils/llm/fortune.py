from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, Field

from utils.llm.clients import llm_medium
from utils.llm.prompt_registry import PromptSpec, get_prompt, resolve_llm

# ******************************************************
# ************* 系统固定行为标签 (宜 / 忌) **************
# ******************************************************
# 这份标签集合需与 App 端 (app/lib/models/fortune.dart) 保持一致，
# App 据此做 chip 样式映射；prompt 内枚举强制 LLM 只能从中选取。

DO_TAGS = [
    '宜出行',
    '宜社交',
    '宜理财',
    '宜学习',
    '宜复盘',
    '宜表达',
    '宜休整',
    '宜运动',
    '宜独处',
    '宜表白',
]

DONT_TAGS = [
    '忌冲动消费',
    '忌争执',
    '忌熬夜',
    '忌重大决策',
    '忌盲目投资',
    '忌强行社交',
    '忌焦虑内耗',
    '忌拖延',
    '忌轻信他人',
    '忌过度劳累',
]

# 十二时辰地支，子 -> 亥
EARTHLY_BRANCHES = ['子', '丑', '寅', '卯', '辰', '巳', '午', '未', '申', '酉', '戌', '亥']


class FortuneTier(str, Enum):
    da_ji = '大吉'
    ji = '吉'
    xiao_ji = '小吉'
    ping = '平'
    xiao_xiong = '小凶'
    xiong = '凶'


class FiveDimensions(BaseModel):
    """五维评分，各 0-20"""
    career: int = Field(description='事业 0-20', ge=0, le=20)
    wealth: int = Field(description='财运 0-20', ge=0, le=20)
    relationship: int = Field(description='情感 0-20', ge=0, le=20)
    health: int = Field(description='健康 0-20', ge=0, le=20)
    mood: int = Field(description='情绪 0-20', ge=0, le=20)


class FortuneAdvice(BaseModel):
    tag: str = Field(description='系统固定标签，必须从给定标签集中选取')
    text: str = Field(description='一句话行动建议', max_length=40)


class LuckyInfo(BaseModel):
    color: str = Field(description='幸运色，如 正红 / 湖蓝 / 米白')
    number: int = Field(description='幸运数字 0-9', ge=0, le=9)
    direction: str = Field(description='幸运方位，如 东 / 东南 / 正北')


class AuspiciousHour(BaseModel):
    branch: str = Field(description='时辰地支：子/丑/寅/卯/辰/巳/午/未/申/酉/戌/亥')
    is_auspicious: bool = Field(description='True=吉时宜办事，False=凶时需规避')
    note: str = Field(description='该时辰简注', max_length=30)


class DailyFortune(BaseModel):
    """每日运势测算结果"""
    score: int = Field(description='当日运势总评分 0-100', ge=0, le=100)
    tier: FortuneTier = Field(description='运势等级文案')
    dimensions: FiveDimensions
    summary: str = Field(description='一句话总览', max_length=120)
    do_advices: List[FortuneAdvice] = Field(description='宜，恰好 3 条')
    dont_advices: List[FortuneAdvice] = Field(description='忌，恰好 3 条')
    lucky: LuckyInfo
    hours: List[AuspiciousHour] = Field(description='12 时辰，按子到亥顺序')


# Fallback template (registry key 'fortune.daily'). Rendered output is passed
# through .strip(), matching the legacy f-string behavior.
_FORTUNE_DAILY = PromptSpec(content='''你是一位融合中西方占卜学的命理顾问。请根据用户的生日，为目标日期生成一份当日运势测算。

    用户生日：{{birthday}}
    目标日期：{{date_str}}

    测算方法（请自行推算，无需外部工具）：
    1. 西方占星：依生日推算太阳星座，结合其元素属性（火/土/风/水）与当日的象征能量。
    2. 中式命理：依生日推算生肖、出生年干支，并结合目标日期的干支，做象征性的喜忌与神煞参考。
    3. 综合中西两套体系得出当日整体运势，确保 score 与 tier、五维评分彼此自洽。

    输出要求（严格遵守）：
    - score：0-100 的整数。tier 必须与 score 区间自洽（大致 90+ 大吉、75-89 吉、60-74 小吉、45-59 平、30-44 小凶、<30 凶）。
    - dimensions：事业/财运/情感/健康/情绪 各 0-20。
    - do_advices：恰好 3 条「宜」，每条 tag 必须从以下固定标签中选取（不得自创），text 为对应的一句话建议：
      {{do_tags}}
    - dont_advices：恰好 3 条「忌」，每条 tag 必须从以下固定标签中选取（不得自创）：
      {{dont_tags}}
    - lucky：给出幸运色、幸运数字(0-9)、幸运方位。
    - hours：恰好 12 条，branch 必须严格按以下顺序覆盖十二时辰：{{branches}}。
      其中标注若干吉时（is_auspicious=true，宜办事）与若干凶时（is_auspicious=false，需规避），note 给出简短说明。
    - summary：一句话总览当日运势基调。

    注意：本测算为娱乐性质，不构成医疗、财务或法律建议，措辞保持温和正向。
    {{language_hint}}''')


def generate_daily_fortune(
    birthday: str,
    date_str: str,
    output_language: Optional[str] = None,
) -> DailyFortune:
    """
    根据用户生日，融合中西方占卜学生成当日运势。

    Args:
        birthday: 用户生日 'YYYY-MM-DD'
        date_str: 目标日期 'YYYY-MM-DD'
        output_language: 用户偏好语言。仅影响自由文本字段（summary/text/note 等）的语言；
            受控值 tier / branch / tag 始终保持中文固定枚举。

    Returns:
        DailyFortune
    """
    language_hint = ''
    try:
        from utils.locales import base_language, language_name_for_prompt

        if output_language:
            base = base_language(output_language)
            if base != 'zh':
                language_hint = (
                    f"\n    重要：summary、各 advice 的 text、各时辰的 note 等自由文本字段必须用 "
                    f"{language_name_for_prompt(output_language)} 输出（用户偏好语言）。"
                    f"但 tier、tag、时辰 branch 这些受控值仍然保持中文固定枚举不变。"
                )
    except Exception:
        pass

    do_tags_str = ' / '.join(DO_TAGS)
    dont_tags_str = ' / '.join(DONT_TAGS)
    branches_str = ' '.join(EARTHLY_BRANCHES)

    resolved = get_prompt('fortune.daily', fallback=_FORTUNE_DAILY)
    prompt = resolved.render(
        birthday=birthday,
        date_str=date_str,
        do_tags=do_tags_str,
        dont_tags=dont_tags_str,
        branches=branches_str,
        language_hint=language_hint,
    ).strip()

    llm = resolve_llm(resolved, llm_medium)
    result: DailyFortune = llm.with_structured_output(DailyFortune).invoke(prompt)
    return result
