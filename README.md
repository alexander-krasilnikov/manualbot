# ManualBot

An iPad app that answers questions about your own documents (PDF, Word, text, photos), entirely on the device.
Import documents, and ask in a chat, with words, with a photo, or both. Answers come only from your documents and cite
the page or section they came from; if the documents don't say, the app says so.

- Search: vector search (EmbeddingGemma 2, 256 dimensions) plus keyword search, stored in Couchbase Lite.
- Photos: the same model embeds photos into the same space as the text, in a second vector index in the same database, so
  a photo finds photos that look like it and typed words find photos by meaning ("the red pump"), even uncaptioned ones.
  The text printed on a photo (a nameplate, say) is read by Apple's Vision text recognition.
- Answers: Gemma 4 E2B, constrained to the retrieved chunks.
- Runtime: both models run on [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) (GPU on devices and Mac, CPU in the
  simulator). The one Apple framework left is Vision's text recognition, which reads scanned pages, photos and nameplates:
  it ships with the operating system, needs no model of its own, and replacing it (a second runtime, hand-written
  pre- and post-processing) was judged not worth it.
- Offline: after both models are downloaded once, nothing needs the network.
- Targets: iPadOS 26 on M4/M5 iPads.

## Set up

Requirements: Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate             # creates ManualBot.xcodeproj from project.yml
open ManualBot.xcodeproj      # run on an iPad simulator, landscape
```

Nothing is built into the app. On first launch it needs a network connection to download two models from Hugging Face,
each verified by checksum: the embedding model (EmbeddingGemma 2, 388 MB) first, so documents can be imported as soon as it
arrives, then the language model (Gemma 4 E2B, 2.6 GB). Until the embedding model is installed nothing can be imported. If
a model file is deleted later, the app returns to the setup screen for it and keeps every document and chat. A language model
that the app no longer lists (the earlier Gemma 4 E4B, 3.7 GB) is deleted at launch.

**After an update that changes the embedding model**, every document is re-indexed automatically in the background
(the library shows "Updating index"), because vectors from different models cannot be compared. Keyword search keeps
finding the documents meanwhile, and vector and photo search return as each one finishes. Chats and originals are untouched.

In the simulator both models run on the CPU (its Metal cannot run them), so indexing and answers are much slower than on an iPad.

### Try it without the real models

Add launch arguments in the scheme (Run, Arguments): `-uiTestModelStub happy -uiTestSeed`. This uses the real database,
extraction, ingestion, retrieval and chat logic with stand-in models (text on photos is still read by the operating system; one stand-in model embeds words and photos, and the words "x100 nameplate" are scripted to find the sample nameplate photo), and five sample documents already indexed, including a photo and a manual with a photo in it.
Other flags: `-uiTestSlow` (slow, stoppable answers). Stub scenarios: `happy`, `llmFailsOnce`, `lowStorage`.

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
  chunks from those pages. Nothing is generated.
- An answer shows the photos on the pages it cites, and tapping one opens that page.

**Ask with words.** A typed question also searches the photos by meaning, so "where is the drain plug?" finds a photo of
the drain plug that nobody captioned, and the answer shows it beside the text, with the chunks of its page. Matching
photos only add to the answer: a photo whose look merely resembles the words never makes a question answerable on its own.

Photos are analyzed on the iPad and are never given to the language model: answers still come only from document text.
A photo kept with a question is stored without its metadata (no location, camera or time).

**Simulator.** Photo search works in the simulator too, on the CPU with the real embedding model (about a second per
photo), or in stub mode with stand-in features (`-uiTestModelStub`).

The distances that count as a match are `imageMaxDistance` (photo to photo) and `textToImageMaxDistance` (words to photo)
in `RetrievalConfiguration`. Both are **provisional**: tuned on 14 Wikimedia Commons photos of equipment, where the query is
a *different* photo of the same kind of thing, not photos taken in the field. Re-tune them with real photos before relying on
them (see Tests, `IMAGE_EVAL_DIR`).

## X-ray and the database explorer

For showing what the app and Couchbase Lite do behind each action. There is nothing to switch on: the right-hand column
has a `Source | X-ray` switch, and tapping a citation or a document returns to Source.

X-ray lists every import, question, source opening, re-index and deletion as a group, with each database step inside
(for photos: each photo read, the batch of photos stored as blobs beside their JSON, and the image search over the second
vector index):
the SQL++ as executed with its parameters, the time, the index the query plan uses (the raw plan is one tap away), how
many rows the index returned, how many were visible and how many were used, and the stored JSON of any chunk or
document ID you tap. "Why it matters" adds one sentence per step. "Slow reveal" shows a burst of steps one at a time,
the text buttons enlarge the panel for a projector, and "Reset demo" (after confirming) clears the library and chats
and imports six sample documents (the four text ones, a service manual PDF whose figure is a photo of a nameplate, and a
photo of another unit's nameplate; the photos are drawn in code, so they carry no licence of their own).

Run it on the real database without the real models: `-uiTestModelStub happy -uiTestSeed`. The panel then shows a
"stub models" notice, because the distances come from a stand-in embedder and mean nothing; use the real models when you
want to talk about relevance.

### Database explorer

The Library toolbar has a **Database** button that opens a full-screen, read-only view of the local Couchbase
Lite database; Done returns to exactly where you were. Collections are grouped as sync-ready and local only, each with its
document count (read when it opens, and again with Refresh). Pick a collection to page through its document IDs (filter by
ID), then a document to see it as stored: vectors shortened with "Show in full", image and text blobs with a preview, and
fields that name another document (`docId`, `chatId`, `imageId`) are links, with Back returning to where you came from.
A document record also lists its chunks and images. Indexes shows each index's kind and settings. **Query** is a SQL++
console: pick a starter (keyword search, the chunks of one document, ingest jobs by state) or type a SELECT, see up to
200 rows with the time, and open the query plan. Parameters (`$name`, including `$vector`) are not supported. Tapping a
document ID in X-ray opens the explorer at that document. It never writes, and it adds nothing to the X-ray log.

### Document contents

To see how a document was split, tap the **›** at the right of a ready document in the Library (photos have nothing to
open). The sidebar then lists the document's chunks or its images (the switch at the top), grouped under page headers for
a PDF and under headings for other files. A chunk that stands for a photo carries a photo mark. Tap one and the right-hand
column shows it: for a chunk, its number out of the total, page and heading, length, embedding model and number of
dimensions, and its full text, with the sentences it repeats from the previous chunk and the next chunk tinted
(Previous and Next step through the list); for an image, the stored picture (pinch to zoom), its size, caption and where
the caption came from, and the text read off it. **Show in document** opens the original at that spot with the chunk
highlighted, and **Show chunk** on an image jumps to the chunk that makes it searchable. The list is read when it opens and
again when a re-index finishes; X-ray shows that read as one "Contents of …" step. Nothing is written, and previews run
no queries, so stepping through chunks adds nothing to the X-ray log.

### Talk track

1. **Import.** Tap Reset demo, then watch the Import groups: the file is stored as a blob next to its JSON record, the
   chunks and their vectors are written in one transaction, and the chunk set is made searchable in a second one. The
   indexing job is saved in a collection that never replicates.
2. **Ask.** "How do I reset the X200?" Open the vector search: one SQL++ query over the same database that holds the
   documents, the index it used, and the stored chunk with its 256-number vector as an ordinary JSON field.
3. **Exact codes.** "What does error E-042 mean?" Open the keyword search and the merge: a full-text query in the same
   engine, and the two result lists merged by rank. This is why a code and a description both land on the right page.
4. **Follow-up.** Ask "And the X100?" and show the rewritten standalone query, then an off-topic question and the
   relevance check that stops the model being called.
5. **Photo.** Tap the sample-photo button (or the camera, with a real nameplate) and send the photo alone: the app reads
   "MODEL X200-B" off the plate, finds the manual page whose figure looks like it, and lists that page's chunks. In
   X-ray, open the photo analysis, then the image search: a second vector index (`images_vec`) in the same database,
   queried with the same SQL++, and the merge now has a third list. Add "how do I descale it?" to get a cited answer.
   Then type "where is the nameplate?" with no photo: the question's own vector searches the same photo index (Words → photos
   search), and a fourth column appears in the merge.
6. **Look inside.** Tap Database after an import: the chunks each point back to their document, ingest jobs and the
   vector-index settings sit in collections that never replicate, and the keyword starter runs the same full-text query
   in the console, with a plan that names `chunks_fts`.
7. **Chunks.** Tap › next to the service manual and open its image, then Show chunk to land on the text that makes the
   figure searchable. To show the overlap, open a longer document (the sample PDFs are about one chunk a page, so there
   is nothing to tint): step through two chunks and point out the sentences the next chunk repeats, which is why a
   question that lands on a chunk's edge still finds its answer.
8. **Offline.** Turn on airplane mode: the network indicator flips and everything above still works and is still traced.

### If asked: "so filtered vector search is slow?"

At 20,000 chunks, adding the visibility filter to the vector query cost about 160-330 ms, against a few milliseconds
without it. So the index is queried unfiltered and visibility (the active generation of a ready document) is decided from
the chunk ID, which encodes document, generation and position. The row funnel in X-ray shows this: rows the index
returned, rows that were visible, rows used. It also keeps a re-index in progress invisible to search until it is switched
in. These figures were measured earlier in this project and are recorded in the comment above the search code
(`CouchbaseChunkSearch.swift`); re-measure with `RUN_BENCHMARKS=1` before quoting them, and do not generalise them to other products.

## Tests

```sh
for p in Ports Core Adapters; do (cd Packages/$p && swift test); done      # packages, on the Mac
DEST='platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
xcodebuild test -project ManualBot.xcodeproj -scheme ManualBot -destination "$DEST" \
  -only-testing:ManualBotTests                                                # app unit tests
