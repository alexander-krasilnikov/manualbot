# Tasks

## 1. Confirm the mechanism

- [x] 1.1 Add `VectorThreadExitTests` in `Packages/Adapters/Tests/AdaptersTests`, opt-in with `RUN_CRASH_REPRO=1` and skipped by default. It opens a temporary database with a few hundred 256-dimension chunk vectors, runs an `APPROX_VECTOR_DISTANCE` query directly on 32 short-lived `Thread`s that exit as soon as their query returns, then waits 10 s. Verify by running `RUN_CRASH_REPRO=1 swift test --filter VectorThreadExitTests` in `Packages/Adapters`: the test process aborts with `__kmp_free` / `__kmp_internal_end_thread` in the crash log, matching the app's crash reports. If it does not abort, note that in design.md (D1 still applies because the crash reports show the mechanism) and continue.

## 2. Database thread executor

- [x] 2.1 Add `Packages/Adapters/Sources/Adapters/Couchbase/DatabaseThread.swift`: a `SerialExecutor` with one process-wide `shared` instance, one named `Thread` ("ManualBot database") that is never ended, a FIFO job queue under an `NSCondition`, `enqueue(_:)`, `checkIsolated()`, `isCurrent`, and `runAndWait(_:)` (runs a throwing closure on the thread, blocks the caller until it finishes, rethrows, and fails with a `precondition` when called on the database thread itself). Verify with `DatabaseThreadTests`: jobs run in FIFO order on the database thread; `runAndWait` returns the value and rethrows the error; the thread is the same object across 1,000 jobs started from detached tasks.
- [x] 2.2 Make `CouchbaseDocumentRepository` run on it: add `nonisolated var unownedExecutor` returning `DatabaseThread.shared.asUnownedSerialExecutor()`, and move the open, `CouchbaseSchema.prepare` and `backfillActiveCounts` in `init` into `DatabaseThread.shared.runAndWait`. Verify with a test that `vectorSearch`, `imageSearch`, `upsert(chunks:)` and the trace inspector's `query` see `DatabaseThread.shared.isCurrent == true` (checked through a test-only hook or `assumeIsolated`), and that a schema `prepare` that rebuilds a vector index (the existing dimension-change case in `CouchbaseIndexMigrationTests`) runs on the database thread.
- [x] 2.3 Add `assert(DatabaseThread.shared.isCurrent)` at the top of `search` (the helper shared by chunk and image search) and of `CouchbaseSchema.prepare`, so vector work that runs off the thread fails in debug builds. Verify the Adapters suite still passes: `swift test` in `Packages/Adapters`.

## 3. Regression coverage

- [x] 3.1 Extend `VectorThreadExitTests` with a default-on case that goes through the repository: 32 short-lived `Thread`s and 32 detached tasks each call `vectorSearch` (bridging with a semaphore on the threads), all return their expected nearest chunk, then the test waits 10 s and runs one more search. Verify that it passes by default and that the opt-in direct case from 1.1 still aborts. That shows the test exercises the bug and the repository path avoids it. (Result: the repository case passes by default. The "still aborts" half does not apply, because the opt-in probe did not reproduce on macOS in 1.1; see design.md, Risks.)
- [x] 3.2 Run the Couchbase-touching suites that this change affects: `swift test --filter 'Couchbase|ChunkSearch|ChatRepository|ActiveCounts|Arrival|LibrarySync|Ingestion|DatabaseThread|VectorThreadExit'` in `Packages/Adapters`, and `Packages/Core`'s tests, unchanged. Verify that all pass.
- [ ] 3.3 Add a short "Database thread" paragraph to `docs/architecture.md` (next to the Adapters description): all Couchbase Lite work runs on one long-lived thread because the vector search extension's OpenMP runtime crashes when a thread it used exits, with a link to this change. Verify that the paragraph renders in the GitHub preview of the file.

## 4. App check

- [ ] 4.1 Build and run the app in the iPad Simulator with the real models, import two manuals, ask ten questions with idle gaps of 30–60 s between them, and also launch once after changing the embedding model, which forces an index rebuild. Verify that no new `ManualBot-*.ips` appears in `~/Library/Logs/DiagnosticReports` and that the app is still running at the end.
- [ ] 4.2 File the OpenMP thread-exit assertion with the Couchbase Lite vector search team, attaching the three crash reports and the opt-in repro from 1.1. Verify that the issue link is recorded in design.md under Risks.
