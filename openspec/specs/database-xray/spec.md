# database-xray Specification

## Purpose
Lets a presenter show, live and inside the app, what Couchbase Lite and the retrieval pipeline do behind each user action, and why each step matters, without changing how the app behaves.

## Requirements

### Requirement: Demo mode
The app SHALL offer a demo mode, off by default, that can be turned on from within the app or with a launch argument. The setting MUST persist across launches. When demo mode is off, the app MUST show no X-ray controls, and import, search, chat and storage behavior MUST be identical to the app without this feature.

#### Scenario: Default install
- **WHEN** the app is launched for the first time without the launch argument
- **THEN** demo mode is off and no X-ray control is visible

#### Scenario: Turn on from the app
- **WHEN** the presenter turns demo mode on
- **THEN** the detail column shows a Source / X-ray switch, and demo mode is still on after relaunch

#### Scenario: Launch argument
- **WHEN** the app is launched with the demo mode launch argument
- **THEN** demo mode is on for that launch

#### Scenario: Same answers with demo mode on or off
- **WHEN** the same question is asked over the same library with demo mode on and with it off
- **THEN** the retrieved passages, answer and citations are the same

### Requirement: Detail column switch
In demo mode, the detail column SHALL switch between the source viewer and the X-ray panel. Tapping a citation or a library document MUST switch the column to Source and open it as before. Switching to X-ray MUST NOT close the open source.

#### Scenario: Citation tap while X-ray is showing
- **WHEN** X-ray is showing and the presenter taps a citation
- **THEN** the column switches to Source and shows the cited passage highlighted

#### Scenario: Return to X-ray
- **WHEN** the presenter switches from Source to X-ray and back
- **THEN** the same source is still open at the same position

### Requirement: Live operation log
While demo mode is on, the X-ray panel SHALL show events as they happen, grouped by the user operation that caused them: importing a document, asking a question, opening a source, re-indexing, deleting a document, and resetting the demo. Each group MUST show its title, start time and total duration, and each event its time and duration where measurable. Database activity not caused by a user operation (for example, refreshing the library list) MUST be grouped as background activity, hidden by default and shown on request. The most recent group MUST be expanded and earlier groups collapsed. The log MUST keep at least the last 50 groups. The presenter MUST be able to clear the log.

#### Scenario: Events appear while answering
- **WHEN** the presenter asks a question with X-ray showing
- **THEN** a new group titled with the question appears, expanded, and its events appear as each step completes

#### Scenario: Background activity hidden
- **WHEN** the library refreshes its list without a user action
- **THEN** no new visible group appears unless background activity is shown

#### Scenario: Clear
- **WHEN** the presenter clears the log
- **THEN** the panel is empty and new operations start appearing again

### Requirement: Import events
Importing a document SHALL produce, in order: the document record saved to the documents collection; the original file stored as a blob, with its size and content type; each ingestion job state change, marked as stored in a device-local collection that is never replicated; for each image kept, an image analysis event with the length of its recognized text, its caption source (nearby text, alt text, or none) and its feature vector dimension; each batch of images written in one transaction, with the number of images and the blob size; each batch of passages written in one transaction, with the number of passages, vector dimensions and duration; and the activation step that makes the new passages and images searchable and removes the superseded ones in one transaction, with the number of passages and images removed.

#### Scenario: First import
- **WHEN** the presenter imports a text document
- **THEN** the import group shows the document save, the blob with its size, the job states through ready, at least one passage batch, and an activation step that removes zero old passages

#### Scenario: Photo import
- **WHEN** the presenter imports a photo
- **THEN** the import group shows the image analysis, an image batch with its blob size, one passage batch, and the activation step

#### Scenario: Re-index
- **WHEN** the presenter re-indexes a ready document
- **THEN** the group shows a new generation number being written, and an activation step that removes the previous generation's passages and images in the same transaction

### Requirement: Question events
Asking a question SHALL produce events for: the photo analysis when a photo is attached (recognized text and feature vector dimension); the standalone query when a follow-up was rewritten (showing original and rewritten text); embedding the query (duration and vector dimensions); the vector search query; the keyword search query, or a note that the question had no keywords; the image search query when a photo is attached; rank fusion; the relevance decision; the language model's time to first token and total time, or a note that the model was not called; and the reply message saved to the messages collection.

#### Scenario: Answered question
- **WHEN** the presenter asks a question the documents answer
- **THEN** the group shows embedding, vector search, keyword search, fusion, a relevance decision that passes, model timing, and the saved reply

#### Scenario: Off-topic question
- **WHEN** the presenter asks a question no document covers
- **THEN** the relevance decision shows the best distance above the threshold, and the group says the language model was not called

#### Scenario: Follow-up
- **WHEN** the presenter asks a follow-up in the same chat
- **THEN** the group shows the original question and the standalone query used for search

