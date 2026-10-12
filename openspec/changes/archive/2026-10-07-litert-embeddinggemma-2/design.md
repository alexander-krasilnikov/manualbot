# Design

## Context

See proposal.md for the motivation and the specs in this change for the required behavior.

- **Embedder today.** `CoreMLEmbedder` runs a compiled Core ML EmbeddingGemma 300M with a fixed 256-token input and 768-dimension output, and `GemmaTokenizer` (swift-transformers) tokenizes for it. The same tokenizer is the `TokenCounting` behind `Chunker(configuration: .embeddingGemma)`. The model ships in `BundledModels/`, fetched by `scripts/fetch-embedder.sh` and checked at build time by `scripts/check-bundled-models.sh`. The manifest marks it `packaging: bundled`, and `ModelStore` and `FileModelFiles` have special cases for that.
- **Photos today.** `VisionFeaturePrinter` produces 768-float feature prints into `images_vec`. It refuses to start in the iOS Simulator, where the print is degenerate, and the app then hides photo search.
- **Runtime.** `LiteRTLMKit` vendors the LiteRT-LM Swift wrapper and xcframeworks at v0.17.1. It already contains `EmbeddingEngine` (text and image `Content`, `EmbeddingOptions(normalize:outputSize:)`, batch calls), unused so far. It carries one local patch (`Conversation.deinit` deletes off-thread). LiteRT-LM v0.18.0, released 2026-10-06, is the first release that supports EmbeddingGemma 2. Its xcframework checksums are `d765b995…c347` (iOS) and `5f6ee68d…6cfb4f` (macOS).
- **Model.** `litert-community/embeddinggemma-2-text-vision-440m-litert-lm`, file `embeddinggemma-2-text-vision-440m.litertlm`, 387,710,976 bytes, SHA-256 `92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0`, Apache 2.0. It has int4 text weights and an int8 vision encoder. Output sizes are 128, 256, 512 and 768. Text input signatures are 128 to 8,192 tokens, and images take 70 or 140 soft tokens. LiteRT-LM resizes images itself. Documented prompts: `task: search query | text: …` for queries and `task: search result | text: …` for documents, trimmed, and added by the caller.
- **Language model.** Gemma 4 E4B, 3.66 GB. Candidate: `gemma-4-E2B-it.litertlm`, 2,588,147,712 bytes, SHA-256 `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`. Its model card reports, on an iPhone 17 Pro GPU, 56.5 against 25.1 tokens/s decode and 1.45 against 3.4 GB memory compared with E4B.
- **Evaluation today.** `EvalRunner` and `EvalTests` measure retrieval only: recall@6 at least 85%, answer and refusal rates at least 90%, and they tune the relevance threshold. `RealStackTests` checks a few answers. Nothing measures answer quality across the question set. No `.litertlm` file is on the development Mac, and there is about 100 GB free.

## Goals / Non-Goals

**Goals:**
- One runtime (LiteRT-LM) for every model the app downloads. Apple Vision is kept only for text recognition.
- One vector space for passages and photos, at 256 dimensions.
- Every decision that depends on how the new model behaves (prompts, backends, token limits, thresholds) is settled by measurement in the spike or the evaluations, not assumed.
- The language model is chosen by criteria recorded before the candidate is run (D11).

**Non-Goals:**
- Replacing Apple Vision text recognition (PP-OCR on LiteRT was reviewed and rejected for now: a second runtime, hand-written pre- and post-processing, and no iOS validation).
- Searching passages directly with a photo's vector (photo to text). Photos keep reaching passages through matching photos and recognized identifiers. This can be added later on the same vectors.
- Audio and video embeddings, and the 740M variant.
- A real equipment photo corpus. It is still needed (as in `image-import-and-search` task 6.4) and is out of this change's control.

## Decisions

### D1. Upgrade the vendored LiteRT-LM to v0.18.0

Re-vendor `swift/*.swift` from tag v0.18.0 (same exclusions as before), switch the two binary targets to the v0.18.0 URLs and checksums, and check whether upstream fixed the `Conversation.deinit` hang. Re-apply the patch only if it did not, and keep the README's "Local patches" list accurate. The generator and its tests must keep passing on the new runtime before anything else builds on it.

*Alternative:* staying on v0.17.1. Rejected: it predates EmbeddingGemma 2.

### D2. A spike settles what the documents leave open

