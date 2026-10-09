# Design

## Context

See proposal.md for the motivation and `specs/model-catalog` and `specs/model-provisioning` for the required behavior.

- **Models today.** `App/Resources/ModelManifest.json` lists exactly one model per role. `ModelStore` (Core) downloads, verifies and tracks them. `FileModelFiles.removeUnlisted(keeping:)` runs on every `refresh()` and deletes any model the manifest no longer lists. `ServiceFactory` picks the first manifest entry of each role.
- **Services are built once.** `AppModel.build(for:)` creates `CoreServices` only while `core == nil`, then the library, chat and source view models from it. Nothing tears them down. `ChatService` is attached once `canChat` holds.
- **The embedder is hard-coded to EmbeddingGemma 2.** `LiteRTEmbedder` has a static `modelIdentity` (`embeddinggemma-2-text-vision-440m@1/256`), the documented prompt templates, `maxInputLength = 512` and `outputSize: 256`. `Chunker(configuration: .embeddingGemma2)` sets the chunk sizes. `RetrievalConfiguration` holds `maxDistance`, `imageMaxDistance` and `textToImageMaxDistance`, all tuned for this model by the retrieval and photo evaluations.
- **Switching embedders already works at the data level.** `CouchbaseSchema` rebuilds a vector index when its recorded dimension changes. `IngestionService.reindexOutdated(for:)` re-queues every document embedded by another identity, and vector search skips vectors with a foreign model tag. This is how the E4B to E2B and EmbeddingGemma 300M to 2 updates were shipped.
- **Cancellation hooks exist.** `ChatViewModel.stopAndWait()` stops and saves a partial answer. Interrupted ingestion jobs resume where they stopped. `ServiceFactory.unloadModels()` frees both engines.
- **Runtime.** LiteRT-LM v0.18.0 (vendored `LiteRTLMKit`). `ModelInfo(modelPath:)` reports `modelType()`, `minRuntimeVersion`, `maxContextTokens()`, `inputModalities` and, for embedders, `embedding?.dimension()`. It needs the whole file on disk.
- **What exploration found about Hugging Face and the file format:**
  - `GET https://huggingface.co/api/models?author=litert-community&search=…` lists repositories. `pipeline_tag` is missing on most, so it cannot tell an LLM from an embedder.
  - `GET /api/models/<repo>?blobs=true` gives each file's `size` and `lfs.sha256`, plus `gated` and `cardData.license`.
  - `resolve/main/<file>` honours `Range` (HTTP 206).
  - A `.litertlm` file starts with the magic `LITERTLM`, a major/minor/patch format version (Gemma 4 E2B 1.5.0, EmbeddingGemma 2 1.7.0), and a flatbuffer section table within the first ~2 KB. Section names show the type: an LLM has `tf_lite_prefill_decode`, an embedder `tf_lite_text_encoder`. A `tf_lite_vision_encoder` section means images are supported. The minimum runtime version is not in the table. It is likely in a metadata section that the table points to, but this is unverified.
- **About** is a sheet opened from the library toolbar (`LibraryView`), with a fixed list of the two models.

## Goals / Non-Goals

**Goals:**
- One place (`ModelStore`) owns what is installed, what is active, and every download, whether the model came from the manifest, the catalog or a search.
- Everything that is specific to an embedding model lives in one value (an embedder profile), so a second embedder is data, not code.
- Changing the active model reuses the cold-start path (build services from the active selection), not a separate hot-swap path.

**Non-Goals:**
- Any model source other than `litert-community` on Hugging Face.
- Signing in to Hugging Face, or gated repositories.
- A remotely updated catalog. The catalog ships in the app.
- Per-model settings for language models (sampler, context size, backend). The app's current values apply to all.
- Running two language models or two embedders at once, or comparing them side by side.
- Multi-file (zip) models found by search. Search offers single `.litertlm` files only.

## Decisions

### D1. Embedder profiles carry everything model-specific

A new `EmbedderProfile` value in Core holds (it cannot live in Ports: it holds `ChunkerConfiguration` and the retrieval distances, which are Core types, and Ports does not depend on Core. Adapters already depends on Core, so `LiteRTEmbedder` can take it):
- the identity (id, version, dimension),
- the query and chunk prompt templates,
- `maxInputLength` and the output size,
- the `ChunkerConfiguration`,
- the three relevance distances (text, photo to photo, words to photo),
- `supportsImages`.

The profile also builds the prompt text for a question or a passage. For EmbeddingGemma 2 it is made from the constants the app had before (`ChunkerConfiguration.embeddingGemma2` and the defaults of `RetrievalConfiguration`), and a test keeps the bundled catalog entry equal to it.

