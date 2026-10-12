# Design

## Context

See proposal.md for motivation and specs/document-contents/spec.md for the behavior.

- The workspace is a three-column `NavigationSplitView` (`WorkspaceView`): `LibraryView` in the sidebar, chat in the content column, and `DetailColumn` (source viewer or X-ray) in the detail column. `show(_:)` switches the detail column to Source and, when collapsed, moves to the detail column.
- `SourceViewerModel.Content` already covers `.pdf`, `.text`, `.image`, `.deleted(Citation)` and `.unavailable(title:reason:)`. `open(Citation)` runs under an `openSource` trace operation and highlights a chunk in a PDF or text document.
- `DocumentRepository` already returns the active generation's chunks (`activeChunks(docId:)`, sorted by ordinal) and images (`activeImages(docId:)`), and an image's display copy (`imageData(id:)`).
- Every repository query emits an X-ray `query` event. Without a `TraceContext.operation` it lands in the "Background activity" group.
- Chunks do not store how much they overlap. The chunker starts each chunk with trailing sentences of the previous one (within `overlapTokens`), joined with single spaces, and never across a PDF page.
- Image proxy chunks are written after all text chunks: their ordinals follow the last text chunk, and they carry the image's page and heading.
- `LibraryViewModel.Status.isReady` is true for `.ready` and for `.updating` (a re-index running while the previous index stays searchable).

## Goals / Non-Goals

**Goals:**
- Load a document's contents once per open and per finished re-index, then do selection and stepping without further reads.
- Keep the preview inside the existing Source tab, so the detail-column switch, the explorer's "return to the same source" and Show in document work as they do now.

**Non-Goals:**
- Searching or filtering within a document's chunks.
- Showing vector values, earlier generations, or chunks of a re-index still running.
- Editing, deleting or re-embedding a single chunk or image.

## Decisions

### D1. Sidebar navigation stack
`LibraryView`'s list is wrapped in a `NavigationStack` with a path holding at most one document ID. The contents control on `LibraryRow` (a trailing chevron button, separate from the row's tap target) appends the ID. The pushed view is `DocumentContentsView`.

*Alternative:* inline disclosure groups in the library list. Rejected: a manual has hundreds of chunks, which would bury the other documents and leave no room for the Chunks / Images switch.

### D2. `DocumentContentsModel`
A `@MainActor @Observable` model per opened document, created by the pushed view, holding:
- `chunks: [ChunkEntry]` and `images: [ImageEntry]`. These are display copies without vectors: a chunk keeps its ID, ordinal, page, heading, text, image ID, embedding model and `embedding.count`; an image keeps its ID, `n`, page, heading, caption, caption source, OCR text and size. A 400-chunk manual with 768-d vectors would otherwise hold about 1.2 MB of floats for nothing.
- `kind` (chunks or images), `selection` (a chunk or image ID), and the derived `sections`.
- `load()`, which reads chunks and images in one `browseContents` trace operation titled “Contents of “<title>””, and `thumbnail(for:)`, which caches display copies by image ID.

Selection is owned here. `WorkspaceView` observes it and asks the source viewer to show the preview (D3).

### D3. Previews are source-viewer content
`SourceViewerModel.Content` gains two cases:
- `.chunk(ChunkPreview)`: the entry, its position and total, the overlap ranges (D5), and whether Previous and Next exist.
- `.image(ImagePreview)`: the entry and its display copy, read with `imageData(id:)`. That is a plain document read, not a query, so it emits no trace event and needs no operation of its own.

A preview whose item is gone, or whose document is gone, uses the existing `.unavailable(title:reason:)` case. The card views live in `SourceViewerView`. Their Previous, Next, Show chunk and Show in document actions are closures passed down from `WorkspaceView`: they call the contents model's `select` or `source.open(Citation)`, the latter built the same way `ChatService` builds a citation for that chunk.

*Alternative:* a third detail tab, "Contents". Rejected: it duplicates the Source / X-ray switch logic, and Show in document would have to switch tabs.

### D4. Sections and order
Entries are grouped by page for PDF and by heading otherwise (a missing heading groups under the document title). Within a section, entries are sorted by ordinal, and sections are ordered by their smallest ordinal. This puts an image's proxy chunk at the end of its page or heading section instead of in a block after the last page. A heading that occurs twice in a document is merged into one section, which is acceptable for this view.

