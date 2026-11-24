"""Guards for the embedding switch and the restored semantic retrieval.

Every failure mode pinned here was live in production, and each one failed
silently — no exception, no error log, just worse answers:

1. The retrieval graph queried Pinecone with `[1] * 3072`, a constant vector.
   Every stored vector is equidistant from it, so ranking was arbitrary and
   only the metadata filter did any work.
2. Embeddings ran on OpenAI, whose credits were exhausted. The failure was
   swallowed twice over, so the index went 36 days stale unnoticed.
3. Date extraction dropped anything after 2025 — in 2026 that is every date
   the user mentions.
4. Three of seven OpenRouter model tiers pointed at delisted ids.
5. `temperature` is rejected by some Claude models, and the clients are built
   at import time, so one unfiltered temperature takes the whole backend down
   on startup rather than failing a single request.

These are source-level assertions where a live call would need credentials.
That is deliberate: it keeps the guard meaningful in CI, where the mistakes
being prevented are re-introduced by editing exactly these lines.

Run:
    cd backend && python3 tests/test_embeddings_and_retrieval.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

BACKEND = os.path.join(os.path.dirname(__file__), "..")


def source(rel_path):
    with open(os.path.join(BACKEND, rel_path), encoding="utf-8") as f:
        return f.read()


def code_only(rel_path):
    """Source with comments and docstrings removed.

    Needed because several of these tests assert that a helper is *not* called,
    and the reason it isn't is explained in a nearby comment that names it.
    Matching raw text would flag the explanation as the offence.
    """
    import io
    import tokenize

    text = source(rel_path)
    kept = []
    previous_type = tokenize.INDENT
    try:
        tokens = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except tokenize.TokenError:
        return text
    for token in tokens:
        if token.type == tokenize.COMMENT:
            continue
        # A string is a docstring when it stands alone as a statement.
        if token.type == tokenize.STRING and previous_type in (
            tokenize.INDENT,
            tokenize.DEDENT,
            tokenize.NEWLINE,
            tokenize.NL,
        ):
            continue
        kept.append(token.string)
        if token.type not in (tokenize.NL, tokenize.COMMENT):
            previous_type = token.type
    return "\n".join(kept)


class ASemanticRetrievalIsActuallyUsed(unittest.TestCase):
    """Retrieval must rank by the query, not by a constant vector.

    ⚠️ These guards live in `agent_tools.py`, not `graph.py`. They used to read
    `graph.py`'s `query_vectors()`, but the P1 agent overhaul moved the Pinecone
    call into the `memory_search` tool and left `graph.py` as the agent loop only.
    The assertions kept passing/failing against a file that no longer contains
    the code they guard — i.e. the guard was silently pointed at nothing. If this
    moves again, follow `generate_embedding_query`, don't re-pin a filename.
    """

    def setUp(self):
        self.src = source("utils/retrieval/agent_tools.py")
        self.body = self.src.split("def memory_search(")[1].split("\n    @tool")[0]

    def test_question_is_embedded(self):
        embed_line = next(
            line for line in self.body.splitlines() if "generate_embedding_query(" in line
        )
        self.assertIn("vector =", embed_line)

    def test_no_constant_vector_on_the_query_path(self):
        # The original bug: Pinecone was queried with `[1] * 3072`, so every
        # stored vector was equidistant and only the metadata filter did any
        # work. There is no constant-vector path left at all now — a hardcoded
        # dimension anywhere in here means one has crept back.
        self.assertNotIn("[1] * 3072", self.src)
        self.assertNotIn("[1] * EMBEDDING_DIMENSION", self.src)

    def test_embedding_failure_does_not_kill_the_chat_turn(self):
        # Raising here would fail the whole turn. Returning no results merely
        # makes the agent answer without retrieval, which it can do.
        self.assertIn("except Exception", self.body)
        self.assertIn("logger.exception", self.body)
        self.assertIn('return {"results": []}', self.body)

    def test_query_embedding_is_not_commented_out(self):
        self.assertNotIn("#    generate_embedding(", self.src)

    def test_dead_openai_client_is_gone(self):
        # Unused, but it forced OPENAI_API_KEY at import time.
        for path in ("utils/retrieval/graph.py", "utils/retrieval/agent_tools.py"):
            self.assertNotIn("ChatOpenAI", source(path), path)


class AaLocalEnvMatchesProduction(unittest.TestCase):
    """Testing the chat path on the wrong library generation proves nothing.

    Production builds from `requirements.fargate.txt` (Dockerfile:11), but
    README/CLAUDE.md pointed at `requirements.txt`, which is a full generation
    behind on the langchain stack — langgraph 0.2.39 vs 1.0.7. Following the
    documented setup gave a local env that could not exercise what production
    runs.
    """

    PROD_REQUIREMENTS = "requirements.fargate.txt"

    def _pinned(self, name):
        for line in source(self.PROD_REQUIREMENTS).splitlines():
            if line.strip().startswith(f"{name}=="):
                return line.split("==", 1)[1].strip()
        return None

    def test_retrieval_stack_is_pinned_in_the_prod_manifest(self):
        # These are the packages the chat/retrieval path runs on. An unpinned
        # entry means the deployed version can move without a code change.
        for name in ("langgraph", "langchain-core", "langchain-aws", "google-genai"):
            self.assertIsNotNone(
                self._pinned(name), f"{name} is not pinned in {self.PROD_REQUIREMENTS}"
            )

    def test_installed_versions_match_production(self):
        # Skips rather than fails: CI may install a subset. The point is to
        # catch a *mismatch*, not to require every package be present.
        import importlib.metadata as md

        mismatches = []
        for name in ("langgraph", "langchain-core", "langchain-aws", "google-genai"):
            expected = self._pinned(name)
            try:
                actual = md.version(name)
            except md.PackageNotFoundError:
                continue
            if expected and actual != expected:
                mismatches.append(f"{name}: local {actual} != prod {expected}")
        if mismatches:
            self.fail(
                "local env differs from production — the chat path would be tested "
                "against a different library generation:\n  " + "\n  ".join(mismatches)
            )

    def test_stale_manifest_is_labelled(self):
        # requirements.txt cannot resolve as written (langchain-openai 0.2.3
        # needs core 0.3.x, langchain-google-genai>=4.2.0 needs >=1.4.7), so it
        # must at least warn the reader off.
        head = source("requirements.txt")[:2000]
        self.assertIn("requirements.fargate.txt", head)
        self.assertIn("NOT what production installs", head)


class AbRetrievalRankingSurvivesTheFirestoreFetch(unittest.TestCase):
    """Restoring semantic ranking is pointless if the next step discards it.

    `query_vectors` hands `get_conversations_by_ids` a list ordered by
    relevance, but `db.get_all` returns documents in whatever order the batch
    resolves — measured against production, a 4-id request came back with the
    4th id first, every time. Re-keying by id and re-emitting in the caller's
    order is what makes the restored ranking actually reach the answer.
    """

    def setUp(self):
        self.src = source("database/developer_data.py")
        self.body = self.src.split("def get_conversations_by_ids")[1].split("\ndef ")[0]

    def test_result_is_ordered_by_the_requested_ids(self):
        self.assertIn("for cid in conversation_ids", self.body)

    def test_it_does_not_return_fetch_order(self):
        # `[d for d in docs]` / `list(by_id.values())` both leak get_all's order.
        code = " ".join(
            line for line in self.body.splitlines() if not line.lstrip().startswith("#")
        )
        self.assertNotIn("list ( by_id . values", code.replace("(", " ( ").replace(")", " ) "))

    def test_missing_ids_are_skipped_not_crashed(self):
        # A vector can outlive its conversation (deleted, or discarded after
        # indexing); the id must drop out rather than raise a KeyError.
        self.assertIn("if str(cid) in by_id", self.body)


class BWriteAndReadPathsUseDifferentTaskTypes(unittest.TestCase):
    """Documents and queries embed into slightly different subspaces."""

    def setUp(self):
        self.src = source("utils/llm/embeddings.py")

    def test_both_task_types_exist(self):
        self.assertIn("RETRIEVAL_DOCUMENT", self.src)
        self.assertIn("RETRIEVAL_QUERY", self.src)

    def test_document_function_uses_document_task_type(self):
        body = self.src.split("def generate_embedding_document")[1].split("def ")[0]
        self.assertIn("RETRIEVAL_DOCUMENT", body)
        self.assertNotIn("RETRIEVAL_QUERY", body)

    def test_query_function_uses_query_task_type(self):
        body = self.src.split("def generate_embedding_query")[1].split("def ")[0]
        self.assertIn("RETRIEVAL_QUERY", body)
        self.assertNotIn("RETRIEVAL_DOCUMENT", body)

    def test_no_ambiguous_single_function(self):
        # A bare `generate_embedding` is what let both paths share one task
        # type by accident.
        self.assertNotIn("def generate_embedding(", self.src)

    def test_dimension_matches_the_index(self):
        from utils.llm.embeddings import EMBEDDING_DIMENSION

        self.assertEqual(EMBEDDING_DIMENSION, 3072)


class BbAllWritePathsEmbedTheSameTextShape(unittest.TestCase):
    """A reindex must not leave the index in a different text shape.

    What gets embedded is `Structured.__str__` — "Title (Category)\\nOverview" —
    not the raw field dump. Stringifying the Firestore dict instead yields
    Python repr noise, and it measurably ranks worse: 0.7230 vs 0.7932 cosine
    against the matching query on a real conversation. If the reindex script
    and the live write path disagree, every conversation written after a full
    reindex is embedded differently from the whole index behind it.
    """

    def test_dict_and_model_produce_identical_text(self):
        from models.conversation import Structured
        from utils.llm.embeddings import structured_as_embedding_text

        structured = Structured(title="T", overview="O", emoji="x", category="other")
        self.assertEqual(
            structured_as_embedding_text(structured),
            structured_as_embedding_text(structured.model_dump()),
        )

    def test_it_is_the_model_rendering_not_the_dict_dump(self):
        from models.conversation import Structured
        from utils.llm.embeddings import structured_as_embedding_text

        text = structured_as_embedding_text(
            Structured(title="T", overview="O", emoji="x", category="other").model_dump()
        )
        self.assertNotIn("'title'", text, "raw dict repr leaked into the embedded text")
        self.assertNotIn("CategoryEnum", text)
        self.assertIn("T (Other)", text)

    def test_a_malformed_dict_still_yields_text(self):
        # Better a slightly-off vector than no vector, but it must warn.
        from utils.llm.embeddings import structured_as_embedding_text

        self.assertTrue(structured_as_embedding_text({"unexpected": "shape"}))

    def test_every_embedding_call_site_goes_through_it(self):
        # Assert on what actually reaches the embedder, not merely that the
        # helper is imported somewhere — an import alone would let a raw str()
        # slip through unnoticed. `str(...)` of a structured value is the
        # specific mistake being guarded against, in either spelling.
        for path in ("utils/conversations/process_conversation.py", "scripts/reindex_vectors.py"):
            code = " ".join(code_only(path).split())
            self.assertIn("structured_as_embedding_text (", code, f"{path} never calls the shared serializer")
            for forbidden in (
                "str ( conversation . structured )",
                "str ( structured )",
                "str ( c [ 'structured' ] )",
            ):
                self.assertNotIn(
                    forbidden,
                    code,
                    f"{path} embeds {forbidden} directly instead of the shared serializer",
                )


class CTruncationIsReported(unittest.TestCase):
    """The model truncates past 2048 tokens with HTTP 200 and no exception."""

    def test_result_carries_the_flag(self):
        from utils.llm.embeddings import EmbeddingResult

        self.assertTrue(hasattr(EmbeddingResult, "truncated"))

    def test_result_is_usable_as_a_vector(self):
        # Call sites that only want the numbers shouldn't need to unpack.
        from utils.llm.embeddings import EmbeddingResult

        result = EmbeddingResult(values=[0.1, 0.2, 0.3])
        self.assertEqual(len(result), 3)
        self.assertEqual(result[0], 0.1)
        self.assertEqual(list(result), [0.1, 0.2, 0.3])

    def test_write_path_checks_the_flag(self):
        src = source("utils/conversations/process_conversation.py")
        self.assertIn("embedded.truncated", src)
        self.assertEqual(src.count("if embedded.truncated"), 2, "both write paths must check")


class DEmbeddingFailuresAreLoud(unittest.TestCase):
    """Two layers of silence are what hid a 36-day-stale index."""

    def setUp(self):
        self.src = source("utils/conversations/process_conversation.py")

    def test_dict_write_path_logs_a_traceback(self):
        handler = self.src.split("save_vector_from_dict failed")[1][:200]
        self.assertIn("traceback.print_exc()", handler)

    def test_every_thread_target_catches_exceptions(self):
        # A bare threading.Thread(target=save_structured_vector) discards
        # whatever the target raises. There are two such call sites — the
        # process_conversation path and the App-created-conversation path — and
        # missing either leaves half the writes silent.
        code = code_only("utils/conversations/process_conversation.py")
        normalised = " ".join(code.split())
        targets = [
            chunk.lstrip() for chunk in normalised.split("target =")
            if chunk.lstrip().startswith("save_structured_vector")
            or chunk.lstrip().startswith("_save_structured_vector_logged")
        ]
        self.assertEqual(len(targets), 2, f"expected 2 vector-writing threads, found {len(targets)}")
        for target in targets:
            self.assertTrue(
                target.startswith("_save_structured_vector_logged"),
                "a vector-writing thread still uses the unguarded target",
            )

    def test_failures_are_greppable(self):
        self.assertIn("[EMBEDDING] ERROR", self.src)


class EOpenAIIsFullyCutFromEmbeddings(unittest.TestCase):
    def test_clients_no_longer_imports_openai_embeddings(self):
        src = source("utils/llm/clients.py")
        self.assertNotIn("OpenAIEmbeddings", src)

    def test_chat_openai_class_is_kept(self):
        # OpenRouter reuses the ChatOpenAI class with its own base_url —
        # deleting it because of the name would break every LLM call.
        src = source("utils/llm/clients.py")
        self.assertIn("from langchain_openai import ChatOpenAI", src)
        self.assertIn("openrouter.ai", src)

    def test_vector_db_uses_the_new_query_function(self):
        src = source("database/vector_db.py")
        self.assertIn("generate_embedding_query", src)
        self.assertNotIn("embeddings.embed_query", src)


class FDatesAfterTwentyTwentyFiveSurvive(unittest.TestCase):
    """Today is 2026; a >2025 cutoff discards every date the user mentions."""

    def test_no_year_cutoff_in_code(self):
        src = source("utils/llm/chat.py")
        self.assertNotIn("date.year > 2025", src)

    def test_no_year_cutoff_in_prompts(self):
        src = source("utils/llm/chat.py")
        self.assertNotIn("Do not include dates greater than 2025", src)

    def test_registry_seed_matches_the_code(self):
        # The registry overrides the in-code fallback, so fixing only the
        # Python leaves production running the old prompt.
        src = source("scripts/benchmark/seed_prompts/chat.json")
        self.assertNotIn("Do not include dates greater than 2025", src)


class GModelTiersResolveToLiveModels(unittest.TestCase):
    def setUp(self):
        from utils.llm.clients import OPENROUTER_MODELS

        self.models = OPENROUTER_MODELS

    def test_delisted_ids_are_gone(self):
        delisted = {
            "openai/o1-preview",
            "google/gemini-flash-1.5-8b",
            "anthropic/claude-3.7-sonnet",
        }
        self.assertEqual(delisted & set(self.models.values()), set())

    def test_every_tier_is_mapped(self):
        expected = {
            "mini",
            "medium",
            "medium_experiment",
            "large",
            "high",
            "persona_mini",
            "persona_medium",
        }
        self.assertEqual(set(self.models), expected)

    def test_medium_tier_is_preserved_and_light_tier_migrates(self):
        self.assertTrue(self.models["medium"].startswith("anthropic/"))
        self.assertEqual(self.models["mini"], "openai/gpt-6-luna")
        self.assertEqual(self.models["medium_experiment"], "openai/gpt-6.1-sol")


class HSamplingParamsAreFilteredByModel(unittest.TestCase):
    """The Claude 5 generation dropped `temperature` / `top_p` / `top_k`.

    Bedrock rejects a non-default value outright
    (`ValidationException: temperature is deprecated for this model`);
    OpenRouter accepts the request and silently strips it. Both are wrong to
    send, and the Bedrock case is a hard failure.

    Testing with `temperature=1.0` proves nothing on either backend — 1.0 is
    the default, so it is accepted by models that have otherwise dropped the
    parameter. Production passes 0.8 on the persona tiers, which is the value
    that actually fails.
    """

    def test_the_whole_claude_5_generation_is_listed(self):
        from utils.llm.clients import MODELS_WITHOUT_TEMPERATURE

        for base in ("claude-sonnet-5", "claude-opus-5", "claude-fable-5"):
            self.assertIn(base, MODELS_WITHOUT_TEMPERATURE)

    def test_matching_is_by_base_model_not_provider_id(self):
        # The same model is spelled three ways: anthropic/claude-opus-5
        # (OpenRouter), global.anthropic.claude-opus-5 (Bedrock inference
        # profile), anthropic.claude-opus-5 (Bedrock direct). An exact-match
        # set silently misses two of them.
        from utils.llm.clients import _model_accepts_temperature

        for spelling in (
            "anthropic/claude-opus-5",
            "global.anthropic.claude-opus-5",
            "anthropic.claude-opus-5",
            "global.anthropic.claude-sonnet-5",
        ):
            self.assertFalse(
                _model_accepts_temperature(spelling), f"{spelling} should be filtered"
            )

    def test_models_that_still_accept_it_keep_it(self):
        # Historical models still accept sampling; their runtime replacements
        # have separate capability entries in the versioned configuration.
        from utils.llm.clients import _model_accepts_temperature

        for spelling in (
            "anthropic/claude-haiku-4.5",
            "global.anthropic.claude-haiku-4-5-20251001-v1:0",
            "openai/gpt-4.1",
            "gemini-3.5-flash-lite",
        ):
            self.assertTrue(
                _model_accepts_temperature(spelling), f"{spelling} should keep temperature"
            )

    def test_gpt_replacements_drop_sampling_parameters(self):
        from utils.llm.model_config import model_parameters

        for model in ('openai/gpt-6-luna', 'openai/gpt-6.1-sol', 'global.openai.gpt-6-luna'):
            parameters = model_parameters(model, temperature=0.8, top_p=0.9, top_k=20)
            self.assertTrue({'temperature', 'top_p', 'top_k'}.isdisjoint(parameters))

    def test_streaming_clients_drop_it_where_unsupported(self):
        # These four pass temperature at import time.
        import utils.llm.clients as clients

        for name in (
            "llm_large_stream",
            "llm_high_stream",
            "llm_persona_mini_stream",
            "llm_persona_medium_stream",
        ):
            client = getattr(clients, name)
            model = getattr(client, "model_name", None) or getattr(client, "model_id", "")
            if not clients._model_accepts_temperature(model):
                self.assertIsNone(
                    getattr(client, "temperature", None),
                    f"{name} kept a temperature {model} no longer accepts",
                )


class IPineconeQueryDegradesInsteadOfFailing(unittest.TestCase):
    """top_k=10000 with metadata can cross Pinecone's 4MB response cap."""

    def setUp(self):
        self.src = source("database/vector_db.py")

    def test_query_is_wrapped(self):
        body = self.src.split("def query_vectors_by_metadata")[1]
        self.assertIn("try:", body)
        self.assertIn("except Exception", body)

    def test_it_retries_smaller_rather_than_giving_up(self):
        self.assertIn("attempt_top_k", self.src)

    def test_ladder_never_grows_beyond_the_request(self):
        # A naive (top_k, top_k // 4, 100) ladder retries *larger* when the
        # caller asked for top_k=20.
        self.assertIn("if 0 < k <= top_k", self.src)

    def test_a_total_failure_returns_empty_not_none(self):
        body = self.src.split("def query_vectors_by_metadata")[1]
        self.assertIn("if xc is None:", body)


