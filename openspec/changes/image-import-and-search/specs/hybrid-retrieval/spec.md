# Spec Delta

## MODIFIED Requirements

### Requirement: Result fusion
Vector and keyword results SHALL be merged into a single ranked list with no duplicate passages, and cut to a bounded number of passages for answering. When the question includes a photo, the passages of the pages or sections holding the matching images, together with those images' own passages, SHALL be merged as a third ranked list, ordered by image match.

#### Scenario: Passage found by both
- **WHEN** the same passage is returned by both vector and keyword search
- **THEN** it appears once in the merged results and ranks higher than a passage found by only one of them with comparable ranks

#### Scenario: Passage reached through a photo
- **WHEN** the user's photo matches a photo on page 14 of a manual and the typed question is also answered on page 14
- **THEN** the page 14 passage appears once in the merged results and ranks above passages found by only one search

### Requirement: Relevance gate
Retrieval SHALL report whether the best result meets a configurable relevance threshold. A result MUST also be relevant when the question's photo has an image match within the image distance threshold. When no result meets either, the outcome MUST be "not relevant", and it MUST still include the closest passages so they can be shown as suggestions.

#### Scenario: Off-topic question
- **WHEN** the user asks about something none of the documents cover
- **THEN** retrieval reports "not relevant" along with the closest few passages

#### Scenario: Passed on a photo match
- **WHEN** the typed question's passages are beyond the text threshold but the photo closely matches a library image
- **THEN** retrieval reports relevant, passed on the image match