The first task is a gated test suite (`RUN_SPIKES=1`, like `ImageFeaturePrintSpikeTests`) on the Mac and in the iOS Simulator. It records its findings in its header and answers:
1. Does the model load and embed text and images through `EmbeddingEngine`, on CPU and GPU (Mac), and on CPU in the simulator, with distinct vectors for different inputs?
2. Does `EmbeddingOptions(outputSize: 256)` return 256 floats, and are they unit length, or should `normalize: true` be set?
3. Does the Swift API expose a token count? If not, how long can a passage be before the chosen input signature truncates it? This decides D4.
4. How should a photo be embedded: alone, or with a document instruction? And should passages include their title? Each choice is compared by recall on a small set before the full evaluation.
5. Latency per text batch and per image, and memory, alongside a loaded Gemma 4 engine on the Mac.

The spike's answers are written into this design before the dependent tasks start.

### D3. One adapter for text and photos: `LiteRTEmbedder`

An actor owning one `EmbeddingEngine` (created lazily, released by `unload()` on memory warnings, as `CoreMLEmbedder` does). It conforms to both `Embedder` and `ImageFeaturing` with **one identity**, `embeddinggemma-2-text-vision-440m@1/256`. That way the existing model-tag checks keep text and photo vectors consistent without new ports.
- **Prompts (settled by the spike):** queries become `task: search query | text: <trimmed>`, passages `task: search result | title: <title, at most 60 characters> | text: <trimmed>` (the title raised the ranking and widened the gap between answerable and unanswerable questions; task 6.1 can revisit it). A photo is embedded alone, with no prompt, at the default of 140 vision tokens. Both use `outputSize: 256` and `normalize: true`, so vectors are unit length.
- **Batches:** `embed(_:kind:)` uses `computeEmbeddingBatch`.
- **Backend:** GPU on devices and Mac, CPU in the simulator, decided by `targetEnvironment(simulator)`.
- **Input length:** `maxInputLength` is set to 512. Input longer than the signature is not truncated by the engine: it throws `INVALID_ARGUMENT … exceeds maximum supported signature length`. The embedder therefore cuts such text to 80% of its words and retries, until it fits, so identifier-heavy passages (which tokenize at up to about 4 tokens per word) are embedded from their start instead of failing the whole document.
- **Threading:** blocking C calls run on one serial queue, the lesson from `VisionQueue`.

`CoreMLEmbedder`, `GemmaTokenizer`, `VisionFeaturePrinter`, `VisionQueue`'s feature-print use, the Core ML compute-unit plumbing, and the swift-transformers package are removed. `VisionTextRecognizer` stays.

*Alternative:* a separate image adapter on the same engine. Rejected: two identities for one model would let text and photo vectors drift apart in the tag checks.

### D4. Chunk sizes without the model's tokenizer

The spike found no token-count API (D2 question 3), so chunking uses `ApproximateTokenCounter`, which counts 1.35 tokens per word. Measured against the model on English prose it over-counts by about 6% (1.26 real tokens per word), so its numbers are safe for prose. A new `ChunkerConfiguration.embeddingGemma2` targets passages well inside the 512-token input. The first guess was target 300 and maximum 380 approximate tokens; the retrieval evaluation (D9) chose target 130 and maximum 180 instead (about 170 real tokens at most, far inside the limit, leaving room for the template and title of about 30 tokens). Identifier-heavy text can use three times as many tokens as counted, which the embedder's shrink-and-retry (D3) absorbs, and the retrieval evaluation (D9) confirms the size. The `title:` prefix of EmbeddingGemma 1 is replaced by the title inside the new template.

### D5. Vector indexes rebuilt when their dimension changes

`CouchbaseSchema.prepare` records the dimension each vector index was created with in a device-local metadata document. When the configured dimension differs (768 to 256), it deletes and recreates `chunks_vec` and `images_vec` before use. Without this, a Couchbase Lite vector index keeps its original dimension and the new vectors would not be indexed. Stored documents are untouched; the model-tag filter keeps old vectors out of results until D6 replaces them.

*Finding while implementing (3.1):* with Couchbase Lite 4.1.2, calling `createIndex` again under the same name with a different dimension already replaces the index; the migration test passes even with the explicit delete disabled. The recorded dimension and the explicit delete are kept anyway, so the behavior does not depend on that, and a database made by a version that recorded nothing is rebuilt once.

### D6. Start-up re-index of documents embedded by another model

`IngestionService` gains `reindexOutdated(for identity:)`. One query (`SELECT DISTINCT docId FROM chunks WHERE embeddingModel != $tag`, over active generations only) finds stale documents, and each gets a normal re-index job. Re-indexing already keeps the old generation in place until the new one is complete, so keyword search keeps working. `AppModel` calls it once the embedder is ready. The library shows "Updating index" with progress for a document that is searchable and has a re-index job running. This applies to any re-index, which is also more honest for manual re-indexing.

### D7. Provisioning: a downloaded embedder