class JReindexScriptSeesEveryRecord(unittest.TestCase):
    """The obvious helpers both under-count, each for a different reason."""

    def setUp(self):
        # Code only — both helpers are named in the docstrings that explain
        # why they are avoided.
        self.code = code_only("scripts/reindex_vectors.py")

    def test_it_does_not_use_get_users_list(self):
        # get_users_list orders by created_at, and Firestore omits documents
        # missing the ordering field — 28 of 137 users, holding most vectors.
        self.assertNotIn("get_users_list", self.code)
        self.assertIn("list_documents", self.code)

    def test_it_does_not_use_get_conversations(self):
        # get_conversations limits in Firestore but filters `discarded` in
        # Python afterwards, so paginating on top of it loses records.
        self.assertNotIn("dev_db.get_conversations", self.code)

    def test_existing_metadata_is_preserved(self):
        # Only the vector is being replaced; re-extracting people/topics would
        # mean thousands of extra LLM calls.
        self.assertIn("_fetch_existing_metadata", self.code)

    def test_truncation_is_summarised(self):
        self.assertIn("truncated_detail", self.code)

    def test_progress_is_journalled_for_resume(self):
        self.assertIn("save_progress", self.code)
        self.assertIn("--resume", self.code)


if __name__ == "__main__":
    unittest.main(verbosity=2)