xcodebuild test-without-building -project ManualBot.xcodeproj -scheme ManualBot -destination "$DEST" \
  -only-testing:ManualBotUITests -parallel-testing-enabled YES -parallel-testing-worker-count 2   # UI tests, ~12 min
```

The UI tests run on two simulator clones at once (about 12 minutes instead of 20). Three clones are not faster: they slow
each other down enough that timing-sensitive tests fail. The unit tests run on their own first for the same reason.

Tests against the real models are skipped unless you point them at the files (the app downloads its models; to run these
tests fetch them yourself from the `url` entries in `App/Resources/ModelManifest.json`, into a folder outside the
repository or into `LocalModels/`, which git ignores):

| Variable | Points at | Enables |
|---|---|---|
| `EMBEDDER_MODEL_PATH` | `embeddinggemma-2-text-vision-440m.litertlm` | embedder, retrieval and photo evaluations, large-document tests |
| `GENERATOR_MODEL_PATH` | `gemma-4-E2B-it.litertlm` | generator, full-pipeline tests, answer evaluation |
| `ANSWER_EVAL_BASELINE_MODEL_PATH` | `gemma-4-E4B-it.litertlm` | with the two above, runs a baseline model first and prints whether the candidate meets the pass criteria |
| `ANSWER_EVAL_REPORT`, `ANSWER_EVAL_MODEL` | a Markdown file, a name | save the answer evaluation's report and name the model in it |
| `RUN_BENCHMARKS=1` | | 20,000-chunk retrieval benchmark and 5,000-photo search benchmark (add `EMBEDDER_MODEL_PATH`) |
| `RUN_SPIKES=1` | | the EmbeddingGemma 2 spike (output size, input limits, templates, latency) |
| `IMAGE_EVAL_DIR` | a folder of photos (below) | photo and words-to-photo search evaluation on those photos |

For the iOS simulator, prefix the variables with `TEST_RUNNER_`.

```sh
# Retrieval quality (recall, relevance threshold, chunk sizes), in Packages/Adapters:
EMBEDDER_MODEL_PATH=…/embeddinggemma-2-text-vision-440m.litertlm swift test --filter RealEvalTests
# Answer quality of a language model (31 questions and 6 follow-up pairs), comparing a candidate with the current one:
EMBEDDER_MODEL_PATH=… GENERATOR_MODEL_PATH=…/gemma-4-E2B-it.litertlm ANSWER_EVAL_BASELINE_MODEL_PATH=…/gemma-4-E4B-it.litertlm \
  swift test --filter AnswerEvalTests
