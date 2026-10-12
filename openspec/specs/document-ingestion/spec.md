# document-ingestion Specification

## Purpose
Turns user-imported text, PDF, and DOCX files into searchable, citable chunks stored on the device, and lets the user manage that library.

## Requirements

### Requirement: Supported import sources
The app SHALL let users import files from the Files app document picker, from the share sheet, and by drag and drop onto the library. It SHALL accept plain text (`.txt`, `.md`), PDF (`.pdf`), Word (`.docx`) and photo (`.jpg`, `.jpeg`, `.png`, `.heic`, `.heif`) files, and several files at once. Any other file type MUST be rejected with a message naming the file and the reason.

#### Scenario: Multi-file import
- **WHEN** the user selects three PDFs and one DOCX in the document picker
- **THEN** all four appear in the library with status "queued"

#### Scenario: Photo import
- **WHEN** the user drops a `.heic` photo onto the library
- **THEN** it appears in the library as a photo document with status "queued"

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
- **THEN** every stored chunk records the page number it came from

#### Scenario: DOCX tables
- **WHEN** a DOCX containing a table is indexed
- **THEN** the table cell text is searchable

### Requirement: On-device OCR for scanned pages
For PDF pages with no extractable text layer, the app SHALL recognize text using on-device OCR and treat the result like extracted text for that page.

#### Scenario: Scanned manual
- **WHEN** the user imports a PDF made of scanned page images
- **THEN** the document becomes searchable and chunks cite the correct page numbers

### Requirement: Chunking with provenance
Extracted text SHALL be split into overlapping chunks of bounded size. Each chunk MUST record its document, its position in the document, its page (where applicable), and its nearest heading (where available). Chunks MUST NOT span PDF page boundaries.

#### Scenario: Chunk metadata
- **WHEN** a document finishes indexing
- **THEN** each chunk has a document reference, an ordinal, and a page or heading reference

### Requirement: Embedding with model identity
Each chunk and each photo SHALL be embedded with the installed embedding model, into the same vector space, and the stored vector MUST record the identifier and version of the embedding model and its vector dimension.

#### Scenario: Model recorded on chunks
- **WHEN** a chunk is stored
- **THEN** it includes its vector, the embedding model identifier and version, and the dimension

#### Scenario: Model recorded on photos
- **WHEN** a photo from a document or an imported photo is stored
- **THEN** its vector comes from the same embedding model as the chunks and records the same model identifier, version and dimension

### Requirement: Background ingestion with status
Ingestion SHALL run without blocking the UI, SHALL process documents from a persistent queue, and SHALL show each document's status: queued, extracting, recognizing text, analyzing images (with progress), embedding (with progress), ready, or failed (with a reason). Ingestion that is interrupted by app suspension or termination MUST resume on the next launch without duplicating chunks or images.

#### Scenario: Progress visible
- **WHEN** a 300-page PDF is being indexed
- **THEN** the library shows its status and embedding progress while the user keeps using the app

#### Scenario: App killed mid-ingestion
- **WHEN** the app is terminated while a document is embedding and is later relaunched
- **THEN** ingestion of that document resumes and the document ends with exactly one set of chunks and one set of images

#### Scenario: Unreadable file
- **WHEN** a PDF is password-protected or corrupt
- **THEN** the document shows status "failed" with a readable reason, and other queued documents keep processing

### Requirement: Search availability during ingestion
Only documents with status "ready" SHALL be included in retrieval and image search. A document's chunks and images MUST become searchable together, never partially.

#### Scenario: Partially embedded document
- **WHEN** the user asks a question while a document is still embedding
- **THEN** no chunks or images from that document are used to answer

### Requirement: Re-indexing
The user SHALL be able to re-index a document. Re-indexing MUST produce a new, complete set of chunks and images and remove the previous set only after the new set is ready, so the document stays searchable throughout.

