# Tasks

## 1. Spike: Vision feature print in Couchbase Lite

- [x] 1.1 Add `ImageFeaturePrintSpikeTests` in Packages/Adapters (skipped unless `RUN_SPIKES=1`) that records the feature print revision, element count and type, compares the rank order of L2-normalized cosine distance against `computeDistance` on 20 test images, and measures `images_vec` results with 10, 100 and 1,000 rows at 8 and 16 centroids. Verify the findings are written in the test's header comment and decide D1 (dimension, normalization), D6 (centroids) and the brute-force fallback row count.

## 2. Ports

- [x] 2.1 Add `ImageFeaturing` (with an `EmbeddingModelIdentity`), `TextRecognizing` (`RecognizedLine` with text and box), and `ImageSearching` (`ScoredImage`), plus fakes in PortsTesting: `FakeImageFeaturer`, which gives deterministic vectors from image pixels so a re-crop of the same picture stays close, and `FakeTextRecognizer`, which returns scripted lines. Verify with PortsTests that the fake featurer puts a re-crop nearer than a different image.
- [x] 2.2 Add `ImageRecord` (ID `docId:generation:img:n`, with `makeID`/`parseID`), `ExtractedImage` with `captionSource`, `ExtractedDocument.images`, `DocumentType.image`, `IngestState.analyzingImages`, `IngestJobRecord.nextImage`, `Chunk.imageId`, `Citation.imageId`, `ImageMatch`, and `MessageRecord.attachment`, `imageMatches` and `matchesOnly`. Verify with PortsTests that older JSON without the new fields still decodes, and that image IDs never parse as chunk IDs.
- [x] 2.3 Extend `DocumentRepository` with `writeImages`, `images(docId:generation:)`, `activeImages(docId:page:)`/`(docId:heading:)`, `activeChunks(docId:page:)`/`(docId:heading:)` and `imageData(id:)`, and implement them in `InMemoryDocumentRepository`, including activation and deletion of images. Verify with PortsTests that `activate` removes the other generations' images.

## 3. Adapters: storage and search

- [x] 3.1 In `CouchbaseSchema`, add the `images` collection, the `images_vec` vector index (dimension from `ImageFeaturing.identity`, centroids from task 1.1) and an `images_doc_gen` value index. Verify that a fresh and an existing database both open, using an Adapters test that reopens a database created by the previous schema.
- [x] 3.2 Implement image writes (display-copy blob plus fields), image reads, and page and heading lookups in `CouchbaseDocumentRepository`. Make `activate` and `deleteDocument` include `images` in the same transaction. Verify with `CouchbaseRepositoryTests` that a re-index leaves only the new generation's images and that deletion leaves none.
- [x] 3.3 Implement `ImageSearching` on the repository using the `vectorSearch` pattern (unfiltered query, visibility from the ID, `featureModel` filter, window growth; the spike in 1.1 found the index accurate from 10 images up, so there is no brute-force fallback). Emit `.query` events with purpose `.image`. Verify with tests for scope filtering, a wrong-revision exclusion, a not-ready document being excluded, and a funnel with returned rows greater than visible rows.
- [x] 3.4 Teach `CouchbaseTraceInspector` the `images_vec` and `images_doc_gen` index names and how to shorten an image document (blob and features). Verify with a test that the image query plan names `images_vec`.

## 4. Adapters: image analysis and extraction

- [x] 4.1 Add `VisionTextRecognizer`, with language correction as an option, and move `PDFExtractor`'s OCR onto it. Verify that the existing scanned-PDF `ExtractorTests` still pass, and that a new test on a rendered "MODEL X200-B" image returns that text uncorrected.
- [x] 4.2 Add `VisionFeaturePrinter`, implementing `ImageFeaturing`, with the identity tag read at startup and normalization as decided in task 1.1. Verify with an Adapters test that a crop of a test photo is nearer than an unrelated photo.
- [x] 4.3 Add `ImageExtractor` for jpg, jpeg, png, heic and heif, applying EXIF orientation, and register the types in `FileDocumentExtractor`. Verify with tests on fixtures that include a rotated HEIC.
- [x] 4.4 Add image placement scanning to `PDFExtractor`: `CGPDFScanner` with `q`/`Q`/`cm` tracking, Form XObject recursion, and caption search in the band below and then above each image. Verify with `ExtractorTests` on generated PDFs: a captioned photo on page 2 with its caption, an image inside a Form XObject, and a damaged image stream that is skipped.
- [x] 4.5 Add the image filters from design D4 (minimum size, repeated digest, full-page images on OCR pages). Verify with a generated PDF that has a logo on every page and a scanned page, which yields no images while the scanned page's text is still extracted.
- [x] 4.6 Extend `DocxExtractor` to record `w:drawing` blips with alt text, resolve them through `word/_rels/document.xml.rels`, and take the caption from `Caption`-style or "Figure" paragraphs, ignoring auto-generated alt text. Verify with a DOCX fixture whose image under "Installation" has alt text "Pump, front view".

## 5. Core: ingestion

