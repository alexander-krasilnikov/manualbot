# database-explorer Specification

## Purpose
Lets a presenter or developer look inside the app's local Couchbase Lite database on the device, browsing its collections, documents and indexes and running read-only SQL++ queries, without changing what is stored.

## Requirements

### Requirement: Entry and exit
The database explorer SHALL be available from a control in the workspace at all times. It MUST open full screen over the workspace. Closing it MUST return to the workspace with the same library selection, chat, detail column tab and open source as before it was opened.

#### Scenario: Always there
- **WHEN** the app has just been launched
- **THEN** the workspace shows the Database control

#### Scenario: Open and close
- **WHEN** a chat and a source are open, and the presenter opens the explorer and then closes it
- **THEN** the workspace shows the same chat and the same source at the same position

### Requirement: Read-only
The explorer MUST NOT create, change or delete any document, collection or index. Nothing the explorer reads or queries MUST appear in the X-ray log. Import, search, chat and storage behavior MUST be the same whether or not the explorer was used.

#### Scenario: Browsing leaves no trace
- **WHEN** the presenter browses collections, opens documents and runs a query in the explorer, then closes it
- **THEN** the X-ray log has no new events, and every collection has the same document count as before

### Requirement: Collections overview
The explorer SHALL list every collection in the app's scope with its document count, grouped into collections that are replicated and collections that stay on the device. Counts MUST be read when the explorer opens and when the presenter asks to refresh; they MUST NOT change on their own while the explorer is showing.

#### Scenario: Groups and counts
- **WHEN** the presenter opens the explorer on a library of three ready documents and one chat
- **THEN** documents, chunks and images are listed as replicated, chats, messages, ingestJobs and localMeta as local only, and documents shows a count of 3

#### Scenario: Refresh
- **WHEN** a document finishes importing while the explorer is open and the presenter refreshes
- **THEN** the counts include the new document and its chunks

### Requirement: Document list
Selecting a collection SHALL list its document IDs in ascending order, a page at a time, with a way to load the next page. The presenter MUST be able to filter the list to IDs that contain a given text. An empty collection or a filter with no matches MUST say so.

#### Scenario: Paging
- **WHEN** the presenter selects a collection with more documents than fit on one page and loads more
- **THEN** the next IDs follow the previous ones in order, with no ID repeated or skipped

#### Scenario: Filter
- **WHEN** the presenter filters the chunks collection by a document ID
- **THEN** only chunk IDs containing that text are listed

#### Scenario: Empty collection
- **WHEN** the presenter selects a collection with no documents
- **THEN** the list says the collection is empty

### Requirement: Document view
Selecting a document SHALL show it as stored, as pretty-printed JSON with keys, strings, numbers and literals in distinct colors, using the X-ray document inspection's shortening: vectors shortened to a few leading values and their length, blobs shown as content type, size and digest. The presenter MUST be able to show any shortened vector in full. Image blobs MUST offer a preview of the image and text blobs a preview of their text, next to the blob's attributes; other blobs show only their summary. If the document no longer exists, the view MUST say so.

#### Scenario: Chunk
- **WHEN** the presenter opens a chunk
- **THEN** it shows the text, page, generation, embedding model and a shortened embedding with its length

#### Scenario: Highlighted JSON
- **WHEN** the presenter opens any document
- **THEN** it is shown as indented JSON in which keys, string values and numbers are colored differently

#### Scenario: Full vector
- **WHEN** the presenter asks to show the embedding in full
- **THEN** all of its values are shown

#### Scenario: Image preview
- **WHEN** the presenter opens an image record and asks for its blob preview
- **THEN** the stored image is shown next to the blob's attributes

#### Scenario: Deleted while browsing
- **WHEN** the presenter selects a document that was deleted after the list was loaded
- **THEN** the view says the document no longer exists

### Requirement: References
A field that holds the ID of a document in another collection (a chunk's or image's document, a chunk's image, a message's chat) SHALL open that document in the explorer when tapped. Viewing a document record MUST also list its chunks and images, each opening when tapped. The presenter MUST be able to go back to the document they came from.

#### Scenario: Chunk to document
- **WHEN** the presenter taps the document ID in a chunk
- **THEN** the explorer shows that document record, and going back shows the chunk again

#### Scenario: Document to chunks
- **WHEN** the presenter opens a document record
- **THEN** its chunks and images are listed, and tapping one opens it

### Requirement: Indexes
The explorer SHALL list every index with its name and collection. For indexes the app creates, it MUST show their kind (vector, full-text or value) and key settings: indexed expression or fields, and for vector indexes the dimensions, distance metric, centroids and encoding.

#### Scenario: Vector index
- **WHEN** the presenter opens the chunk vector index
- **THEN** it shows the chunks collection, the embedding expression, the embedding model's dimensions, cosine distance, 64 centroids and its encoding

### Requirement: SQL++ console
The explorer SHALL offer a query editor that runs a SQL++ query typed by the presenter or chosen from a set of starter queries (at least a keyword search, the chunks of one document, and ingest jobs by state). Results MUST show at most 200 rows, with values shortened as in the document view and a notice when more rows exist. The console MUST show the execution time and row count, and MUST show the query plan on request. A query that fails or uses a parameter MUST show the database error or a message that parameters are not supported, without leaving the explorer. A running query MUST be cancellable; after cancelling, the editor is usable again and the query's results are not shown.

