# Design

## Context

The repository is empty apart from the OpenSpec scaffolding, so this is a greenfield app. The motivation and scope are in proposal.md, and the behavior contracts are in `specs/`. The constraints that shape the design:

- **Target**: M4/M5 iPads (8–16 GB RAM) on iPadOS 26 only. This makes Gemma 4 E4B and EmbeddingGemma feasible together, and makes iOS 26 Core ML conversions usable.
- **Offline**: models are downloaded once. Everything after that is on-device, and there is no server component.
- **Storage**: Couchbase Lite (CBL) **Enterprise Edition** with the Vector Search extension. In CBL vector search, an untrained index falls back to a full scan. Training needs at least as many vectors as centroids (about 10 per centroid is recommended, with centroids ≈ √N), and it can happen during the first `APPROX_VECTOR_DISTANCE` query after enough data exists.
- **Sync later**: documents and vectors will replicate in a future change, and v1 must not need a data migration for that.

## Goals / Non-Goals

**Goals:**
- A modular pipeline with swappable model runtimes behind narrow protocols.
- A deterministic, testable RAG core (chunking, fusion, gating, citation validation) that is independent of the models.
- A CBL schema that works unchanged when a replicator is added.
- Answer quality that is measurable through an evaluation harness from the start.

**Non-Goals:**
- Replication and sync, user accounts, or multi-user scoping (channels).
- iPhone, Mac Catalyst, or the "Designed for iPad" Mac target.
- Other formats (PPTX, XLSX, HTML, images), audio, or using Gemma 4's vision input.
- Choosing between models or runtimes at runtime. Exactly one model of each kind is installed.
- Summarizing whole documents, or questions that require reading all of a large document.

## Decisions

### D1. Architecture: layered modules in one Xcode project with local Swift packages

```
 App (SwiftUI)            LibraryView | ChatView | SourceViewer | ModelSetupView
   |
 Features                 IngestionService   ChatService   ModelStore
   |                           |                  |            |
 Core (pure Swift, tested)  Extractors  Chunker  Retriever  PromptBuilder
                                                 Fusion     CitationValidator
   |                           |                  |
 Ports (protocols)        Embedder     Generator      DocumentRepository
   |                         |             |               |
 Adapters                 CoreMLEmbedder  LiteRTGenerator  CBLRepository
                                          (or LlamaCppGenerator)
```

The Core code depends only on the protocols (Ports), which lets unit tests replace the models and the database with fakes: a deterministic fake embedder, a scripted generator, and an in-memory CBL database. *Alternative considered:* one app target containing everything. It's simpler, but the RAG logic becomes hard to test without models.

### D2. Embedding model: EmbeddingGemma 300M through Core ML, 768 dimensions, L2-normalized

The model uses the ANE-targeted iOS 26 Core ML conversion (int8, about 300 MB), which leaves the GPU free for the LLM. Inputs follow EmbeddingGemma's prompt templates: passages use `title: {doc title} | text: {chunk}`, and queries use `task: search result | query: {q}`. The dimension is fixed at **768**. At this corpus size the storage cost is negligible, and a fixed dimension keeps vectors compatible across future synced devices. The model's identity string (for example, `embeddinggemma-300m@<manifest version>/768`) is written to every chunk. *Alternatives:* MLX Swift embedders (these would compete with the LLM for the GPU), or a smaller Matryoshka dimension such as 256 (smaller vectors, but a locked-in quality loss for no real benefit here).

**Spike results (task 1.3, Apple M2 Pro host; iPad numbers still to add).** The Core ML conversion (`valindotai/embeddinggemma-300m-coreml`, Gemma license, not gated) takes a **fixed 256-token input** (`input_ids` int32 and `attention_mask` fp16, both `[1, 256]`) and returns a `[1, 768]` fp16 embedding with norm 1.0001; the app renormalizes in float32. The tokenizer (`tokenizer.json`, 33 MB) adds both `<bos>` and `<eos>`, so truncation must keep the final `<eos>`. Inference takes about **13 ms per text** on the Neural Engine. A relevant passage scored cosine 0.48 against 0.22 for an unrelated one, and a five-question mini-library ranked the right passage first every time. Two costs need UI states: the first inference after install takes **40-90 s** while Core ML specializes the model for the Neural Engine (repeated for a model at a new path), and loading the tokenizer takes about 4.5 s in a debug build, so it is loaded once and shared. The model is a directory, not a file, so it ships as a zip (see D10).