#### Scenario: Re-index keeps document available
- **WHEN** the user re-indexes a ready document
- **THEN** questions keep being answered from the previous chunks and images until the new ones are ready, and afterwards only the new chunks and images exist

### Requirement: Deletion
Deleting a document SHALL remove the document record, its stored original file, and all of its chunks, images and vectors in one operation. Citations to it in existing chats MUST remain visible as text, marked as belonging to a deleted document. When sync is on, the delete confirmation MUST say that the document will be removed from every device that shares the library.

#### Scenario: Delete document
- **WHEN** the user deletes a document
- **THEN** it disappears from the library, none of its chunks or images are returned by search, and earlier citations to it show as "document deleted"

#### Scenario: Delete with sync on
- **WHEN** the user chooses to delete a document while sync is on
- **THEN** the confirmation says it will be removed from every device, and nothing is deleted unless the user confirms

### Requirement: Library view
The library SHALL list every document with its title, type, page count (for PDF), number of photos found (when any), import date, and ingestion status, and SHALL let the user rename documents. Photo documents MUST show a thumbnail.

#### Scenario: Rename
- **WHEN** the user renames a document
- **THEN** the new title appears in the library and in future citations

#### Scenario: Photo document
- **WHEN** an imported photo is ready
- **THEN** the library shows it with a thumbnail and the type "Photo"

### Requirement: Photo documents
An imported photo SHALL become a document that holds one image. The text recognized in the photo SHALL be extracted on the device. A photo with no recognizable text MUST still become ready and remain findable by its title and by similar image search.

#### Scenario: Nameplate photo
- **WHEN** the user imports a photo of a nameplate
- **THEN** the document becomes ready and the text on the nameplate is searchable

#### Scenario: Photo without text
- **WHEN** the user imports a photo of a part with no visible text
- **THEN** the document becomes ready, and a photo search with a similar picture finds it

### Requirement: Images embedded in documents
During ingestion, the app SHALL extract the raster images embedded in PDF and DOCX files. Each kept image MUST record its page (PDF) or nearest preceding heading (DOCX), and a caption when one exists: for PDF, the caption-like text directly below or above the image on the page; for DOCX, the image's alt text or an adjacent caption paragraph. Images smaller than a minimum size, images repeated on many pages of the same document, and full-page images on pages that needed text recognition MUST be skipped. A failure to read a single image MUST NOT fail the document.

#### Scenario: Photo in a PDF
- **WHEN** a PDF manual with a captioned photo on page 14 is indexed
- **THEN** that photo is stored with page 14 and its caption

#### Scenario: Photo in a DOCX
- **WHEN** a DOCX with an image whose alt text is "Pump, front view" under the heading "Installation" is indexed
- **THEN** that image is stored with the heading "Installation" and the caption "Pump, front view"

#### Scenario: Logo and scans skipped
- **WHEN** a scanned PDF with a small logo repeated on every page is indexed
- **THEN** neither the logo nor the full-page scans are stored as images, and the scanned text is still searchable

#### Scenario: Damaged image
- **WHEN** one image in a PDF cannot be decoded
- **THEN** that image is skipped and the document still becomes ready

### Requirement: Re-index after an embedding model change
When the installed embedding model differs from the model recorded on a document's stored vectors, the app SHALL queue that document for re-indexing automatically, without user action. Until the new vectors are ready, the document MUST stay findable by keyword search and MUST NOT be returned by vector or photo search with vectors from the other model. The library MUST show that the document is being re-indexed.

#### Scenario: App updated to a new embedding model
- **WHEN** the app starts with a new embedding model installed and the library holds documents indexed with the previous model
- **THEN** every such document is queued for re-indexing, keyword search keeps finding them meanwhile, and each becomes fully searchable once its new vectors are ready

#### Scenario: Nothing to re-index
- **WHEN** every document's vectors already come from the installed embedding model
- **THEN** no re-indexing is queued at start-up

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
