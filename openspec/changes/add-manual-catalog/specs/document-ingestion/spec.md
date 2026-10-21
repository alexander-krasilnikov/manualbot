# Spec Delta

## MODIFIED Requirements

### Requirement: Supported import sources
The app SHALL let users import files from the Files app document picker, from the share sheet, by drag and drop onto the library, and from the manual catalog. It SHALL accept plain text (`.txt`, `.md`), PDF (`.pdf`), Word (`.docx`) and photo (`.jpg`, `.jpeg`, `.png`, `.heic`, `.heif`) files, and several files at once. Any other file type MUST be rejected with a message naming the file and the reason.

#### Scenario: Multi-file import
- **WHEN** the user selects three PDFs and one DOCX in the document picker
- **THEN** all four appear in the library with status "queued"

#### Scenario: Photo import
- **WHEN** the user drops a `.heic` photo onto the library
- **THEN** it appears in the library as a photo document with status "queued"

#### Scenario: Unsupported type
- **WHEN** the user drops a `.pptx` file onto the library
- **THEN** the file is not imported and the app shows that the type is not supported

#### Scenario: Catalog import
- **WHEN** the user imports an entry from the manual catalog
- **THEN** the downloaded PDF is queued like a PDF picked in the Files app, and the original is kept with the document record

## ADDED Requirements

### Requirement: Document origin
A document imported from the manual catalog SHALL record its catalog entry and the address it was downloaded from. The library MUST show the publisher host for such a document, and the origin MUST survive re-indexing and sync.

#### Scenario: Origin shown
- **WHEN** the user opens the details of a document imported from the catalog
- **THEN** the library shows the publisher host it came from

#### Scenario: Origin kept on another iPad
- **WHEN** sync is on and a catalog document reaches a second iPad
- **THEN** that iPad shows the same origin and does not download the file again
