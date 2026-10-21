# Spec Delta

## MODIFIED Requirements

### Requirement: Strictly grounded answers
Answers SHALL be generated only from the chunks retrieved for the question. The app MUST NOT present general-knowledge content that is not supported by the retrieved chunks, except as a reply that is labelled as not from the user's documents under the Conversational or Open answer style.

#### Scenario: Answer from documents
- **WHEN** the user asks a question that a document answers
- **THEN** the answer states that information and cites the chunk it came from

#### Scenario: Model has no supporting chunk
- **WHEN** the language model indicates that the chunks do not answer the question, and the answer style is Strict or Balanced
- **THEN** the app shows the not-found response instead of a generated answer

### Requirement: Not-found response
Under the Strict and Balanced answer styles, when retrieval reports "not relevant", or generation reports that the question cannot be answered from the chunks, the app SHALL reply that the answer was not found in the user's documents and SHALL list the closest chunks as tappable suggestions. When retrieval reports "not relevant" under these styles, the app MUST NOT invoke the language model.

#### Scenario: Off-topic question
- **WHEN** the user asks about something none of the documents cover, and the answer style is Strict or Balanced
- **THEN** the app promptly replies "not found in your documents" and shows up to three closest chunks

## ADDED Requirements

### Requirement: Answer style setting
Settings SHALL offer one slider that sets the answer style. Along it are four named stops, in order: Strict, Balanced, Conversational, Open. The slider position is a relevance distance in steps of 0.01, and the page MUST show the current stop's name, the exact distance and a hint explaining what that position does. The distance MUST be the cutoff for typed questions. The setting MUST persist across launches, and the default MUST be Balanced at the embedding model's tuned distance.

#### Scenario: Default unchanged
- **WHEN** the user has never moved the slider
- **THEN** the style is Balanced at the tuned distance (0.28 for EmbeddingGemma 2), and answers behave as they did before the setting existed

#### Scenario: Moving within a stop
- **WHEN** the user drags the slider from 0.28 to 0.30
- **THEN** the page still shows Balanced, now with distance 0.30, and a question whose best match is at 0.29 is answered from the documents

#### Scenario: Stricter cutoff
- **WHEN** the user sets the slider to Strict at 0.24 and asks a question whose best match is at 0.26
- **THEN** the app gives the not-found response without invoking the language model

#### Scenario: Hint follows the stop
- **WHEN** the user moves the slider into Conversational
- **THEN** the hint says that questions the documents don't answer get a short reply that isn't from the documents

#### Scenario: Remembered
- **WHEN** the user sets Open at 0.36 and relaunches the app
- **THEN** the page shows Open at 0.36 and questions are answered in that style

### Requirement: Replies not from the documents
Under the Conversational and Open answer styles, whenever Strict and Balanced would give the not-found response, the app SHALL instead ask the language model for a reply with no document text in its prompt. Such a reply MUST carry no citations and MUST be visibly labelled "Not from your documents", including after relaunch. Photo-only questions are unaffected.

#### Scenario: Uncited answer under Open
- **WHEN** the style is Open and the model's answer from the chunks cites no supplied chunk
- **THEN** that answer is discarded and the app shows the labelled reply instead

#### Scenario: Documents answer the question
- **WHEN** the style is Open and a document answers the question
- **THEN** the answer is generated from the chunks with citations and carries no label

#### Scenario: Label survives relaunch
- **WHEN** a chat holds a labelled reply and the app is relaunched
- **THEN** the reply is still labelled "Not from your documents"

### Requirement: Content of replies not from the documents
Under Conversational, a reply not from the documents MUST be brief and in the user's language, limited to what the app is, what it can do and how to rephrase, and MUST NOT state facts. Under Open, it MAY answer from general knowledge, and the closest chunks MUST still be listed as suggestions.

#### Scenario: Question about the assistant
- **WHEN** the style is Conversational and the user asks "Sprichst du italienisch?" with no relevant chunk
- **THEN** the app shows a short reply in German, labelled "Not from your documents", with no citations

#### Scenario: General-knowledge answer
- **WHEN** the style is Open and the user asks a question none of the documents cover
- **THEN** the app shows a generated answer labelled "Not from your documents", followed by up to three closest chunks as suggestions
