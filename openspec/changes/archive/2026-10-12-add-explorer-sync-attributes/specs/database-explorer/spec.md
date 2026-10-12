# Spec Delta

## ADDED Requirements

### Requirement: Hideable sync attributes
The document view SHALL have a separately labeled Sync attributes section above the document JSON, initially collapsed for each newly opened document. The presenter MUST be able to expand and collapse it independently of body controls. Expanded attributes SHALL use highlighted, pretty-printed JSON and the same text size as the document body.

#### Scenario: Initial placement
- **WHEN** the presenter opens an existing document
- **THEN** the collapsed Sync attributes header appears above its JSON body
- **AND** the attribute values are hidden

#### Scenario: Hide after inspection
- **WHEN** the presenter expands Sync attributes and then collapses it
- **THEN** the attribute values disappear while its header remains above the body
- **AND** expanded vectors and blob previews keep their state

#### Scenario: Consistent rendering
- **WHEN** the presenter expands Sync attributes
- **THEN** loaded values appear as indented JSON with distinct colors for keys, strings, numbers, and literals, using the document body's text size

### Requirement: Local sync attribute values
Sync attributes SHALL show the selected document's ID, scope, collection, revision ID, local sequence, raw revision timestamp, and expiration from the local database. Missing revision ID and unset expiration MUST be represented as null. The values MUST remain separate from the stored document body and MUST NOT claim to indicate upload completion or server state.

#### Scenario: Stored revision
- **WHEN** the presenter expands Sync attributes on a saved document
- **THEN** the section shows that document's local identity and revision metadata
- **AND** the sequence and raw revision timestamp retain their exact integer values

#### Scenario: No expiration
- **WHEN** the selected document has no expiration
- **THEN** the attributes show expiration as null

#### Scenario: Device-local document
- **WHEN** the presenter expands Sync attributes on a chat or another device-local document
- **THEN** its local revision metadata is available even though the document is not replicated

### Requirement: Automatic local attribute loading
Sync attributes SHALL load automatically on first expansion without a Fetch action. Inspection MUST work offline and with sync disabled, without network requests, database writes, or X-ray events. Loaded values SHALL be retained across collapse and expansion within the same document view, without polling. A newly opened document view MUST load its own attributes.

#### Scenario: First expansion offline
- **WHEN** the presenter expands Sync attributes while offline with sync disabled
- **THEN** the attributes load automatically from local storage
- **AND** no network request, database change, or X-ray event occurs

#### Scenario: Reopen section
- **WHEN** the presenter collapses a successfully loaded section and expands it again in the same document view
- **THEN** the previously loaded attributes are shown without another read

#### Scenario: Different document
- **WHEN** the presenter follows a reference to another document and expands Sync attributes there
- **THEN** the section loads metadata for that document and never displays the previous document's values

### Requirement: Attribute loading failures
Loading, missing-document, and error states SHALL appear within the Sync attributes section while leaving the already displayed body usable. Failed reads MUST offer Retry. Navigating away MUST prevent a late result from appearing in another document's view.

#### Scenario: Reading attributes
- **WHEN** the presenter first expands Sync attributes and the read is still running
- **THEN** the section shows a loading indicator and the document JSON remains usable

#### Scenario: Read fails
- **WHEN** loading attributes fails
- **THEN** the section shows an error and Retry action
- **AND** Retry reads the attributes again without requiring the document view to reopen

#### Scenario: Document deleted after body load
- **WHEN** the body was loaded but the document is deleted before the attribute read
- **THEN** the section says the local document no longer exists
- **AND** the already displayed body remains usable

#### Scenario: Late result
- **WHEN** an attribute read completes after the presenter navigates to another document
- **THEN** it does not change the other document's section

### Requirement: Copy sync attributes separately
The expanded, successfully loaded section SHALL offer Copy Sync Attributes, which copies only the displayed metadata as valid JSON. Copy JSON on the document body MUST continue to copy only the body's JSON.

#### Scenario: Copy attributes
- **WHEN** the presenter chooses Copy Sync Attributes after loading
- **THEN** the clipboard contains the metadata JSON without document body fields

#### Scenario: Copy body
- **WHEN** the presenter chooses the document body's Copy JSON after inspecting attributes
- **THEN** the clipboard contains the body JSON without added metadata fields
