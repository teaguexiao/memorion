# Backend model configuration

`llm_models.json` is the source of truth for default model tiers, explicit
legacy-model replacements, inference parameters, and the benchmark fallback
judge panel. 
- `schema_version`: configuration format version (currently 1).
- `version`: release identifier; bump it whenever configuration changes.
- `providers`: each provider's complete tier-to-model mapping.
- `replacements`: mappings for older model IDs, including model IDs stored in
  transcript cleaner settings.
- `model_parameters`: provider/model-specific inference settings. Credentials and
  API base URLs cannot be supplied here.
- `models_without_temperature`: model-name fragments whose sampling parameters
  must be omitted.
- `benchmark_default_judges`: fallback only. Explicit evaluator configurations,
  historical runs, and models selected for comparison retain their original IDs.
- `chapter_rollup`: generation and factual-review tier names, resolved through
  the selected provider's mappings.
