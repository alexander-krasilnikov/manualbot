# Spec Delta

## MODIFIED Requirements

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

### Requirement: Background ingestion with status
Ingestion SHALL run without blocking the UI, SHALL process documents from a persistent queue, and SHALL show each document's status: queued, extracting, recognizing text, analyzing images (with progress), embedding (with progress), ready, or failed (with a reason). Ingestion that is interrupted by app suspension or termination MUST resume on the next launch without duplicating passages or images.

#### Scenario: Progress visible
- **WHEN** a 300-page PDF is being indexed
- **THEN** the library shows its status and embedding progress while the user keeps using the app

#### Scenario: App killed mid-ingestion
- **WHEN** the app is terminated while a document is embedding and is later relaunched
- **THEN** ingestion of that document resumes and the document ends with exactly one set of passages and one set of images

#### Scenario: Unreadable file
- **WHEN** a PDF is password-protected or corrupt
- **THEN** the document shows status "failed" with a readable reason, and other queued documents keep processing

### Requirement: Search availability during ingestion
Only documents with status "ready" SHALL be included in retrieval and image search. A document's passages and images MUST become searchable together, never partially.

#### Scenario: Partially embedded document
- **WHEN** the user asks a question while a document is still embedding
- **THEN** no passages or images from that document are used to answer

### Requirement: Re-indexing
The user SHALL be able to re-index a document. Re-indexing MUST produce a new, complete set of passages and images and remove the previous set only after the new set is ready, so the document stays searchable throughout.

#### Scenario: Re-index keeps document available
- **WHEN** the user re-indexes a ready document
- **THEN** questions keep being answered from the previous passages and images until the new ones are ready, and afterwards only the new passages and images exist

### Requirement: Deletion
Deleting a document SHALL remove the document record, its stored original file, and all of its passages, images and vectors in one operation. Citations to it in existing chats MUST remain visible as text, marked as belonging to a deleted document.

#### Scenario: Delete document
- **WHEN** the user deletes a document
- **THEN** it disappears from the library, none of its passages or images are returned by search, and earlier citations to it show as "document deleted"

### Requirement: Library view
The library SHALL list every document with its title, type, page count (for PDF), number of photos found (when any), import date, and ingestion status, and SHALL let the user rename documents. Photo documents MUST show a thumbnail.

#### Scenario: Rename
- **WHEN** the user renames a document
- **THEN** the new title appears in the library and in future citations

#### Scenario: Photo document
- **WHEN** an imported photo is ready
- **THEN** the library shows it with a thumbnail and the type "Photo"

## ADDED Requirements

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