`LiteRTEmbedder.init` takes a profile, and its identity, prompts, options and the dimension check come from it. `ServiceFactory` builds the `Chunker` and the `Retriever` configuration from the same profile.

The built-in embedder catalog (`App/Resources/EmbedderCatalog.json`) is a list of `ModelSpec` and profile pairs. EmbeddingGemma 2 Text Vision 440M is its first entry, with today's constants moved into it unchanged. The default embedder in the manifest refers to a catalog entry by id.

*Alternative:* derive the profile from `ModelInfo` (the dimension) and use generic prompts. Rejected: prompts and thresholds decide retrieval quality and cannot be read from the file. A model with the wrong prompt format passes every runtime check and still retrieves poorly.

### D2. Which embedders go into the catalog is decided by evaluation

Any embedder other than EmbeddingGemma 2 is listed only after the existing retrieval evaluation (`EvalRunner`, and the photo evaluation for models with images) has:
- settled its prompts and thresholds,
- met the current recall baseline.

Candidates found on `litert-community` are `embeddinggemma-2-740m` and `embeddinggemma-2-text-270m`, and the second is text-only. If none passes, the catalog ships with one entry. The Models page, activation and re-index logic still apply to language models, and the catalog is ready for a second entry.

Pass criteria, fixed before the evaluation runs (the existing baselines in `hybrid-retrieval` and `image-search`):
- Text retrieval: the expected chunk is in the top 6 for at least 85% of the questions.
- Relevance threshold: one exists that both lets every answerable question through and refuses every unanswerable one. Its value becomes the profile's `maxDistance`.
- Photos (only for models with images): top-3 recall of at least 80% for photo queries and at least 70% for text queries. Their tuned thresholds become the profile's `imageMaxDistance` and `textToImageMaxDistance`.
- A text-only candidate is judged on text retrieval alone, and its profile has `supportsImages = false`.

**Results (task 7.1; full tables in `evaluations/embedder-candidates.md`).** Both candidates pass. The 270M and the 740M gave the same text results as the shipped 440M to three decimals (recall@6 100%, answerable at most 0.239, off-topic from 0.323, every threshold from 0.24 to 0.32 separates perfectly), which fits the main model card: the three are one model with different encoders loaded. The 740M's photo results are also identical to the 440M's (photo to photo top-3 0.86, words to photo 1.00). So both enter the catalog with the shipped prompts, chunk sizes and distances. The evaluation also found that `LiteRTEmbedder` could not load a text-only model; that is fixed.

### D12. Embedders found by search are untested, and get generic settings

Search also returns embedding models (the header says which kind a file is), and any of them can be downloaded and used. A file cannot say how it should be prompted or where its distances separate a match from a poor one, so such an embedder gets a *generic* profile built after download from what the runtime reads from the file: `EmbeddingDescription` (the vector size it reports, whether it takes images, and an input length it supports) stored in the model's record. The profile has empty prompt templates, the file's own vector size as both dimension and output size (a truncation is only safe for models trained for it), chunk sizes chosen for the input length, and the distances the app ships with. The page, the confirmation and the model's row say it is untested. Switching back re-indexes, as for any switch.

The relevance distances are the weak point: they are tuned per model, and the shipped ones may refuse every question or accept every one on another model. That is why the app says so before and after, and why switching back is cheap to explain. Calibrating them automatically is not part of this change.

*Alternative:* keep embedders to the built-in list. Rejected by the user: it keeps the page from being a way to try a model the app has not seen.

### D3. Installed, active and default are three separate facts

- **Installed:** files on disk, as today, under `<id>/<version>/`. Each installed model also gets a small `model.json` sidecar with its `ModelSpec`, source (`manifest`, `catalog` or `search`), repository and licence. That way search results do not have to be found again offline.
- **Active:** `ActiveModels { embedder: String?, generator: String? }`, persisted in Application Support. `nil` means "follow the manifest default".
- **Default:** the manifest entry for the role.

`ModelStore` gains:
- `installedModels()`: read from the sidecars and the manifest,
- `activeSpec(for:)`,
- `activate(_:)`,
- `delete(_:)`, which refuses the active model,
- `install(_:)`, which takes any `ModelSpec`, not just manifest ids.

Readiness (`canImport`, `canChat`) is computed from the **active** spec of each role, so the existing staged-readiness behaviour and setup screen work unchanged.

