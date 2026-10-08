# Spec Delta

## MODIFIED Requirements

### Requirement: Document view
Selecting a document SHALL show it as stored, as pretty-printed JSON with keys, strings, numbers and literals in distinct colors, using the X-ray document inspection's shortening: vectors shortened to a few leading values and their length, blobs shown as content type, size and digest. The presenter MUST be able to show any shortened vector in full. Image blobs MUST offer a preview of the image and text blobs a preview of their text, next to the blob's attributes; other blobs show only their summary. If the document no longer exists, the view MUST say so.

#### Scenario: Chunk
- **WHEN** the presenter opens a chunk
- **THEN** it shows the text, page, generation, embedding model and a shortened embedding with its length

#### Scenario: Highlighted JSON
- **WHEN** the presenter opens any document
- **THEN** it is shown as indented JSON in which keys, string values and numbers are colored differently

#### Scenario: Full vector
- **WHEN** the presenter asks to show the embedding in full
- **THEN** all of its values are shown

#### Scenario: Image preview
- **WHEN** the presenter opens an image record and asks for its blob preview
- **THEN** the stored image is shown next to the blob's attributes

#### Scenario: Deleted while browsing
- **WHEN** the presenter selects a document that was deleted after the list was loaded
- **THEN** the view says the document no longer exists