Previous and Next follow list order, so they never jump from the last page to the proxy chunks. The number shown on a card is `ordinal + 1`, which matches the chunk's ID in X-ray and the explorer.

### D5. Overlap is computed, not stored
A pure function `ChunkOverlap.shared(previous:current:)` returns the longest whole-word suffix of the previous chunk that is a prefix of the current one, with whitespace normalized. The card marks `shared(previous, current)` at its start and `shared(current, next)` at its end. Neighbors are taken by ordinal ±1 among text chunks only. Proxy chunks show no overlap, and chunks across a page break naturally share nothing.

*Alternative:* store `overlapCount` on each chunk at ingestion. Rejected: it is a schema change that needs a re-index to show anything, for a display-only feature.

### D6. Reloading and deletion
`DocumentContentsView` runs `.task(id: item.status)` on the library item. When the status changes to `.ready`, the model reloads. If the selected ID is not in the new lists, the selection is kept and the preview becomes `.unavailable(…, "This chunk is no longer in the document's index.")`. IDs include the generation, so after a re-index this is the normal outcome. When the item disappears from `library.items`, the path is cleared, and if the preview belonged to that document it becomes `.unavailable(…, "The document was deleted.")`.

### D7. Tracing
`TraceOperation.Kind` gains `browseContents`; no X-ray view switches on the kind, so it needs no other change. Chunk previews and stepping read nothing, and an image's display copy is a blob read that emits no event, so none of them emit anything. Show in document is an ordinary `openSource` operation.

*Alternative:* run the reads with tracing suppressed, like the explorer's inspector. Rejected: it needs a suppression mechanism in Ports, and opening a source is already traced, so browsing contents being visible is consistent and useful in a demo.

### D8. Narrow layout
Selecting an item goes through the same `show(_:)` path as a citation, which sets `compactColumn = .detail`. Going back returns to the sidebar column, where the pushed contents view and its selection are still in place.

### D9. Accessibility identifiers
`contents-<title>` (row control), `contentsKind` (switch), `chunkRow-<ordinal>`, `imageRow-<n>`, `chunkPreview`, `imagePreview`, `previousChunk`, `nextChunk`, `showChunk`, `showInDocument`, `contentsEmpty`. These follow the existing `doc-<title>` and `thumbnail-<title>` pattern and are used by the UI tests.

### D10. Open in Database
`SourceViewerModel` records the document ID of what it opened and exposes `databaseRecord`: `documents/<docId>` for a PDF, text or photo; `chunks/<id>` and `images/<id>` for the cards; nothing for a deleted document or the empty state. The button (`openInDatabase`) sits in each view's header, not in the navigation bar: the source view stays alive behind the X-ray tab, so a toolbar item would show there too. `PreviewActions.openInDatabase` presents the explorer with an `ExplorerTarget`, as X-ray's document links do, so the explorer's "return to where you were" applies unchanged.

### D11. Highlighted JSON in the explorer
The document view renders the stored JSON itself rather than a `Text` of the whole string: one row per top-level key, nested values pretty-printed and highlighted by a small `JSONHighlighter` (an `AttributedString` with semantic system colors, so dark mode works). Interactive values stay interactive inside the JSON: a reference's value is a link that pushes the referenced record; a shortened vector is shown as a number array with a Show all button on its row; a blob is shown as its JSON object with Preview on the key's row and the preview below the object. The existing accessibility identifiers are kept so the explorer and X-ray UI tests still apply.

*Alternative:* a WebView with a JSON highlighter library. Rejected: an extra web stack offline, and the inline buttons would need a JavaScript bridge.

## Risks / Trade-offs

- [A `NavigationStack` inside the split view's sidebar behaves differently when the split view collapses on narrow widths.] → Build and check the compact flow first (task 2.1), before the cards. Fall back to presenting the contents in the content column if push-and-back is unreliable.
- [Several hundred rows with images loading lazily may stutter.] → `List` rows load thumbnails in `.task` and cache them in the model, and rows show only the first two lines of a chunk.
- [Whole-word overlap matching can mark a coincidental repeat when two chunks don't overlap but one ends with the words the next starts with.] → This is harmless for display: the text really is repeated. The unit tests pin the chunker's actual output.
- [After every re-index the open preview becomes "no longer in the index".] → This is honest, because the IDs changed. The list beside it already shows the new chunks, so the user selects again.