- **Manifest:** the embedder entry becomes `embeddinggemma-2-text-vision-440m`, version 1, role embedder, the Hugging Face resolve URL, 387,710,976 bytes, the SHA-256 above, `packaging: file`. `ModelStore` already downloads the embedder before the generator.
- **Removed:** the `bundled` packaging case and its branches, `BundledModels/`, the two scripts, the build phase, the `bundled` UI-test scenario, and the related tests.
- **Old files:** model files in the models directory that are no longer in the manifest (an old E4B after a switch to E2B) are deleted at launch, so an update does not leave gigabytes behind.
- **Notices:** About lists EmbeddingGemma 2 under Apache 2.0 and removes swift-transformers.
- **Missing model:** the existing recovery flow covers it. A missing embedder returns to setup with library and chats intact.

### D8. Typed words reach photos by meaning

`Retriever` also searches `images_vec` with the question's text vector. Matches within `textToImageMaxDistance` are expanded into their page or section passages exactly as photo matches are, and added as one more ranked list in rank fusion. They appear in `RetrievalResult.images`, so answers can show them. They never make a question relevant on their own (spec). X-ray labels this image search "words → photos", and `FusionEntry` gets its position. A typed question with a photo attached keeps the photo list and adds this one.

### D9. Thresholds and baselines re-established

Three thresholds are re-tuned:
- `maxDistance` (text to passage), with `EvalTests` and the perfect-threshold search, on the real embedder (`EMBEDDER_MODEL_PATH` replaces `EMBEDDER_MODEL_DIR`);
- `imageMaxDistance` (photo to photo);
- the new `textToImageMaxDistance` (words to photo).

The last two use `ImageEvalTests`, which gains text queries with expected photos. The committed generated set covers the mechanics. Real tuning uses `IMAGE_EVAL_DIR` (now also reading `"text"` queries from `eval.json`) on the local stand-in landscape set until real equipment photos exist. Every chosen value is recorded in a comment with the numbers behind it and marked provisional where the set is a stand-in. The stub factory keeps its own stand-in thresholds.

**Results (2026-10-06, Mac, real model).**
- *Passage size and `maxDistance`* (`RealEvalTests`, 25 answerable and 6 off-topic questions over 6 documents): recall@6 was 100% at every size from 80 to 400 tokens. The room between the worst answerable question and the nearest off-topic one was 0.080 (target 80), 0.080 (100), 0.083 (130), 0.065 (150), 0.024 (180) and 0.029 for 220 and larger. Target 130 (maximum 180) was chosen. With it, answerable questions reach at most 0.239 and off-topic ones start at 0.323, and every threshold from 0.24 to 0.32 separates them; `maxDistance` is 0.28. At that setting the gate lets through 100% of the answerable questions and refuses 100% of the off-topic ones (the previous model: 0.66 and 0.87, threshold 0.76). Only six questions are off-topic, so the margin should be checked on a larger set.
- *Photos* (`ImageEvalTests`, 14 Wikimedia Commons photos of equipment as the library; as queries a different photo of the same kind of thing, 6 unrelated photos, 28 descriptions such as "a ball valve" and 4 descriptions of things no photo shows): the right photo was in the top three for 12 of 14 photo queries (86%) and for all 28 text queries (100%, 26 of them first). Photo-to-photo distances overlap (right matches up to 0.31, median 0.17; the nearest library photo for unrelated photos from 0.21, median 0.28), so `imageMaxDistance` stays 0.25: it keeps 71% of the matches and rejects 83% of the unrelated photos. Re-shots of the same object, as in the generated set, are far closer (at most 0.054). Words to photo separate cleanly: right matches at most 0.276, unrelated words from 0.327, so `textToImageMaxDistance` is 0.30. Both are provisional until field photos exist.
- *Latency* (p95, Mac, debug build, the real model embedding the question or photo): retrieval at 20,000 passages 119 ms (target 500); photo search at 5,000 photos 223 ms (target 300), of which about 175 ms is embedding the photo. The iPad figures are still to be measured.

### D10. Stub mode

