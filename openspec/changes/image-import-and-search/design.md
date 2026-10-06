# Design

## Context

See proposal.md for the motivation and the specs in this change for the required behavior.

- Everything after extraction is text. `ExtractedDocument` is `[Block]`, `Chunk` carries text plus a 768-dimension EmbeddingGemma vector, and `Citation` is a text snapshot. EmbeddingGemma is text-only.
- `PDFExtractor` already renders scanned pages and runs `VNRecognizeTextRequest` inside the extractor. `DocxExtractor` opens the package with ZIPFoundation and parses only `word/document.xml`.
- `IngestionService` follows a fixed sequence: extract, chunk, embed in batches with resumable `nextOrdinal`, then `repository.activate(generation:)`. Activation switches the active generation and removes the other generations in one transaction. It throws `noText` when chunking produces nothing.
- Search visibility is decided from the chunk ID (`docId:generation:ordinal`) against the active generations, with an unfiltered index query and a growing candidate window (`CouchbaseChunkSearch`). Results from searches are merged by `RankFusion` (Reciprocal Rank Fusion over any number of ranked ID lists).
- The relevance gate passes on distance or on a verbatim identifier (`QueryTerms.codes`).
- `LiteRTLMKit` supports image input to Gemma, but this change does not use it (see D9).

## Goals / Non-Goals

**Goals:**
- No new model, bundled or downloaded. Only Vision framework requests.
- Reuse the passage pipeline wherever an image can be reduced to text, so typed search, citations, scope, re-indexing and deletion mostly come for free.
- Images and passages of a generation become visible, are replaced, and are deleted together, in the same transactions.

**Non-Goals:**
- Vector line drawings in PDFs (exploded views, wiring diagrams drawn as paths), and figure detection on rendered pages.
- Matching text to images by meaning (CLIP-style). Typed search reaches images only through their caption, heading and recognized text.
- Sending images to the language model, or generating image captions.
- Cropping or highlighting the image region in the PDF source view.
- Images in Markdown files (`![](…)`). An imported `.md` has no access to the referenced files.

## Decisions

### D1. Image features: Vision feature print behind an `ImageFeaturing` port

Ports gains `protocol ImageFeaturing: Sendable { var identity: EmbeddingModelIdentity { get }; func features(of image: CGImage) async throws -> [Float] }`. The adapter wraps `VNGenerateImageFeaturePrintRequest`. Its identity is `vision-featureprint@<revision>/<elementCount>`, read from the request and observation at startup, so an OS revision change shows up as a different tag. The vector is L2-normalized before storing, so the cosine metric in Couchbase Lite ranks the same way as the feature print's own distance.

*Alternatives:* MobileCLIP (rejected: adds ~150 MB of bundled model, and text-to-image by meaning is a non-goal); Gemma vision captions (rejected: needs the 3.7 GB model at import time and is slow per image).

The first task is a spike that confirms the element count and type for the current revision, whether normalized cosine distance ranks the same as `computeDistance`, and the training behavior of the vector index with a small library. It is recorded the same way as the existing `VectorSearchSpikeTests`.

### D2. Text recognition becomes a shared port

The OCR in `PDFExtractor.recognize` moves to a `TextRecognizing` port with a Vision adapter (`recognize(_ image: CGImage) -> [RecognizedLine]`, where each line has text and a bounding box). `PDFExtractor` uses it for scanned pages, unchanged in behavior. Ingestion uses it for every kept image, and chat uses it for photo questions. The adapter runs each request on a dedicated serial queue rather than the Swift concurrency pool, sets `automaticallyDetectsLanguage`, and leaves language correction off for images, because nameplate codes such as `X200-B` get "corrected" otherwise. Scanned pages keep correction on, as they have it today.

### D3. Data model: an `images` collection, plus one passage per image

```
images collection (sync-ready)                 chunks collection (unchanged shape)
id      docId:generation:img:n                 id      docId:generation:ordinal
docId, generation, n, page?, heading?          ...existing fields...
caption?, captionSource (nearby|alt|none)      imageId?   <-- new, set on image passages
ocrText, width, height
features [Float], featureModel (tag)
image   blob (display copy, JPEG)
```

