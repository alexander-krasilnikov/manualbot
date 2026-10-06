# ManualBot

An iPad app that answers questions about your own documents (PDF, Word, text, photos), entirely on the device.
Import documents, and ask in a chat, with words, with a photo, or both. Answers come only from your documents and cite
the page or section they came from; if the documents don't say, the app says so.

- Search: vector search (EmbeddingGemma 300M, Core ML) plus keyword search, stored in Couchbase Lite.
- Photos: photos are searched by how they look (Apple's Vision feature print, in a second vector index in the same
  database) and by the text on them (Vision text recognition). Both come with the operating system: no extra model.
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
extraction, ingestion, retrieval and chat logic with fake models (text on photos is still read by the operating system; how a photo *looks* is a stand-in too), and five sample documents already indexed, including a photo and a manual with a photo in it.
Other flags: `-uiTestSlow` (slow, stoppable answers). Stub scenarios: `happy`, `bundled`, `llmFailsOnce`, `lowStorage`.

## Photos

**Import.** JPEG, PNG and HEIC files import like any document (picker, share sheet, drag and drop). A photo document is
findable by its title, by the text read from it, and by how it looks. Photos *inside* PDF and Word files are found too:
each one is stored with its page (PDF) or section (Word) and a caption, taken from the text next to it or the author's
description. Logos, icons, pictures repeated on many pages, and full-page scans are skipped. Documents imported before
photos were supported get their photos when they are re-indexed.

**Ask with a photo.** In the chat, the camera button takes a photo and the photo button picks one; send it alone or with a
question.

- Photographing a **nameplate** reads its model and part numbers (ratings, dates and protection classes are left out) and
  searches the documents for them, so "how do I descale it?" with a photo of the unit finds the right manual.
- A photo **alone** is answered with the library photos that look like it, each with its document and page, and the
  passages from those pages. Nothing is generated.
- An answer shows the photos on the pages it cites, and tapping one opens that page.

Photos are analyzed on the iPad and are never given to the language model: answers still come only from document text.
A photo kept with a question is stored without its metadata (no location, camera or time).

**On a device only.** Photo similarity needs the system's image model, which the iOS Simulator does not have (it returns the
same result for every picture). The app checks for this at start-up and leaves photo search off there rather than
matching everything with everything, so try photos on an iPad, or in stub mode (stand-in features, `-uiTestModelStub`).

The distance that counts as "looks like" is `imageMaxDistance` in `RetrievalConfiguration`. It is **provisional**: tuned on
transformed landscape photographs, not on photos of equipment. Re-tune it with real photos before relying on it (see
Tests, `IMAGE_EVAL_DIR`).

## Demo mode (X-ray)

For showing what the app and Couchbase Lite do behind each action. Turn it on in About (the switch is remembered) or
launch with `-demoMode`. The right-hand column then has a `Source | X-ray` switch; tapping a citation or a document
returns to Source. With demo mode off the app is unchanged.

X-ray lists every import, question, source opening, re-index and deletion as a group, with each database step inside
(for photos: each photo read, the batch of photos stored as blobs beside their JSON, and the image search over the second
vector index):
the SQL++ as executed with its parameters, the time, the index the query plan uses (the raw plan is one tap away), how
many rows the index returned, how many were visible and how many were used, and the stored JSON of any passage or
document ID you tap. "Why it matters" adds one sentence per step. "Slow reveal" shows a burst of steps one at a time,
the text buttons enlarge the panel for a projector, and "Reset demo" (after confirming) clears the library and chats
and imports six sample documents (the four text ones, a service manual PDF whose figure is a photo of a nameplate, and a
photo of another unit's nameplate; the photos are drawn in code, so they carry no licence of their own).

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
5. **Photo.** Tap the sample-photo button (or the camera, with a real nameplate) and send the photo alone: the app reads
   "MODEL X200-B" off the plate, finds the manual page whose figure looks like it, and lists that page's passages. In
   X-ray, open the photo analysis, then the image search: a second vector index (`images_vec`) in the same database,
   queried with the same SQL++, and the merge now has a third list. Add "how do I descale it?" to get a cited answer.
6. **Offline.** Turn on airplane mode: the network indicator flips and everything above still works and is still traced.

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
| `RUN_BENCHMARKS=1` | | 20,000-passage retrieval benchmark and 5,000-photo search benchmark |
| `RUN_SPIKES=1` | | the Vision feature print spike (format, ranking, index behaviour) |
| `IMAGE_EVAL_DIR` | a folder of real photos (below) | photo search evaluation on real photos |

For the iOS simulator, prefix the variables with `TEST_RUNNER_`.

The photo evaluation (`ImageEvalTests`) always runs on a generated set, which checks the harness but cannot judge real
photos. For real ones, point `IMAGE_EVAL_DIR` at a folder with the library's photos in `references/`, new photos of the
same things (other angle, light, crop) and unrelated photos in `queries/`, and an `eval.json`:

```json
{"queries": [{"file": "pump-angle2.jpg", "expected": "pump.jpg"}, {"file": "unrelated.jpg", "expected": null}]}
```

```sh
IMAGE_EVAL_DIR=~/image-eval swift test --filter ImageEvalTests    # in Packages/Adapters; prints recall and a threshold table
```

It reports the share of query photos whose expected photo is in the top three, and, for each candidate threshold, how
many matches are kept and how many unrelated photos are rejected. Use it to set `imageMaxDistance`.

The simulator needs an iOS 26 runtime; the app tests above name `iPad Pro 13-inch (M5)`, which is one.

## Layout

- `App/`: SwiftUI app (library, chat, source viewer, model setup).
- `Packages/Ports`: the interfaces between parts, plus test fakes.
- `Packages/Core`: model-independent logic (chunking, retrieval, chat, ingestion).
- `Packages/Adapters`: Couchbase Lite, Core ML, LiteRT-LM, extractors, downloader.
- `Packages/LiteRTLMKit`: vendored, patched Swift wrapper for LiteRT-LM (see its README).
- `openspec/`: the change's proposal, specs, design and task list.
