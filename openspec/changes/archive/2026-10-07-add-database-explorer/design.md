# Design

## Context

See proposal.md for the motivation and specs/database-explorer/spec.md for the required behavior.

- `CouchbaseDocumentRepository` is an actor that owns the one `Database`. All app reads go through it. Its `run(_:parameters:shown:)` helper emits a `query` trace event for every SQL++ query.
- `TraceInspector` (Ports) is already implemented on the repository in `CouchbaseTraceInspector.swift`: `plan(sql:)` binds stand-in parameters and returns `explain()`, and `storedDocument(collection:id:)` returns pretty-printed JSON through `displayValue` (vectors shortened, blobs reduced to type, length and digest). Neither emits trace events.
- `AppModel` sets `demo.xray.inspector = core.repository`, so the X-ray panel reads through the port without depending on Adapters.
- `CouchbaseSchema` names one scope (`manualbot`), seven collections (five sync-ready, two local-only) and six indexes. Index settings are constants there, and the dimension each vector index was created with is recorded in `localMeta`.
- X-ray IDs are rendered by `StoredDocumentLink`, which presents `StoredDocumentSheet`.
- `WorkspaceView` holds the split view state (`visibility`, `compactColumn`, `detailTab`). `LibraryView` has the toolbar with the About button.
- The X-ray panel text size is `XrayModel.textSize`, applied with `.dynamicTypeSize`.

## Goals / Non-Goals

**Goals:**
- One read path for the X-ray panel and the explorer, through `TraceInspector`, so the app keeps no Couchbase Lite dependency.
- No cost when the explorer is closed. Every read happens on demand.
- Explorer reads never show up in the X-ray log.

**Non-Goals:**
- Editing, deleting or creating anything.
- Live updates from collection change listeners.
- Query parameters, including `$vector`, saved queries and query history.
- A separate explorer window (iPad multi-window). It can be a later change.
- Browsing databases other than the app's own, or scopes other than `manualbot`.

## Decisions

### D1. Extend `TraceInspector` rather than add a new port

The explorer needs the same kind of read-only, display-ready access as X-ray, from the same object. The port gains:

| Call | Returns |
|---|---|
| `collectionSummaries()` | name, `localOnly`, document count for each collection in the scope |
| `documentIDs(collection:after:containing:limit:)` | one page of IDs in ascending order |
| `storedDocument(collection:id:fullVectors:)` | as today; `fullVectors: true` skips shortening (the existing two-argument call keeps its behavior) |
| `blob(collection:id:key:)` | content type and data, or `nil` |
| `children(documentID:)` | IDs of the passages and images whose `docId` is the document |
| `indexes()` | name, collection, and a description for app-defined indexes |
| `query(sql:limit:)` | column names, rows as display JSON, a `truncated` flag, the execution time |

The return values are small Sendable structs in Ports, such as `CollectionSummary`, `IndexSummary` and `QueryRows`. `PortsTesting` gets an in-memory fake for app unit tests.

*Alternative:* a separate `DatabaseBrowser` port. Rejected because it would sit on the same actor with the same shortening rules. Splitting it would duplicate `displayValue` and the wiring in `AppModel` for no gain.

### D2. Reads bypass the traced `run` helper

Inspector calls use `database.createQuery` and `Collection` APIs directly, never `run(_:)`. That keeps the explorer out of the X-ray log without adding a "do not trace" flag. A test asserts that a `RecordingTracer` sees no events from any inspector call.

### D3. Counts, paging and filtering

- Counts use `Collection.count`, which does not run a query.
- Paging is keyset-based: `SELECT meta().id AS id FROM manualbot.<c> WHERE meta().id > $after [AND contains(meta().id, $filter)] ORDER BY meta().id LIMIT <n>`, with a page size of 50. Keyset paging stays correct when documents are added or removed between pages. OFFSET paging would repeat or skip IDs.
- The collection name is checked against the collections that actually exist in the scope before it is put into the SQL text, because collection names cannot be bound as parameters. `LIMIT` cannot be bound either, so the limit is an `Int` written into the text.
- `local only` comes from `CouchbaseSchema`: `ingestJobs` and `localMeta` are local-only, everything else is sync-ready. A collection the schema doesn't know about is listed as sync-ready.

### D4. Index descriptions from the schema

Couchbase Lite does not return an index's configuration, only its name. `indexes()` lists names from `Collection.indexes()` on every collection and attaches a description for the six names `CouchbaseSchema` defines: kind, expression or fields, and for vector indexes the metric, centroids, encoding and the dimensions recorded in `localMeta`. To keep a single source, the constants and configurations move into one table in `CouchbaseSchema` that both `prepare` and `indexes()` read. An index with an unknown name shows its name and collection only.

### D5. The SQL++ console

- **Read-only:** Couchbase Lite SQL++ only supports `SELECT`, so the database itself rejects anything else and the console does no checking of its own.
- **Parameters:** before running, the console looks for `$identifier` outside string literals and refuses the query with a message. This uses the same pattern `plan(sql:)` already uses.
- **Cap:** `query(sql:limit:)` iterates the `ResultSet` and stops after `limit + 1` rows (limit 200). The extra row only sets `truncated`. It does not wrap or rewrite the user's SQL, so the plan and errors refer to the query exactly as typed.
- **Display:** each row is `Result.toDictionary()` passed through `displayValue`, so vectors and blobs look the same as in the document view.
- **Timing:** measured around `execute()` and the iteration, the same way X-ray measures it.
- **Plan:** reuses `plan(sql:)`.
- **Cancel:** the console runs the query in a `Task` and cancel abandons it. The UI goes back to the editor, and when the result arrives it is dropped because the task is no longer current. Couchbase Lite has no API to interrupt `execute()`, so the actor stays busy until the query ends (see Risks).
- **Starter queries:** a static list in the app: a keyword search with `MATCH(chunks_fts, "...")`, the passages of the first document (filled in from `collectionSummaries()` and the first ID when the starter is picked), and ingest jobs grouped by state.

