# Design

## Context

See proposal.md for the motivation and specs/database-xray/spec.md for the required behavior.

- All SQL++ is built inside `CouchbaseDocumentRepository` and its `ChunkSearching` extension (Adapters). The search loop there already knows the window size, returned rows, visibility rejects and retries. The repository is an actor.
- Pipeline decisions (rewrite, fusion, relevance gate, model calls) live in Core: `Retriever`, `ChatService`, `QueryRewriter`, `IngestionService`. Core depends only on Ports.
- The app builds services in `LiveServiceFactory` and `StubServiceFactory`. Stub mode uses the real Couchbase Lite database with a fake embedder and generator, in a fresh temporary directory each launch.
- `explain()` already exists on the repository for tests, and tests rely on the plan text containing index names.
- The detail column of `WorkspaceView` is `SourceViewerView`. Citation and library taps call `SourceViewerModel.open…` and then show the detail column.

## Goals / Non-Goals

**Goals:**
- One trace path that serves both the stub and live configurations.
- Zero work on the hot path when demo mode is off: no event values built, no timing, no plans.
- Events attributed to the user operation that caused them, including work in concurrent child tasks (`async let` searches).

**Non-Goals:**
- A general logging or telemetry system, or exporting traces off the device.
- Tracing inside Couchbase Lite itself (storage engine, index maintenance). Only what the app asks of the database is shown.
- An interactive query editor.

## Decisions

### D1. A `Tracer` port with a no-op default, injected at construction

Ports gains `protocol Tracer: Sendable { var isEnabled: Bool { get }; func record(_ event: TraceEvent) }`, a `TraceEvent` value type and `NoTracer`. The repository, `Retriever`, `ChatService`, `QueryRewriter` and `IngestionService` take an optional `tracer:` parameter, defaulting to `NoTracer`. Call sites guard event construction with `if tracer.isEnabled`, so formatting vectors, timing and copying rows only happen in demo mode. Toggling demo mode flips `isEnabled` on the app's single tracer instance, so services do not need rebuilding.

*Alternatives:* wrapping the ports in tracing decorators (rejected: the SQL, funnel and retries are internal to the adapter and invisible at the port); `os_signpost`/`Logger` (rejected: cannot be read back into the UI reliably and carries no structured payload).

### D2. Operation grouping with a task-local

Ports defines `enum TraceContext { @TaskLocal static var operation: TraceOperation? }`, where `TraceOperation` holds an ID, kind (import, ask, openSource, reindex, delete, reset) and title. The entry points that start an operation (`ChatService.answer`, `IngestionService.process` and its delete/reindex paths, `SourceViewerModel.open`, the reset action) run their work inside `TraceContext.$operation.withValue(…)`. The tracer stamps each event with the current operation, or "background" when it is `nil`. Task-locals propagate through actor hops and into `async let` children, so the parallel vector and keyword searches land in the right group without passing IDs through the ports.

Ingestion runs in its own long-lived loop, so `enqueue` (called by the import action) and `process` (called later) are different tasks. The import group is therefore keyed by document ID: `process` opens an operation with an ID derived from the doc ID, and the panel merges events with the same operation ID into one group. `enqueue` uses the same derived ID.

### D3. Event model: typed kinds, rendered by the app

`TraceEvent` is an enum-tagged struct (`kind`, `timestamp`, `duration`, `operation`, payload) with these payloads:

| Kind | Payload | Emitted by |
|---|---|---|
| `documentSaved`, `messageSaved` | collection, doc ID | repository |
| `blobStored` / `blobRead` | doc ID, content type, length, digest, cache hit | repository |
| `jobState` | doc ID, state, progress, `localOnly: true` | IngestionService |
| `batchWritten` | collection, count, dimensions | repository (`writeChunks`) |
| `generationActivated` | doc ID, generation, removed count | repository (`activate`) |
| `documentDeleted` | doc ID, passages removed | repository |
| `query` | SQL text, parameters (shortened), duration, returned rows, purpose (vector/keyword/other), funnel attempts | repository |
| `queryRewritten` | original, standalone | ChatService |
| `queryEmbedded` | dimensions, duration | Retriever |
| `fusion` | method, k, entries (chunk ID, title, vector pos, keyword pos, distance, score) | Retriever |
| `relevance` | best distance, threshold, outcome (distance / identifier(code) / failed) | Retriever |
| `generation` | first-token time, total time, or `skipped` | ChatService |