`removeUnlisted` becomes `removeAbandoned`. It deletes a model only when the model has no sidecar marking it user-installed and it is not the active or default model. This keeps the "a replaced default never leaves gigabytes behind" behaviour.

*Alternative:* add search results to a mutable copy of the manifest. Rejected: it mixes "what the app ships" with "what this device has", and an app update would have to merge the two.

### D4. Search, header probe and validator are three ports

- `ModelSearching`: `search(_ text) async throws -> [ModelCandidate]`. The adapter calls the Hugging Face API with `URLSession`, keeps only non-gated repositories, then fetches `?blobs=true` per result to read each `.litertlm` file's size, `lfs.sha256` and licence. Files without `lfs.sha256` are dropped.
- `ModelHeaderProbing`: `probe(_ url) async throws -> ModelHeader`. It makes one `Range: bytes=0-65535` request and parses the magic, the format version and the section table to get `kind` (`llm`, `embedder` or `unknown`) and `supportsImages`. It may also read `minRuntimeVersion` if D5 finds where it is stored.
- `ModelValidating`: `validate(file, spec) throws -> ModelDescription`. It wraps `ModelInfo`, then checks the type against the role, `minRuntimeVersion` against the bundled runtime (`0.18.0`), and `maxContextTokens()` against the generator's 4096. For embedders it also checks that the file can produce the profile's output size: the file reports its largest output (768 for EmbeddingGemma 2), and the profile asks for a truncation of it (256).

`ModelStore.install` runs the validator after the checksum and before `files.install`. On failure the file is discarded and the state becomes `.failed(reason)`.

The probe reads the header bytes itself, because the C API needs a complete file. It checks the `LITERTLM` magic, the format version (a major version other than 1 gives `unknown`) and the header size, then looks for the section names inside the header: `tf_lite_prefill_decode` means a language model, `tf_lite_text_encoder` an embedder, `tf_lite_vision_encoder` image support. It does not parse the flatbuffer: the names are what identifies a section, and a reader for the table would be more code for the same answer. Revisit if a later format version changes the names; until then such a file reads as `unknown`.

*Alternative:* the `swift-huggingface` package, which is in `.build` as a leftover. Rejected: the app needs two endpoints. A dependency adds weight and network behaviour the offline audit would have to cover.

### D5. Reading the minimum runtime version early is a timeboxed spike

One task, gated like the earlier spikes (`RUN_SPIKES=1`), follows the section table to the metadata section of a few real files with a second range request, and looks for the minimum runtime version. If it works within the timebox, `ModelHeader.minRuntimeVersion` is filled and the page can mark incompatible files before download. If not, the page marks such files "checked after download", as the spec allows, and the validator (D4) remains the gate. The specs hold either way.

**Result of the spike (task 3.4).** Neither local file declares a minimum runtime version. `ModelInfo.minRuntimeVersion` is `nil` for Gemma 4 E2B (LiteRT-LM format 1.5.0) and for EmbeddingGemma 2 (format 1.7.0), and no version string appears in the first 64 KB of either. The probe therefore leaves `minRuntimeVersion` nil, and until a file declares one, the runtime check after download (`LiteRTModelValidator`) is the only runtime gate. The "Needs a newer version of the app" path is covered by a unit test of the version comparison, not by a real file. The spike is `Packages/Adapters/Tests/AdaptersTests/MinRuntimeVersionSpikeTests.swift`, run with `RUN_SPIKES=1`.

### D6. Memory fit is a size rule

A candidate is "too large" when its file size exceeds 45% of `ProcessInfo.physicalMemory`. On an 8 GB iPad that is about 3.6 GB: Gemma 4 E4B (3.66 GB) is borderline and 12B or larger is excluded. The fraction is one constant, and it is tuned on a real device (see Open Questions).

*Alternative:* `os_proc_available_memory()`. Rejected for this check: it changes from moment to moment and depends on what else is loaded, so the same model would be offered or refused at random.

### D7. Activation rebuilds the services through the cold-start path

`AppModel` gains `switchModel(to:)`:
1. `chat.stopAndWait()`.
2. `IngestionService.stop()` ends the run loop and waits for it. The loop runs in a task of its own that `stop()` can cancel, because runs are started from several places (library import and delete, reset, background indexing), so `AppModel` could not hold one task. The caller's own cancellation still ends the loop, as before.
3. `factory.unloadModels()`.
4. `store.activate(id)`, which persists the selection.
5. For a language model: drop `chatService` and let `buildServices` attach a new one.
6. For an embedder: drop `core`, `library`, `chat` and `source`, close the library database (so the next one opens with the new vector size), then call `buildServices`. That builds `CoreServices` from the new profile and runs `reindexOutdated` as it already does.
7. Indexing that was stopped carries on.

