"""Text embeddings for conversation retrieval.

Runs on Vertex AI `gemini-embedding-001`. Picked over the alternatives after
testing four GCP models against the real production corpus (mostly Chinese):
it was the only one that hit 5/5 on the probe questions, and it is the only
GCP model that emits 3072 dimensions, which is what the existing Pinecone
index was built for. `text-embedding-005` scored 1/5 — it is English-only,
despite the higher version number.

Two things callers must respect:

**Task type is not cosmetic.** Documents and queries live in slightly
different subspaces, so a document embedded as a query (or vice versa) loses
real precision. Use `generate_embedding_document` when writing and
`generate_embedding_query` when searching. There is deliberately no
`generate_embedding` here — the old single function let both paths share one
task type by accident.

**The model silently truncates past 2048 tokens.** No exception, HTTP 200,
`statistics.truncated = True` on the response. Production conversations top
out around 1560 characters today, but `Structured.overview` is prompted for
"minimum 1000 words" with no cap, so this will bite eventually. Every
function here returns the flag, and `EmbeddingResult.__len__`/indexing keep
the vector usable without unpacking.
"""

import json
import logging
import os
from dataclasses import dataclass
from typing import List, Optional

logger = logging.getLogger(__name__)

# Aligned with the LLM_PROVIDER switch in clients.py.
EMBEDDING_PROVIDER = os.environ.get('EMBEDDING_PROVIDER', 'vertex')

EMBEDDING_MODELS = {
    'vertex': 'gemini-embedding-001',  # 3072 dims, selected
}

# The index dimension. gemini-embedding-001 defaults to 3072 and supports
# 1536/768 via output_dimensionality; changing this means rebuilding the index.
EMBEDDING_DIMENSION = 3072

# Hard limit of gemini-embedding-001. Past this the input is silently cut.
EMBEDDING_MAX_TOKENS = 2048

GOOGLE_CLOUD_PROJECT = os.environ.get('GOOGLE_CLOUD_PROJECT')
GOOGLE_CLOUD_LOCATION = os.environ.get('GOOGLE_CLOUD_LOCATION', 'us-central1')

_client = None


@dataclass
class EmbeddingResult:
    """A vector plus whether the input was silently truncated."""

    values: List[float]
    truncated: bool = False
    token_count: Optional[int] = None

    # Callers that only want the vector can treat this as the list it wraps,
    # so switching to this type doesn't ripple through every call site.
    def __len__(self):
        return len(self.values)

    def __iter__(self):
        return iter(self.values)

    def __getitem__(self, item):
        return self.values[item]


def _get_client():
    """Vertex AI client, built once. Same credential path as image_generation."""
    global _client
    if _client is None:
        from google import genai

        credentials = None
        if os.environ.get('SERVICE_ACCOUNT_JSON'):
            from google.oauth2 import service_account

            service_account_info = json.loads(os.environ['SERVICE_ACCOUNT_JSON'])
            credentials = service_account.Credentials.from_service_account_info(
                service_account_info, scopes=['https://www.googleapis.com/auth/cloud-platform']
            )
        _client = genai.Client(
            vertexai=True,
            project=GOOGLE_CLOUD_PROJECT,
            location=GOOGLE_CLOUD_LOCATION,
            credentials=credentials,
        )
    return _client


def _embed(contents: List[str], task_type: str) -> List[EmbeddingResult]:
    from google.genai import types

    if EMBEDDING_PROVIDER not in EMBEDDING_MODELS:
        raise ValueError(f'Unknown EMBEDDING_PROVIDER: {EMBEDDING_PROVIDER}')

    response = _get_client().models.embed_content(
        model=EMBEDDING_MODELS[EMBEDDING_PROVIDER],
        contents=contents,
        config=types.EmbedContentConfig(
            task_type=task_type,
            output_dimensionality=EMBEDDING_DIMENSION,
        ),
    )

    results = []
    for embedding in response.embeddings:
        stats = embedding.statistics
        truncated = bool(stats and stats.truncated)
        token_count = int(stats.token_count) if stats and stats.token_count else None
        if truncated:
            logger.warning(
                'embedding input truncated at %d tokens (task_type=%s) — the tail was dropped',
                EMBEDDING_MAX_TOKENS,
                task_type,
            )
        results.append(
            EmbeddingResult(values=list(embedding.values), truncated=truncated, token_count=token_count)
        )
    return results


def structured_as_embedding_text(structured) -> str:
    """The canonical text to embed for a conversation's structured summary.

    Every path that writes a vector must go through this, because what gets
    embedded is `Structured.__str__` — a clean "Title (Category)\\nOverview"
    rendering — not the raw field dump. Stringifying the Firestore dict instead
    produces Python repr noise (`{'title': ..., 'category': <CategoryEnum...>}`)
    which measurably hurts ranking: on a real conversation, cosine against the
    matching query was 0.7230 for the dict form vs 0.7932 for the model form,
    and the two representations of identical content only agree at 0.8695.

    Accepts either a `Structured` model or the dict Firestore hands back.
    """
    if isinstance(structured, dict):
        from models.conversation import Structured

        try:
            structured = Structured(**structured)
        except Exception as e:
            # Better a slightly-off representation than no vector at all, but
            # say so — a systematic failure here would quietly split the index
            # into two incompatible text shapes.
            logger.warning('could not coerce structured dict to Structured (%s) — embedding the raw dict', e)
    return str(structured)


def generate_embedding_document(content: str) -> EmbeddingResult:
    """Embed text for storage. Use this on the write path."""
    return _embed([content], 'RETRIEVAL_DOCUMENT')[0]


def generate_embedding_query(query: str) -> EmbeddingResult:
    """Embed text for searching. Use this on the read path."""
    return _embed([query], 'RETRIEVAL_QUERY')[0]


def generate_embeddings_documents(contents: List[str]) -> List[EmbeddingResult]:
    """Batch variant of `generate_embedding_document`, for reindexing."""
    if not contents:
        return []
    return _embed(contents, 'RETRIEVAL_DOCUMENT')