The stub keeps stand-in models, but words and photos now share one: `FakeJointEmbedder` (in `PortsTesting`) embeds text as a hashed bag of words and photos as colour-cell features, in one 768-dimension space (photo features padded with zeros) with one identity, like the real model. Scripted *anchors* let chosen words "find" a chosen picture (the stub anchors "x100 nameplate" to the seeded nameplate photo), which is what lets a stub-mode UI test show a photo found by typed words. `StubGenerator` is unchanged. The photo controls no longer depend on a feature-print check: `supportsPhotos` is true whenever the embedder is installed. (The first plan was `FakeEmbedder` at 256 dimensions beside `FakeImageFeaturer` with a separate identity; the retriever searches photos with the question's vector only when both are the same model, so the stub needed to be one.)

### D11. Choosing E2B: evaluation and pass criteria (recorded before any run)

**Runner.** A new `AnswerEvalRunner` (Core) runs every case of the evaluation suite through `ChatService` on the real retrieval stack with the new embedder. It uses the app's own settings (temperature 0.2, max 512 tokens) and a fixed sampler seed, so runs repeat. The suite gains six follow-up pairs (a question, then a follow-up that needs the first to be understood) with expected passages.

**Measured, per model:**
- **States:** the answer text contains the expected `contains` text, ignoring case and spacing.
- **Cites:** a cited passage contains the expected text.
- **Wrongly refused:** answerable questions that got the not-found reply, from retrieval or from the model.
- **Answered when unanswerable:** a generated answer to a question the documents cannot answer.
- **Grounding failures:** answers replaced by not-found because no valid citation remained.
- **Follow-up hits:** the rewritten query retrieved the expected passage.
- **Speed:** time to first text and decode speed on the Mac, reported but not a criterion. Device speed is checked separately.

**E2B replaces E4B only if all of these hold, compared with E4B on the same run of the same suite:**
1. "Cites" for E2B is at least E4B's minus 5 percentage points, and at least 80% absolute.
2. "States" for E2B is at least E4B's minus 5 percentage points.
3. "Wrongly refused" for E2B is no more than E4B's plus 1 question.
4. "Answered when unanswerable" for E2B is no more than E4B's.
5. "Grounding failures" for E2B are no more than E4B's plus 1 question.
6. "Follow-up hits" for E2B are no fewer than E4B's minus 1.

If any criterion fails, E4B stays, the report is kept with the change, and the manifest is not touched. If all pass, the manifest switches to E2B, and D7's cleanup removes the old E4B file on devices that had it.

These criteria are fixed as written here. If they are later found to be wrong, the change is made in this document, with the reason, *before* the candidate is evaluated again.

**Outcome (2026-10-06).** E2B met all six criteria against E4B on the same run (states 100% against 97%, cites 100% against 100%, no refusals, no unanswerable question answered, no grounding failure, 6 of 6 follow-up hits), and was about three times faster to first text on the Mac (0.38 s against 1.14 s). The manifest now lists E2B. The numbers, both reports and the decision are in `evaluations/`.

## Risks / Trade-offs

- [v0.18.0 is new, released the day this was planned] → The spike and the existing generator tests run on it before anything depends on it. If it regresses the generator, the change stops and reports instead of working around it.
- [The documented Swift API omits output size and normalization] → The vendored `EmbeddingOptions` exposes both, and the spike checks the actual vector length and norm.
- [Approximate token counts could overflow the input signature and silently truncate passages] → Generous headroom (D4), and the spike measures the worst case.
- [The first launch now needs a network connection before anything can be imported] → Accepted with the user's choice. The setup screen says so plainly (spec scenario), and the embedder downloads first (388 MB, before the language model).
- [GPU memory: embedder and language model on one GPU] → Ingestion already pauses while an answer is generated. The spike measures memory with both loaded, and E2B would halve the language model's share.
- [Re-indexing a large library after the update takes time and battery] → It runs through the existing background queue and resumes after interruption. Keyword search keeps working throughout.
- [Thresholds tuned on stand-in photos] → Recorded as provisional, as before. The real corpus remains an open item shared with `image-import-and-search` 6.4.
- [Two `.litertlm` engines (embedding and generation) in one process have not been tried in this app] → Covered by the spike (D2.5) and by the real-stack and answer-evaluation runs, which load both.
- [Rollback] → An older build cannot use the 256-dimension index or the new model. Downgrading means reinstalling. Documents and chats survive in the database, and the older build re-indexes with its own model.

## Migration Plan

1. The update installs. The manifest now lists the downloaded embedder, which is missing, so setup shows it, and the language model too if a switch to E2B happened. The library and chats are intact.
2. Once the embedder is installed, the vector indexes are rebuilt at their new dimension (D5) and every document is queued for re-indexing (D6). Keyword search works throughout. Vector and photo search fill in as documents finish.
3. Model files no longer in the manifest are deleted (D7).

There is no data migration beyond re-indexing, and chats and originals are untouched.

## Open Questions

- None from the spike: its answers are recorded in the header of `EmbeddingGemma2SpikeTests` and in D3 and D4. Still open for later tasks: whether 70 vision tokens per image is good enough on real photos (task 6.2), and whether the title in the passage template helps on the full evaluation (task 6.1).
