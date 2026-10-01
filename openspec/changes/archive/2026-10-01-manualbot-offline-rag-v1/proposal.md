# Proposal

## Why

People who work with manuals, specs, and notes need answers from *their* documents, often in places with poor or no connectivity, and often with content that must not leave the device. Current M4/M5 iPads can run a capable local LLM (Gemma 4 E4B) and embedding model (EmbeddingGemma), and Couchbase Lite now supports on-device vector search, so a fully offline, citation-grounded document assistant is feasible. The repository is empty, so this change defines v1 of the app.

## What Changes

- New iPadOS 26 app (ManualBot) for M4/M5 iPads with a three-column layout: library, chat, and source viewer.
- **Model provisioning**: a one-time, resumable, checksum-verified download of EmbeddingGemma and Gemma 4 E4B. After setup, the app never needs the network for import, indexing, search, or chat.
- **Document ingestion**: import plain text, PDF (including scanned PDFs through on-device OCR), and DOCX. Documents are extracted, chunked with page and heading provenance, embedded, and stored in Couchbase Lite, with per-document status shown while this runs in the background.
- **Hybrid retrieval**: combines vector search (Couchbase Lite vector index) and full-text search. Searches the whole library by default and can be narrowed to pinned documents. A relevance gate discards weak matches.
- **Grounded chat**: answers come only from retrieved passages and carry numbered citations. The app validates those citations, says "not found in your documents" when nothing relevant is found, rewrites follow-up questions into standalone queries, streams responses, and keeps chat history.
- **Source viewer**: tapping a citation opens the cited page or section with the passage highlighted.
- **Sync-ready data model**: v1 runs on a single device, but documents and chunks (including vectors) are shaped for later replication. Chunks record their embedding model identity, chunks are immutable per generation, original files are stored as blobs, and device-local state is kept in separate collections.

## Capabilities

### New Capabilities
- `model-provisioning`: the built-in embedding model, the first-run download, verification, and storage of the language model, model readiness states, and the offline guarantee for core features after setup.
- `document-ingestion`: importing, extracting, chunking, embedding, and storing TXT/PDF/DOCX documents; ingestion status; re-indexing and deletion.
- `hybrid-retrieval`: vector search plus full-text search, result fusion, document scoping, and the relevance gate.
- `grounded-chat`: strict, citation-backed question answering, the not-found fallback, follow-up handling, chat persistence, and citation navigation to the source viewer.

### Modified Capabilities
- None. There are no existing specs.

## Impact

- **New codebase**: a SwiftUI iPadOS 26 app target plus unit and UI test targets.
- **Dependencies**: Couchbase Lite Swift **Enterprise Edition** plus the Vector Search extension (licensing required for production), LiteRT-LM (a vendored, patched copy of its Swift wrapper) for Gemma 4, Core ML and `swift-transformers` for EmbeddingGemma, a ZIP library for DOCX, and Apple PDFKit and Vision.
- **Entitlements and capabilities**: increased memory limit, background tasks for ingestion, and background URLSession for model download.
- **Size and storage**: the app grows by about 340 MB for the built-in embedding model; the 3.7 GB language model is downloaded into Application Support (excluded from backup); plus the user's documents and vectors in Couchbase Lite.
- **Network**: used only to download the language model. No telemetry, and document content is never sent off the device.
- **Future**: Couchbase Lite replication (App Services / Sync Gateway) with vector sync is out of scope but must not require a data migration.
