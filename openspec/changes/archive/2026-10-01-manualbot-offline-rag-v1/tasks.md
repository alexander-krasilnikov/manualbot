# Tasks

## 1. Project setup and spikes

- [x] 1.1 Create the Xcode project (iPadOS 26, iPad only, SwiftUI) with the app, unit test, and UI test targets plus local packages `Core`, `Ports`, and `Adapters` (design D1). Verify that `xcodebuild build` and an empty test run succeed.
- [ ] 1.2 Add Couchbase Lite Swift Enterprise Edition and the Vector Search extension (SPM, or a vendored XCFramework if SPM fails). Enable the extension at startup. Verify with a test that creates a 768d vector index and runs an `APPROX_VECTOR_DISTANCE` query on an M4 iPad.
- [x] 1.3 Spike the embedder: load the EmbeddingGemma Core ML conversion, record its maximum sequence length, and measure per-chunk latency on the ANE. Verify that the output is 768-dimensional with an L2 norm of about 1, and write the results into design.md D2.
- [ ] 1.4 Spike the generator: run Gemma 4 E4B 4-bit on LiteRT-LM and on llama.cpp on an M4 iPad, and measure time to first token (~3k-token prompt), tokens per second, and peak memory. Record the choice in design.md D3. Verify that the chosen runtime streams tokens in a test harness.
- [ ] 1.5 Add the `increased-memory-limit` entitlement, the background-tasks capability, and the App Group. Verify that they appear in the signed build's entitlements.
- [ ] 1.6 Confirm the redistribution and license terms for both models and pick the hosting location (design D10). Verify by recording the URLs and SHA-256 values in a draft `ModelManifest.json`.

## 2. Ports and data layer

- [x] 2.1 Define the `Embedder`, `Generator` (streaming plus cancellation), and `DocumentRepository` protocols with deterministic fakes. Verify that the fakes compile and that a smoke test uses each one.
- [x] 2.2 Implement the CBL schema (scope `manualbot`, the collections from D4, and the chunk ID scheme). Verify with a test that saves and reads back each document type.
- [x] 2.3 Create the vector index, the FTS index, and the value indexes (D5). Verify with a test that queries use the indexes, using `explain()` output.
- [x] 2.4 Implement the active-generation visibility rule and the atomic generation switch and purge (D4). Verify with a test that a document with a half-written new generation only returns old-generation chunks.
- [x] 2.5 Implement document deletion that removes the document, its blob, and its chunks in one batch. Verify with a test that no chunks remain and that message citation snapshots are untouched.

## 3. Model provisioning

- [x] 3.1 Implement manifest loading and the per-model state machine in `ModelStore` (D10). Verify with unit tests for each state transition.
- [x] 3.2 Implement background `URLSession` download with resume data, the free-space check, streaming SHA-256 verification, backup exclusion, and deletion when verification fails. Verify with tests against a local test server: interrupted resume, bad checksum, and insufficient space.
- [x] 3.3 Build the model setup screen (sizes, storage, progress, retry) and staged readiness (import enabled once the embedder is ready, chat enabled once both are ready). Verify with a UI test using a stubbed `ModelStore`.
- [x] 3.4 Implement recovery for missing models at launch. Verify with a test that deletes a model file and relaunches, then checks that setup shows only that model and that the library and chats persist.
- [ ] 3.5 Implement the Core ML `Embedder` adapter and the chosen `Generator` adapter as actors, with lazy loading and unloading on memory warnings (D11). Verify with integration tests on a device.

## 4. Document ingestion

- [x] 4.1 Implement the TXT/MD extractor (encoding fallback, Markdown headings). Verify with fixture tests for UTF-8, Latin-1, and heading extraction.
- [x] 4.2 Implement the PDF extractor with per-page text and the Vision OCR fallback for pages without text (D6). Verify with fixtures: a text PDF has correct page numbers, and a scanned PDF produces searchable text.
- [x] 4.3 Implement the DOCX extractor (ZIPFoundation + `XMLParser`, with headings, lists, and tables in reading order). Verify with fixture tests, including a table.
- [x] 4.4 Implement the chunker (D7): token-bounded, with overlap, never crossing pages, carrying headings, and merging small tails. Verify with unit tests for size bounds, page boundaries, and provenance.
- [x] 4.5 Implement the `IngestionService` pipeline with a persistent `ingestJobs` queue, batched embedding, resume from `nextOrdinal`, status updates, and failure reasons (D11). Verify with tests: killing and resuming the service yields exactly one chunk set, and a corrupt file fails without blocking the queue.
- [ ] 4.6 Add `BGProcessingTask` scheduling, pausing ingestion during generation, and the post-ingestion index warm-up query. Verify by manually triggering the background task in the debugger and checking the logs.
- [x] 4.7 Implement re-indexing through a new generation. Verify with a test that search keeps returning old chunks until the switch, and only new chunks after it.
- [ ] 4.8 Build the import entry points: `.fileImporter` (multi-select), `.dropDestination`, and a share extension through the App Group inbox. Add rejection of unsupported types. Verify with a UI test for picker import and a manual check of share-sheet and drag-and-drop import.
- [x] 4.9 Build the library view (title, type, pages, date, status and progress, rename, delete, re-index). Verify with a UI test covering rename and delete.