### D3. LLM runtime: Gemma 4 E4B (4-bit) behind a `Generator` protocol; spike LiteRT-LM vs llama.cpp

The `Generator` protocol exposes `generate(_ request:) -> AsyncThrowingStream<String>`; ending iteration or cancelling the task stops generation.

**Chosen: LiteRT-LM** (`gemma-4-E4B-it.litertlm`, 3.66 GB, Apache-2.0, not gated; SHA-256 `0b2a8980…52e0`), on its GPU (Metal) backend. Spike results (task 1.4, Apple M2 Pro host, macOS GPU backend; iPad numbers still to add): engine initialization 0.6-1.4 s; a realistic RAG prompt of six 180-token passages plus the system prompt (about 1.3k tokens) gives a **time to first token of 1.1 s**, decoding runs at **about 47 tokens/s**, and peak resident memory is about 0.85 GB (the model is memory-mapped). A 3k-token prompt takes 3.3 s to first token, which is why passages are capped at 200 tokens (D7). Streamed chunks are deltas. Stopping works instantly: `Conversation.cancel()` makes the stream end with a `CANCELLED` error, which the adapter treats as a normal stop. llama.cpp was not needed and is not evaluated.

Packaging findings: upstream's repository stores files in Git LFS and one object is missing at tag v0.17.1, so a normal SwiftPM checkout fails (it needs `git-lfs` and `GIT_LFS_SKIP_SMUDGE=1`). The Swift wrapper is therefore **vendored** as the local package `LiteRTLMKit`, with the prebuilt xcframeworks fetched from release assets by checksum. The vendored copy carries one patch: upstream's `Conversation.deinit` deletes the native session synchronously, which deadlocks when the native callback thread drops the last reference (any stopped request), so the delete runs on a background queue. Requests are served one at a time; each is a fresh conversation, so nothing leaks between questions. *Alternative:* Apple Foundation Models, rejected because the requirement is Gemma.

### D4. Couchbase Lite schema

One database containing the scope `manualbot`:

| Collection | Sync-ready | Key fields |
|---|---|---|
| `documents` | yes | `title`, `type`, `file` (blob), `pageCount`, `activeGeneration`, `importedAt`, `deleted` |
| `chunks` | yes | `docId`, `generation`, `ordinal`, `page?`, `heading?`, `text`, `embedding` [768 floats], `embeddingModel`, `dims` |
| `chats` | yes | `title`, `pinnedDocIds[]`, `createdAt`, `updatedAt` |
| `messages` | yes | `chatId`, `role`, `text`, `standaloneQuery?`, `citations[{n, chunkId, docId, docTitle, page?, heading?, snippet}]`, `stopped`, `createdAt` |
| `ingestJobs` | **local only** | `docId`, `targetGeneration`, `state`, `progress`, `nextOrdinal`, `error?` |

The document ID for a chunk is `"{docId}:{generation}:{ordinal}"`. This makes writes idempotent, so an ingestion that resumes after a crash overwrites chunks rather than duplicating them. Each citation stores a snapshot of the passage text so that citations to deleted documents still render (a grounded-chat requirement). *Alternative:* store vectors on a separate collection or outside CBL. That's rejected because CBL's vector index needs the vector on the indexed document, and future vector sync depends on it.

**Visibility rule (atomic availability):** retrieval only matches chunks where `generation == documents.activeGeneration` for a document that is ready and not deleted. Ingestion writes the chunks of a new generation first, then switches `activeGeneration` in a single document save, then purges the old generation. Re-indexing (keep the old set until the new one is ready) and all-or-nothing searchability both follow from this. The query can't express a join to `documents` efficiently, so the Retriever keeps an in-memory `docId → activeGeneration` map, refreshed from a live query on `documents`, and adds `docId`/`generation` predicates to the query.

### D5. Indexes

