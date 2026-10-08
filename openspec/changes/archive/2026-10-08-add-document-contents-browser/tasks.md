# Tasks

## 1. Trace operation kind (Ports, App)

- [x] 1.1 Add `browseContents` to `TraceOperation.Kind` (design D7); verify that `swift build` in Packages/Ports succeeds. (No X-ray view switches on the kind, so no icon or label is needed.)

## 2. Contents model and sidebar (App)

- [ ] 2.1 (Built; the UI tests for the control, Back and the row tap pass. Still to do: the narrow-window check, which needs iPad Split View or Slide Over and cannot be driven by the UI tests.) Wrap `LibraryView`'s list in a `NavigationStack` with a document-ID path, and add the trailing contents control to `LibraryRow`, shown only for ready (`isReady`) documents that are not photos, with the `contents-<title>` identifier (design D1, D9). Push a placeholder view, then check in the simulator on a full-width and a narrow (split-screen) iPad window that pushing and going back work and that the row tap still opens the document (design risk 1); verify with a UI test that the control is absent for the seeded photo document and that Back returns to the library.
- [x] 2.2 Add `ChunkOverlap.shared(previous:current:)` (design D5); verify with app unit tests that it returns the repeated sentences for two consecutive chunks produced by `Chunker` with `.embeddingGemma2`, nothing for chunks on different PDF pages, and nothing when either chunk stands for an image.
- [x] 2.3 Add `DocumentContentsModel` with vector-free `ChunkEntry` and `ImageEntry`, `kind`, `selection`, `sections` (design D4), `load()` under a `browseContents` operation, and a thumbnail cache (design D2); verify with app unit tests on `InMemoryDocumentRepository` that PDF chunks group by page with an image's proxy chunk at the end of its page section, that headings group in order of first ordinal, that `load()` keeps only the active generation, and that with a `RecordingTracer` the load records events under one `browseContents` operation.
- [x] 2.4 Build `DocumentContentsView`: a Chunks / Images switch (`contentsKind`) with counts, sectioned lists, chunk rows (number, first two lines, photo badge for proxy chunks), image rows (thumbnail, caption), and the empty state for a document without images (`contentsEmpty`) (design D9); verify with a UI test that a seeded PDF shows page sections and a badged chunk, and that the seeded text document's Images list says it has none.

## 3. Previews (App)

- [x] 3.1 Add `.chunk(ChunkPreview)` and `.image(ImagePreview)` to `SourceViewerModel.Content` with `preview(_:)` for the selected chunk or image (design D3, D7); verify with app unit tests that a chunk preview carries its position, total, overlap ranges and Previous/Next availability, and that previews and stepping record no trace events against a real database.
- [x] 3.2 Build the chunk card in `SourceViewerView` (`chunkPreview`): "n of total", page and heading, length, embedding model and dimension, the full text with the start and end overlap tinted, and Previous/Next (`previousChunk`, `nextChunk`), with no vector values; verify with a UI test that selecting a chunk shows the card and that Next selects and shows the following chunk in list order.
- [x] 3.3 Build the image card (`imagePreview`): the zoomable display copy (reusing `ZoomableImage`), pixel size, page or heading, caption with its source, recognized text, and Show chunk (`showChunk`), which switches the contents to Chunks and selects the proxy chunk; verify with a UI test on the seeded manual's figure that the card shows its caption and that Show chunk selects the badged chunk.
- [x] 3.4 Add Show in document (`showInDocument`) to both cards, building the `Citation` as `ChatService` does and calling `source.open(_:)`; verify with a UI test that it opens the seeded PDF at the chunk's page with `chunkHighlighted` shown.

## 4. Workspace wiring (App)

- [ ] 4.1 (Built; the UI test for X-ray to Source passes. Still to do: the narrow-window check, as in 2.1.) In `WorkspaceView`, route a contents selection to the source viewer through `show(_:)` so the detail column switches to Source and, when collapsed, moves to the detail column (design D8); verify with a UI test that selecting a chunk while X-ray is showing switches to Source, and in the simulator in a narrow window that the preview fills the window and Back returns to the contents with the selection kept.
- [x] 4.2 Reload the contents when the library item's status turns `.ready`, mark a preview whose item is gone as unavailable, and clear the path and mark the preview when the document is deleted (design D6); verify with app unit tests that a re-index leaves the old chunk's preview unavailable and the list on the new generation, and with a UI test that deleting the open document returns the sidebar to the library and the preview says it was deleted.
- [x] 4.3 Add a UI test that opens a document's contents, selects a chunk and steps with Next, and then checks the X-ray log: one new contents operation and no events from the stepping; verify that it passes.

## 5. Readiness

- [x] 5.1 Add a "Document contents" part to README.md (how to open it, what the cards show, and a talk-track step: open the manual's contents, step through two chunks to show the overlap, then open the figure and its chunk); verify that the section renders and that its steps match the app.
- [x] 5.2 Run the package tests and the app unit and UI tests with the commands in README.md and confirm they all pass.
- [ ] 5.3 (Needs a real iPad with the real models.) On an iPad with the real models, open the contents of the largest sample document and scroll both lists; confirm that the list opens without a visible pause and scrolls smoothly. If it does not, record it and note thumbnail downscaling as a follow-up.

## 6. Open in Database and JSON view (App)

- [x] 6.1 Add `databaseRecord` to `SourceViewerModel` (design D10); verify with app unit tests that a PDF, a chunk preview and an image preview map to `documents/<docId>`, `chunks/<id>` and `images/<id>`, and that a deleted document maps to nothing.
- [x] 6.2 Add the Open in Database button (`openInDatabase`) to the PDF, text and photo headers and to both cards, presenting the explorer at the record; verify with UI tests that from a chunk card the explorer shows `chunks/<id>` and closing it shows the card again, and that from an image card the image record shows its blob Preview.
- [x] 6.3 Add `JSONHighlighter` and render the explorer's document view as highlighted JSON with inline reference links, Show all for shortened vectors and Preview next to blobs (design D11); verify with unit tests that keys, strings, numbers and literals get distinct colors and that the text is valid indented JSON, and that the existing explorer and X-ray UI tests pass unchanged.

## Workflow follow-up

- Archive the change after review, syncing `document-contents` into `openspec/specs/`.
