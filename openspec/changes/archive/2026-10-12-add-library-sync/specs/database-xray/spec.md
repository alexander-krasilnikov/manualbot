# Spec Delta

## ADDED Requirements

### Requirement: Sync events
While sync is on, the X-ray panel SHALL show replication activity as its own operation kind, visible by default: the
replicator's state changes, each batch of records sent or received with its collection and count, records refused by the
server with the reason, and each received document becoming searchable once all of its chunks and images have arrived.
The captions MUST explain that the library replicates while vector and full-text indexes are built on each device.

#### Scenario: Receiving a manual
- **WHEN** another iPad imports a manual while X-ray is showing
- **THEN** a sync group shows the received document record, the received chunk and image batches, and the moment the document became searchable

#### Scenario: Sync off
- **WHEN** sync is off
- **THEN** no sync events appear

## MODIFIED Requirements

### Requirement: Reset demo
The X-ray panel SHALL offer a reset action that, after a confirmation naming what will be deleted, deletes every document and chat and imports a fixed set of bundled sample documents, including at least one PDF, one photo, and one document that contains a photo. The reset MUST be traced as its own operation. Cancelling the confirmation MUST change nothing. When sync is on, the confirmation MUST say that the documents are deleted from every device that shares the library.

#### Scenario: Reset
- **WHEN** the presenter confirms reset
- **THEN** the library contains only the sample documents, which become ready, the chat list is empty, and the X-ray log shows the deletions and the imports

#### Scenario: Reset with sync on
- **WHEN** the presenter chooses reset while sync is on
- **THEN** the confirmation says the documents are deleted from every device, and after confirming, every syncing iPad's library contains only the sample documents

#### Scenario: Cancel reset
- **WHEN** the presenter cancels the reset confirmation
- **THEN** the library and chats are unchanged
