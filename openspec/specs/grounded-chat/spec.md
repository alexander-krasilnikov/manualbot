# grounded-chat Specification

## Purpose
Answers the user's questions in a chat interface using only chunks from their own documents, with verifiable citations that open the original source.

## Requirements

### Requirement: Strictly grounded answers
Answers SHALL be generated only from the chunks retrieved for the question. The app MUST NOT present general-knowledge content that is not supported by the retrieved chunks.

#### Scenario: Answer from documents
- **WHEN** the user asks a question that a document answers
- **THEN** the answer states that information and cites the chunk it came from

#### Scenario: Model has no supporting chunk
- **WHEN** the language model indicates that the chunks do not answer the question
- **THEN** the app shows the not-found response instead of a generated answer

### Requirement: Not-found response
When retrieval reports "not relevant", or generation reports that the question cannot be answered from the chunks, the app SHALL reply that the answer was not found in the user's documents and SHALL list the closest chunks as tappable suggestions. When retrieval reports "not relevant", the app MUST NOT invoke the language model.

#### Scenario: Off-topic question
- **WHEN** the user asks about something none of the documents cover
- **THEN** the app promptly replies "not found in your documents" and shows up to three closest chunks

### Requirement: Citations
Every factual statement in an answer SHALL be followed by a citation marker referring to a retrieved chunk. Each marker MUST show the document title and page (or section), and the answer MUST list its sources. Markers that do not refer to a chunk supplied for that answer MUST be removed before display. An answer left with no valid citations MUST be replaced by the not-found response.

#### Scenario: Valid citations
- **WHEN** an answer is displayed
- **THEN** every citation marker resolves to a chunk that was retrieved for that question

#### Scenario: Invented citation
- **WHEN** the model outputs a citation number that was not in the supplied chunks
- **THEN** that marker is not shown

### Requirement: Citation navigation
Tapping a citation SHALL open the source viewer on the cited document at the cited page or section, with the cited chunk highlighted. Tapping a citation of an image, or an image match, MUST show that image: an imported photo opens in an image view, and a photo inside a document opens the document at the image's page or section. For a deleted document, the app MUST show the stored chunk text and indicate that the document was deleted.

#### Scenario: Open PDF citation
- **WHEN** the user taps a citation to page 42 of a PDF
- **THEN** the source viewer shows page 42 with the chunk highlighted

#### Scenario: Open DOCX citation
- **WHEN** the user taps a citation to a DOCX document
- **THEN** the source viewer shows the document's text scrolled to the cited chunk, highlighted

#### Scenario: Open imported photo
- **WHEN** the user taps a citation of an imported photo
- **THEN** the source viewer shows the photo, zoomable, with its title

#### Scenario: Open photo inside a manual
- **WHEN** the user taps an image match from page 14 of a PDF
- **THEN** the source viewer shows page 14

### Requirement: Follow-up questions
The app SHALL interpret a question in the context of the current chat, so that a follow-up such as "and on the older model?" retrieves chunks as if it had been asked on its own. The standalone query that was used MUST be viewable by the user.

#### Scenario: Pronoun follow-up
- **WHEN** the user asks "How do I reset the X200?" and then "What about the X100?"
- **THEN** the second question retrieves chunks about resetting the X100

### Requirement: Streaming responses
Generated answers SHALL stream into the chat as they are produced. The user MUST be able to stop generation. On a supported device, the first streamed text SHALL appear within 3 seconds of sending, when the question is answered from up to six chunks.

#### Scenario: Stop generation
- **WHEN** the user taps stop while an answer is streaming
- **THEN** generation stops, the partial answer is kept and marked as stopped, and its citations are validated

### Requirement: Chat persistence
Chats and their messages, including citations and pinned documents, SHALL be stored on the device and restored after relaunch. Users MUST be able to create, rename, and delete chats.

#### Scenario: Relaunch
- **WHEN** the user relaunches the app
- **THEN** earlier chats appear with their messages, and their citations still work

### Requirement: Document pinning
Within a chat, the user SHALL be able to pin one or more ready documents to narrow the search scope, and to clear the pins to go back to the whole library. The current scope MUST always be visible in the chat.

#### Scenario: Pin documents
- **WHEN** the user pins Manual A in a chat
- **THEN** the chat shows a "Manual A" scope chip, and later answers cite only Manual A

### Requirement: Chat availability
Chat input SHALL be disabled, with an explanation, while the language model is not installed or while the library has no ready documents.

#### Scenario: Empty library
- **WHEN** no documents are ready
- **THEN** the chat input is disabled and the user is prompted to import a document

### Requirement: iPad layout
The app SHALL present a three-column layout (library, chat, source viewer) in landscape, and SHALL adapt to narrower sizes such as portrait, Split View, and Stage Manager windows by collapsing columns without losing any function.

#### Scenario: Split View
- **WHEN** the app runs in a narrow Split View window
- **THEN** the library, chat, and source viewer are still reachable, and tapping a citation still opens the source

### Requirement: Photo questions
The chat SHALL let the user attach one photo to a question, either taken with the camera or picked from the photo library, with or without typed text. The photo MUST be analyzed on the device and MUST NOT be sent to the language model. Text recognized in the photo SHALL be used as query text, alongside any typed question. The attached photo MUST be stored with the question and shown in the chat. When the photo has no typed question, the app SHALL reply with the matching images and their chunks, without invoking the language model; when nothing matches, it SHALL give the not-found response.

#### Scenario: Nameplate with a question
- **WHEN** the user photographs a nameplate reading "MODEL X200-B" and asks "how do I descale it?"
- **THEN** the answer is about descaling the X200 and cites chunks from the X200 manual

#### Scenario: Photo only
- **WHEN** the user sends a photo of a unit without typing anything and a manual contains a similar photo
- **THEN** the reply lists that photo with its document and page, and the chunks from that page, and no answer is generated

#### Scenario: Photo with no match
- **WHEN** the user sends a photo that matches no library image and contains no recognizable text
- **THEN** the app replies with the not-found response

#### Scenario: Camera unavailable
- **WHEN** camera access has been denied
- **THEN** the user can still pick a photo from the library, and the app explains how to allow camera access

### Requirement: Images in answers
An answer SHALL show, beside its sources, a thumbnail for each image stored on a cited page or section and for each cited image chunk. Image matches shown in a reply MUST keep showing their document title and page after the document is deleted, marked as deleted, without the thumbnail.

#### Scenario: Cited page with a photo
- **WHEN** an answer cites page 14 of a manual and page 14 holds a photo
- **THEN** the answer's sources show that photo's thumbnail

#### Scenario: Deleted document
- **WHEN** a reply listed an image match from a document that has since been deleted
- **THEN** the match shows the document title and page, marked as deleted

### Requirement: Answer quality baseline
The project SHALL maintain an answer evaluation over the retrieval evaluation set, run with the installed language model on the real retrieval stack. For answerable questions it MUST report how often the answer states the expected fact, how often it cites a chunk that contains it, and how often it is wrongly refused; for unanswerable questions, how often an answer is generated at all; and the time to first text and generation speed. A language model MUST NOT replace the current one unless it meets pass criteria recorded in the project before the evaluation of the candidate is run.

#### Scenario: Comparing language models
- **WHEN** the answer evaluation is run with the current and a candidate language model
- **THEN** it reports the same measures for both, and the candidate is adopted only if it meets the recorded pass criteria

#### Scenario: Criteria fixed in advance
- **WHEN** a candidate model is evaluated
- **THEN** the pass criteria it is judged against were recorded before its evaluation was first run
