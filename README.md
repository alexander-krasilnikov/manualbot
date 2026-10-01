# ManualBot

An iPad app that answers questions about your own documents (PDF, Word, text), entirely on the device.
Import documents, and ask in a chat. Answers come only from your documents and cite the page or section they came from;
if the documents don't say, the app says so.

- Search: vector search (EmbeddingGemma 300M, Core ML) plus keyword search, stored in Couchbase Lite.
- Answers: Gemma 4 E4B (LiteRT-LM), constrained to the retrieved passages.
- Offline: after the language model is downloaded once, nothing needs the network.
- Targets: iPadOS 26 on M4/M5 iPads.

## Set up

Requirements: Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./scripts/fetch-embedder.sh   # once: fetches the embedding model that ships inside the app (~330 MB, verified)
xcodegen generate             # creates ManualBot.xcodeproj from project.yml
open ManualBot.xcodeproj      # run on an iPad simulator, landscape
```

The build fails with instructions if the embedding model has not been fetched.

The language model (3.7 GB) is downloaded from inside the app on first use. In the simulator it runs on the CPU
(the simulator's Metal cannot run it), so answers are much slower than on an iPad.

### Try it without the real models

Add launch arguments in the scheme (Run, Arguments): `-uiTestModelStub happy -uiTestSeed`. This uses the real database,
extraction, ingestion, retrieval and chat logic with fake models, and three sample documents already indexed.
Other flags: `-uiTestSlow` (slow, stoppable answers). Stub scenarios: `happy`, `bundled`, `llmFailsOnce`, `lowStorage`.

## Tests

```sh
for p in Ports Core Adapters; do (cd Packages/$p && swift test); done      # packages, on the Mac
xcodebuild test -project ManualBot.xcodeproj -scheme ManualBot \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'         # app unit and UI tests
```

Tests against the real models are skipped unless you point them at the files:

| Variable | Points at | Enables |
|---|---|---|
| `EMBEDDER_MODEL_DIR` | `BundledModels/embeddinggemma-300m` | embedder, retrieval evaluation, large-document tests |
| `GENERATOR_MODEL_PATH` | `gemma-4-E4B-it.litertlm` | generator and full-pipeline tests |
| `RUN_BENCHMARKS=1` | | 20,000-passage retrieval benchmark |

For the iOS simulator, prefix the variables with `TEST_RUNNER_`.

## Layout

- `App/`: SwiftUI app (library, chat, source viewer, model setup).
- `Packages/Ports`: the interfaces between parts, plus test fakes.
- `Packages/Core`: model-independent logic (chunking, retrieval, chat, ingestion).
- `Packages/Adapters`: Couchbase Lite, Core ML, LiteRT-LM, extractors, downloader.
- `Packages/LiteRTLMKit`: vendored, patched Swift wrapper for LiteRT-LM (see its README).
- `openspec/`: the change's proposal, specs, design and task list.
