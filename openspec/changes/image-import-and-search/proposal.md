# Proposal

## Why

Technicians in the field often know a machine by what it looks like or by its nameplate, not by the words a manual uses. Today ManualBot can only be asked in typed text, and it ignores every photo: imported photos are rejected, and the photos inside PDF and Word manuals are thrown away during extraction. Taking a photo of a nameplate or a part, and finding the manual pages and photos that match it, is the most natural question an on-site user can ask, and it can be answered on the device with OCR and image features the OS already provides.

## What Changes

- **Photo import**: JPEG, PNG and HEIC files can be imported as documents, through the same picker, share sheet and drag and drop. A photo document is searchable by the text recognized in it, by its title, and by how it looks.
- **Photos inside documents**: photos embedded in PDF and DOCX files are extracted during ingestion. Small images (logos, icons) and full-page scans are skipped. Each kept image records its document, page (PDF) or section heading, and its caption, taken from the nearby caption text or, in DOCX, the alt text.
- **Image index**: every image gets an image feature vector from the on-device Vision feature print. The vector is stored with the model revision that produced it, in a new `images` collection with its own vector index in the same Couchbase Lite database. Images follow the same generations as passages, so they become searchable, are replaced on re-index, and are deleted together with their document's passages.
- **Text to image**: each image also gets one passage built from its caption, section heading and recognized text. That passage is searched by the existing hybrid retrieval, so typing "filter housing photo" can find a captioned photo.
- **Photo as a question**: in chat, the user can take a photo or pick one, with or without a typed question. The app recognizes text in the photo (for example the model and part numbers on a nameplate) and uses it as keyword and semantic query text. It also finds visually similar images. Matching images bring in the passages from their page or section as a third ranked list in rank fusion.
- **Grounding is unchanged**: answers are still generated only from document text. A photo match never becomes evidence by itself, and the photo is not given to the language model. A photo with no typed question gets a "matches" reply listing the similar images and their passages, without calling the language model.
- **Images in answers**: a citation of a page or section that holds a photo shows the photo as a thumbnail. A citation of an image's passage opens that image, and an imported photo opens in an image view in the source column.
- **X-ray**: image analysis, image writes, the image vector query with its row funnel, image positions in fusion, and the image relevance decision are traced. The demo reset adds a sample photo and a sample PDF that contains a photo.

## Capabilities

### New Capabilities
- `image-search`: the image index, image feature vectors and their model identity, finding similar images from a photo, the passage that makes an image findable by text, image relevance, and the image retrieval quality baseline.

### Modified Capabilities
- `document-ingestion`: image file types are accepted; photos embedded in PDF and DOCX are extracted with their location and caption; an "analyzing images" status is added; activation, re-indexing and deletion include images; the library shows photo documents.
- `hybrid-retrieval`: rank fusion takes passages reached through matching images as a third list, and the relevance gate can pass on a close image match.
- `grounded-chat`: a photo can be asked as a question, alone or with text; answers and citations show the images on the cited page or section; citation navigation opens images.
- `database-xray`: import, question, fusion and relevance events cover images; the demo reset includes photo samples.

## Impact

- **Ports**: an image feature port (with a model identity, like `Embedder`), a text recognition port, an image search port, image fields on `ExtractedDocument`, an image record type, and optional image references on `Chunk`, `Citation` and `MessageRecord`.
- **Core**: `IngestionService` gains an image analysis step, and documents with no text but with images no longer fail. `Retriever` accepts an optional photo and fuses a third list. `ChatService` handles photo questions and the matches-only reply.
- **Adapters**: OCR moves out of `PDFExtractor` into a shared Vision text recognizer. `PDFExtractor` finds image placements on each page. `DocxExtractor` reads `w:drawing` relationships and alt text. There is a new Vision feature print adapter. `CouchbaseSchema` adds the `images` collection and an `images_vec` index, and the repository writes, activates and deletes images with passages.
- **App**: the picker and drop types gain images, the chat input gains camera and photo buttons, `Info.plist` gains a camera usage description, the source viewer gains an image view, citations show thumbnails, and the library shows photo documents.
- **Data**: new optional fields decode as absent on older records. Existing documents have no images until they are re-indexed. No migration is needed.
- **Dependencies**: none new. Vision feature print and text recognition are system frameworks, and there is no new bundled or downloaded model.
