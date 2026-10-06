# Proposal

## Why

ManualBot already runs Couchbase Lite's main strengths on the device: vector search and full-text search in one embedded SQL++ engine, files stored as blobs next to the JSON, and ACID batches that make a re-index visible in one step. A customer using the app sees none of this. Couchbase sales engineers want to present the app live and show, as it runs, what the database is doing and why it matters, without slides and without a debugger.

## What Changes

- **Demo mode**: a switch in the app (off by default, also settable by launch argument). When it is off, the app looks and behaves exactly as it does today.
- **X-ray panel**: in demo mode, the detail column gets a `Source | X-ray` switch. X-ray shows a live, grouped log of what the app does behind the scenes: the import, ask, open-source, re-index and delete operations, and within each one every database read, write, batch and query.
- **Query details**: each SQL++ query shows its text, bound parameters (vectors cut short), execution time, the index it uses (with the raw query plan on tap) and a row funnel (candidates → visible → used). Tapping a passage ID shows the stored JSON document, including its embedding field.
- **Pipeline decisions**: the query rewrite, query embedding, rank fusion (with each passage's vector and keyword ranks), the relevance gate (best distance against the threshold) and the language model's time to first token.
- **"Why it matters" captions**: a toggle that adds one plain-language line per event explaining the Couchbase benefit. This includes the visibility-by-ID pattern used for unfiltered vector search, described as a deliberate design.
- **Presenter aids**: a projector text size control, a slow-reveal mode that shows a burst of events one at a time, the latest operation kept expanded, a network online/offline indicator, and a confirmed "Reset demo" that clears the library and chats and re-imports bundled sample documents.
- No change to retrieval, chat, ingestion or storage behavior. Tracing does nothing when demo mode is off.

## Capabilities

### New Capabilities
- `database-xray`: demo mode, the X-ray panel and what it must show for each operation, query details, document inspection, captions, presenter aids, and the guarantee that the app is unchanged when demo mode is off.

### Modified Capabilities
- None. Citation taps still open the source viewer as `grounded-chat` requires; the new spec adds that a citation tap switches the detail column back to Source.

## Impact

- **Ports**: a new trace interface and event model, with a no-op default.
- **Adapters**: the Couchbase Lite repository and search report the queries, batches, blobs and row funnels they run, and can return a stored document and a query plan on request.
- **Core**: the retriever, chat service and ingestion service report pipeline steps and group events by operation.
- **App**: a demo mode setting, the X-ray views, a switch in the detail column, the reset action, and bundled sample documents (a few KB: the existing evaluation corpus plus a small generated PDF).
- **Dependencies**: none new. The network indicator uses Apple's Network framework.
- **Performance**: no cost when demo mode is off; with it on, query plans are computed only when first shown.
