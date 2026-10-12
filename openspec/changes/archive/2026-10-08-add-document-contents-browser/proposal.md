# Proposal

## Why

A user or presenter can see a document only as a whole, or through the single chunk an answer cites. There is no way to see how the app split a document: how many chunks it made, where they break and overlap, which photos it kept, and what each photo's caption and recognized text say. The Database explorer can show this, but only as raw JSON, full screen, away from the chat. The data is already stored and readable through the repository, so a readable view inside the workspace costs little.

## What Changes

- **Document contents in the library sidebar**: a ready document that is not a photo gets a control that opens its contents in the sidebar. Tapping the row itself still opens the document as before. Back returns to the library.
- **Chunks and Images**: the contents view switches between the document's chunks and its images, both from the active index only, grouped into sections by page (PDF) or heading (Word, Markdown, text). Each list shows its count. A chunk that stands for an image is listed with a photo badge.
- **Chunk preview**: selecting a chunk shows a readable card in the right column's Source view: its number out of the total, page and heading, length, embedding model and vector dimension (not the vector values), and the full text with the part repeated from the previous chunk and the part repeated in the next chunk tinted. Previous and Next step through the chunks, and Show in document opens the original at that chunk, highlighted, as a citation does.
- **Image preview**: selecting an image shows the stored picture (zoomable), its size, page or heading, caption and where the caption came from, recognized text, a link to the chunk that stands for it, and Show in document.
- **Keeping up with changes**: when a re-index finishes, the contents reload to the new index, and a preview whose item is no longer in the index says so. If the document is deleted, the sidebar goes back to the library.
- **Open in Database**: the document preview (PDF, text, photo) and the chunk and image cards get a button that opens the Database explorer at that record (`documents`, `chunks` or `images`); closing the explorer returns to the same preview.
- **JSON document view in the explorer**: a stored record is shown as pretty-printed, syntax-highlighted JSON instead of field by field. Vectors stay shortened with a way to show them in full, references stay tappable, and an image blob has its Preview button next to its JSON attributes.
- The contents view writes nothing. Loading a document's contents shows in X-ray as its own operation, like opening a source does; selecting and stepping through chunks, and showing an image's stored picture, run no queries and add no events.

## Capabilities

### New Capabilities
- `document-contents`: browsing a document's chunks and images from the library, the chunk and image previews in the detail column, navigation between them and back to the document, and behavior when the document is re-indexed or deleted.

### Modified Capabilities
- `database-explorer`: "Document view" shows the stored record as syntax-highlighted JSON, with the existing shortening, full-vector, reference and blob-preview behavior kept inside it.

## Impact

- **App**: `Library` gains a contents model and view and a sidebar navigation stack; `LibraryRow` gains the contents control. `SourceViewerModel` gains chunk and image preview content, and `SourceViewerView` the two cards. `WorkspaceView` routes a selection to the detail column the same way it routes a citation.
- **Ports**: `TraceOperation.Kind` gains `browseContents`. No repository API changes: the view reads `activeChunks(docId:)`, `activeImages(docId:)` and `imageData(id:)`, which already exist.
- **Adapters**: no change for this feature (the CMYK and decode fixes made alongside it are separate).
- **Explorer**: `ExplorerDocumentView` renders highlighted JSON; the explorer is opened at a record from the source viewer.
- **Dependencies**: none new.
- **Performance**: a large manual has several hundred chunks; they are loaded once when the contents open and when a re-index finishes, without their vectors being shown.