### D6. Presentation: a full-screen cover from the workspace

`WorkspaceView` adds `.fullScreenCover(item: $explorerTarget)` presenting `ExplorerView`. `explorerTarget` is an optional `ExplorerTarget` (a collection and an optional ID, or root). Because the workspace stays mounted underneath, its library selection, chat, detail tab, X-ray expansion state and source position are kept with no extra work. The entry button sits in `LibraryView`'s toolbar next to About.

`ExplorerView` is a three-column `NavigationSplitView`:
- **Sidebar:** Query, the Sync-ready collections, the Local only collections, and Indexes, with counts and a refresh button.
- **Content:** the ID list with search and "load more", the console editor with its results, or the index list.
- **Detail:** a `NavigationStack` that holds the document view. Following a reference or opening a child pushes onto this stack, so Back returns to the previous document. The stack also holds the result row view and the plan view.

An `@MainActor @Observable ExplorerModel`, created by `DemoSession` with the inspector, holds the selection, pages, counts, console state and navigation path. It applies `XrayModel.textSize` through `.dynamicTypeSize`.

*Alternative:* a third tab in the detail column. Rejected during exploration because the column is too narrow for three columns.

### D7. References

A field is a reference when its key appears in a fixed map: `docId` points to documents, `chatId` to chats and `imageId` to images. The document view renders the JSON as lines. On a line whose key is in the map, the value is a button that pushes that document. For a `documents` record, the view adds a "Passages and images" section from `children(documentID:)`, using the existing `chunks_doc_gen` and `images_doc_gen` indexes. The map lives in the app, next to the view, because it is a display decision.

To make the JSON tappable and expandable per vector, the document view needs structure rather than one string. `storedDocument` keeps returning the pretty-printed string, and the explorer view parses it back with `JSONSerialization` and renders it field by field: the top-level keys, with nested values shown as pretty-printed JSON. That leaves the port unchanged for X-ray. For "show in full", the view asks again with `fullVectors: true`.

### D8. Blob previews

`blob(collection:id:key:)` returns the blob's data. The view shows images with `Image(uiImage:)`, and `text/*` blobs as their first 64 KB of text. Any other type, including PDFs, shows only the summary. PDFs can already be opened in the app's source viewer, so no second PDF viewer is added.

### D9. X-ray links open the explorer

`StoredDocumentLink` calls an `openInExplorer(collection:id:)` closure on `XrayModel`, which `WorkspaceView` provides to set `explorerTarget`. `StoredDocumentSheet` is removed. Opening at a target selects that collection, clears the ID filter and pushes the document onto the detail stack. If the document no longer exists, the document view shows "This document no longer exists", which satisfies the modified X-ray requirement. The accessibility identifiers `xrayDocLink-<id>`, `xrayStoredDocument` and `xrayDocumentGone` stay, applied in the explorer document view, so the existing UI tests keep working with small changes.

### D10. Demo mode is removed; tracing is always on

`DemoSettings`, the About toggle, the `xray.demoMode` preference and the `-demoMode` argument are deleted. `DemoSession` turns the tracer on when it is created, so the log covers everything since launch. `DetailColumn` always shows the Source / X-ray switch, `WorkspaceView` always passes the explorer action to the library and the sample photo to the chat, and Reset demo stays in the X-ray toolbar behind its confirmation.

`Tracer.isEnabled` stays in the port. It is still the guard that keeps tests and `NoTracer` free of event work, and the app can turn it off again if the cost below turns out to matter.

*Alternatives:* tracing only while the X-ray tab is open (rejected: the log would miss earlier operations, such as the imports a presenter wants to show first); keeping demo mode for X-ray and ungating only the explorer (offered, not chosen).

## Risks / Trade-offs

- [Tracing work now runs for every user on every operation] → events are small and shortened at construction, the log keeps only the last 50 groups, and the earlier X-ray change already measured durations around the database call only. A test compares answers with tracing on and off; task 7.4 checks the import time on the seeded library with the tracer on and off.
- [A destructive Reset demo and a debug-looking X-ray are now in front of every user] → Reset stays behind a confirmation that names what is deleted, and only inside the X-ray tab.

- [A slow console query blocks the repository actor, delaying chat or ingestion on stage] → Starter queries are fast. The cap stops iteration at 201 rows. The console shows a "query is still running in the database" note after a cancel until the actor returns. A second read-only `Database` connection would remove this coupling, and is the fallback if a dry run shows stalls.
- [Explorer reads during import see half-finished generations] → That is the real state and the explorer is honest about it: passages of a generation that has not been activated yet are listed. The document view shows `generation`, and the document record shows `activeGeneration`.
- [Full vectors of a few hundred values make the view long] → They show only on an explicit action, one field at a time.
- [Index descriptions drift from the real configuration] → D4 makes `prepare` and `indexes()` read the same table. A test compares the listed vector dimensions with the recorded `localMeta` value.
- [Re-parsing the JSON string loses key order or number formatting] → Keys are already sorted (`.sortedKeys`), and numbers are displayed as stored.

## Migration Plan

No data migration and no schema change, since the index definitions are only refactored into a table. Rollback means removing the button and restoring the X-ray sheet.