- **Vector index** on `chunks.embedding`: `dimensions: 768`, `metric: cosine`, `centroids: 64`, `encoding: SQ8`. For a personal library of 1k–20k chunks, 64 centroids is roughly √N at the low-to-mid range, and an untrained index still returns correct results by full scan. The index is recreated with more centroids only if the evaluation shows a need. Chunk writes are grouped with `database.inBatch`. After an import finishes, the app runs a warm-up vector query in the background so that index training doesn't land on the user's first question.
- **Spike findings (task 1.2):** Couchbase Lite EE 4.1.2 (`couchbase-lite-swift-ee`) and Vector Search 2.0.0 (`couchbase-lite-vector-search-spm`) both install through SPM as binary targets, so the vendored-XCFramework fallback isn't needed. The vector search framework has no Swift module: `Extension.enableVectorSearch()` comes from `CouchbaseLiteSwift`, and the package only has to be linked. `CouchbaseLiteSwift` exports its own `Result` type, which shadows `Swift.Result`. **Queries must pass the metric explicitly** (`APPROX_VECTOR_DISTANCE(embedding, $vector, "cosine")`), otherwise a cosine index rejects the query. The spike test passes on the macOS host and the iPad Pro M5 simulator. Verification on a physical M4 iPad is still outstanding.
- **Query shape (task 5.5):** a `WHERE` clause on either index query makes Couchbase Lite read every candidate row. At 20,000 passages an unfiltered `LIMIT 20` vector query pushes the limit into the index, while adding a `WHERE` (scope, generation or model) cost 330 ms and a full-text query went from 1 ms to 160-275 ms; scoped search reached a 1.3 s p95. Search therefore runs both index queries with no `WHERE`, fetches 3x the limit, and filters on the chunk ID (`docId:generation:ordinal`), the document's active generation, and the requested scope in Swift, retrying with a 4x larger window (up to 5,000) when too few survive. Measured p95 fell from 1,356 ms to 108 ms on an Apple Silicon host. The chunk ID format is therefore load-bearing and must not change without a migration.
- **Full-text index** on `chunks.text` (English stemming, with no diacritics sensitivity).
- **Value indexes** on `chunks.docId`, `chunks.generation`, `messages.chatId`, and `messages.createdAt`.

### D6. Extraction

| Type | Approach |
|---|---|
| TXT/MD | `String(contentsOf:usedEncoding:)`, falling back to UTF-8 lossy. Markdown `#` headings become heading provenance. |
| PDF | PDFKit `page.string` for each page. If a page returns fewer than about 20 non-whitespace characters, it's rendered at 2x and passed to Vision `RecognizeDocumentsRequest` / `VNRecognizeTextRequest` (accurate mode, language correction on). |
| DOCX | Unzip with ZIPFoundation, then stream-parse `word/document.xml` with `XMLParser`. `w:p` is a paragraph, `w:pStyle` Heading*/Title marks headings, and the `w:tbl` → `w:tc` cells are written out row by row as "cell \| cell". The source viewer renders the extracted paragraphs, not the original DOCX layout. |

Extractors output a common `[Block(text, page?, heading?, kind)]` stream.

### D7. Chunking

The chunker is a pure function over blocks. It targets about 180 tokens per chunk (maximum 200, overlap 30, tails under 45 merged), measured with the embedding model's own tokenizer, so a chunk plus the passage template (title capped at 60 characters) and `<bos>`/`<eos>` always fits the 256-token input from D2 without truncation. It splits first on block boundaries, then on sentences. It never crosses a PDF page, and it carries the last seen heading forward. Tiny trailing chunks get merged into the previous chunk. *Alternative:* fixed character windows. That's simpler, but it cuts sentences apart and hurts citation quality.

### D8. Retrieval pipeline

```
 standalone query
    |--> embed (query template) --> APPROX_VECTOR_DISTANCE top 20  (scope + generation filters)
    |--> FTS MATCH top 20        (same filters)
    v
 Reciprocal Rank Fusion (k = 60) --> dedupe --> top 6
    v
 relevance gate: pass if best cosine distance <= T_vec  OR  top FTS hit is exact token match
    v
 RetrievalResult { passages[<=6], relevant: Bool, closest[<=3] }
```

