# Proposal

## Why

The X-ray panel shows what the database does during each operation, but not what the database holds. A presenter cannot show the collections, the local-only split, the indexes or how a passage points to its document, except by tapping one ID at a time. A developer debugging ingestion has no way to look at the database on the device other than adding log lines. A read-only explorer inside the app serves both, and nearly all of the read path already exists in the X-ray document inspection.

## What Changes

- **Database explorer**: a full-screen, read-only view of the local Couchbase Lite database. It is always available, opened from a toolbar button. Done returns to the workspace exactly as it was left.
- **Three columns**: a sidebar with the collections (grouped as sync-ready and local-only, each with its document count), the indexes, and a Query entry; a middle column with the document IDs of the selected collection (paged, filterable by ID) or the SQL++ editor and its results; a right column with the selected document, result row, index or query plan.
- **Document view**: the stored JSON as in X-ray (vectors shortened, blobs summarized), plus showing a vector in full, a preview of image and text blobs, and fields that reference another document (`docId`, `chatId`, `imageId`) opening that document. A `documents` record also lists its passages and images.
- **SQL++ console**: run a SELECT typed by the user or picked from a few starter queries, see up to 200 result rows, open the query plan, and cancel a slow query. Queries with parameters are not supported in v1 and show an error.
- **X-ray link**: tapping a document ID in an X-ray event opens the explorer at that document, instead of showing it in a sheet.
- **Demo mode is removed.** X-ray, the explorer, Reset demo and the sample-photo button are part of the app at all times. There is no setting, About toggle or `-demoMode` launch argument, and tracing records from launch. The remembered preference is ignored.
- Counts and lists refresh when the explorer opens and on a refresh action, not live.
- The explorer never writes to the database and is not shown in the X-ray log. Import, search, chat and storage behavior are unchanged.

## Capabilities

### New Capabilities
- `database-explorer`: the entry point, the full-screen layout, browsing collections, documents and indexes, the document view with references and blob previews, the SQL++ console, and the read-only guarantee.

### Modified Capabilities
- `database-xray`: the "Demo mode" requirement is removed and replaced by "Always available". "Detail column switch", "Live operation log" and "Reset demo" no longer depend on demo mode. "Document inspection" opens the database explorer at the tapped document instead of showing the JSON in place.

## Impact

- **Ports**: `TraceInspector` gains read-only listing calls (collections with counts, a page of document IDs, indexes), a full-vector option for a stored document, a blob read, and a capped SQL++ query.
- **Adapters**: `CouchbaseTraceInspector.swift` implements them on the existing repository, with no trace events.
- **App**: a new `Explorer` folder with the explorer model and views, a toolbar button and full-screen presentation in the workspace, and the X-ray document links routed to the explorer.
- **Dependencies**: none new.
- **Behavior for everyone**: the detail column always has the Source / X-ray switch, and tracing work (events, timings, shortened vectors) now happens on every import and question. It was off by default before.
- **Performance**: no cost while the explorer is closed. A console query runs on the repository actor and can delay the app's own database work until it finishes.