Parameters are stored already shortened (first 4 values plus length for float arrays) so large vectors are never kept in the log. Captions are a static table in the app keyed by kind (and query purpose), so wording changes need no Core change.

*Alternative:* free-form strings (rejected: the panel needs structured fields for funnels, fusion tables and tappable IDs).

### D4. Row funnel from the existing search loop

`CouchbaseChunkSearch.search` records one attempt per loop iteration: window, rows returned, rows rejected as not visible, rows rejected by embedding model, kept. Execution time is measured around `execute().allResults()` only, not the document fetches after it, so the shown time is the index query. The fused count ("used") comes from the later `fusion` event; the panel joins them inside the group.

### D5. Plans and document inspection on demand

The repository gains two read-only methods behind a small `TraceInspector` port: `plan(sql:) -> String` and `storedDocument(collection:id:) -> [String: Any]?`, with blobs reduced to type, length and digest and float arrays shortened. The plan is not computed when the query runs. The panel asks for it when the event is first shown, and caches it by SQL text. The index label is derived by matching known index names (`chunks_vec`, `chunks_fts`, `chunks_doc_gen`, `messages_chat`) in the plan text, which tests already rely on; otherwise it shows "no index". The recorded parameters are shortened, so the plan request binds stand-ins of the right type (a zero vector of the index's dimension, an empty string); the plan does not depend on parameter values.

### D6. Delivery to the UI

The app's `DemoTracer` (a `final class` with a lock, `@unchecked Sendable`) appends to a bounded ring buffer (50 operation groups) and publishes through an `AsyncStream` to an `@MainActor @Observable XrayModel`. `XrayModel` holds the groups, the background toggle, captions, text size and slow-reveal state. Slow reveal is purely presentational: events go into a pending queue that a timer releases one at a time (default 400 ms), so operations never wait on the UI.

### D7. Demo mode setting and UI placement

`demoMode` is stored in `UserDefaults` and shown as a toggle in the About sheet; the `-demoMode` launch argument forces it on for that launch. In demo mode, the detail column wraps `SourceViewerView` in a container with a segmented `Source | X-ray` control in its toolbar. The column's selected tab lives in `WorkspaceView` state; the existing `show { … }` helper also sets the tab to Source, which satisfies the citation-tap requirement. The panel toolbar holds captions, background, slow reveal, text size (`.dynamicTypeSize` scoped to the panel), clear and reset. The network indicator uses `NWPathMonitor`.

### D8. Reset demo

Reset runs as a `reset` operation: it deletes every chat through the chat repository and every document through `IngestionService.delete` (so in-progress jobs stop cleanly), then enqueues the bundled samples and wakes ingestion. Samples live in `App/Resources/DemoSamples/`: copies of the three evaluation corpus files (x200-manual.md, bike-repair.md, warranty.txt). The sample PDF is not bundled; reset generates it with the existing `StubServiceFactory.makePDF` helper, moved to a shared app file, so stub seeding and reset share one source. Reset works the same in stub and live mode.

## Risks / Trade-offs

- [Tracing changes behavior or timing] → tracing is append-only and never awaited by the traced code; a test runs the same questions with tracing on and off and compares passages and answers.
- [Measured times are inflated by tracing] → durations are measured around the database call only, and event construction happens after the timer stops.
- [Fake embedder distances are meaningless in stub mode] → the panel shows a "stub models" badge in its header when the stub factory is used, so a presenter does not discuss stub distances as real.
- [Raw plans are hard to read] → the index label is shown by default, and the raw plan is behind a tap.
- [Stage-hostile wording of the unfiltered-search pattern] → caption text is reviewed with a sales engineer before release (see tasks); it lives in one app-side table.
- [Live-mode reset deletes the user's own documents] → reset is only available in demo mode, needs explicit confirmation, and the dialog names what will be deleted.
- [Task-local not set on some path] → events with no operation go to background, so nothing is lost; a test checks that ask and import events land in their groups.

## Migration Plan

No data migration. Demo mode is off by default, so existing installs are unaffected. Rollback is removing the feature; nothing is stored in the database.
