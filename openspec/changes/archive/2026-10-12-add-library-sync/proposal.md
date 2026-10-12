# Proposal

## Why

Each iPad has its own library today: a manual imported on one iPad has to be imported again, and indexed again, on every
other. A team of iPads should share one library, so that any of them can import a manual and every other one can search
it shortly after, while each keeps working offline as it does now. Couchbase Lite already stores the library and the
collections were split into replicated and device-local ones from the start, so Sync Gateway and Couchbase Server can
carry it. Developers and presenters also need a way to run that backend on a laptop.

## What Changes

- Add two-way replication of the library (`documents` with their originals, `chunks`, `images`) between the iPad and a
  Sync Gateway database backed by Couchbase Server. Every iPad can import, rename, re-index and delete; the result
  reaches every other iPad.
- Index once, search everywhere: chunks and image vectors replicate with their documents, so a document imported on one
  iPad becomes searchable on another without being indexed there. A received document is searchable only once all of
  its chunks and images have arrived; until then the library shows it as arriving.
- One embedding model for the fleet: the app's default embedder. While an iPad uses another embedder, or its library
  still holds vectors from one, sync is paused with an explanation, and it resumes once the library is back on the fleet
  model.
- Originals larger than 20 MB (the largest attachment Sync Gateway accepts) are refused at import, whether or not sync is
  on. Documents imported before this change with larger originals are kept on the device and shown as not shared.
- **BREAKING** (demo data): chats and messages become device-local and never replicate. They were labelled
  "sync-ready" until now.
- Deleting a document, and resetting the demo, remove documents from every iPad once sync is on; their confirmations say
  so. Sample documents get fixed identities, so two iPads loading the samples share one copy.
- Settings gets a Sync page next to Models: server address, user name and password (kept in the Keychain), an on/off
  switch, the status and last error, and the documents that are not shared. A cloud indicator in the library toolbar
  shows the sync state and opens the Sync page.
- The X-ray panel shows replication activity: documents sent and received, and documents completing their arrival.
- Network use after setup is extended to sync, to the configured server only, and only while sync is on.
- Add a Docker Compose stack that starts Couchbase Server and Sync Gateway on a laptop, creates the bucket, scope and
  collections, the Sync Gateway database with its sync function, and one user per iPad, with one command.

## Capabilities

### New Capabilities
- `library-sync`: two-way replication of the shared library with Sync Gateway: what replicates, the fleet embedding
  model rule, arrival of received documents, the Sync settings page and status indicator, credentials, and errors.
- `local-sync-stack`: the Docker Compose stack that runs Couchbase Server and Sync Gateway locally, already configured
  for the app, and how an iPad or the simulator connects to it.

### Modified Capabilities
- `document-ingestion`: originals over 20 MB are refused at import; deleting a document removes it from every iPad
  when sync is on.
- `database-explorer`: chats and messages are listed as device-local, not sync-ready.
- `model-provisioning`: offline operation allows network requests to the configured Sync Gateway while sync is on.
- `model-catalog`: activating an embedder other than the fleet model says, in its confirmation, that sync pauses.
- `database-xray`: replication activity is traced; resetting the demo with sync on removes documents from every iPad,
  and its confirmation says so.

## Impact

- **Ports / Core**: a sync port (start, stop, status) and the fleet-model pause rule; ingestion records the number of
  chunks and images of the active generation on the document, and refuses large originals.
- **Adapters**: a Couchbase Lite replicator over the `documents`, `chunks` and `images` collections; the schema moves
  `chats` and `messages` to device-local; readiness of a document also requires all of its chunks and images to be
  present.
- **App**: Settings with Models and Sync, the toolbar cloud indicator, Keychain storage for the password, X-ray sync
  events, delete and reset confirmations, fixed sample document IDs. Info.plist gains local-network access
  (`NSAllowsLocalNetworking`, `NSLocalNetworkUsageDescription`) so a real iPad can reach a laptop.
- **New files**: `sync/` with `docker-compose.yml`, init scripts, the Sync Gateway database config and sync function,
  and a README section on running it.
- **Dependencies**: none new in the app (replication is part of Couchbase Lite Enterprise 4.1.2). The stack uses the
  Couchbase Server and Sync Gateway container images.
- **README**: the offline promise is qualified for sync, and a Sync section describes setup.
