# Tasks

## 1. Trace port (Ports)

- [x] 1.1 Add `Tracer`, `NoTracer`, `TraceEvent` (kinds and payloads from design D3), `TraceOperation` and the `TraceContext.operation` task-local; verify with a Ports test that a task-local operation set with `withValue` is visible inside an `async let` child and across an actor hop.
- [x] 1.2 Add a `RecordingTracer` test fake to PortsTesting that stores events with their operation; verify `swift test` in Packages/Ports passes.
- [x] 1.3 Add a parameter-shortening helper (float arrays keep 4 leading values plus length); verify with a unit test on a 768-value array.

## 2. Couchbase adapter (Adapters)

- [x] 2.1 Add a `tracer:` init parameter to `CouchbaseDocumentRepository` (default `NoTracer`) and emit `query` events for every `createQuery` call, timing only `execute().allResults()`, built only when `tracer.isEnabled`; verify with an Adapters test that `documents()` produces one `query` event with its SQL text and that `NoTracer` produces none.
- [x] 2.2 Emit funnel attempts from the search loop (window, returned, not-visible, wrong-model, kept) on vector and keyword `query` events; verify with a test that seeds two generations of a document and checks returned > visible, and a test that forces a window retry and checks two attempts.
- [x] 2.3 Emit `documentSaved`, `blobStored`, `blobRead` (with cache hit), `batchWritten`, `generationActivated` (with removed count), `documentDeleted` and `messageSaved`; verify with a test that re-indexing a document reports the previous generation's passage count as removed.
- [x] 2.4 Add the `TraceInspector` port and implement `plan(sql:)` (stand-in parameters, design D5) and `storedDocument(collection:id:)` (blobs reduced to type/length/digest, vectors shortened); verify with tests that the vector query plan contains `chunks_vec` and that a stored chunk returns a shortened `embedding` and `nil` after deletion.

## 3. Pipeline events (Core)

- [x] 3.1 Add `tracer:` to `Retriever` and emit `queryEmbedded`, `fusion` (method RRF, k, per-passage positions, distance, score) and `relevance` (distance / identifier with the code / failed); verify with Core tests using fakes: a passage found by both searches shows both positions, and an error-code question passes on identifier.
- [x] 3.2 In `ChatService`, open an `ask` operation around `answer`, emit `queryRewritten` for follow-ups and `generation` (first-token and total time, or skipped on not-found); verify with Core tests that an off-topic question records `generation` skipped and all events carry the ask operation.
- [x] 3.3 In `IngestionService`, emit `jobState` (marked local-only) and open import, re-index and delete operations keyed by document ID (design D2); verify with a Core test that `enqueue` and the later `process` events share one operation ID.
- [x] 3.4 Add a test that runs the evaluation questions through the stub stack with `NoTracer` and with `RecordingTracer` enabled and asserts identical passages, answers and citations; verify it passes in Packages/Adapters.

## 4. App wiring and demo mode

- [x] 4.1 Add `DemoTracer` (lock, `AsyncStream`, `isEnabled` toggle) and a `TraceLog` that keeps the last 50 operation groups, and pass the one tracer to every service in both `LiveServiceFactory` and `StubServiceFactory`; verify with app unit tests that disabling the tracer stops new events and that the 51st group evicts the oldest.
- [x] 4.2 Add the `demoMode` setting (UserDefaults, toggle in the About sheet, `-demoMode` launch argument) driving `DemoTracer.isEnabled`; verify with an app unit test for persistence and the launch argument.
- [x] 4.3 Wrap the detail column in a `Source | X-ray` container shown only in demo mode, with the tab held in `WorkspaceView` and set to Source by the existing `show` helper; verify with a UI test that a citation tap while X-ray is showing switches to Source with the passage highlighted, and that no switch exists with demo mode off.
- [x] 4.4 Open an `openSource` operation in `SourceViewerModel.open` paths; verify with an app unit test that opening a citation records `blobRead` in that operation.

## 5. X-ray panel UI

- [x] 5.1 Build `XrayModel` and the grouped log view: latest group expanded, older collapsed, background group hidden by default with a toggle, clear action; verify with a UI test (stub, seeded) that asking a question adds an expanded group titled with the question.
- [x] 5.2 Build the event detail views: query (SQL, shortened parameters, time, index label, raw plan on tap via `TraceInspector`, funnel attempts), fusion table, relevance, generation, import steps; verify with a UI test that opening the vector search event shows `chunks_vec` and the funnel, and that the plan button shows plan text.
- [x] 5.3 Make chunk and document IDs tappable to show the stored JSON from `storedDocument`, including the "no longer exists" state; verify with a UI test on a fusion entry.
- [x] 5.4 Add the captions toggle and the caption table keyed by event kind and query purpose, including the unfiltered-vector-search wording; verify with a unit test that every `TraceEvent` kind has a caption.
- [x] 5.5 Add the panel text size control (scoped `dynamicTypeSize`), the slow-reveal queue (default 400 ms, presentational only), the `NWPathMonitor` online/offline indicator and the "stub models" header badge; verify with app unit tests that slow reveal releases queued events one per interval, in order, even when they arrive a few milliseconds apart (the airplane-mode check on a device is part of 7.3).

## 6. Reset demo

- [x] 6.1 Copy the evaluation corpus files into `App/Resources/DemoSamples/`, move `makePDF` to a shared app file used by stub seeding and reset, and add the files to the app target in project.yml; verify that `xcodegen generate` and the app build succeed and the stub seed still produces three ready documents.
- [x] 6.2 Implement the confirmed reset as a `reset` operation (delete chats, delete documents through ingestion, enqueue samples, wake ingestion); verify with a UI test that confirming leaves only the sample documents ready and no chats, and that cancelling changes nothing.

## 7. Demo readiness

- [x] 7.1 Run all package tests and the app unit and UI tests (commands in README.md) and confirm they pass with demo mode off and on.
- [x] 7.2 Add a "Demo mode" section to README.md with the launch argument, a suggested five-step talk track (import, ask, ask about E-042, follow-up, airplane mode), and the prepared answer on unfiltered vector search; verify the section renders and its launch arguments work in the simulator.
- [ ] 7.3 Do a dry run on an M4/M5 iPad with the real models, mirrored to an external display: turn on airplane mode and confirm the network indicator flips while importing and asking still work and are traced; review the caption wording with a sales engineer and record the agreed wording changes in the caption table.
