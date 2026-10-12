# Tasks

## 1. Schema and document record

- [x] 1.1 Move `chats` and `messages` to the device-local list in `CouchbaseSchema` and relabel the explorer groups "replicated" / "local only"; update `ExplorerTests` / `ExplorerUITests` so the groups-and-counts scenario passes with documents, chunks, images replicated
- [x] 1.2 Write `chunkCount` for the new generation in the activation transaction (alongside `activeGeneration`), add it to `DocumentRecord`, and verify with an Adapters test that import and re-index both record the active set's chunk count
- [x] 1.3 Backfill `chunkCount` from local counts on repository open for documents without it, and verify with a test that opens a database written without the field

## 2. Arrival guard

- [x] 2.1 Add the per-`(docId, generation)` completeness cache to the repository and filter `activeGenerations()` by it (chunks and images present match `chunkCount` / `imageCount`); verify with an Adapters test that saves a document record with `activeGeneration` and only part of its chunks and finds no search results, then adds the rest and finds them
- [x] 2.2 Expose a way to recompute completeness for given document IDs (for the replicator listener) and for all incomplete documents (on open and library refresh); verify with a test that a document becomes visible after recompute
- [x] 2.3 Add library statuses "arriving" and "indexing on another device" in `LibraryViewModel.status` and the library row; verify with `ViewModelTests` cases for a record with incomplete active set and no job, and a record with no `activeGeneration` and no job
- [x] 2.4 Make `reindexOutdated` / `outdatedDocuments` skip arriving documents and documents without `activeGeneration`; verify with a Core test that such documents are not queued
- [x] 2.5 Check retrieval latency stays within budget with the cache: run the existing large-library retrieval test and confirm it passes

## 3. Ingestion: size limit and fixed sample IDs

- [x] 3.1 Refuse files over 20 × 1024 × 1024 bytes in `IngestionService` before anything is stored, reported through the existing rejection path with name, size and limit; verify with Core tests for 34 MB (refused, others in the batch imported) and exactly 20 MB (imported), and a `ViewModelTests` case for the message
- [x] 3.2 Let `IngestionService.import` take an optional document ID and have `SampleDocuments` use `sample-<name>`; verify with a test that loading samples twice into one database leaves one copy of each, and with `DemoTests` that reset still ends with only the samples

## 4. Sync port and policy

- [x] 4.1 Add `LibrarySync`, `SyncConfiguration` and `SyncStatus` to Ports and a scripted stub to `PortsTesting`; verify the packages build and the stub emits a scripted status sequence in a test
- [x] 4.2 Implement `SyncPolicy` in Core (running / paused: off-model embedder, outdated documents remaining, with the fleet model's name); verify with unit tests for: fleet model and no outdated documents → running; other embedder → paused; fleet model with outdated documents → paused until zero; sync disabled → off

## 5. Couchbase Lite replicator adapter

- [x] 5.1 Implement `CouchbaseLibrarySync`: continuous push-pull replicator over `documents`, `chunks`, `images` with basic authentication, status mapping (connecting, syncing, up to date, credentials refused without retry, unreachable with retry), sent and received counts; verify with an in-process test against a `URLEndpointListener` peer that a document with its chunks and images replicates and the status reaches up to date
- [x] 5.2 Add the push filter: originals over the limit and their chunks and images, and chunks or images not from the fleet model; verify with in-process tests that such records do not reach the peer while others do, and that the not-shared list names the large document
- [x] 5.3 Feed the replicator's document listener into the completeness recompute; verify with an in-process test that a received document is invisible to search until all chunks arrive and visible right after
- [x] 5.4 Verify replication of deletes and re-index with in-process tests: a delete on one side removes the document, chunks and images on the other; a re-index on one side leaves exactly the new generation on the other
- [x] 5.5 Verify that `chats`, `messages`, `ingestJobs` and `localMeta` records never reach the peer, with an in-process test that writes one of each

## 6. App: settings, status and wiring

- [x] 6.1 Add `SyncSettings` (address, user name, enabled in `UserDefaults`; password in the Keychain) and verify with `AppTests` that values persist and the password is not stored in `UserDefaults`
- [x] 6.2 Wire the replicator into `AppModel`: start when enabled and `SyncPolicy` says running, pause or resume on embedder switch and when documents become ready, stop before `makeCore` replaces the repository and restart after; verify with `ModelSwitchTests` that switching to another embedder pauses and switching back resumes only after re-indexing finishes
- [x] 6.3 Turn the toolbar gear into Settings with Models and Sync rows (Models page unchanged) and update existing UI tests that open the Models page; verify `ModelSettingsUITests` pass
- [x] 6.4 Build the Sync page (address, user name, password, switch, state, last sync, counts, last error, not-shared documents) and verify with view-model tests for each state and a UI test that enters settings and turns sync on with the stub
- [x] 6.5 Add the cloud indicator next to the gear, showing each state and opening Settings at Sync; add the `-uiTestSync` launch argument; verify with a UI test per state that the indicator shows it and opens the Sync page
- [x] 6.6 Add "from every device" to the delete and reset confirmations when sync is enabled, and the sync-pause sentence to the embedder activation confirmation when the target is not the fleet model; verify with view-model tests for the confirmation texts with sync on and off
- [x] 6.7 Add `NSAllowsLocalNetworking` and `NSLocalNetworkUsageDescription` to `project.yml`, run `xcodegen generate`, and verify the generated Info.plist contains both keys

## 7. X-ray sync events

- [x] 7.1 Add the `sync` operation kind and events (state changes, sent/received batches per collection, refused records, document searchable) with their caption; verify with `DemoTests` that a scripted replication produces a visible sync group with those events and that no sync events appear with sync off
- [x] 7.2 Verify a reset with sync on is traced as before and that the X-ray UI test for reset still passes

## 8. Local sync stack

- [x] 8.1 Pin Couchbase Server and Sync Gateway Enterprise image tags compatible with Couchbase Lite 4.1.2 and write `sync/docker-compose.yml` with health checks, `4984` published, `4985` bound to `127.0.0.1`; verify `docker compose config` succeeds
- [x] 8.2 Write `sync/init/cb-init.sh` (cluster, bucket, scope, collections, Sync Gateway RBAC user) and `sync/init/sgw-init.sh` (database config, users `ipad1`–`ipad3`), both idempotent; verify that `docker compose up` from empty reports ready and that running it a second time succeeds without errors
- [x] 8.3 Write `sync/sgw/bootstrap.json` and `sync/sgw/database.json` with the `library` sync function for the three collections; verify with curl that an unauthenticated request to `4984` is refused, an authenticated user can write a document, and `4985` is not reachable on the LAN address
- [x] 8.4 Write `sync/README.md` (start, simulator and iPad addresses, users, reset with `down -v`) and `.env.example`; verify by following it from a clean checkout
- [x] 8.5 Add the opt-in Adapters suite enabled by `SYNC_GATEWAY_URL` that replicates a document with chunks and images and a 20 MB original through the stack; verify it passes against a running stack and is skipped without the variable

## 9. Documentation and end-to-end check

- [x] 9.1 Update the README: qualify the offline promise for sync, add a Sync section (Settings, fleet model rule, 20 MB limit, chats stay local, global delete) linking to `sync/README.md`; verify the commands in it run as written
- [x] 9.2 End-to-end check with the stack and two simulators: import on one, it arrives and becomes searchable on the other without indexing; rename and delete propagate; switching one simulator to another embedder pauses its sync and it resumes after switching back and re-indexing; chats stay local
