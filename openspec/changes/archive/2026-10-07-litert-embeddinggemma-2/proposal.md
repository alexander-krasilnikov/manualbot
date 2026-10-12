# Proposal

## Why

The app runs three model stacks: EmbeddingGemma 300M on Core ML for text, Apple's Vision feature print for how photos look, and Gemma 4 on LiteRT-LM for answers. Text and photos therefore live in two unrelated vector spaces, so words can reach a photo only through its caption, and the feature print does not work at all in the iOS Simulator. EmbeddingGemma 2 (released with LiteRT-LM v0.18.0) embeds text and images into one space and runs on the same LiteRT-LM runtime as the language model, so one runtime can serve all models and photos become searchable by meaning. Gemma 4 E2B, a smaller language model in the same family, may answer as well as E4B with half the memory and twice the speed, which is worth measuring now that the model setup is changing anyway.

## What Changes

- **Embedding model**: EmbeddingGemma 2 Text Vision 440M (`embeddinggemma-2-text-vision-440m.litertlm`, 388 MB) on LiteRT-LM replaces EmbeddingGemma 300M on Core ML, with 256-dimension vectors (Matryoshka output size) instead of 768. The Core ML model, its tokenizer, and the swift-transformers dependency are removed.
- **BREAKING: the embedding model is downloaded, not built in.** It is listed in the model setup next to the language model, verified by checksum, and needed before documents can be imported. The app becomes about 330 MB smaller. The first launch now needs a network connection before anything can be indexed.
- **Photos share the text vector space.** Each photo is embedded by the same model. Apple's Vision feature print is removed. Typed questions also search photos directly by meaning, in addition to their captions and recognized text.
- **Existing libraries are re-indexed automatically** after the update, because vectors from different models cannot be compared. Documents stay findable by keyword search, and by vector search once their new vectors are ready.
- **The LiteRT-LM runtime is upgraded** from v0.17.1 to v0.18.0, the first release that supports EmbeddingGemma 2.
- **Thresholds and evaluations are redone**: the text relevance threshold, the photo match threshold, a new text-to-photo threshold, the retrieval quality baseline, and the photo evaluation.
- **Gemma 4 E2B is evaluated against E4B** with a new answer evaluation over the existing question set. The app switches to E2B only if it meets pass criteria written before the evaluation runs. Otherwise E4B stays.
- **Kept**: Apple Vision text recognition (scanned pages, photos, nameplates).

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `model-provisioning`: the embedding model is downloaded and verified like the language model instead of being built in; setup lists both models; import becomes available once the embedding model is installed.
- `document-ingestion`: passages and photos are embedded by one model; a change of embedding model re-indexes every document automatically.
- `hybrid-retrieval`: typed questions also search photo vectors; the relevance gate and the quality baseline are re-established for the new model.
- `image-search`: photo vectors come from the embedding model, not a separate image model; photos are findable by the meaning of typed words, not only by their text. This capability is introduced by the change `image-import-and-search`, which must be archived before this change is archived.
- `grounded-chat`: a new answer quality baseline over the evaluation questions, used to choose the language model.

## Impact

- **Dependencies**: LiteRTLMKit re-vendored at v0.18.0 (Swift wrapper and both xcframeworks, local patch re-applied if still needed). swift-transformers removed from Adapters. Core ML no longer used.
- **Ports**: no new ports. One adapter implements both `Embedder` and `ImageFeaturing` with the same model identity.
- **Adapters**: new `LiteRTEmbedder`; `CoreMLEmbedder`, `GemmaTokenizer` and `VisionFeaturePrinter` removed. `CouchbaseSchema` recreates the vector indexes when their dimension changes.
- **Core**: the chunker's sizes change to suit the new input limits; a start-up re-index of documents embedded by another model; retrieval adds a text-to-photo list; a new answer evaluation runner.
- **App**: manifest entry for the downloaded embedder (and possibly E2B instead of E4B); setup and readiness flows; About notices; `BundledModels/`, `fetch-embedder.sh` and the build check removed; the stub factory keeps stand-in models.
- **Data**: every document is re-indexed once after the update. Chats and originals are unaffected.
- **Order of work**: `image-import-and-search` is archived first; its task 6.4 (tuning the Vision feature print threshold on real photos) is superseded by this change's photo evaluation.
