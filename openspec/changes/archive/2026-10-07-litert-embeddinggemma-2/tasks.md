# Tasks

## 1. Runtime and spike

- [x] 1.1 Re-vendor LiteRTLMKit at v0.18.0 (wrapper sources, both binary targets and checksums from design D1), check whether upstream fixed the `Conversation.deinit` hang, and re-apply the patch only if not; update its README. Verify all package tests pass and `LiteRTGeneratorTests` passes with a downloaded Gemma 4 E4B (`GENERATOR_MODEL_PATH`).
- [x] 1.2 Download `embeddinggemma-2-text-vision-440m.litertlm` into an ignored local folder and verify its SHA-256 against the value in design D7. Verify the checksum matches.
- [x] 1.3 Write `EmbeddingGemma2SpikeTests` (gated by `RUN_SPIKES=1`, model path from `EMBEDDER_MODEL_PATH`) answering design D2 questions 1–5 on the Mac (CPU and GPU), and run its CPU part in the iOS Simulator. Record the answers in the test header and in design D3/D4. Verify every D2 question has a recorded answer.

## 2. Embedder

- [x] 2.1 Add `LiteRTEmbedder` (design D3): one engine, `Embedder` and `ImageFeaturing` with the identity `embeddinggemma-2-text-vision-440m@1/256`, prompts and image treatment as settled by the spike, batch embedding, GPU or CPU by environment, a serial queue for blocking calls, `unload()`. Verify with Adapters tests gated on `EMBEDDER_MODEL_PATH`: paraphrases are nearer than unrelated text, a photo is nearer to its own description than to an unrelated one, vectors are 256 long and unit length, and different photos give different vectors.
- [x] 2.2 Add `ChunkerConfiguration.embeddingGemma2` and the token counting decided in design D4. Verify with `ChunkerTests` that no passage exceeds the configured maximum, and with the spike's check that the longest passage of the evaluation documents is not truncated.
- [x] 2.3 Remove `CoreMLEmbedder`, `GemmaTokenizer`, `VisionFeaturePrinter` and its spike, and the swift-transformers dependency, and move every caller to `LiteRTEmbedder`. Verify all three package suites build and pass.

## 3. Storage and re-indexing

- [x] 3.1 Record each vector index's dimension in device-local metadata and rebuild `chunks_vec` and `images_vec` when it changes (design D5). Verify with an Adapters test that opens a database created with 768-dimension indexes using a 256-dimension identity, finds the indexes rebuilt (query plans name them), and finds new 256-dimension vectors searchable.
- [x] 3.2 Add `IngestionService.reindexOutdated(for:)` (design D6) and call it once the embedder is ready. Verify with Core tests that documents embedded by another model are queued and become searchable by vector search after re-indexing, keyword search finds them throughout, and nothing is queued when every document is current.
- [x] 3.3 Show "Updating index" with progress for a searchable document whose re-index is running. Verify with `LibraryViewModelTests` that the status shows during a re-index and returns to ready.

## 4. Retrieval

- [x] 4.1 Search photos with the question's text vector within `textToImageMaxDistance`, expand matches into page or section passages as one more fusion list, add them to the result's images, and keep them out of the relevance decision (design D8). Verify with `PhotoRetrievalTests` for the spec scenarios "Passage reached through words that describe a photo" and "Words that only resemble a photo", and that existing photo-question tests still pass.
- [x] 4.2 Trace the words-to-photos search in X-ray (query purpose, fusion column, caption) and show matching photos beside text answers. Verify with app unit tests for the X-ray text and a UI test in stub mode in which a typed question shows a matching photo.

## 5. Provisioning

- [x] 5.1 Change the manifest's embedder to the downloaded EmbeddingGemma 2 entry (design D7) and remove the `bundled` packaging case, `BundledModels/`, both scripts, the build phase and the `bundled` UI-test scenario. Verify with `ModelStoreTests` that the embedder downloads first and import becomes available before the language model, and that the app builds without `BundledModels/`.
- [x] 5.2 Delete model files no longer in the manifest at launch. Verify with a `ModelStoreTests` or `FileModelFiles` test that an unlisted model file is removed and listed ones are kept.
- [x] 5.3 Update the setup texts (download needed once, embedder first), About notices (EmbeddingGemma 2 under Apache 2.0, swift-transformers removed) and the stub factory (design D10). Verify with the model setup UI tests, updated for a downloaded embedder, and `testAboutCarriesTheGemmaNotice`.

## 6. Thresholds and baselines

- [x] 6.1 Run the retrieval evaluation with the real embedder, choose the chunk size and `maxDistance`, and record both with their numbers. Verify recall@6 is at least 85% and answer and refusal rates are at least 90% (`EvalTests` with `EMBEDDER_MODEL_PATH`).
- [x] 6.2 Extend `ImageEvalTests` with text queries and expected photos (generated set and the `eval.json` format), run it with the real embedder on the generated set and the local stand-in photos, and record `imageMaxDistance` and `textToImageMaxDistance` as provisional. Verify photo-query top-3 recall is at least 80% and text-query top-3 recall is at least 70% on the stand-in set.
- [x] 6.3 Re-run `ImageBenchmarkTests` and `RetrievalBenchmarkTests` with the real embedder producing the query vectors. Verify the p95 targets (300 ms photo search at 5,000 photos, 500 ms retrieval at 20,000 passages) on the Mac, and note that the iPad figures are still to be measured.

## 7. Language model choice

- [x] 7.1 Add six follow-up pairs to the evaluation suite and an `AnswerEvalRunner` with the measures in design D11, and an `AnswerEvalTests` suite gated on `EMBEDDER_MODEL_PATH` and `GENERATOR_MODEL_PATH` that prints a report. Verify with Core unit tests of the runner on scripted answers (each measure counted correctly) and one real run with E4B.
- [x] 7.2 Download `gemma-4-E2B-it.litertlm` and verify its SHA-256 (design Context), run the answer evaluation with E4B and E2B, and save both reports in the change folder. Verify both reports exist and were produced by the same suite and settings.
- [x] 7.3 Apply the design D11 criteria: if all pass, switch the manifest's generator to E2B; if any fails, keep E4B and record which criterion failed. Verify the decision and the reasons are recorded in the change, and that `RealStackTests` passes with the chosen model.

## 8. Wrap-up

- [x] 8.1 Update the README (models and runtime, first-run download, re-index after update, evaluation variables, which Apple framework remains and why). Verify the README commands run as written.
- [x] 8.2 Run all package tests and the app test suite on the iPad simulator, and confirm photo search now works in the simulator with the real embedder (live mode) or record why not. Verify everything passes and `openspec validate litert-embeddinggemma-2 --strict` is clean.
