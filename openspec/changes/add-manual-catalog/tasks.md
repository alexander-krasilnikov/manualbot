# Tasks

## 1. Curated source and maintenance script

- [x] 1.1 Convert `seed/candidates.json` and `seed/rejected.json` into `scripts/manual-catalog/curated.json`: give every entry a stable slug `id`, keep `selected`, `kind`, licence note and notes, store rejections with reason and date, and set `documentId` on the two Couchbase entries that are bundled samples (`sample-couchbase-under-the-hood`, `sample-capella-architecture-overview`). Verify with a one-off count: 70 selected across the 9 categories, ids and URLs unique.
- [x] 1.2 Add `scripts/manual-catalog.swift` with the `check` command: `URLSession` with an ephemeral configuration and an honest User-Agent, HTTPS only (including the final address after redirects), `%PDF-` signature, exact byte count up to 20 MiB, SHA-256, and per-entry results ok / changed / too large / not a PDF / blocked / gone / unreachable. Verify by running it on `curated.json` (the report lists every selected entry and writes no file, confirmed with `git status`) and on a copy with one entry pointed at an HTML page, which must report "gone" and exit non-zero.
- [x] 1.3 Add retries with a pause for 5xx and 429, sequential requests per host with spacing, and the per-category summary table with a final "N need attention" line. Verify by pointing one entry at a URL that answers 429 (or a local server that does) and seeing it reported "unreachable", not "gone".
- [x] 1.4 Add the military distribution-statement check with PDFKit: read the first pages' text and fail a Military entry that lacks a public-release statement or carries a restriction or export-control notice. Verify on the six selected Military entries (all pass) and on the rejected TM 9-2320-391-10-3 URL (fails).
- [x] 1.5 Add `refresh`: re-measure qualifying entries and update size, page count, title, checksum and `verifiedAt` in `curated.json`, leaving failing entries untouched and listed. Verify that a run updates `verifiedAt` and that a deliberately broken entry keeps its old record.
- [x] 1.6 Add `rebuild`: promote a qualifying alternate of the same category and kind into a failing slot, validate (unique ids, HTTPS only, all 9 categories, every entry ≤ 20 MiB, count compared with the previous file), sort by category and title, and write `App/Resources/ManualCatalog.json` only when validation passes. Verify that two runs give byte-identical output (`shasum`), and that a duplicated URL makes it write nothing.
- [x] 1.7 Run `rebuild` to produce the first `App/Resources/ManualCatalog.json`, include it in the app bundle via `project.yml`, and record every entry the check marked "blocked" (the app's downloader will hit the same wall) by swapping it for an alternate. Verify the resource is in the built app and the check reports no selected entry blocked.
- [x] 1.8 Write `docs/manual-catalog.md`: what the catalog is, the selection rules, and how to run `check`, `refresh` and `rebuild` before a release. Verify each documented command runs as written.

## 2. Ports: catalog, origin and downloader contracts

- [x] 2.1 Add `ManualCatalog` and `ManualCatalogEntry` (with `kind`, `category`, optional `documentId`, and a computed `documentID` of `documentId ?? "catalog-<id>"`) in `Ports`, decoded like `ModelManifest`. Verify with a Ports test that decodes `App/Resources/ManualCatalog.json` and a fixture with an unknown field.
- [x] 2.2 Add `DocumentOrigin` (entry id and URL) and an optional `origin` on `DocumentRecord`, defaulted to `nil`, and carry it in `InMemoryDocumentRepository`. Verify with a Codable test that a record JSON without `origin` still decodes.
- [x] 2.3 Add the `ManualDownloading` port (download an entry to a temporary file with progress and cancellation; typed errors for offline, blocked, gone, not a PDF, too large, HTTP status, connection lost) and a fake in `PortsTesting`. Verify the package builds and the fake is usable from a test.

## 3. Adapters: persistence and download

- [x] 3.1 Store and read `origin` in `CouchbaseDocumentRepository` and its sharing path, so it survives re-indexing and replication. Verify with repository tests: round trip, an older document without `origin`, and a re-index that keeps it; and, with `SYNC_GATEWAY_URL` set, that a replicated record carries it.
- [x] 3.2 Add `URLSessionManualDownloader`: ephemeral session, no cookies, honest User-Agent, streamed through a delegate, `%PDF-` check on the first bytes, abort past 20 MiB with or without Content-Length, HTTPS-only final address, file named `<entryId>.pdf`, SHA-256 while streaming, temporary file removed on every failure. Verify with `URLProtocol`-stubbed tests (like `HuggingFaceModelSearchTests`) for: PDF at an address without `.pdf`, HTML body, 403, 404, a body that passes 20 MiB without Content-Length, an http final redirect, a dropped connection (no file left), and cancellation.
- [x] 3.3 Add an opt-in network test (`RUN_NETWORK_TESTS=1`) that downloads two small real entries (one NREL, one manufacturer) through the adapter. Verify it passes locally and is skipped by default; list it in `docs/testing.md`.

## 4. Core: import with origin

- [x] 4.1 Let `IngestionService.enqueue` accept an optional origin and write it on the new record; an existing id is still left untouched. Verify with Core tests: a catalog import stores the origin, a second import with the same id does nothing, and a re-index keeps the origin.
- [x] 4.2 Add a catalog import use case that downloads an entry, checks the checksum against the record (a mismatch is reported, not an error), hands the file to `enqueue` with the entry's title, `documentID` and origin, and removes the temporary file afterwards. Verify with Core tests using the fake downloader: success, mismatch note, each failure leaving no document and no file, and an entry whose document already exists not being downloaded.

## 5. App: catalog model and wiring

- [x] 5.1 Load `ManualCatalog.json` in `AppEnvironment` and wire the downloader; move `NetworkMonitor` out of `App/Demo` into a shared place without changing its behavior. Verify the app tests still pass and the catalog loads in `AppTests`.
- [x] 5.2 Add `CatalogViewModel`: grouping by category, kind filter (hiding empty categories), text search over title, publisher and category, per-entry state derived from the library's document ids and in-flight downloads (not imported, downloading with progress, queued, in library, failed with reason), cancel, retry, multi-select import where one failure does not stop the others, offline disabling, and a per-host "first download" notice remembered across launches. Verify with `AppTests` covering each requirement scenario in the `manual-catalog` spec, including delete returning an entry to "not imported" and an entry imported on another iPad showing "In library".
- [x] 5.3 Add a UI-test launch option that swaps in a stub downloader serving a fixture PDF (and one failing entry), like the existing model stub. Verify a UI test can import from the catalog without network.

## 6. App: catalog and library UI

- [x] 6.1 Turn the toolbar Import button into a menu with "Files…" and "Manual catalog…", and add the catalog to the empty-library screen. Verify with a UI test that both routes open the catalog sheet and "Files…" still opens the picker.
- [x] 6.2 Build the catalog sheet: category sidebar, kind filter, search, rows with title, publisher, kind badge, size, pages and state, multi-select, an entry detail with publisher, licence note and source address, the host notice, the offline message, and "Open in browser" for a blocked entry. Verify with UI tests: search "outboard", the catalog filter, a single import reaching the library, a multi-select import with one failure, and the failed row offering retry.
- [x] 6.3 Show the publisher host for documents with an origin in the library's document details. Verify with a UI test after a catalog import, and with an app test for a synced record that carries an origin.
- [x] 6.4 Update the copy that says everything stays on the iPad so it mentions catalog downloads, and update `README.md`, `docs/using.md`, `docs/architecture.md` and `docs/demo.md` (a short catalog step, with a screenshot via `DocsScreenshotsUITests` and `scripts/export-doc-screenshots.sh`). Verify the docs render and the screenshot test passes.

## 7. Integration checks

- [x] 7.1 Run the package tests for Ports, Core and Adapters and the affected app unit and UI tests (`ViewModelTests`, the new catalog tests, `AppUITests`), and confirm they pass.
- [ ] 7.2 On a simulator or iPad with network, import at least one entry from each of the nine categories, including an archive.org and an `info.couchbase.com` entry, and confirm each reaches "ready" and is answerable in chat; record any host that fails in the app but passed the script, and fix the list with `rebuild`.
- [ ] 7.3 Run `swift scripts/manual-catalog.swift check` one last time and confirm it exits successfully with no selected entry needing attention.

## Workflow follow-up

- Archive the change with `/opsx:archive` after review, which folds `manual-catalog`, `manual-catalog-curation` and the `document-ingestion` delta into the main specs.
- The `seed/` folder is input to task 1.1 only; it is archived with the change and is not used afterwards.
