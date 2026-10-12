# Design

## Context

See proposal.md for motivation and specs/database-explorer/spec.md for behavior. `DocumentView` renders body JSON from `ExplorerModel.document`, which calls `TraceInspector.storedDocument`. `CouchbaseTraceInspector` serializes `doc.toDictionary()`, so database-managed metadata is absent. `DocumentField` adds reference, vector, and blob controls to body fields; metadata needs only ordinary highlighted JSON.

The installed Couchbase Lite 4.1.2 Swift interface exposes `Document.id`, `revisionID: String?`, `sequence: UInt64`, `timestamp: UInt64`, and `collection`. `Collection.getDocumentExpiration(id:)` returns `Date?`. These public APIs cover the narrowed scope without a network connection or private SDK methods.

## Goals / Non-Goals

**Goals:**
- Keep SDK types inside Adapters and return a small Sendable value through Ports.
- Give each document view its own disclosure and load state while preserving its existing body interactions.
- Preserve full-width integer metadata through display and clipboard serialization.

**Non-Goals:**
- Interpret revision IDs, reconstruct revision history, or infer whether a revision reached the server.
- Access `_sync`, `_vv`, or other server xattrs, expose an Admin API, or add a backend service.
- Change the body JSON contract or persist disclosure state across launches.

## Decisions

### 1. Add a separate local metadata read

Add `DocumentSyncAttributes` in `InspectorModels.swift` and `TraceInspector.syncAttributes(collection:id:) async throws -> DocumentSyncAttributes?`. The value contains `id`, `scope`, `collection`, `revisionID`, `sequence`, `timestamp`, and `expiration`. Preserve the SDK's unsigned integer types; use `Date?` for expiration.

The adapter resolves the collection in the app's scope, reads the stored document once for its revision fields, and reads expiration through the collection. Return nil for a missing document and throw for an actual read error. Add a configurable implementation to `FakeTraceInspector` and update any other conformers.

Alternative: merge metadata into `storedDocument`. This would change copying and field classification and blur the distinction between stored body fields and database-managed attributes. A separate read also avoids doing metadata work until the user expands the section.

### 2. Render an ordinary metadata JSON object

Use the seven stable keys above. Represent absent revision IDs and expiration as JSON null; serialize a present expiration as ISO 8601 UTC text. Display `timestamp` as the exact raw SDK integer, without treating it as a wall-clock date or parsing `revisionID`. Keep `sequence` as an exact integer too.

Reuse `JSONHighlighter` for syntax colors and the body's font. Serialize UInt64 values without a Double or Float round trip; use exact integer JSON number rendering in the highlighter if needed. Give the section its own Copy Sync Attributes action that uses the same JSON string shown on screen. Keep body Copy JSON unchanged.

Alternative: render metadata through `DocumentField`. Its reference/vector/blob classification is useful for body data but unnecessary for these fixed fields and could accidentally add controls to metadata.

### 3. Use document-scoped disclosure and loading state

Introduce a small document attribute model or equivalent state holder scoped to `(collection, id)`, called through `ExplorerModel`. State is idle, loading, loaded, missing, or failed. The disclosure binding belongs to this document view, starts false, and triggers a load only on first expansion. Retry is available for failed reads. Successful data remains cached while the section is collapsed; there is no automatic refresh or polling.

Place a `DisclosureGroup("Sync attributes")` before `jsonView(json)` in the existing scroll content. Show progress and failure content inside the disclosure. Only construct it when the body is found, preserving the existing whole-document missing/error views. If the document disappears between body and attribute reads, show the missing state inside the section.

Tie tasks to document identity and cancel on leaving; check identity/generation before accepting results so even a non-cancellable SDK read cannot populate another document's state. The JSON body, children, vectors, and previews remain independently usable.

Alternative: place shared attributes on the single explorer model without document identity. That risks late reads or back navigation showing another document's data.

### 4. Treat the section as a local snapshot

The view can show metadata from a slightly later instant than its body because the read occurs on expansion. Document that the section reflects a local snapshot and does not prove server synchronization. Reopening the document creates a fresh attribute load. This matches the explorer's existing on-demand reads and avoids subscriptions or background work.

## Risks / Trade-offs

- Large UInt64 values can lose precision in number formatting -> test display and clipboard JSON with values above 2^53 and UInt64.max; avoid floating-point conversion.
- Body and metadata may be read at different times -> present them separately as local snapshots; never infer upload status from either.
- A metadata error could hide usable body content -> use independent load states and inline errors.
- New port requirements affect test doubles -> update `FakeTraceInspector` and find all conformers before compiling.

## Migration Plan

No data or server migration is needed. Implement the port and adapter first, then document-scoped loading and UI, then focused tests and the README update. Ship with the regular app build. Rollback removes the UI and added inspector method without changing stored documents.