T_vec is a cosine distance. **Tuned in task 6.3** on the evaluation set (31 questions over six documents in Markdown, text, DOCX, text PDF and a scanned PDF, 25 answerable and 6 not): with the real embedder, recall@6 is 100% (25/25), the farthest answerable question is at 0.66 and the nearest off-topic one at 0.87, and every threshold from 0.68 to 0.86 answers all 25 and refuses all 6 (at 0.90 only half of the off-topic questions are refused). The default is **0.76**, in the middle of that range. A larger or more homogeneous library (say, thirty near-identical manuals) will crowd the distances, so the harness should be rerun when the corpus changes; it is deterministic and takes seconds. Small hand-written suite, so treat 100% as a regression guard, not a measurement of real-world accuracy.

### D9. Grounded generation

1. **Rewriting:** when the chat has previous turns, a short Gemma call (max 64 tokens, temperature 0) rewrites the last user message into a standalone query using the last 3 exchanges. The first message in a chat skips this step. The rewritten query is stored on the message.
2. **Retrieval** as in D8. If `relevant == false`, the app returns the not-found response immediately without calling the LLM.
3. **Prompt:** the system prompt says to answer only from the numbered passages, cite each claim as `[n]`, and output exactly `NOT_FOUND` if the passages don't answer the question. It's followed by the numbered passages (`[n] (Title, p. X) text`) and then the question. Chat history is *not* included in the answer prompt, only in the rewrite prompt. This keeps prefill short and keeps earlier answers from being treated as sources.
4. **Streaming** goes through `AsyncThrowingStream`, and the UI renders the text incrementally. When the output starts with `NOT_FOUND`, the app suppresses it and switches to the not-found response.
5. **Validation** after the stream finishes (or is stopped): the app parses the `[n]` markers, drops any `n` that wasn't supplied, and builds the citation list. If no valid markers remain, it replaces the answer with the not-found response and its closest passages.

Sampling uses temperature 0.2 and at most 512 output tokens.

### D10. Model provisioning

`ModelManifest.json` is bundled with the app and lists `{id, version, url, bytes, sha256, role}` for each model. `ModelStore` downloads through a background `URLSession` and keeps resume data. It verifies each file by streaming a SHA-256 over it, moves the file into `Application Support/Models/<id>/<version>/`, and sets `isExcludedFromBackup`. A model is a single file, a zip archive, or **bundled** (`packaging` in the manifest). The embedding model is bundled: it ships in the app's resource folder at `BundledModels/<id>/`, is reported installed from the first launch, and is never downloaded (a missing one is reported as a broken install, not fetched). Only the language model is downloaded. Bundling removes the hosting question, the zip step and the multi-file manifest for the embedder, at the cost of about 340 MB of app size, tying model updates to app releases, and repeating the Neural Engine specialization (40-90 s) after an install or update, which I expect but have not measured. The weights are not stored in git: `scripts/fetch-embedder.sh` fetches them from a pinned commit of the public Core ML conversion and verifies every file against `scripts/embedder.sha256`, and a build phase (`scripts/check-bundled-models.sh`) fails the build with instructions if they are missing. Zip archives remain supported by the installer (they are tested) but no shipped model uses them. Archives are described as follows: a zip is: Core ML models are directories (`encoder.mlmodelc` plus the tokenizer), so they ship as one zip whose checksum is verified before it is unpacked into the version directory, and an install marker records that unpacking finished. Archive entries that would land outside the version directory are rejected. It then publishes per-model states (`missing → downloading(progress) → verifying → installed | failed`). At launch it only checks size and existence. The full checksum runs once at install. The language model downloads straight from its public, ungated, Apache-2.0 Hugging Face URL. Shipping the embedding model inside the app is redistribution under the Gemma Terms of Use, so the About screen carries the required notice; that wording should be confirmed by someone qualified before release.

### D11. Concurrency and memory