## 5. Hybrid retrieval

- [x] 5.1 Implement the vector search query with scope, generation, and `embeddingModel` filters. Verify with a test that mismatched-model chunks and chunks outside the scope are excluded.
- [x] 5.2 Implement the FTS query with the same filters. Verify with a test that an exact code such as `E-042` is found.
- [x] 5.3 Implement Reciprocal Rank Fusion, deduplication, and top-k selection. Verify with unit tests that a passage found by both searches ranks first.
- [x] 5.4 Implement the relevance gate (T_vec OR exact-match bypass) and the closest-passage suggestions (D8). Verify with unit tests for relevant, not-relevant, and bypass cases.
- [ ] 5.5 Add a retrieval latency benchmark with 20k synthetic chunks. Verify that the p95 is at most 500 ms on an M4 iPad.

## 6. Evaluation harness

- [x] 6.1 Assemble sample documents (text PDF, scanned PDF, DOCX, TXT) and `eval.json` with about 30 questions, each with an expected passage location, including unanswerable questions. Verify that the fixtures load in a test.
- [x] 6.2 Implement the eval runner, which reports recall@6, not-found precision, and citation validity. Verify that it runs and prints a report.
- [x] 6.3 Tune T_vec (and centroids if needed) against the eval set. Verify that recall@6 is at least 85%, and record the final values in design.md.

## 7. Grounded chat

- [x] 7.1 Implement the chat and message repository (create, rename, delete, pinned documents, citation snapshots). Verify with a persistence test across database reopen.
- [x] 7.2 Implement follow-up rewriting into standalone queries, stored on the message (D9 step 1). Verify with a scripted-generator unit test and a device check of the X200/X100 scenario.
- [x] 7.3 Implement prompt building with numbered passages and the strict system prompt (D9 step 3). Verify with snapshot tests of the prompt text.
- [x] 7.4 Implement `ChatService` orchestration: the not-found short-circuit (no LLM call), streaming, `NOT_FOUND` detection, and stopping. Verify with unit tests that the generator is never called when `relevant == false`.
- [x] 7.5 Implement citation validation (drop invented markers, fall back to not-found when no valid markers remain). Verify with unit tests for valid, invented, and missing citations.
- [x] 7.6 Build the chat UI: streaming messages, citation chips with a sources list, stop button, scope chips for pinning, disabled states (no LLM, empty library), and the "show standalone query" affordance. Verify with UI tests using a scripted generator.

## 8. Source viewer and layout

- [x] 8.1 Build the PDF source viewer that navigates to the cited page and highlights the passage. Verify with a UI test that tapping a citation shows the correct page with the highlight.
- [x] 8.2 Build the text viewer for DOCX, TXT, and MD that scrolls to the cited passage and highlights it, plus the deleted-document fallback showing the snapshot. Verify with UI tests.
- [ ] 8.3 Build the three-column `NavigationSplitView` with collapsing behavior for portrait, Split View, and Stage Manager. Verify with manual checks at each size class that citations still open the source.

## 9. End-to-end verification

- [ ] 9.1 Test airplane mode on an M4 iPad: import a PDF, a scanned PDF, and a DOCX, wait for them to be ready, and ask answerable and unanswerable questions. Verify that the answers are cited and that refusals show the closest passages.
- [ ] 9.2 Audit network traffic during core use (Instruments or a proxy). Verify that no requests are made after model setup.
- [ ] 9.3 Check performance: time to first token is at most 3 s with 6 passages, the app survives memory pressure with both models loaded, and a 300-page PDF indexes with visible progress. Record the results.

## 10. Built-in embedding model

- [x] 10.1 Add a `bundled` packaging type: `ModelStore` treats a bundled model as installed from launch, never downloads it, excludes it from storage checks, and reports a missing one as failed. Verify with store tests for install, download list, storage requirement and the missing case.
- [x] 10.2 Resolve bundled models inside the app's resource folder in `FileModelFiles` (cannot be installed or removed). Verify with file-layer tests for present, missing and uninstall cases.
- [x] 10.3 Add `scripts/fetch-embedder.sh` (pinned commit, per-file checksums, repairs a corrupted file), `scripts/check-bundled-models.sh` as a build phase, and bundle `BundledModels/` in the app target. Verify that a corrupted file is refetched and that the app unit test finds the model inside the built app.
- [x] 10.4 Skip the setup screen when nothing needs downloading, show only the language model for download, and add an About screen with the Gemma notice and third-party licences. Verify with UI tests for the bundled launch and the About screen, and by launching the real app on a fresh simulator install.
