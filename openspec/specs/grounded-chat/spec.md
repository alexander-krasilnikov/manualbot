# grounded-chat Specification

## Purpose
Answers the user's questions in a chat interface using only passages from their own documents, with verifiable citations that open the original source.

## Requirements

### Requirement: Strictly grounded answers
Answers SHALL be generated only from the passages retrieved for the question. The app MUST NOT present general-knowledge content that is not supported by the retrieved passages.

#### Scenario: Answer from documents
- **WHEN** the user asks a question that a document answers
- **THEN** the answer states that information and cites the passage it came from

#### Scenario: Model has no supporting passage
- **WHEN** the language model indicates that the passages do not answer the question
- **THEN** the app shows the not-found response instead of a generated answer

### Requirement: Not-found response
When retrieval reports "not relevant", or generation reports that the question cannot be answered from the passages, the app SHALL reply that the answer was not found in the user's documents and SHALL list the closest passages as tappable suggestions. When retrieval reports "not relevant", the app MUST NOT invoke the language model.

#### Scenario: Off-topic question
- **WHEN** the user asks about something none of the documents cover
- **THEN** the app promptly replies "not found in your documents" and shows up to three closest passages

### Requirement: Citations
Every factual statement in an answer SHALL be followed by a citation marker referring to a retrieved passage. Each marker MUST show the document title and page (or section), and the answer MUST list its sources. Markers that do not refer to a passage supplied for that answer MUST be removed before display. An answer left with no valid citations MUST be replaced by the not-found response.

#### Scenario: Valid citations
- **WHEN** an answer is displayed
- **THEN** every citation marker resolves to a passage that was retrieved for that question

#### Scenario: Invented citation
- **WHEN** the model outputs a citation number that was not in the supplied passages
- **THEN** that marker is not shown

### Requirement: Citation navigation
Tapping a citation SHALL open the source viewer on the cited document at the cited page or section, with the cited passage highlighted. For a deleted document, the app MUST show the stored passage text and indicate that the document was deleted.

#### Scenario: Open PDF citation
- **WHEN** the user taps a citation to page 42 of a PDF
- **THEN** the source viewer shows page 42 with the passage highlighted

#### Scenario: Open DOCX citation
- **WHEN** the user taps a citation to a DOCX document
- **THEN** the source viewer shows the document's text scrolled to the cited passage, highlighted

### Requirement: Follow-up questions
The app SHALL interpret a question in the context of the current chat, so that a follow-up such as "and on the older model?" retrieves passages as if it had been asked on its own. The standalone query that was used MUST be viewable by the user.

#### Scenario: Pronoun follow-up
- **WHEN** the user asks "How do I reset the X200?" and then "What about the X100?"
- **THEN** the second question retrieves passages about resetting the X100

### Requirement: Streaming responses
Generated answers SHALL stream into the chat as they are produced. The user MUST be able to stop generation. On a supported device, the first streamed text SHALL appear within 3 seconds of sending, when the question is answered from up to six passages.

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
