# Spec Delta

## ADDED Requirements

### Requirement: Original size limit
The app SHALL refuse to import a file larger than 20 MB, whether or not sync is on, so that every document it stores
can be shared. The refusal MUST name the file, its size and the limit, and MUST NOT stop the other files of the same
import.

#### Scenario: Large PDF
- **WHEN** the user imports a 34 MB PDF together with a 2 MB DOCX
- **THEN** the PDF is not imported and the app says it is 34 MB, over the 20 MB limit, and the DOCX is imported

#### Scenario: At the limit
- **WHEN** the user imports a file of exactly 20 MB
- **THEN** it is imported

## MODIFIED Requirements

### Requirement: Deletion
Deleting a document SHALL remove the document record, its stored original file, and all of its chunks, images and vectors in one operation. Citations to it in existing chats MUST remain visible as text, marked as belonging to a deleted document. When sync is on, the delete confirmation MUST say that the document will be removed from every device that shares the library.

#### Scenario: Delete document
- **WHEN** the user deletes a document
- **THEN** it disappears from the library, none of its chunks or images are returned by search, and earlier citations to it show as "document deleted"

#### Scenario: Delete with sync on
- **WHEN** the user chooses to delete a document while sync is on
- **THEN** the confirmation says it will be removed from every device, and nothing is deleted unless the user confirms
