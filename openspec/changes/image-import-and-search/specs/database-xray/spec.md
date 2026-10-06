# Spec Delta

## MODIFIED Requirements

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

### Requirement: Reset demo
In demo mode, the app SHALL offer a reset action that, after confirmation, deletes every document and chat and imports a fixed set of bundled sample documents, including at least one PDF, one photo, and one document that contains a photo. The reset MUST be traced as its own operation. Cancelling the confirmation MUST change nothing.

#### Scenario: Reset
- **WHEN** the presenter confirms reset
- **THEN** the library contains only the sample documents, which become ready, the chat list is empty, and the X-ray log shows the deletions and the imports

#### Scenario: Cancel reset
- **WHEN** the presenter cancels the reset confirmation
- **THEN** the library and chats are unchanged