A model is only kept if it loads. `buildServices(verifyChat: true)` loads the language model at once (at launch it still loads at the first question), and `makeCore` already warms up the embedder before it touches the database. If either fails, the previous selection is restored and the error is thrown.

The X-ray and explorer get the new repository through the same assignments as at launch.

The confirmation's document count is `repository.documentIDs(notEmbeddedBy:)` for the new identity, which is every searchable document. The same query `reindexOutdated` uses.

*Alternative:* swap the embedder inside a running `CoreServices`. Rejected: the retriever, ingestion, image search and chunker all hold the embedder or its profile. A rebuild is the path every launch already tests.

### D11. A job started by another model starts over

An `IngestJobRecord` remembers the tag of the embedding model that made the vectors written so far (`embeddingModel`). When a job is processed and another model is installed, it starts a new generation from the first chunk instead of resuming at `nextOrdinal`. Without this, a document interrupted under one embedder and resumed under another would hold vectors of two models in one generation. Activating the new generation removes the abandoned one, as for any re-index. The same applies after an app update that changes the embedder, which had the same gap.

*Alternative:* have the switch re-index every document with unfinished work. Rejected: it only covers switches made in the app, and the job is the thing that knows which model started it.

### D8. Photo search follows the active profile

`CoreServices.supportsPhotos` already gates the photo button. It becomes `profile.supportsImages`, and the button gives way to an explanation that names the active embedder. When the profile has no images the factory builds ingestion and retrieval without image features: images are not embedded, text-to-photo retrieval is off, and a photo is refused at import (it used to be accepted and fail later, which left a failed document behind). A photo document that is already in the library cannot be re-indexed without an image model, so it keeps its old vectors: search skips them because they belong to another model, and they are valid again when a model with photos is back.

### D9. Settings is a sheet next to About

A Settings button in the library toolbar opens a sheet with one "Models" section for now. Its rows are installed models grouped by role, then "Available embedders" from the catalog and "Find language models" (search field and results). It is backed by a `ModelSettingsViewModel` over `ModelStore` and the two search ports, in the same style as `ModelSetupViewModel`. About reads installed models from `ModelStore` instead of its fixed list.

### D10. Network use in Settings is labelled, not hidden

The X-ray's network indicator stays as it is. Requests from Settings go through a `URLSession` that the tracer labels "model search" or "model download", so a demo shows they come only from the user's action. The UI test for "no outbound traffic during core use" keeps running without opening Settings.

## Risks / Trade-offs

- [The header format changes in a later `.litertlm` version] → The probe returns `unknown` for an unknown major version or when no known section name is found. The page then offers the file as "checked after download", and the validator still decides.
- [A search result's licence is missing or not permissive] → Show the licence string as stated and link the repository. No licence filtering beyond what the repository declares. The About screen lists it.
- [`lfs.sha256` can describe a file that changes later on `main`] → The checksum is read at the moment of download and stored in the sidecar. A changed file fails verification and can be retried.
- [Re-indexing a large library takes a long time on the new embedder] → The confirmation names the count. Keyword search keeps working, and background indexing (`BGProcessingTask`) continues it.
- [The size rule is wrong for some models: mixture-of-experts, or models with large unused audio sections] → It is a rough filter by design. The engine failing to load is still caught at activation: the app reports it and keeps the previous model active.
- [Activating a language model that loads but fails at runtime (for example, out of memory)] → `switchModel` keeps the previous active id until the new engine has loaded once. On failure it restores the previous selection and shows the error.
- [The catalog has only one embedder for a while] → Acceptable. Language model choice is most of the value, and the profile refactor is needed before any second embedder.

## Migration Plan

- First launch after the update: no `ActiveModels` file exists, so both roles follow the manifest defaults. Installed files get a sidecar with source `manifest`. Nothing is re-indexed, because the embedder identity is unchanged.
- `removeAbandoned` sees the same files as `removeUnlisted` did. On existing installs both models are defaults, so nothing is deleted.
- Rollback: an older build ignores sidecars and `ActiveModels`, and its `removeUnlisted` deletes user-installed models. Documents and chats are kept, but they are re-indexed if the active embedder was different. This is acceptable for a development build.

## Open Questions

- The memory fraction in D6 (45%) is tuned once on the smallest supported iPad with Gemma 4 E4B loaded next to the embedder.
- Whether E4B appears in search as "too large" or as allowed on 8 GB iPads follows from that tuning. It does not change the specs.
