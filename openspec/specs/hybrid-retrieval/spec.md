# hybrid-retrieval Specification

## Purpose
Finds the passages most relevant to a question by combining semantic vector search with exact keyword search over the local library, and decides whether anything found is relevant enough to answer from.

## Requirements

### Requirement: Semantic vector search
Retrieval SHALL embed the query with the same embedding model used for passages and return the nearest passages by vector similarity. Passages whose recorded embedding model or dimension differs from the installed embedding model MUST be excluded.

#### Scenario: Paraphrased question
- **WHEN** the user asks "how do I restore factory settings" and a manual says "to reset the unit to defaults, hold..."
- **THEN** that passage is among the retrieved results

#### Scenario: Mismatched embedding model
- **WHEN** a passage was embedded with a different model version than the one installed
- **THEN** that passage is not returned by vector search

### Requirement: Keyword search
Retrieval SHALL also run a full-text search over passage text, so that exact tokens such as error codes, part numbers, and model names are found even when vector similarity is weak.

#### Scenario: Exact error code
- **WHEN** the user asks "what does E-042 mean" and exactly one passage contains "E-042"
- **THEN** that passage is among the retrieved results

### Requirement: Result fusion
Vector and keyword results SHALL be merged into a single ranked list with no duplicate passages, and cut to a bounded number of passages for answering.

#### Scenario: Passage found by both
- **WHEN** the same passage is returned by both vector and keyword search
- **THEN** it appears once in the merged results and ranks higher than a passage found by only one of them with comparable ranks

### Requirement: Document scope
By default, retrieval SHALL search all ready documents in the library. When a chat has pinned documents, retrieval MUST return only passages from those documents.

#### Scenario: Whole library
- **WHEN** a chat has no pinned documents
- **THEN** results may come from any ready document

#### Scenario: Pinned scope
- **WHEN** a chat has Manual A and Manual B pinned
- **THEN** every retrieved passage belongs to Manual A or Manual B

### Requirement: Relevance gate
Retrieval SHALL report whether the best result meets a configurable relevance threshold. When no result meets it, the outcome MUST be "not relevant", and it MUST still include the closest passages so they can be shown as suggestions.

#### Scenario: Off-topic question
- **WHEN** the user asks about something none of the documents cover
- **THEN** retrieval reports "not relevant" along with the closest few passages

### Requirement: Retrieval latency
On a supported device with a library of up to 20,000 passages, retrieval (query embedding, both searches, and fusion) SHALL complete within 500 ms at the 95th percentile, excluding one-time vector index training.

#### Scenario: Large library
- **WHEN** the library holds 20,000 passages and the user asks a question
- **THEN** retrieval results are available within 500 ms

### Requirement: Retrieval quality baseline
The project SHALL maintain an evaluation set of questions with their expected source passages over sample documents. Retrieval MUST return the expected passage in the top results for at least 85% of the set, and the relevance threshold MUST be tuned against it.

#### Scenario: Evaluation run
- **WHEN** the retrieval evaluation is run against the sample documents
- **THEN** it reports recall in the top results and that recall is at least 85%
