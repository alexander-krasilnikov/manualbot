# Spec Delta

## MODIFIED Requirements

### Requirement: Embedding with model identity
Each passage and each photo SHALL be embedded with the installed embedding model, into the same vector space, and the stored vector MUST record the identifier and version of the embedding model and its vector dimension.

#### Scenario: Model recorded on chunks
- **WHEN** a passage is stored
- **THEN** it includes its vector, the embedding model identifier and version, and the dimension

#### Scenario: Model recorded on photos
- **WHEN** a photo from a document or an imported photo is stored
- **THEN** its vector comes from the same embedding model as the passages and records the same model identifier, version and dimension

## ADDED Requirements

### Requirement: Re-index after an embedding model change
When the installed embedding model differs from the model recorded on a document's stored vectors, the app SHALL queue that document for re-indexing automatically, without user action. Until the new vectors are ready, the document MUST stay findable by keyword search and MUST NOT be returned by vector or photo search with vectors from the other model. The library MUST show that the document is being re-indexed.

#### Scenario: App updated to a new embedding model
- **WHEN** the app starts with a new embedding model installed and the library holds documents indexed with the previous model
- **THEN** every such document is queued for re-indexing, keyword search keeps finding them meanwhile, and each becomes fully searchable once its new vectors are ready

#### Scenario: Nothing to re-index
- **WHEN** every document's vectors already come from the installed embedding model
- **THEN** no re-indexing is queued at start-up
