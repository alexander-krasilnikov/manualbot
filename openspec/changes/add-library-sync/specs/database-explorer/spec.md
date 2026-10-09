# Spec Delta

## MODIFIED Requirements

### Requirement: Collections overview
The explorer SHALL list every collection in the app's scope with its document count, grouped into collections that are replicated and collections that stay on the device. Counts MUST be read when the explorer opens and when the presenter asks to refresh; they MUST NOT change on their own while the explorer is showing.

#### Scenario: Groups and counts
- **WHEN** the presenter opens the explorer on a library of three ready documents and one chat
- **THEN** documents, chunks and images are listed as replicated, chats, messages, ingestJobs and localMeta as local only, and documents shows a count of 3

#### Scenario: Refresh
- **WHEN** a document finishes importing while the explorer is open and the presenter refreshes
- **THEN** the counts include the new document and its chunks