- The image ID carries the generation, so `CouchbaseImageSearch` checks visibility from the ID, as chunk search does. The `img` segment keeps image IDs and chunk IDs apart.
- Each image produces one `ChunkDraft` whose text is `caption · heading · ocrText`, in that order, with empty parts dropped. If all three are empty, the text is the document title. These drafts are appended after the text drafts, continuing the ordinal sequence, with `imageId` set. Embedding, keyword search, scope, the relevance gate and citations all work on them unchanged.
- `Citation` and `Chunk` gain `imageId: String?`. `MessageRecord` gains `hasAttachment` (the user's photo is a display-copy blob on the message document, read with `ChatRepository.attachment(messageId:)` so listing messages never loads it; saving a message again keeps its photo), `imageMatches: [ImageMatch]` and `matchesOnly`. `ImageMatch` is a snapshot of image ID, doc ID, document title, page, heading, and distance, so it still renders after deletion. All new fields decode as absent on older records, following the `MessageRecord` pattern already in place.
- `DocumentType` gains `.image`. Its original file is stored as today, unchanged.

The display copy is downscaled to at most 1600 px on the long edge and encoded as JPEG at quality 0.8, with no metadata copied. This keeps the collection small and drops EXIF location from the copy that a future replicator would carry. The original file blob of an imported photo is stored as-is, as the "Original file retention" requirement needs.

*Alternative:* storing images only as fields on chunks (rejected: a second vector field on chunks would need its own index anyway, and image-only data such as blob and size would bloat every passage).

### D4. Extraction output

`ExtractedDocument` gains `images: [ExtractedImage]`. Each has a `CGImage` (or encoded data), page, heading, caption and `captionSource`. Extractors only find images and their context. Analysis (OCR and features) happens in ingestion, so it can report progress and is shared by all sources.

- **Photo files** (`ImageExtractor`): one image, with EXIF orientation applied, and no blocks.
- **PDF**: a `CGPDFScanner` pass per page tracks the graphics state (`q`, `Q`, `cm`) and records each `Do` of an Image XObject with its placed rectangle in page space. Inline images (`BI`/`ID`) are ignored. The caption is the PDFKit text in a band directly below the rectangle, else directly above it. It is accepted only if it is short (one to two lines) or starts with `Fig`, `Figure`, `Abb` or `Photo`.
- **DOCX**: the XML delegate notes `w:drawing` → `a:blip r:embed` and `wp:docPr descr`/`title` at its place in reading order. `word/_rels/document.xml.rels` maps the relationship to `word/media/…`. The caption is the alt text if it is present and not auto-generated ("A picture containing…" is treated as absent). Otherwise it is the next paragraph if that paragraph has style `Caption` or starts with `Figure`. The heading is the current heading.

**Filters**, applied in the extractor:
- shortest side under 160 px;
- the same image data (by digest) appearing on more than 3 pages of the document;
- PDF pages that went through OCR and whose largest image covers more than 70% of the page.

Decode failures for one image are logged and skipped. *Assumption:* these thresholds are starting values, tuned on the sample documents and evaluation set.

### D5. Ingestion: an "analyzing images" step that is safe to repeat

After extraction, the job enters `analyzingImages`. For each image, it runs OCR, computes the feature print, makes the display copy, and writes images in batches of 8 through `repository.writeImages`. The batches are atomic, and the deterministic IDs mean that redoing a batch overwrites it. On resume, the step starts at `nextImage`, a new field on the job, stored like `nextOrdinal`. The image drafts are then built from the stored images, so a resumed job does not need the images it analyzed earlier.

The `noText` check moves to "no drafts and no images", so a photo with no text becomes ready. `activate(generation:)` deletes other generations from both `chunks` and `images` in the same transaction it already uses. `deleteDocument` purges both collections.

Ingestion is paused while the language model answers (`setPaused`), as embedding already is. This avoids Vision and LiteRT competing for the GPU.

### D6. Image search adapter

A new `ImageSearching` port (`imageSearch(_ vector:, limit:, filter:) -> [ScoredImage]`) is implemented in the Couchbase adapter on the same pattern as `vectorSearch`. It uses an unfiltered `APPROX_VECTOR_DISTANCE(features, $vector, "cosine")` over `images_vec`, checks visibility from the ID, filters out rows with the wrong `featureModel`, uses the same window growth (it is the same loop as passage search, made generic), and reports the same `QueryTrace` funnel with purpose `.image`. `images_vec` uses 8 centroids against 64 for `chunks_vec`, because photo libraries are far smaller than passage sets. The spike (D1) measured 8 and 16 centroids as equally accurate from 10 to 1,000 images.

### D7. Retrieval with a photo

```
photo --> TextRecognizing --> ocr lines --> PhotoQuery.text(typed, ocr)
      \-> ImageFeaturing  --> vector  --> imageSearch --> image hits (<= imageMaxDistance)
                                                             |
                     for each hit, best first: its image passage, then the active
                     passages on the same page (PDF) or under the same heading (DOCX)
                                                             v
   text vector list   +   keyword list   +   image-reached list  --> RankFusion (3 lists)
```

- **Query text.** It's the typed question, plus the OCR lines that contain an identifier (`QueryTerms.codes`) or follow a label such as `Model`, `Type`, `P/N` or `Part`. Lines such as `230V~` and `50Hz` are only kept if they're identifiers. If there's no typed question, the identifiers alone are the query. Then the existing keyword search finds `X200-B` verbatim, and the identifier relevance path applies.
- **Expanding hits into passages.** It's done with a new repository read, `activeChunks(docId:page:)` or `(docId:heading:)`, using the existing `chunks_doc_gen` index with an extra predicate.
- **Relevance.** `RelevanceOutcome` gains `.passedOnImage(distance)`. `RetrievalConfiguration` gains `imageMaxDistance` and `imageCandidates`. `RetrievalResult` gains `images: [RetrievedImage]`.
- `Retriever.retrieve(_ question:, photo: CGImage? = nil, scope:)` keeps its existing call sites unchanged.

### D8. Chat flow and the matches-only reply

`ChatService.ask` takes an optional photo. The user message is saved with the attachment before retrieval.

- **Photo plus text.** This is today's pipeline with photo retrieval. The query rewriter sees only text, and the answer prompt is unchanged, so `PromptBuilder`, `CitationValidator` and the not-found gate are untouched.
- **Photo only.** No rewrite and no generation. If retrieval is relevant, the reply is a `MessageRecord` with fixed text ("Matching photos and passages from your documents:"), `imageMatches`, and the fused passages as citations. Otherwise it's the not-found reply. A new flag `matchesOnly` lets the chat view render it as a result list rather than prose.

The X-ray "generation skipped" event covers this case.

### D9. No image goes to Gemma

Sending the photo to Gemma 4 E4B would let the model describe things the documents never say, against "Strictly grounded answers". It would also need the vision backend loaded beside the text session. The OCR and identifier route gets the nameplate case without it. *Alternative kept for later:* using Gemma vision only to pull out labelled fields from a nameplate, with the output used as query text and never shown. This would be a separate change, measured against the OCR heuristic.

### D10. App surfaces

- **Library and import.** `SupportedTypes.picker` and the drop handler gain `.jpeg`, `.png` and `.heic`. Library rows show a thumbnail for `.image` documents, and "N photos" for documents with images.
- **Chat input.** A camera button (wrapping `UIImagePickerController`, shown only when `isSourceTypeAvailable(.camera)`) and a `PhotosPicker` button attach one photo, shown as a removable chip. `Info.plist` gains `NSCameraUsageDescription`. When access is denied, the app shows a short message with a Settings link.
- **Answers.** Sources show thumbnails resolved from `images` by `(docId, page|heading)` of each citation, and from `imageId`. Thumbnails load lazily from the blob, with a small in-memory cache. Matches-only replies render as a grid of image matches, with the passages below.
- **Source viewer.** It gains a `.image(title:, url:)` content case, zoomable, for imported photos. Image matches from documents open the existing PDF or text view at the page or heading.
- **X-ray.** It gains event kinds `imageAnalyzed`, `imagesWritten` and `photoAnalyzed`. `.query` gains purpose `.image`, `FusionEntry` gains `imagePosition`, and `.relevance` gains the image fields. `CouchbaseTraceInspector` learns `images_vec`, and shows the image blob as type, size and digest. Captions go in the existing app-side table.
- **Demo samples.** The photos are drawn in code (a steel nameplate with stamped text, for an X200 and for an X100), so there is no photograph to license. Reset imports the X100 plate as a photo document and a generated service manual PDF whose figure is the X200 plate, cropped and turned a few degrees, under a caption. The X200 plate itself is the photo the presenter asks with (a button in demo mode), so a photo-to-manual match works on stage without a real nameplate.

## Risks / Trade-offs

- [The feature print matches look-alike photos of different models, such as two grey units] → The OCR identifiers come into fusion as their own list, and a nameplate code outranks visual similarity through the keyword list and the identifier relevance path. The image threshold is tuned against the evaluation set, not chosen by eye.
- [The image index barely trains on a small library] → The spike found the index returning the right top match from 10 images up, so no fallback is built. [The feature print changes dimension in a future OS revision] → The index dimension is fixed when the index is created, and images carry their model tag, so a changed tag excludes old images. A changed dimension would also need a new index, which is out of scope until a revision actually changes it.
- [PDF image placement parsing misses images (Form XObjects, unusual transforms)] → Recurse into Form XObjects with their matrix. Anything else is skipped and the document still indexes. Tests use generated PDFs with nested forms.
- [Photo-heavy manuals slow ingestion: OCR runs on every kept image] → Progress is shown as "analyzing images n/m", and resume avoids repeating work. Recognition stays at the accurate level: a nameplate photo is the case where a missed character costs the most. All Vision requests run one at a time on a dedicated serial queue (see `VisionQueue`), because blocking requests issued from the Swift concurrency pool starved it and hung the test run.
- [Storage grows with display copies] → The 1600 px JPEG copies are about 150–300 KB each. The library shows the photo count, so a heavy document is visible.
- [Captions picked from the wrong text block in PDFs] → A strict band and length rule, and a wrong caption only adds noise to one passage. Evaluation questions check that images can be found by their captions.
- [The photo-only reply might feel like an empty answer] → It is shown as a result grid, with a hint to add a question. This keeps the "no generated text without grounding" rule simple.

## Migration Plan

- Existing records decode with the new fields absent. The `images` collection and `images_vec` index are created on launch by `CouchbaseSchema.prepare`, which already uses create-if-missing.
- Existing documents get images when they are re-indexed. There is no automatic re-index. The library shows no photo count for them until then.
- Rollback: the extra collection and fields are ignored by the previous build, and chunks that have `imageId` are ordinary passages to it.

## Open Questions

- Whether the photo copy attached to a question should be kept forever with the chat or pruned after a period. This doesn't affect the specs, which only require that it is stored and shown.
- Exact thresholds (minimum image size, repeat count, caption band height). These are tuned during implementation against the samples.
