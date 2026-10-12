# Design

## Context

See proposal.md for why. The relevant state of the code:

- One Couchbase Lite Enterprise 4.1.2 database, scope `manualbot`. `CouchbaseSchema` labels `documents`, `chunks`,
  `images`, `chats`, `messages` as sync-ready and `ingestJobs`, `localMeta` as device-local. Deletes use `delete`
  (tombstones), never `purge`, so they replicate as they are.
- Document IDs are random UUIDs; chunk IDs are `docId:generation:ordinal` (`Chunk.makeID`); image IDs follow the same
  pattern. A document's searchable set is the one named by `documents.activeGeneration`, read by
  `CouchbaseDocumentRepository.activeGenerations()`, which both search and readiness go through.
- Ingestion saves the document record first, attaches the original as a blob, writes chunk and image batches, and then
  in one transaction sets `activeGeneration` and deletes the previous generation. Progress lives in `ingestJobs`.
- The library derives a document's status from its record and its local job (`LibraryViewModel.status`): no job plus an
  `activeGeneration` reads as ready.
- `Services.makeCore` builds the repository, ingestion and retrieval from the active embedder, and is rebuilt on every
  embedder switch. `IngestionService.reindexOutdated` re-indexes documents whose vectors came from another model.

## Goals / Non-Goals

**Goals:**
- A received document never becomes searchable half-way, and no vector from a model other than the fleet model ever
  leaves an iPad.
- Sync is an add-on: with sync off, behaviour, storage and network traffic are as today.
- Replication can be tested in-process, without Docker; the Compose stack is for manual and opt-in end-to-end runs.

**Non-Goals:**
- Per-model chunk sets, or sharing an index between iPads on different embedders.
- Syncing chats or messages, per-person accounts, sign-out, or private documents.
- Capella App Services, TLS, or production deployment of the stack.
- Server-side ingestion or search.
- Smarter conflict merging than Couchbase Lite's default resolver (see Risks).

## Decisions

### D1. Replicate `documents`, `chunks`, `images` into one `library` channel
One continuous push-and-pull replicator with a collection configuration for each of the three collections, against
`ws(s)://<host>:4984/manualbot`, with basic authentication. The Sync Gateway sync function is the same for all three:
`requireAccess("library"); channel("library")` (on deletes, the function sees `doc._deleted` and still routes to
`library`). Each seeded user has `admin_channels: ["library"]`.
- *Why one channel:* every iPad shares the whole library; there are no per-user or per-model partitions. `requireAccess`
  makes write permission the same as read permission.
- *Alternative:* a channel per document type or per model (variant ii in exploration). Rejected with the fleet model.

`chats` and `messages` move to the device-local list in `CouchbaseSchema`; the explorer's grouping reads that list, so
the rename to "replicated" / "local only" follows.

### D2. Fleet model = the app's default embedder, enforced by a pause rule in Core
`SyncPolicy` (Core, pure) computes `running` or `paused(reason)` from: sync enabled, active embedder identity, the fleet
model (a `FleetModel`: the identity and the name shown to the user; by default `EmbedderProfile`'s default), and the number of documents whose vectors are not from the fleet model
(`outdatedDocuments(for: fleet)`). It pauses while the active embedder is not the fleet model **or** that number is
above zero, and is re-evaluated on embedder switch, on every document becoming ready, and on launch.
- *Why "and the library is back on the fleet model", not just "fleet model active":* while paused, an off-model iPad
  re-indexes everything locally: new generations with other vectors, and tombstones for the fleet chunk set. A
  replicator pushes every change since its last checkpoint, so resuming as soon as the fleet model is active again would
  push that state. Resuming only when no document is outdated means everything pushed is fleet-model data again
  (re-indexed generations and tombstones for the off-model generations, which the server never saw and ignores).
- *Belt and braces:* the push filter (D4) also drops any chunk or image whose model is not the fleet model.
- *Alternative:* block activating another embedder while sync is on. Rejected: the Models page would need a
  sync-specific branch everywhere; the pause is clearer and was chosen in exploration.

### D3. Arrival guard: the document records how many chunks and images its active set has
Activation (the transaction that sets `activeGeneration`) also writes `chunkCount` and `activeImageCount` for that
generation, counted from what the database holds. (`imageCount` is not used: it is saved before activation, so during a
re-index it would describe the new set while `activeGeneration` still names the old one.) The check keys its cache on the
record's revision, so a record deleted and created again under the same ID is checked again. On the receiving side, `activeGenerations()` returns a document only when the device holds that many
chunks and images for that generation. Counting uses the existing `chunks_doc_gen` / `images_doc_gen` value indexes.
To stay inside the 500 ms retrieval budget both answers are cached in memory, keyed on the record's generation, counts and
revision: a whole set stays whole until its record changes, and a set found incomplete is not counted again until the
replicator's document listener names the document (`refreshArrivals`) or the repository itself writes chunks or images for
it. A refresh forgets "incomplete" before it queries, so a failed refresh cannot leave a document stuck as arriving. "Became
searchable" is reported once per generation and counts (not per revision), so a rename does not announce it again.
- Library status gains two states: **arriving** (`activeGeneration` set, set incomplete here, whatever the local job says)
  and **indexing on another device** (no `activeGeneration`, no local job). A local import gets its job right after its
  record, so a record with neither, that `IngestionService` is not storing at this moment, was received. A user can index
  such a document here with the row's *Index here* button (the same re-index as the context menu's).
