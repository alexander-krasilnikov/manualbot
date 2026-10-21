# Spec Delta

## Purpose

Lets the user fill the library from a curated list of public technical PDFs (manuals, product catalogs and whitepapers), grouped by industry, without leaving the app or hunting for links.

## ADDED Requirements

### Requirement: Bundled curated catalog
The app SHALL ship a catalog of curated public PDFs that can be browsed without a network connection. Each entry MUST name its category, title, publisher, kind (manual, catalog or whitepaper), language, size, page count and licence note, and the HTTPS address of the PDF. The catalog MUST contain no PDF files.

#### Scenario: Browsing offline
- **WHEN** the iPad has no network and the user opens the catalog
- **THEN** every entry is listed with its details, and importing an entry says that an internet connection is needed

#### Scenario: Categories
- **WHEN** the user opens the catalog
- **THEN** entries are grouped under Automotive, Motorcycle, Ships, Yachts, Manufacturing, Wind turbines, Field service, Military and Couchbase

### Requirement: Opening the catalog
The library SHALL offer the catalog next to the Files import, both from the import control in the toolbar and from the empty-library screen.

#### Scenario: Empty library
- **WHEN** the library has no documents
- **THEN** the empty screen offers the catalog alongside "Import documents"

### Requirement: Finding entries
The user SHALL be able to filter the catalog by category and by kind, and to search it by text matched against title, publisher and category.

#### Scenario: Search
- **WHEN** the user types "outboard"
- **THEN** only entries whose title, publisher or category contain "outboard" are listed

#### Scenario: Kind filter
- **WHEN** the user selects the kind "catalog"
- **THEN** only catalogs are listed, and the categories that have none are hidden

### Requirement: Importing from the catalog
The user SHALL be able to import one entry, or several selected entries, from the catalog. The app SHALL download each PDF to temporary storage and hand it to the same import path as a file from the Files app, so it is queued, indexed and synced like any other document.

#### Scenario: One entry
- **WHEN** the user taps Import on an entry and the download completes
- **THEN** the document appears in the library with status "queued" and its title is the entry's title

#### Scenario: Several entries
- **WHEN** the user selects five entries and chooses Import
- **THEN** all five download and, as each finishes, it joins the library, and a failure in one does not stop the others

### Requirement: Entry states
Each catalog entry SHALL show its state: not imported, downloading with progress, queued for indexing, in the library, or failed with a readable reason. A failed entry MUST offer retry. An entry whose document is already in the library MUST NOT be downloaded or imported a second time, on this iPad or on another iPad that shares the library.

#### Scenario: Already imported
- **WHEN** an entry's document is in the library
- **THEN** the entry shows "In library" and offers no Import action

#### Scenario: Imported on another iPad
- **WHEN** sync is on and the user imported an entry on one iPad
- **THEN** the same entry shows "In library" on the other iPad, and importing it there does not create a second document

#### Scenario: Progress
- **WHEN** a download is running
- **THEN** the entry shows progress, and the user can cancel it

#### Scenario: Removed from the library
- **WHEN** the user deletes a document that came from the catalog
- **THEN** its entry returns to "not imported"

### Requirement: Download validation
The app SHALL accept a download only if its content starts with the PDF signature, whatever the address ends in or the server claims. A download larger than 20 MB MUST be abandoned as soon as the limit is passed, without storing the file, and the refusal MUST name the entry, its size when known, and the limit.

#### Scenario: Address without .pdf
- **WHEN** an entry's address does not end in ".pdf" but returns a PDF
- **THEN** the download is accepted

#### Scenario: Page instead of PDF
- **WHEN** the address returns an HTML page, for example because the publisher moved the file
- **THEN** nothing is imported and the entry shows that the link no longer leads to a PDF

#### Scenario: Over the limit
- **WHEN** a file grows past 20 MB while downloading
- **THEN** the download stops, nothing is kept, and the entry shows the limit

### Requirement: Failure handling
When a download fails because the device is offline, the host refuses the request, the server answers with an error, or the connection drops, the entry MUST show a reason in plain words and keep its place in the list. Failed downloads MUST NOT leave partial files or partial documents behind.

#### Scenario: Host refuses
- **WHEN** a publisher's server answers "forbidden"
- **THEN** the entry shows that the publisher does not allow automatic downloads, and offers to open the address in the browser

#### Scenario: Connection lost
- **WHEN** the connection drops at 60% of a download
- **THEN** the entry shows a failure with retry, and no document or temporary file remains

### Requirement: Publisher changes
The catalog SHALL record each entry's checksum as last verified. When a download's checksum differs, the app MUST still import it, and the entry MUST show that the publisher has updated the file since the catalog was prepared.

#### Scenario: Updated manual
- **WHEN** a downloaded PDF's checksum differs from the recorded one
- **THEN** the document is imported and the entry shows the note about the updated file

### Requirement: Network disclosure
Before the first download from a publisher, the app SHALL state that the PDF will be downloaded from the publisher's host, naming the host. The catalog MUST contact only the hosts of entries the user chose to import, and MUST NOT send anything about the user or the library to them.

#### Scenario: First download
- **WHEN** the user imports an entry hosted on docs.nlr.gov for the first time
- **THEN** the app names docs.nlr.gov before downloading

#### Scenario: Browsing sends nothing
- **WHEN** the user browses and searches the catalog
- **THEN** the app makes no network requests

### Requirement: Licence visibility
Each entry SHALL show its licence note, such as public-domain US government work or free manufacturer download. The app MUST import only from the publisher's published address and MUST NOT carry copies of the documents.

#### Scenario: Licence shown
- **WHEN** the user opens an entry's details
- **THEN** its publisher, licence note and source address are shown
