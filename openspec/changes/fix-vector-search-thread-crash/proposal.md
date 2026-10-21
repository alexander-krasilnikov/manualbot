# Proposal

## Why

The app sometimes crashes a few seconds after the user sends a question. All three ManualBot crash reports on the development Mac (2026-10-13, 2026-10-18, 2026-10-20, all in the iOS Simulator) have the same stack: an idle GCD worker thread exits, and the OpenMP runtime bundled in `CouchbaseLiteVectorSearch` runs its per-thread cleanup (`__kmp_internal_end_thread` → `__kmp_free`), trips a debug assertion and aborts the process (`EXC_BREAKPOINT`). The language model's threads were idle in every report. Vector queries run inside `CouchbaseDocumentRepository`, a plain actor, so they run on whichever Swift-concurrency pool thread is free. OpenMP registers that borrowed thread as one of its own, and when the system later retires the thread, OpenMP's cleanup crashes. Because the crash depends on when the thread is retired, it only happens sometimes, and always shortly after a question.

## What Changes

- All Couchbase Lite work that can run vector search or vector index training happens on one dedicated, long-lived thread that the app owns and never ends. This covers queries, writes that update the vector indexes, and opening the database and preparing its indexes. No Swift-concurrency pool thread or GCD worker thread runs that work.
- `CouchbaseDocumentRepository` runs on a custom serial executor backed by that thread, so every method keeps its current `async` signature. Callers (`Retriever`, ingestion, chat, sync arrival, the trace inspector and database explorer) do not change.
- Opening the database (`init`) moves onto the same thread, because preparing the schema can create or rebuild a vector index on existing data, and that also runs OpenMP.
- A regression test runs vector work from many short-lived tasks and threads, lets those threads exit, and checks that the process survives and that the work ran on the database thread.
- The OpenMP thread-exit assertion is reported to the Couchbase Lite vector search team with the three crash reports. The workaround does not depend on their fix.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `hybrid-retrieval`: adds a requirement that searching must never terminate the app because of the threads the search runs on, including after the threads that issued the search have exited.

## Impact

- **Code**: `Packages/Adapters/Sources/Adapters/Couchbase/CouchbaseDocumentRepository.swift` (executor, init); a new database-thread executor file in the same folder. Extensions on the repository (chunk search, image search, sharing, trace inspector) inherit the executor and need no changes.
- **Performance**: all database work is serialized on one thread. It already was serialized, because it runs on an actor; only the thread it runs on changes. Searches running at the same time still queue behind one another, as they do today. The 500 ms retrieval budget is unaffected.
- **Dependencies**: none added. `CouchbaseLibrarySync` uses the replicator, whose threads Couchbase Lite owns and keeps alive, so it is out of scope unless the regression test shows otherwise.
- **Platforms**: the crash has only been observed in the Simulator. The fix applies the same way on devices.
