# Spec Delta

## Purpose

Turns user-imported text, PDF, and DOCX files into searchable, citable passages stored on the device, and lets the user manage that library.

## ADDED Requirements

### Requirement: Supported import sources
The app SHALL let users import files from the Files app document picker, from the share sheet, and by drag and drop onto the library. It SHALL accept plain text (`.txt`, `.md`), PDF (`.pdf`), and Word (`.docx`) files, and several files at once. Any other file type MUST be rejected with a message naming the file and the reason.

#### Scenario: Multi-file import
- **WHEN** the user selects three PDFs and one DOCX in the document picker
- **THEN** all four appear in the library with status "queued"

#### Scenario: Unsupported type
- **WHEN** the user drops a `.pptx` file onto the library
- **THEN** the file is not imported and the app shows that the type is not supported

### Requirement: Original file retention
The app SHALL store a copy of each imported original file with its document record, so it can be displayed in the source viewer and re-indexed without the user importing it again.

#### Scenario: Source removed after import
- **WHEN** the user deletes the original file from the Files app after importing it
- **THEN** the document still opens in the source viewer and can still be re-indexed

### Requirement: Text extraction
The app SHALL extract text with location metadata: page numbers for PDF, and headings and paragraph order for DOCX and Markdown. Plain text MUST be decoded as UTF-8, falling back to other detected encodings. For DOCX, body paragraphs, headings, list items, and table cell text MUST be extracted in reading order.

#### Scenario: PDF page provenance
- **WHEN** a text-based PDF is indexed
- **THEN** every stored passage records the page number it came from

#### Scenario: DOCX tables
- **WHEN** a DOCX containing a table is indexed
- **THEN** the table cell text is searchable

### Requirement: On-device OCR for scanned pages
For PDF pages with no extractable text layer, the app SHALL recognize text using on-device OCR and treat the result like extracted text for that page.

#### Scenario: Scanned manual
- **WHEN** the user imports a PDF made of scanned page images
- **THEN** the document becomes searchable and passages cite the correct page numbers

### Requirement: Chunking with provenance
Extracted text SHALL be split into overlapping passages of bounded size. Each passage MUST record its document, its position in the document, its page (where applicable), and its nearest heading (where available). Passages MUST NOT span PDF page boundaries.

#### Scenario: Passage metadata
- **WHEN** a document finishes indexing
- **THEN** each passage has a document reference, an ordinal, and a page or heading reference

### Requirement: Embedding with model identity
Each passage SHALL be embedded with the installed embedding model, and the stored vector MUST record the identifier and version of the embedding model and its vector dimension.

#### Scenario: Model recorded on chunks
- **WHEN** a passage is stored
- **THEN** it includes its vector, the embedding model identifier and version, and the dimension

### Requirement: Background ingestion with status
Ingestion SHALL run without blocking the UI, SHALL process documents from a persistent queue, and SHALL show each document's status: queued, extracting, recognizing text, embedding (with progress), ready, or failed (with a reason). Ingestion that is interrupted by app suspension or termination MUST resume on the next launch without duplicating passages.

#### Scenario: Progress visible
- **WHEN** a 300-page PDF is being indexed
- **THEN** the library shows its status and embedding progress while the user keeps using the app

#### Scenario: App killed mid-ingestion
- **WHEN** the app is terminated while a document is embedding and is later relaunched
- **THEN** ingestion of that document resumes and the document ends with exactly one set of passages

#### Scenario: Unreadable file
- **WHEN** a PDF is password-protected or corrupt
- **THEN** the document shows status "failed" with a readable reason, and other queued documents keep processing

### Requirement: Search availability during ingestion
Only documents with status "ready" SHALL be included in retrieval. A document's passages MUST become searchable together, never partially.

#### Scenario: Partially embedded document
- **WHEN** the user asks a question while a document is still embedding
- **THEN** no passages from that document are used to answer

### Requirement: Re-indexing
The user SHALL be able to re-index a document. Re-indexing MUST produce a new, complete set of passages and remove the previous set only after the new set is ready, so the document stays searchable throughout.

#### Scenario: Re-index keeps document available
- **WHEN** the user re-indexes a ready document
- **THEN** questions keep being answered from the previous passages until the new ones are ready, and afterwards only the new passages exist

### Requirement: Deletion
Deleting a document SHALL remove the document record, its stored original file, and all of its passages and vectors in one operation. Citations to it in existing chats MUST remain visible as text, marked as belonging to a deleted document.

#### Scenario: Delete document
- **WHEN** the user deletes a document
- **THEN** it disappears from the library, none of its passages are returned by search, and earlier citations to it show as "document deleted"

### Requirement: Library view
The library SHALL list every document with its title, type, page count (for PDF), import date, and ingestion status, and SHALL let the user rename documents.

#### Scenario: Rename
- **WHEN** the user renames a document
- **THEN** the new title appears in the library and in future citations
