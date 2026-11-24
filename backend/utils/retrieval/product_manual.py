"""Product manual lookup for the chat agent's `product_faq` tool.

Why this exists: asked "how do I pair the device" or "my Memorion won't sync",
the agent had no source of truth about its own product. Observed live before this
tool landed — three distinct failure modes, all worse than a plain "I don't know":

* "怎么充电/电池能用多久" → routed to `memory_search`, i.e. it went looking through
  the user's *recordings* for the answer.
* "蓝牙连不上怎么办" → flatly refused: "不在我能查到的记忆范围内".
* "Memorion 多少钱" → `web_search` found the App Store listing's "免费下载" and
  confidently answered that the product is free, having missed hardware pricing
  entirely. A confident wrong answer is the worst of the three.

Why a repo markdown file and not the prompt registry: the registry versions
*prompts* (A/B, movable `production` label). This is product *facts*. Putting
them behind a prompt label means promoting a prompt revision could silently
change "how many days does the battery last" — two unrelated things sharing one
version pointer. Facts belong in the repo, reviewed like code.

Why not a vector index: the whole manual is ~11 sections / a few KB. Keyword
scoring over explicit per-section keyword lists is exact, debuggable, needs no
embedding round trip, and — unlike a similarity search — returns *nothing* rather
than a plausible-looking nearest neighbour when the manual genuinely doesn't
cover the question. That property is the whole point here (see failure mode 3).

Both languages are matched by plain substring containment, which suits CJK (no
tokenizer needed) and is deliberately lenient for English ("record" hits
"recording"). Keyword lists live next to the prose in `product_manual.md`.
"""

import logging
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger(__name__)

MANUAL_PATH = Path(__file__).with_name("product_manual.md")

# Sections returned per lookup. Small on purpose: the manual is written so one
# question maps to one or two sections, and a wide dump would crowd the context
# with prose the model then has to filter.
DEFAULT_SECTION_LIMIT = 2
MAX_SECTION_LIMIT = 4

# `<!-- id: x | keywords: a,b,c -->` immediately followed by `## Heading`.
_SECTION_RE = re.compile(
    r"<!--\s*id:\s*(?P<id>[a-z0-9\-]+)\s*\|\s*keywords:\s*(?P<keywords>[^>]*?)\s*-->\s*\n"
    r"##\s*(?P<title>.+?)\n"
    r"(?P<body>.*?)"
    r"(?=\n<!--\s*id:|\Z)",
    re.DOTALL,
)

# Attached to every response, hit or miss. The miss case is obvious, but the
# dangerous case is a *partial* hit: the model gets a section that is adjacent to
# the question and fills the gap by guessing. Failure mode 3 in the module
# docstring is exactly that.
GUIDANCE = (
    "Answer only from the sections returned here. If they do not actually cover what was asked, "
    "say so plainly and point the user at the right contact instead of guessing or searching the "
    "web: support@memorion.me for feedback and problems, team@memorion.me for repair, warranty, "
    "returns and exchanges. Never invent prices, warranty terms, or specs."
)


@dataclass(frozen=True)
class ManualSection:
    id: str
    title: str
    keywords: tuple
    body: str


def _parse(text: str) -> List[ManualSection]:
    sections = []
    for m in _SECTION_RE.finditer(text):
        keywords = tuple(
            k.strip().lower() for k in m.group("keywords").split(",") if k.strip()
        )
        sections.append(
            ManualSection(
                id=m.group("id"),
                title=m.group("title").strip(),
                keywords=keywords,
                body=m.group("body").strip(),
            )
        )
    return sections


@lru_cache(maxsize=1)
def load_sections() -> List[ManualSection]:
    """Parse the manual once per process. An unreadable manual is not fatal."""
    try:
        text = MANUAL_PATH.read_text(encoding="utf-8")
    except OSError:
        logger.exception("product manual unreadable at %s", MANUAL_PATH)
        return []
    sections = _parse(text)
    if not sections:
        logger.error("product manual parsed to zero sections at %s", MANUAL_PATH)
    return sections


def _score(section: ManualSection, needle: str) -> tuple:
    """(distinct keywords matched, total matched keyword length) for `needle`.

    Two components because the counts tie constantly: "维修保修" and "怎么维修" both
    match one keyword of `device-troubleshooting`, but a question that matches
    both "维修" and "保修" is more clearly about that section. Length breaks the
    remaining ties toward the more specific keyword — "delete account" should not
    lose to a section that merely matched "delete".
    """
    matched = [k for k in section.keywords if k in needle]
    # The heading itself is a free keyword; some questions quote it verbatim.
    title = section.title.lower()
    if title and title in needle:
        matched.append(title)
    return (len(matched), sum(len(k) for k in matched))


def lookup(query: str, limit: int = DEFAULT_SECTION_LIMIT) -> dict:
    """Return the manual sections most relevant to `query`.

    ``{"sections": [{"id","title","content"}], "guidance": str}`` on a hit;
    on a miss the section list is empty and ``available_topics`` lists what the
    manual *does* cover, so the model can offer a nearby answer rather than
    inventing one.
    """
    sections = load_sections()
    capped = max(1, min(limit or DEFAULT_SECTION_LIMIT, MAX_SECTION_LIMIT))
    needle = (query or "").lower()

    scored = [(s, _score(s, needle)) for s in sections]
    hits = sorted(
        (pair for pair in scored if pair[1][0] > 0),
        key=lambda pair: pair[1],
        reverse=True,
    )[:capped]

    if not hits:
        return {
            "sections": [],
            "available_topics": [{"id": s.id, "title": s.title} for s in sections],
            "guidance": GUIDANCE,
        }

    return {
        "sections": [
            {"id": s.id, "title": s.title, "content": s.body} for s, _ in hits
        ],
        "guidance": GUIDANCE,
    }