- `reindexOutdated` skips arriving documents and documents with no `activeGeneration`: their vectors are on the way.
- *Why not a separate manifest record:* with one writer per document at a time and one model, a field on the document
  is enough, and it is written in the same transaction as `activeGeneration`.
- *Migration:* documents imported before this change have no `chunkCount`. On open, the repository backfills it from the
  local counts before sync may start, so a pushed record always carries it.
- *Re-index on another iPad:* the new `activeGeneration` may arrive before its chunks; the document then reads as
  arriving until they are in. Falling back to the previous generation was considered and rejected as not worth its
  complexity for a few seconds.

### D4. Push filter for size and model
The replicator's push filter drops: a `documents` record whose original blob is larger than the limit; any chunk or
image of such a document (an in-memory set of not-shared IDs, built on open and updated on import); any chunk or image
whose `embeddingModel` / `featureModel` is not the fleet model. Not-shared documents are listed on the Sync page from the
same set.

### D5. 20 MB import limit in Core
`IngestionService` refuses a file over `20 × 1024 × 1024` bytes before anything is stored, so the picker, share sheet,
drag and drop and samples all go through one check. The rejection reuses the existing "rejected file" reporting with a
new reason. The limit is Sync Gateway's maximum attachment size; the stack test (task group 8) confirms a file at the
limit replicates.

### D6. Ports and lifetimes
- **Ports:** `LibrarySync` protocol with `start(SyncConfiguration)`, `stop()`, and `statusUpdates` (an `AsyncStream` of
  `SyncStatus`: off, connecting, syncing, upToDate(lastSync), paused(reason), error(kind, message), with `sent` and
  `received` counts of documents and `records`, a count of everything that moved, which tells the library that chunks arrived). `PortsTesting` gets a scripted stub.
