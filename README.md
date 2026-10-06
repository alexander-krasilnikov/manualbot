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

## Demo mode (X-ray)

For showing what the app and Couchbase Lite do behind each action. Turn it on in About (the switch is remembered) or
launch with `-demoMode`. The right-hand column then has a `Source | X-ray` switch; tapping a citation or a document
returns to Source. With demo mode off the app is unchanged.

X-ray lists every import, question, source opening, re-index and deletion as a group, with each database step inside:
the SQL++ as executed with its parameters, the time, the index the query plan uses (the raw plan is one tap away), how
many rows the index returned, how many were visible and how many were used, and the stored JSON of any passage or
document ID you tap. "Why it matters" adds one sentence per step. "Slow reveal" shows a burst of steps one at a time,
the text buttons enlarge the panel for a projector, and "Reset demo" (after confirming) clears the library and chats
and imports four sample documents.

Run it on the real database without the real models: `-uiTestModelStub happy -uiTestSeed -demoMode`. The panel then shows a
"stub models" notice, because the distances come from a stand-in embedder and mean nothing; use the real models when you
want to talk about relevance.

### Talk track

1. **Import.** Tap Reset demo, then watch the Import groups: the file is stored as a blob next to its JSON record, the
   passages and their vectors are written in one transaction, and the passage set is made searchable in a second one. The
   indexing job is saved in a collection that never replicates.
2. **Ask.** "How do I reset the X200?" Open the vector search: one SQL++ query over the same database that holds the
   documents, the index it used, and the stored passage with its 768-number vector as an ordinary JSON field.
3. **Exact codes.** "What does error E-042 mean?" Open the keyword search and the merge: a full-text query in the same
   engine, and the two result lists merged by rank. This is why a code and a description both land on the right page.
4. **Follow-up.** Ask "And the X100?" and show the rewritten standalone query, then an off-topic question and the
   relevance check that stops the model being called.
5. **Offline.** Turn on airplane mode: the network indicator flips and everything above still works and is still traced.

### If asked: "so filtered vector search is slow?"

At 20,000 passages, adding the visibility filter to the vector query cost about 160-330 ms, against a few milliseconds
without it. So the index is queried unfiltered and visibility (the active generation of a ready document) is decided from
the passage ID, which encodes document, generation and position. The row funnel in X-ray shows this: rows the index
returned, rows that were visible, rows used. It also keeps a re-index in progress invisible to search until it is switched
in. These figures were measured earlier in this project and are recorded in the comment above the search code
(`CouchbaseChunkSearch.swift`); re-measure with `RUN_BENCHMARKS=1` before quoting them, and do not generalise them to other products.

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
