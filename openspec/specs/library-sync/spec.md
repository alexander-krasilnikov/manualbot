# library-sync Specification

## Purpose
Lets a team of iPads share one library through Sync Gateway and Couchbase Server: any iPad imports, and every other
iPad can search the result without indexing it again, while each keeps working offline.

## Requirements

### Requirement: Shared library replication
While sync is on, the app SHALL replicate documents with their originals, chunks and images in both directions with the
configured Sync Gateway database, continuously while a connection exists. Chats, messages, ingestion jobs and other
device-local data MUST NOT be sent.

#### Scenario: Import on one iPad
- **WHEN** iPad A, with sync on, imports a manual and it becomes ready, and iPad B is on the same server
- **THEN** the manual appears in iPad B's library and becomes searchable there without being indexed on iPad B

#### Scenario: Chats stay on the device
- **WHEN** the user of iPad A asks questions in a chat while sync is on
- **THEN** no chat or message is sent to the server, and iPad B's chat list is unchanged

#### Scenario: Rename
- **WHEN** a document is renamed on iPad A while sync is on
- **THEN** iPad B shows the new title

### Requirement: Offline first
Sync MUST NOT be needed for any other feature. With no connection, or with the server unreachable, import, search and
chat SHALL work as without sync, and changes made meanwhile SHALL be sent and received once the server is reachable
again.

#### Scenario: Import while offline
- **WHEN** an iPad with sync on imports a manual in airplane mode and later reconnects
- **THEN** the manual is searchable on that iPad at once, and reaches the other iPads after the reconnection

### Requirement: Arrival of received documents
A document received from the server SHALL become searchable only when this iPad holds every chunk and image of its
active set. Until then the library MUST show it as arriving, and vector, keyword and photo search MUST NOT return any of
its chunks or images. A document whose indexing has not finished on the importing iPad MUST be shown as being indexed
on another device, and MUST NOT be indexed on this iPad unless the user asks to re-index it.

#### Scenario: Partly received
- **WHEN** the record of a 300-chunk manual and 120 of its chunks have arrived
- **THEN** the library shows the manual as arriving, and no question is answered from it

#### Scenario: Fully received
- **WHEN** the remaining chunks and images arrive
- **THEN** the manual becomes ready and searchable, with no indexing on this iPad

#### Scenario: Still indexing elsewhere
- **WHEN** iPad B receives a document that iPad A is still embedding
- **THEN** iPad B shows it as being indexed on another device and does not index it

### Requirement: Fleet embedding model
Shared vectors SHALL come from one embedding model, the app's default embedder. Sync MUST pause while the active
embedder is another model, and while the library still holds a document whose vectors came from another model. It
MUST resume on its own once neither is true.

#### Scenario: Another embedder in use
- **WHEN** the user of an iPad with sync on activates an embedder other than the fleet model
- **THEN** sync pauses, the Sync page and the cloud indicator say why and name the fleet model, and nothing is sent or received

#### Scenario: Back on the fleet model
- **WHEN** the user activates the fleet model again and every document has been re-indexed with it
- **THEN** sync resumes on its own, sending the changes made while paused and receiving what other iPads changed

#### Scenario: Paused during the re-index
- **WHEN** the fleet model is active again but documents are still being re-indexed with it
- **THEN** sync stays paused until the last of them is ready

### Requirement: Original size limit for sharing
Documents whose stored original is larger than 20 MB SHALL NOT be sent to the server. They MUST stay usable on the iPad
that holds them, and MUST be listed as not shared on the Sync page with their size.

#### Scenario: Older large document
- **WHEN** sync is turned on for a library holding a 35 MB PDF imported before the limit existed
- **THEN** the PDF stays searchable on this iPad, is not sent, and the Sync page lists it as not shared, too large

### Requirement: Shared deletion
While sync is on, deleting a document SHALL remove it, its original, its chunks and its images from every iPad that
syncs with the server, and from the server.

#### Scenario: Delete on one iPad
- **WHEN** a document is deleted on iPad A with sync on
- **THEN** it disappears from iPad B's library and none of its chunks or images are returned by search on iPad B

### Requirement: Sync settings
Settings SHALL have a Sync page next to Models, with the server address, user name and password, and a switch that turns
sync on and off. The password MUST be stored in the Keychain and never shown. Sync MUST be off until the user turns it
on, and the setting MUST be remembered across launches.

#### Scenario: First set-up
- **WHEN** the user enters the server address, user name and password and turns sync on
- **THEN** the app connects, the status becomes syncing and then up to date, and the setting stays on after a relaunch

#### Scenario: Turning sync off
- **WHEN** the user turns sync off
- **THEN** nothing more is sent or received, and the library on this iPad stays as it is

### Requirement: Sync status
The Sync page SHALL show the state (off, connecting, syncing, up to date, paused with its reason, or error with its
message), the time of the last completed sync, and how many documents were sent and received. A cloud indicator in the
library toolbar MUST show the same state at a glance and MUST open the Sync page when tapped.

#### Scenario: Indicator
- **WHEN** sync is on and a received manual is arriving
- **THEN** the cloud indicator shows syncing, and tapping it opens the Sync page

#### Scenario: Wrong password
- **WHEN** the server rejects the user name or password
- **THEN** the state is error with a message that the credentials were refused, and sync does not retry until they are changed

#### Scenario: Server unreachable
- **WHEN** sync is on and the server cannot be reached
- **THEN** the state says the server is unreachable, the app keeps retrying, and everything else keeps working

### Requirement: Shared sample documents
The bundled sample documents SHALL have the same identities on every iPad, so loading them on several iPads that sync
leaves one copy of each in the shared library.

#### Scenario: Samples on two iPads
- **WHEN** two iPads with sync on both load the sample documents
- **THEN** each sample appears once in the library of both iPads
