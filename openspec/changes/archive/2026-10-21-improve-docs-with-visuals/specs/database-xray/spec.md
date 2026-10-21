## MODIFIED Requirements

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
- **WHEN** the presenter sends a photo with a question
- **THEN** the group shows the photo analysis with the recognized text, the text searches, the image search query over the image index with its row funnel, and fusion with three lists

### Requirement: Reset demo
The X-ray panel SHALL offer a reset action that, after a confirmation naming what will be deleted, deletes every document and chat and imports a fixed set of bundled sample documents: the Couchbase whitepapers *Couchbase Under the Hood* and *Capella Architecture Overview*, as PDFs, at least one of which contains a photo. The chat SHALL offer a sample photo that matches a photo in the sample documents. The reset MUST be traced as its own operation. Cancelling the confirmation MUST change nothing. When sync is on, the confirmation MUST say that the documents are deleted from every device that shares the library.

#### Scenario: Reset
- **WHEN** the presenter confirms reset
- **THEN** the library contains only the two sample PDFs, which become ready, the chat list is empty, and the X-ray log shows the deletions and the imports

#### Scenario: Sample photo finds its page
- **WHEN** after a reset the presenter sends the sample photo alone
- **THEN** the first photo the reply lists is the debugger figure of *Couchbase Under the Hood*, page 28, with its document and page

#### Scenario: Reset with sync on
- **WHEN** the presenter chooses reset while sync is on
- **THEN** the confirmation says the documents are deleted from every device, and after confirming, every syncing iPad's library contains only the sample documents

#### Scenario: Cancel reset
- **WHEN** the presenter cancels the reset confirmation
- **THEN** the library and chats are unchanged
