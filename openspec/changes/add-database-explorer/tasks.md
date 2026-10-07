# Tasks

## 1. Inspector port (Ports)

- [x] 1.1 Add `CollectionSummary`, `IndexSummary` (with an optional description: kind, expression or fields, metric, dimensions, centroids, encoding) and `QueryRows` (columns, rows as display JSON, `truncated`, duration), and extend `TraceInspector` with `collectionSummaries()`, `documentIDs(collection:after:containing:limit:)`, `storedDocument(collection:id:fullVectors:)`, `blob(collection:id:key:)`, `children(documentID:)`, `indexes()` and `query(sql:limit:)` (design D1), keeping the two-argument `storedDocument` as a default; verify that `swift build` in Packages/Ports succeeds.
- [x] 1.2 Add an in-memory `FakeTraceInspector` to PortsTesting with paged IDs, a `truncated` query result and a configurable delay; verify with a Ports test that paging after an ID returns the next IDs in order.

## 2. Couchbase implementation (Adapters)

- [x] 2.1 Move the six index definitions in `CouchbaseSchema` into one table that `prepare` reads, with no change in behavior; verify that the existing Adapters tests pass and that `CouchbaseTraceTests` still find `chunks_vec` in the vector query plan.
- [x] 2.2 Implement `collectionSummaries()` (`Collection.count`, local-only from the schema) and `indexes()` (names from `Collection.indexes()`, descriptions from the table, vector dimensions from `localMeta`); verify with a test on a seeded database that ingestJobs and localMeta are local-only, the document count matches, and the `chunks_vec` description shows the embedder's dimensions.
- [x] 2.3 Implement `documentIDs` with keyset paging and a `contains` filter, checking the collection name against the scope before building the SQL (design D3); verify with tests that two pages of 50 cover 120 IDs with no repeats or gaps, that a filter narrows the list, and that an unknown collection name throws.
- [x] 2.4 Implement `storedDocument(…fullVectors:)`, `blob(collection:id:key:)` and `children(documentID:)`; verify with tests that a full embedding has the embedder's length, that an image record's `image` blob returns JPEG data, and that a document's children list its passages and images of the active generation.
- [x] 2.5 Implement `query(sql:limit:)`: execute, iterate up to `limit + 1`, convert rows with `displayValue`, and time execution plus iteration (design D5); verify with tests that a query over more than 200 rows returns 200 rows with `truncated`, that vectors in results are shortened, and that invalid SQL throws the database error.
- [x] 2.6 Add a test that runs every inspector call with a `RecordingTracer` and asserts that no events are recorded and that collection counts are unchanged afterward; verify that it passes.

## 3. Explorer model (App)

- [x] 3.1 Add `ExplorerModel` (`@MainActor @Observable`) holding the sidebar selection, counts, the ID pages per collection with the filter, the detail navigation path and a refresh action, created by `DemoSession` and given the inspector in `AppModel`; verify with app unit tests on `FakeTraceInspector` that refresh rereads counts, that "load more" appends the next page, and that changing the filter restarts paging.
- [x] 3.2 Add the console state: the editor text, starter queries (keyword search, passages of the first document, ingest jobs by state), parameter detection outside string literals, run, cancel (abandon the task and drop late results), and the plan request; verify with unit tests that a `$name` query is refused without calling the inspector, and that cancelling a delayed query leaves no results and makes the editor usable again.
- [x] 3.3 Add `ExplorerTarget` and `open(_:)`, which selects the collection, clears the filter and pushes the document; verify with a unit test that opening a passage target sets the selection to chunks and the path to that ID.

## 4. Explorer views (App)

- [x] 4.1 Build `ExplorerView` as a three-column `NavigationSplitView` with the sidebar (Query, Sync-ready, Local only, Indexes, counts, refresh), the content column (ID list with search, empty states and "load more"; console; index list) and a `NavigationStack` detail, with `.dynamicTypeSize(xray.textSize)` and a Done button; verify in the simulator with `-demoMode` and stub models that all seven collections and six indexes are listed.
- [x] 4.2 Build the document view: field-by-field rendering of the parsed JSON, reference keys (`docId`, `chatId`, `imageId`) as buttons that push, a "Passages and images" section for document records, "Show in full" for shortened vectors, image and text blob previews, and the "no longer exists" state with the `xrayStoredDocument` and `xrayDocumentGone` identifiers (design D7, D8); verify with a UI test that tapping a passage's `docId` opens the document record and Back returns to the passage.
- [x] 4.3 Build the console view: editor, starter menu, run and cancel, row count, time, the truncation notice, inline errors, result rows and a plan view; verify with a UI test that the keyword starter returns rows and its plan shows `chunks_fts`.
- [x] 4.4 Build the index detail view from `IndexSummary`; verify in the simulator that `chunks_vec` shows its collection, expression, dimensions, cosine metric, 64 centroids and SQ8 encoding.

## 5. Entry points and X-ray link (App)

- [x] 5.1 Add the Database button to `LibraryView`'s toolbar and `.fullScreenCover(item:)` in `WorkspaceView` (design D6); verify with UI tests that no button exists with demo mode off, and that after opening and closing the explorer the same chat and source are still showing.
- [x] 5.2 Route `StoredDocumentLink` taps through `XrayModel.openInExplorer` to `WorkspaceView`'s explorer target and remove `StoredDocumentSheet` (design D9); verify that the existing X-ray UI tests for inspecting a passage and for a deleted document pass after their assertions are updated to the explorer, and that closing the explorer returns to X-ray with the same groups expanded.
- [x] 5.3 Add a UI test that browses, opens documents and runs a query in the explorer, then checks that the X-ray log gained no group (the read-only requirement end to end); verify that it passes.

## 6. Readiness

- [x] 6.1 Run all package tests and the app unit and UI tests (commands in README.md) and confirm they pass.
- [x] 6.2 Add an "Explorer" part to the README's Demo mode section: how to open it, the starter queries, and a talk-track step (after an import, show the passages pointing to their document and the local-only collections); verify that the section renders.
- [ ] 6.3 Dry run on an iPad with the real models: during an import, run each starter query and confirm that chat answers are not noticeably delayed. If they are, record it and raise the second read-only connection fallback from the design's risks as a follow-up.

## 7. Remove demo mode

- [x] 7.1 Delete `DemoSettings`, the About toggle, the `xray.demoMode` preference and the `-demoMode` argument; make `DemoSession` enable the tracer at creation, and show the Source / X-ray switch, the Database button and the sample-photo button unconditionally (design D10); verify the app builds and an app unit test shows a new `DemoSession` has an enabled tracer.
- [x] 7.2 Remove the demo-off tests (no switch, turn on from About, no explorer button) and the settings unit tests, drop `-demoMode` and the `UITEST_DEMO_MODE` switch from the UI tests, and add a UI test that a fresh launch shows the X-ray switch and the Database button; verify the app unit and UI suites pass.
- [x] 7.3 Update README.md: remove the demo-mode switch and launch-argument wording, say X-ray and the explorer are always available, and keep the stub-models launch line; verify no `-demoMode` or "demo mode" instruction remains.
- [x] 7.4 Time importing the seeded sample documents in a test with `NoTracer` and with the app's tracer enabled and record both timings in the task note; verify the difference is small enough to leave tracing on (otherwise stop and ask). Measured by `TracingCostTests` (median of 7 rounds, fake models, real database): import 0.020 s off / 0.021 s on; evaluation questions 0.465 s off / 0.473 s on, about 2%.