#### Scenario: Photo question
- **WHEN** the presenter sends a nameplate photo with a question
- **THEN** the group shows the photo analysis with the recognized text, the text searches, the image search query over the image index with its row funnel, and fusion with three lists

### Requirement: Query details
Every SQL++ query event SHALL show the query text exactly as executed, its bound parameters, and its execution time. A vector parameter MUST be shown shortened (a few leading values and its length). The event MUST name the index the query plan uses, or state that it uses none, and the raw query plan MUST be available on request. Search queries MUST show a row funnel: rows returned by the index, rows that were visible (the active generation of a ready document within the chat's scope), and passages used after fusion. When the search had to widen its candidate window, each attempt MUST be shown.

#### Scenario: Vector search details
- **WHEN** the presenter opens a vector search event
- **THEN** it shows the SQL++ with the distance function, the shortened 768-value vector, the execution time, the vector index name, and the row funnel

#### Scenario: Raw plan
- **WHEN** the presenter asks for the plan of a query event
- **THEN** the raw query plan from the database is shown

#### Scenario: Scoped chat
- **WHEN** the chat is limited to pinned documents and the presenter opens its vector search event
- **THEN** the funnel shows fewer visible rows than returned rows

### Requirement: Fusion and relevance details
The fusion event SHALL list each fused passage with its document title, its position in the vector results, in the keyword results and in the image-matched results (or absent), its distance, and its fused score, and MUST name the fusion method and its constant. The relevance event MUST show the best distance, the threshold, the best image distance and image threshold when a photo was attached, and whether the result passed on distance, on an identifier from the question found verbatim in a top passage, on an image match, or not at all.

#### Scenario: Passage found by both searches
- **WHEN** a passage appears in both the vector and keyword results
- **THEN** the fusion event shows both of its positions

#### Scenario: Passed on identifier
- **WHEN** a question containing an error code passes relevance only because the code appears in a top passage
- **THEN** the relevance event says it passed on the identifier, naming it

#### Scenario: Passed on image
- **WHEN** a photo question passes relevance only because of a close image match
- **THEN** the relevance event shows the image distance and threshold and says it passed on the image match

### Requirement: Document inspection
Tapping a passage or document ID in an event SHALL show the stored JSON document from its collection, with field names and values as stored. Vector fields MUST be shortened as for parameters; blob fields MUST show their content type, size and digest, not their content. If the document no longer exists, the panel MUST say so.

#### Scenario: Inspect a passage
- **WHEN** the presenter taps a passage ID in a fusion event
- **THEN** the panel shows that passage's stored document, including its text, page, generation, embedding model and a shortened embedding

#### Scenario: Deleted since
- **WHEN** the presenter taps the ID of a passage whose document was deleted
- **THEN** the panel says the document no longer exists

### Requirement: Why it matters captions
The panel SHALL offer a captions toggle. With it on, each event kind MUST show one plain-language sentence stating the benefit it demonstrates (for example, vector and keyword search in one embedded engine, files stored with the data, atomic batches, local-only collections, offline operation). The vector search caption MUST explain that the index is queried unfiltered for speed and visibility is decided from the passage ID, presented as a design choice.

#### Scenario: Captions on
- **WHEN** the presenter turns captions on
- **THEN** every visible event shows its caption

#### Scenario: Captions off
- **WHEN** captions are off
- **THEN** events show only their technical details

### Requirement: Presenter aids
The panel SHALL offer: a text size control, independent of the system text size, that applies to the whole panel including query text; a slow-reveal mode that shows events that arrive together one at a time, at a steady pace, without slowing the operations themselves; and an indicator of whether the device currently has a network connection.

#### Scenario: Larger text
- **WHEN** the presenter increases the panel text size
- **THEN** event titles, details and SQL++ text grow, and the rest of the app is unchanged

#### Scenario: Slow reveal
- **WHEN** slow reveal is on and a question is answered
- **THEN** its events appear one after another at the set pace, and the answer in the chat is not delayed

#### Scenario: Airplane mode
- **WHEN** the presenter turns on airplane mode
- **THEN** the indicator shows offline, and importing and asking still work and are traced

### Requirement: Reset demo
In demo mode, the app SHALL offer a reset action that, after confirmation, deletes every document and chat and imports a fixed set of bundled sample documents, including at least one PDF, one photo, and one document that contains a photo. The reset MUST be traced as its own operation. Cancelling the confirmation MUST change nothing.

#### Scenario: Reset
- **WHEN** the presenter confirms reset
- **THEN** the library contains only the sample documents, which become ready, the chat list is empty, and the X-ray log shows the deletions and the imports

#### Scenario: Cancel reset
- **WHEN** the presenter cancels the reset confirmation
- **THEN** the library and chats are unchanged