#### Scenario: Starter query
- **WHEN** the presenter runs the keyword search starter query
- **THEN** matching chunks are listed with the row count and execution time, and the plan names the full-text index

#### Scenario: Capped results
- **WHEN** the presenter runs a query that matches more than 200 rows
- **THEN** 200 rows are shown with a notice that the results were cut off

#### Scenario: Invalid query
- **WHEN** the presenter runs a query with a syntax error
- **THEN** the database's error message is shown next to the editor

#### Scenario: Parameter
- **WHEN** the presenter runs a query that contains a `$name` parameter
- **THEN** the console says parameters are not supported and runs nothing

#### Scenario: Cancel
- **WHEN** the presenter cancels a running query
- **THEN** the editor is usable again and no results from that query appear

### Requirement: Presenter text size
The explorer SHALL use the X-ray panel's text size setting for its document JSON, query text and results.

#### Scenario: Larger text
- **WHEN** the presenter has increased the X-ray panel text size and opens a document in the explorer
- **THEN** the document JSON is shown at that larger size

### Requirement: Hideable sync attributes
The document view SHALL have a separately labeled Sync attributes section above the document JSON, initially collapsed for each newly opened document. The presenter MUST be able to expand and collapse it independently of body controls. Expanded attributes SHALL use highlighted, pretty-printed JSON and the same text size as the document body.

#### Scenario: Initial placement
- **WHEN** the presenter opens an existing document
- **THEN** the collapsed Sync attributes header appears above its JSON body
- **AND** the attribute values are hidden

#### Scenario: Hide after inspection
- **WHEN** the presenter expands Sync attributes and then collapses it
- **THEN** the attribute values disappear while its header remains above the body
- **AND** expanded vectors and blob previews keep their state

#### Scenario: Consistent rendering
- **WHEN** the presenter expands Sync attributes
- **THEN** loaded values appear as indented JSON with distinct colors for keys, strings, numbers, and literals, using the document body's text size

### Requirement: Local sync attribute values
Sync attributes SHALL show the selected document's ID, scope, collection, revision ID, local sequence, raw revision timestamp, and expiration from the local database. Missing revision ID and unset expiration MUST be represented as null. The values MUST remain separate from the stored document body and MUST NOT claim to indicate upload completion or server state.

#### Scenario: Stored revision
- **WHEN** the presenter expands Sync attributes on a saved document
- **THEN** the section shows that document's local identity and revision metadata
- **AND** the sequence and raw revision timestamp retain their exact integer values

#### Scenario: No expiration
- **WHEN** the selected document has no expiration
- **THEN** the attributes show expiration as null

#### Scenario: Device-local document
- **WHEN** the presenter expands Sync attributes on a chat or another device-local document
- **THEN** its local revision metadata is available even though the document is not replicated

### Requirement: Automatic local attribute loading
Sync attributes SHALL load automatically on first expansion without a Fetch action. Inspection MUST work offline and with sync disabled, without network requests, database writes, or X-ray events. Loaded values SHALL be retained across collapse and expansion within the same document view, without polling. A newly opened document view MUST load its own attributes.

#### Scenario: First expansion offline
- **WHEN** the presenter expands Sync attributes while offline with sync disabled
- **THEN** the attributes load automatically from local storage
- **AND** no network request, database change, or X-ray event occurs

#### Scenario: Reopen section
- **WHEN** the presenter collapses a successfully loaded section and expands it again in the same document view
- **THEN** the previously loaded attributes are shown without another read

#### Scenario: Different document
- **WHEN** the presenter follows a reference to another document and expands Sync attributes there
- **THEN** the section loads metadata for that document and never displays the previous document's values

### Requirement: Attribute loading failures
Loading, missing-document, and error states SHALL appear within the Sync attributes section while leaving the already displayed body usable. Failed reads MUST offer Retry. Navigating away MUST prevent a late result from appearing in another document's view.

#### Scenario: Reading attributes
- **WHEN** the presenter first expands Sync attributes and the read is still running
- **THEN** the section shows a loading indicator and the document JSON remains usable

#### Scenario: Read fails
- **WHEN** loading attributes fails
- **THEN** the section shows an error and Retry action
- **AND** Retry reads the attributes again without requiring the document view to reopen

#### Scenario: Document deleted after body load
- **WHEN** the body was loaded but the document is deleted before the attribute read
- **THEN** the section says the local document no longer exists
- **AND** the already displayed body remains usable

#### Scenario: Late result
- **WHEN** an attribute read completes after the presenter navigates to another document
- **THEN** it does not change the other document's section

### Requirement: Copy sync attributes separately
The expanded, successfully loaded section SHALL offer Copy Sync Attributes, which copies only the displayed metadata as valid JSON. Copy JSON on the document body MUST continue to copy only the body's JSON.

#### Scenario: Copy attributes
- **WHEN** the presenter chooses Copy Sync Attributes after loading
- **THEN** the clipboard contains the metadata JSON without document body fields

#### Scenario: Copy body
- **WHEN** the presenter chooses the document body's Copy JSON after inspecting attributes
- **THEN** the clipboard contains the body JSON without added metadata fields