- The embedder and the generator are Swift `actor`s. Both are loaded lazily and stay resident, which fits within 8 GB with the `com.apple.developer.kernel.increased-memory-limit` entitlement. The app unloads the generator in response to memory warnings.
- Ingestion runs in an `IngestionService` actor. It processes one document at a time and embeds in batches of 16 chunks, writing each batch in one CBL transaction. After each batch it updates `ingestJobs.nextOrdinal` so it can resume from there. It's scheduled with `BGProcessingTask` when the app is backgrounded, and it continues in the foreground otherwise.
- While a chat answer is generating, ingestion pauses between batches so the user's answer gets priority.

Measured (Apple M2 Pro host, real embedder, debug build): a 300-page PDF (300 passages) indexes in 5.9 s with 19 progress updates and 399 MB peak memory; the whole answer pipeline (rewrite, retrieval, generation) peaks at about 0.9 GB with the language model resident.

### D12. UI

(Implementation notes: documents also arrive through the system's "Open in…" and share sheet by declaring the supported document types and handling `onOpenURL`, instead of a separate share-extension target with an App Group inbox; the extension can still be added later if in-place sharing is needed. A `BGProcessingTask` continues indexing when the app is suspended, and a warm-up query after each import trains the vector index before a user's first question. In portrait or narrow windows the three columns collapse to a stack; opening a source moves to the source column.)


The layout is a SwiftUI `NavigationSplitView` with three columns: the Library as the sidebar, Chat as the content column, and the SourceViewer as the detail column. The SourceViewer uses `PDFView` with `PDFSelection` highlighting found by searching the page for the chunk text, and a text view with a highlighted range for DOCX, TXT, and MD. Imports come through `.fileImporter`, a share extension (which copies files into an App Group inbox), and `.dropDestination`. Scope chips sit above the chat input.

### D13. Testing and evaluation

- **Unit tests** cover the chunker, the extractors (fixture TXT, MD, DOCX, text PDF, and scanned PDF), fusion, the gate, citation validation, prompt building, and the manifest and checksum logic, all against fakes.
- **Integration tests** run on an M4 iPad (or an Apple Silicon Mac running the iPad app for CBL and Core ML), with real CBL and the real embedder.
- **Evaluation harness:** a small set of sample documents is bundled in the test resources with `eval.json` (about 30 questions, each with its expected chunk location and answerability). It reports retrieval recall@6, not-found precision, and citation validity. It's also used to tune T_vec.

## Risks / Trade-offs

- **[The Gemma 4 runtime on iOS is immature or slow]** → Spike first (task group 1), keep the `Generator` protocol, and fall back to llama.cpp.
- **[A cold-loading or training index slows the first query]** → Run a background warm-up query after ingestion. An untrained index still returns correct results by full scan.
- **[CBL EE and the Vector Search extension are unavailable through SPM for iPadOS 26]** → Verify in the spike and fall back to an XCFramework in the repo's `Vendor/`.
- **[The Core ML embedder's fixed sequence length is shorter than wanted]** → The chunker cap follows it, so passages are smaller and more chunks are retrieved, which is acceptable.
- **[Strict mode over-refuses]** → Tune the gate with the evaluation set, show the closest passages on refusal so the user still gets value, and add the FTS exact-match bypass.
- **[DOCX layout fidelity]** → The viewer shows extracted text instead of Word layout, which is enough for citations. This is documented as a known limitation.
- **[OCR throughput on large scanned PDFs]** → Per-page progress, background processing, and resumable jobs.
- **[Model hosting license terms]** → Keep the manifest URLs swappable and check the licenses before release.
- **[CBL EE licensing for production]** → This is a business dependency, noted in the proposal impact.

## Migration Plan

This is greenfield, so no data migration is needed. Future-proofing for sync:
- A later change adds a replicator for `documents`, `chunks`, `chats`, and `messages`, and never for `ingestJobs`.
- A device that receives chunks with a different `embeddingModel` ignores them for vector search (spec'd) and can queue them for local re-embedding.
- Changing the embedding model in a future version means bumping the manifest version, re-embedding under a new generation, and switching `activeGeneration`. This is the same path as re-indexing.

## Open Questions

- The final value of T_vec and whether 64 centroids is enough. Both are tuned by the evaluation and don't change the approach.
- Whether the share extension can import directly into the CBL database, or must hand off through the App Group inbox. The inbox is assumed, and either way is an implementation detail.