- [x] 5.1 Add the `analyzingImages` step to `IngestionService`: OCR, features and display copy per image, writes in batches of 8, resume from `nextImage`, and pausing while the model answers. Verify with Core tests using fakes that a job interrupted after the first batch resumes and ends with exactly one set of images.
- [x] 5.2 Build one image passage per stored image (caption · heading · OCR, falling back to the title) with `imageId`, appended after the text drafts. Replace `noText` with "no drafts and no images". Verify with `IngestionServiceTests` that a photo with no text becomes ready with one passage, and that a damaged image doesn't fail its document.
- [x] 5.3 Emit `imageAnalyzed` and `imagesWritten` trace events, and include the image counts in `generationActivated`. Verify with a Core test using `RecordingTracer` on a photo import, checking the event order required by the database-xray spec.

## 6. Core: retrieval and chat

- [x] 6.1 Add `PhotoQuery`, which builds query text from the typed question plus identifier and labelled OCR lines and drops lines such as `230V~` and `50Hz`. Verify with Core unit tests on three nameplate transcripts.
- [x] 6.2 Extend `Retriever.retrieve` with an optional photo: OCR, features, image search with `imageMaxDistance`, expanding hits into image passages plus same-page or same-heading passages, three-list `RankFusion`, `.passedOnImage`, and `RetrievalResult.images`. Emit `photoAnalyzed`, `FusionEntry.imagePosition` and the image relevance fields. Verify with `RetrievalTests` for the "passage reached through a photo" and "passed on a photo match" scenarios, and that calls without a photo are unchanged.
- [x] 6.3 Extend `ChatService.ask` with an optional photo. Save the attachment on the user message. For photo plus text, use the existing pipeline. For photo only, give a `matchesOnly` reply without calling the generator, or the not-found reply. Verify with `ChatTests` that a photo-only question never calls `ScriptedGenerator`, and that a nameplate question cites the X200 passages.
- [ ] 6.4 Add an image evaluation corpus to `Resources/eval` (reference photos, query photos with crops, angle and lighting changes, distractors, and caption questions) and an `ImageEvalTests` run that reports top-3 recall. Tune `imageMaxDistance` on it with the real Vision adapter. Verify that recall is at least 80% and record the chosen threshold in a comment above `RetrievalConfiguration`, as was done for `maxDistance`.
  - Status: not done. The harness (`ImageEvalTests`: a generated set that always runs, and `IMAGE_EVAL_DIR` for a folder of real photos) is built and a provisional threshold (0.25) is recorded above `RetrievalConfiguration`, tuned on a stand-in set of transformed landscape photos. Still needed: a real corpus of equipment and field photos (reference photos, new photos of the same things from other angles and light, unrelated photos, and caption questions) added to `Resources/eval` or supplied via `IMAGE_EVAL_DIR`, and the threshold re-tuned on it.
- [x] 6.5 Add a 5,000-image retrieval benchmark under `RUN_BENCHMARKS=1`. Verify that p95 is under 300 ms on the Mac, and note that the iPad figure is still to be measured on a device.

## 7. App

- [x] 7.1 Add image types to `SupportedTypes.picker`, the drop handler and the share-sheet `Info.plist` document types. Show photo documents with a thumbnail and the "Photo" label, and "N photos" for documents with images. Verify with an app UI test that imports a JPEG in stub mode and sees it reach ready with a thumbnail.
- [x] 7.2 Add camera and `PhotosPicker` buttons to the chat input with a removable photo chip, `NSCameraUsageDescription`, and a denied-access message with a Settings link. Verify with `ViewModelTests` that sending with a photo passes it to `ChatService`, and with a UI test that picks a photo through a stub picker.
- [x] 7.3 Render the attachment on user messages, thumbnails beside sources (by citation `imageId` and by `(docId, page|heading)`), and `matchesOnly` replies as an image grid with passages, including a deleted-document state. Verify with UI tests in stub mode for a cited page with a photo and for a photo-only reply.
- [x] 7.4 Add the `.image` content case to `SourceViewerModel`/`SourceViewerView` (zoomable), and route image matches from documents to the PDF page or text heading. Verify with app unit tests for both routes.
- [x] 7.5 Wire `VisionTextRecognizer`, `VisionFeaturePrinter` and image search into `LiveServiceFactory`, and the same Vision stack into `StubServiceFactory` (the text models stay stand-ins; reading photos is done by the operating system, so it is real in stub mode too), so stub seeding includes a photo document and a PDF with a photo in it. Verify that the app launches in stub mode with `-uiTestModelStub happy -uiTestSeed` and that a photo question gets a matches reply.

## 8. X-ray and demo

- [x] 8.1 Render the new event kinds (`photoAnalyzed`, `imageAnalyzed`, `imagesWritten`, image `.query`, image fusion column, image relevance) with "Why it matters" captions about two vector indexes in one embedded database and blobs stored next to their JSON. Verify with `DemoTests` that a photo question group shows the image query funnel and three-list fusion.
- [x] 8.2 Add generated sample photos (nameplates drawn in code, so no licence applies) and a generated service manual PDF that places a differently cropped copy with a caption, in `SampleDocuments`. Verify with a `DemoUITests` reset where both samples become ready and a photo question with the sample photo matches the PDF page.
- [x] 8.3 Verify that the database-xray "same answers with demo mode on or off" test still passes with photo questions added to its question set.

## 9. Docs and wrap-up

- [x] 9.1 Update README: supported photo types, asking with a photo, a talk-track step for the photo demo, and the new evaluation and benchmark switches. Verify the README commands run as written.
- [x] 9.2 Run all package tests and the app test suite on the iPad simulator. Verify that everything passes and that `openspec validate image-import-and-search --strict` is clean.
