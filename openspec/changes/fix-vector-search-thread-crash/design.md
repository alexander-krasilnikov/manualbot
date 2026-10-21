# Design

## Context

See proposal.md (Why) for the crash and its stack.

- `CouchbaseDocumentRepository` is a default actor. Its jobs run on the Swift-concurrency cooperative pool. The pool's threads are GCD worker threads, which the system creates and retires as it needs to.
- Everything that reaches `CouchbaseLiteVectorSearch` goes through that actor. That includes chunk and image vector queries (`CouchbaseChunkSearch`, `CouchbaseImageSearch`), saves of chunks and images (the vector indexes are not lazy, so a save updates them, and enough new vectors make the index train), and the trace inspector's queries.
- The repository's `init` is synchronous and nonisolated, so it runs on the caller's thread. It opens the database and runs `CouchbaseSchema.prepare`, which can delete and recreate a vector index on existing data (`ensureVectorIndex`). That index work runs OpenMP on the caller's thread.
- `CouchbaseLibrarySync` holds the repository's collections and runs a `Replicator`. Replicator saves happen on threads Couchbase Lite creates and keeps alive.
- The crash happens when a thread exits, not during a query. So any long-lived thread is safe, and any thread that can exit after doing vector work is not.

## Goals / Non-Goals

**Goals:**
- No vector work ever runs on a thread that can exit while the process is alive.
- No change to the repository's public API or to any caller.

**Non-Goals:**
- Fixing OpenMP or Couchbase Lite itself; that is reported upstream.
- Parallel database access. Today's access is already serial.
- The answer-quality problems ("I couldn't find…"), which belong to a separate change.

## Decisions

### D1. A custom serial executor backed by one long-lived thread

Add `DatabaseThread`: a `SerialExecutor` that owns one `Thread` and a FIFO queue of jobs, protected by an `NSCondition`. `enqueue(_:)` appends the job and signals. The thread loops forever, taking jobs and running them with `runSynchronously(on:)`. The executor also implements `checkIsolated()` (current thread is the database thread), so `assumeIsolated` and the runtime's isolation checks work.

`CouchbaseDocumentRepository` exposes it with `nonisolated var unownedExecutor`. Every actor method, including those in the extensions (`+Sharing`, chunk and image search, trace inspector), then runs on that thread without any change to it.

Alternatives considered:
- *Dispatch to a dedicated `DispatchQueue` from inside each search method.* A serial queue still runs on GCD worker threads, which can be retired. This is the same bug.
- *Wrap only `vectorSearch` and `imageSearch`.* This misses index updates on save, index training and index rebuilds at `init`, which also run OpenMP.
- *Set `OMP_NUM_THREADS=1` or other OpenMP environment variables.* This doesn't stop OpenMP from registering the calling thread and cleaning up when it exits, which is the path that crashes. It also isn't a documented setting of the Couchbase Lite vector extension.
- *Use a `TaskExecutor` preference at call sites.* Every caller would have to remember it, and the actor would still default to the pool.

### D2. One thread for the whole process, never ended

`DatabaseThread.shared` is created once, at first use, and never stops. Ending it would run the same OpenMP cleanup that crashes. Every repository instance uses it, including the many short-lived repositories in tests, so they are serialized together. That is harmless: tests already await each call, and the app opens one repository.

Alternative: one thread per repository, ended on `close()` or `deinit`. Rejected, because ending a thread that ran vector work is exactly what crashes.

### D3. `init` runs its database work on the database thread, synchronously

`init` stays synchronous and throwing, so `Services` and `StubServices` don't change. It hands the work (open, `prepare`, `backfillActiveCounts`) to `DatabaseThread.shared.runAndWait { … }`, which enqueues a closure, blocks the caller on a semaphore until it finishes, and rethrows its error. Then `init` stores the results.

`runAndWait` must not be called from the database thread itself, because it would deadlock. Only `init` uses it, and `init` is never isolated to the repository. `runAndWait` checks this with a `precondition` (it compares the current thread with the database thread) so a misuse fails loudly instead of hanging.

Alternative: an `async` initializer. The actor's isolation only applies once all stored properties are set, and the database is opened before that point. So the open would still run on the caller's thread.

### D4. `CouchbaseLibrarySync` stays as it is

Its database work is replicator saves, which Couchbase Lite runs on threads it owns and keeps alive, and simple document reads in `OriginalSizes`. If the regression test (task group 3) or a later crash report shows vector work on its pool threads, it gets the same one-line `unownedExecutor`.

## Risks / Trade-offs

- [A long-running database job, such as training an index over many vectors, blocks every other database call] → Same as today, since the actor already serializes them. Searches stay within the 500 ms budget once the index is trained.
- [Blocking the caller in `init`] → `init` already blocks for the same work today; only the thread it runs on changes.
- [Hidden vector work outside the actor, such as a future `nonisolated` helper or a static function called from elsewhere] → No `nonisolated` members exist today. The executor's `checkIsolated()` plus a debug assertion at the top of the search code and schema preparation (task 2.3) catch work that runs elsewhere.
- [The crash only reproduces in the Simulator, and the regression test may not trigger it reliably] → Task 1.1 tried to reproduce it on purpose. **Result (2026-10-20): it did not reproduce on macOS.** `VectorThreadExitTests` (`RUN_CRASH_REPRO=1`) ran 192 vector queries over 5,000 vectors with the app's 64-centroid index, half on `Thread`s that exit at once and half on GCD worker threads, with 15 s idle gaps. Every query returned, and the process did not abort. Every slice of the xcframework, macOS, Simulator and device, bundles the same `LLVM OMP 5.0.20140926` runtime, and no other binary in the app embeds a second one. So the trigger needs something the test lacks, most likely the iOS Simulator's thread retirement, or index training or saves running at the same time as the in-app work. D1 still applies, because all three crash reports show the abort on an exiting GCD worker thread that ran OpenMP work. The opt-in test stays as a probe, and task 4.1's Simulator soak is the real check of the fix.
- [Ingestion of a large library is slightly slower, because each actor call now hops to the database thread] → An actor hop already happened before; the cost of crossing to a different thread is microseconds, far below the cost of the database work.

## Migration Plan

There is no data migration. The change ships in one build. To roll back, revert the commit; the database format is untouched.