- **Adapters:** `CouchbaseLibrarySync` owns the `Replicator` over the repository's `Database`, maps replicator status and
  errors (401 → credentials refused, no stop-and-retry; unreachable → keeps retrying, the replicator's own behaviour),
  installs the push filter, and feeds the document listener to the arrival cache and the tracer.
- **App:** `SyncSettings` (address, user name, enabled in `UserDefaults`; password in the Keychain as a generic password
  item). `AppModel` stops the replicator before `makeCore` replaces the repository and starts it again on the new one,
  then lets `SyncPolicy` decide whether it runs.
- *Why the replicator in Adapters and the policy in Core:* the policy is testable without a database, and the adapter
  stays a thin mapping of Couchbase Lite.

### D7. UI
- The toolbar gear becomes **Settings**, a list with **Models** (today's page, unchanged) and **Sync**.
- The Sync page: address, user name, password, on/off switch, status, last sync time, sent/received counts, last error,
  not-shared documents.
- A cloud indicator sits next to the gear: `icloud.slash` (off), progress (connecting/syncing), `checkmark.icloud` (up to
  date), `pause` badge (paused), `exclamationmark.icloud` (error). Tapping it opens Settings at Sync.
- Delete and reset confirmations add "from every device" when sync is on (`SyncSettings.enabled`, not live status, so
  the warning holds while offline: the delete is still sent later).
- UI-test launch argument `-uiTestSync off|syncing|upToDate|paused|error` drives the stub, as `-uiTestSearch` does
  today.

### D8. Sample documents with fixed IDs
`IngestionService.import` takes an optional document ID; `SampleDocuments` passes `sample-<name>`. Re-creating a deleted
ID after a reset is allowed by Couchbase Lite and replicates as a new revision.

### D9. X-ray
New trace operation kind `sync`, grouped like user operations and visible by default. Events: replicator state changes,
batches sent and received (one event per collection per batch the document listener reports),
records refused with their error, and "document searchable" when D3's cache flips a document to complete. One caption
explains replicated data versus indexes built on each device.

### D10. Compose stack in `sync/`
```
sync/
  docker-compose.yml         couchbase-server, cb-init, sync-gateway, sgw-init
  init/cb-init.sh            cluster-init, bucket, scope, collections, RBAC user for Sync Gateway (idempotent)
  init/sgw-init.sh           PUT database config, PUT users ipad1..ipad3 (idempotent: 412 on existing db is success)
  sgw/bootstrap.json         Sync Gateway bootstrap config (server address, credentials, no TLS for local use)
  sgw/database.json          bucket, scope manualbot with documents/chunks/images, sync function
  .env.example               passwords, ports
  README.md                  start, connect (simulator: localhost; iPad: LAN IP), users, reset (down -v)
```
- Enterprise images of Couchbase Server and Sync Gateway (the app is on Couchbase Lite Enterprise); versions pinned to
  exact tags that are compatible with Couchbase Lite 4.1.2.
- `4984` published on all interfaces (iPads on the LAN); `4985` (admin) published on `127.0.0.1` only.
- Init containers run once, wait on health checks, and exit 0 when everything already exists.
- Info.plist: `NSAppTransportSecurity/NSAllowsLocalNetworking = YES` (plain `ws://` to local addresses only) and
  `NSLocalNetworkUsageDescription`.

### D11. Testing approach
- Core: `SyncPolicy` and the size limit as unit tests.
- Adapters: real replication between two databases in-process, using Couchbase Lite Enterprise's
  `URLEndpointListener` as the peer: partial arrival, push filters, deletes, generation changes. No Docker needed.
- An opt-in suite (`SYNC_GATEWAY_URL` set) replicates against the Compose stack, following the existing
  `EMBEDDER_MODEL_PATH` pattern.
- App: view-model tests with the stub; UI tests for the Settings/Sync navigation and indicator.

## Risks / Trade-offs

- [Concurrent edits to one document record (rename on A while B re-indexes) resolve with the default resolver, and one
  change is lost] → Rare in a small fleet; the user renames again. A field-merging resolver can come later.
- [Two iPads re-index the same document at once (both after an app update that changes the default embedder) and write
  the same chunk IDs] → Same model and input give near-identical vectors, and the last write wins per chunk; the
  generation and counts agree. Wasteful, not wrong.
- [An iPad that was off-model re-embeds its whole library before it resumes, instead of pulling] → The cost is stated in
  the confirmation; it only happens to iPads that left the fleet model.
- [Partial arrival hides a re-indexed document for a few seconds on other iPads] → Accepted (D3).
- [Global delete and reset make a mistake on one iPad visible everywhere] → The confirmations say so; the server keeps
  no undo.
- [The completeness cache misses an arrival event and a document stays arriving] → Recomputed on every open, and a
  library refresh recomputes documents still arriving.
- [The 20 MB Sync Gateway limit differs from the constant] → The opt-in stack test pushes a file at the limit.
- [A pushed original near 20 MB takes long on slow Wi-Fi] → Replication runs in the background; the X-ray shows progress.

## Migration Plan

1. On first launch of the new version, the repository backfills `chunkCount` for documents without it. Nothing else
   changes until the user turns sync on.
2. Turning sync on for the first time pushes the existing library (except not-shared documents) and pulls the server's.
   Two iPads with their own libraries merge into one.
3. Rollback: turning sync off stops replication and leaves the local library as it is. An older app version ignores
   `chunkCount`.

## Open Questions

- Exact Couchbase Server and Sync Gateway image tags for Couchbase Lite 4.1.2. Pinned during task 8.1 from Couchbase's
  compatibility matrix; it does not change the design.
