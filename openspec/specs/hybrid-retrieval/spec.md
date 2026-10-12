# hybrid-retrieval Specification

## Purpose
Finds the chunks most relevant to a question by combining semantic vector search with exact keyword search over the local library, and decides whether anything found is relevant enough to answer from.

## Requirements

### Requirement: Semantic vector search
Retrieval SHALL embed the query with the same embedding model used for chunks and photos and return the nearest chunks by vector similarity. Chunks whose recorded embedding model or dimension differs from the installed embedding model MUST be excluded.

#### Scenario: Paraphrased question
- **WHEN** the user asks "how do I restore factory settings" and a manual says "to reset the unit to defaults, hold..."
- **THEN** that chunk is among the retrieved results

#### Scenario: Mismatched embedding model
- **WHEN** a chunk was embedded with a different model version than the one installed
- **THEN** that chunk is not returned by vector search

### Requirement: Keyword search
Retrieval SHALL also run a full-text search over chunk text, so that exact tokens such as error codes, part numbers, and model names are found even when vector similarity is weak.

#### Scenario: Exact error code
- **WHEN** the user asks "what does E-042 mean" and exactly one chunk contains "E-042"
- **THEN** that chunk is among the retrieved results

### Requirement: Result fusion
Vector and keyword results SHALL be merged into a single ranked list with no duplicate chunks, and cut to a bounded number of chunks for answering. When the question includes a photo, the chunks of the pages or sections holding the matching images, together with those images' own chunks, SHALL be merged as a further ranked list, ordered by image match. When typed words match library photos by meaning within the text-to-photo threshold, the chunks of those photos' pages or sections SHALL be merged as a further ranked list in the same way.

#### Scenario: Chunk found by both
- **WHEN** the same chunk is returned by both vector and keyword search
- **THEN** it appears once in the merged results and ranks higher than a chunk found by only one of them with comparable ranks

#### Scenario: Chunk reached through a photo
- **WHEN** the user's photo matches a photo on page 14 of a manual and the typed question is also answered on page 14
- **THEN** the page 14 chunk appears once in the merged results and ranks above chunks found by only one search

#### Scenario: Chunk reached through words that describe a photo
- **WHEN** the user asks "where is the drain plug" and an uncaptioned photo of the drain plug on page 9 matches those words by meaning
- **THEN** the chunks of page 9 are among the merged results

### Requirement: Document scope
By default, retrieval SHALL search all ready documents in the library. When a chat has pinned documents, retrieval MUST return only chunks from those documents.

#### Scenario: Whole library
- **WHEN** a chat has no pinned documents
- **THEN** results may come from any ready document

#### Scenario: Pinned scope
- **WHEN** a chat has Manual A and Manual B pinned
- **THEN** every retrieved chunk belongs to Manual A or Manual B

### Requirement: Relevance gate
Retrieval SHALL report whether the best result meets a configurable relevance threshold. A result MUST also be relevant when the question's photo has an image match within the image distance threshold. A match between typed words and a photo MUST NOT on its own make a question relevant. When no result meets either threshold, the outcome MUST be "not relevant", and it MUST still include the closest chunks so they can be shown as suggestions.

#### Scenario: Off-topic question
- **WHEN** the user asks about something none of the documents cover
- **THEN** retrieval reports "not relevant" along with the closest few chunks

#### Scenario: Passed on a photo match
- **WHEN** the typed question's chunks are beyond the text threshold but the photo closely matches a library image
- **THEN** retrieval reports relevant, passed on the image match

#### Scenario: Words that only resemble a photo
- **WHEN** a typed question's chunks are all beyond the text threshold and its words match a library photo by meaning
- **THEN** retrieval reports "not relevant"

### Requirement: Retrieval latency
On a supported device with a library of up to 20,000 chunks, retrieval (query embedding, both searches, and fusion) SHALL complete within 500 ms at the 95th percentile, excluding one-time vector index training.

#### Scenario: Large library
- **WHEN** the library holds 20,000 chunks and the user asks a question
- **THEN** retrieval results are available within 500 ms

### Requirement: Retrieval quality baseline
The project SHALL maintain an evaluation set of questions with their expected source chunks over sample documents. With the installed embedding model, retrieval MUST return the expected chunk in the top results for at least 85% of the set, and the relevance threshold MUST be tuned against it whenever the embedding model changes.

#### Scenario: Evaluation run
- **WHEN** the retrieval evaluation is run against the sample documents with the installed embedding model
- **THEN** it reports recall in the top results and that recall is at least 85%
