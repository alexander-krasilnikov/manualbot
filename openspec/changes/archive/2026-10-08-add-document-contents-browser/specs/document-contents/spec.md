# Spec Delta

## Purpose

Lets a user or presenter look inside an imported document from the library, listing the chunks and images ingestion produced and previewing each one in the detail column, to see how the document was split and indexed.

## ADDED Requirements

### Requirement: Opening a document's contents
Each library row for a ready document that is not a photo SHALL offer a control that opens the document's contents in the library sidebar, with a way back to the library. Tapping the row itself MUST still open the document in the source viewer. Documents that are not ready, and photo documents, MUST NOT offer the control.

#### Scenario: Open and go back
- **WHEN** the user taps the contents control on a ready PDF
- **THEN** the sidebar shows that document's contents, and going back shows the library list again

#### Scenario: Row tap unchanged
- **WHEN** the user taps the row of a ready PDF
- **THEN** the document opens in the source viewer at page 1 and the sidebar still shows the library

#### Scenario: Not offered
- **WHEN** the library holds a document that is still importing and a photo document
- **THEN** neither row offers the contents control

### Requirement: Chunk list
The contents SHALL list the chunks of the document's active index in order, with their count, grouped into sections by page for PDF and by heading otherwise. Each entry MUST show its number and the start of its text. A chunk that stands for an image MUST be marked as such.

#### Scenario: Sections by page
- **WHEN** the user opens the contents of a PDF whose chunks span pages 1 to 3
- **THEN** the chunks are listed in order under the headers Page 1, Page 2 and Page 3, and the total count is shown

#### Scenario: Image chunk marked
- **WHEN** the document has an image on page 2
- **THEN** the chunk that stands for that image is listed under Page 2 with a photo mark

### Requirement: Image list
The contents SHALL switch between chunks and images. The image list SHALL show the images of the active index in order, with their count, grouped like the chunks, each with a thumbnail and its caption when it has one. A document without images MUST say it has none.

#### Scenario: Switch to images
- **WHEN** the user switches the contents of a PDF with three images to Images
- **THEN** three thumbnails are listed under their page headers with the count 3

#### Scenario: No images
- **WHEN** the user switches the contents of a text document to Images
- **THEN** the list says the document has no images

### Requirement: Chunk preview
Selecting a chunk SHALL show it in the detail column's Source view: its number out of the total, page and heading when known, its length, the embedding model and vector dimension, and its full text. Vector values MUST NOT be shown. Text repeated from the previous chunk and text repeated in the next chunk MUST be visibly marked.

#### Scenario: Preview contents
- **WHEN** the user selects chunk 5 of 40 on page 2
- **THEN** the detail column shows "5 of 40", page 2, the chunk's length, the embedding model with its dimension, and the full chunk text

#### Scenario: Overlap marked
- **WHEN** the selected chunk begins with sentences that end the previous chunk
- **THEN** those sentences are marked as repeated from the previous chunk

#### Scenario: Detail column switches to Source
- **WHEN** X-ray is showing and the user selects a chunk
- **THEN** the detail column switches to Source and shows the chunk preview

### Requirement: Stepping between chunks
The chunk preview SHALL offer Previous and Next, which show the neighboring chunk in order and select it in the list. Previous MUST be unavailable on the first chunk and Next on the last.

#### Scenario: Next
- **WHEN** the user taps Next on chunk 5
- **THEN** chunk 6 is shown and selected in the list

#### Scenario: Ends
- **WHEN** the first chunk is shown
- **THEN** Previous is unavailable

### Requirement: Image preview
Selecting an image SHALL show in the detail column's Source view the stored image, zoomable, with its pixel size, page or heading, caption and whether the caption came from nearby text or alt text, and the text recognized in it. The preview MUST offer to show the chunk that stands for the image.

#### Scenario: Preview contents
- **WHEN** the user selects an image with a nearby caption and recognized text
- **THEN** the detail column shows the image, its size, its page, the caption marked as nearby text, and the recognized text

#### Scenario: To its chunk
- **WHEN** the user taps the image's chunk link
- **THEN** the contents switch to Chunks with that chunk selected, and its preview is shown

### Requirement: Show in document
Chunk and image previews SHALL offer Show in document, which opens the original document at the item's location with the item highlighted, as tapping a citation to it would.

#### Scenario: Chunk in a PDF
- **WHEN** the user taps Show in document on a chunk from page 7 of a PDF
- **THEN** the source viewer shows the PDF at page 7 with that chunk highlighted

### Requirement: Narrow layout
When the workspace is collapsed to a single column, selecting a chunk or an image SHALL move to the detail column, and going back MUST return to the contents with the same item selected.

#### Scenario: Compact selection
- **WHEN** the window is narrow and the user selects a chunk
- **THEN** the chunk preview fills the window, and going back shows the contents list

### Requirement: Re-index and deletion
When a re-index of the document finishes while its contents are open, the lists SHALL reload from the new index. A preview whose chunk or image is no longer in the index MUST say so. If the document is deleted, the sidebar MUST return to the library and the preview MUST say the document was deleted.

#### Scenario: Re-index finishes
- **WHEN** a chunk preview is showing and a re-index of its document finishes
- **THEN** the chunk list shows the new index and the preview says the chunk is no longer in the index

#### Scenario: Document deleted
- **WHEN** the user deletes the document whose contents are open
- **THEN** the sidebar shows the library and the preview says the document was deleted

### Requirement: Read-only and traced
Browsing contents and previews MUST NOT change any stored data. Loading a document's contents SHALL appear in the X-ray log as its own operation, named after the document, with the database queries it ran. Showing a chunk or image preview and stepping between chunks read no queries and MUST NOT add events.

#### Scenario: Contents load in X-ray
- **WHEN** the user opens the contents of “Manual.pdf”
- **THEN** the X-ray log gains one operation for the contents of “Manual.pdf” holding the chunk and image queries

#### Scenario: Stepping is quiet
- **WHEN** the user selects a chunk and taps Next three times
- **THEN** the X-ray log gains no events

#### Scenario: Nothing changes
- **WHEN** the user browses a document's contents and previews its chunks and images
- **THEN** every collection has the same document count as before

### Requirement: Open in Database
The document preview (PDF, text or photo) and the chunk and image previews SHALL offer Open in Database, which opens the Database explorer at the shown record: the document record for a document, the chunk record for a chunk, the image record for an image. Closing the explorer MUST return to the same preview.

#### Scenario: From a chunk
- **WHEN** the user taps Open in Database on the preview of chunk 3 of “Manual”
- **THEN** the explorer shows that chunk's stored record, and closing it shows the chunk preview again

#### Scenario: From a document
- **WHEN** the user taps Open in Database while a PDF is open in the source viewer
- **THEN** the explorer shows that document's record in the documents collection

#### Scenario: From an image
- **WHEN** the user taps Open in Database on an image preview
- **THEN** the explorer shows that image's record, with a Preview button next to its image blob