```

The photo evaluation (`ImageEvalTests`) always runs on a generated set (procedural scenes and drawn shapes such as "a red
circle"), which checks the harness but cannot judge real photos. For real ones, point `IMAGE_EVAL_DIR` at a folder with the
library's photos in `references/`, other photos of the same things (other angle, light, crop) and unrelated photos in
`queries/`, and an `eval.json` that may also list typed descriptions of the reference photos:

```json
{"queries": [{"file": "pump-angle2.jpg", "expected": "pump.jpg"}, {"file": "unrelated.jpg", "expected": null}],
 "texts": [{"text": "a centrifugal pump", "expected": "pump.jpg"}],
 "unrelatedTexts": ["a plate of spaghetti"]}
```

```sh
IMAGE_EVAL_DIR=~/image-eval EMBEDDER_MODEL_PATH=…/embeddinggemma-2-text-vision-440m.litertlm \
  swift test --filter ImageEvalTests    # in Packages/Adapters; prints recall and a threshold table
```

It reports the share of query photos and of descriptions whose expected photo is in the top three, and, for each candidate
threshold, how many matches are kept and how many unrelated photos or descriptions are rejected. Use it to set
`imageMaxDistance` and `textToImageMaxDistance`.

The simulator needs an iOS 27 runtime; the app tests above name `iPad Pro 13-inch (M5)`, which is one.

## Layout

- `App/`: SwiftUI app (library, chat, source viewer, model setup).
- `Packages/Ports`: the interfaces between parts, plus test fakes.
- `Packages/Core`: model-independent logic (chunking, retrieval, chat, ingestion).
- `Packages/Adapters`: Couchbase Lite, LiteRT-LM (embedding and answers), Vision text recognition, extractors, downloader.
- `Packages/LiteRTLMKit`: vendored, patched Swift wrapper for LiteRT-LM (see its README).
- `openspec/`: the change's proposal, specs, design and task list.
