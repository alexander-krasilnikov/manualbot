# model-catalog Specification

## Purpose
Lets the user find, download, install, activate and delete embedding and language models that the app's LiteRT-LM runtime can run, from a Models page in Settings, without a new build of the app.

## Requirements

### Requirement: Models page
The app SHALL offer a Models page in Settings, reachable from the library at any time after first-run setup. It MUST list, for each role (embedder and language model), the installed models with their size and licence, mark the active one, and show the device's available storage.

#### Scenario: Opening the page
- **WHEN** the user opens Settings and chooses Models after setup
- **THEN** the page shows EmbeddingGemma 2 as the active embedder and Gemma 4 E2B as the active language model, with their sizes, licences and the available storage

### Requirement: Embedding model sources
Embedding models SHALL come from two sources: a list built into the app, whose entries were tested, and search. Each entry of the list MUST name the model, its download source, size, SHA-256 and licence, and whether it can embed photos. An embedding model found by search that is not in the list is untested.

#### Scenario: Browsing embedders
- **WHEN** the user opens the Models page
- **THEN** every embedding model in the built-in list that is not installed is shown with its size, licence and whether it supports photo search

#### Scenario: Finding an embedding model by search
- **WHEN** the user searches for "embedding"
- **THEN** the results include embedding models, each marked as an embedding model, and marked "Untested" unless it is in the built-in list

### Requirement: Model search
The user SHALL be able to search for models among the public LiteRT-LM model repositories of the `litert-community` organization on Hugging Face. Results MUST include only repositories that are not gated and that contain a `.litertlm` file, and MUST show each file's name, size, licence and whether it is a language model or an embedding model.

#### Scenario: Search results
- **WHEN** the user searches for "gemma"
- **THEN** the results list the matching repositories' `.litertlm` files with size, licence and kind, and gated repositories are left out

#### Scenario: No network
- **WHEN** the user searches with no network connection
- **THEN** the page says that searching needs a connection, and the installed models stay usable

### Requirement: Compatibility before download
Before a download starts, the app SHALL judge each candidate from a small part of its file and from its size. A file whose header is not a LiteRT-LM file, whose model is neither a language model nor an embedding model, or that is larger than the device can hold in memory MUST be marked incompatible and MUST NOT be downloadable. A candidate whose minimum runtime version cannot be read before download MUST be marked as checked after download.

#### Scenario: File of an unknown kind
- **WHEN** a search result's header is a LiteRT-LM header of a model that is neither a language model nor an embedding model
- **THEN** it is marked "Unknown kind of model" and cannot be downloaded

#### Scenario: Too large for the device
- **WHEN** a search result's file is larger than the share of the device's memory a model may use
- **THEN** it is marked "Too large for this iPad" with its size, and cannot be downloaded

#### Scenario: Runtime version unknown before download
- **WHEN** a candidate's header shows a language model but its minimum runtime version cannot be read without downloading it
- **THEN** it is offered for download, marked as checked once downloaded

### Requirement: Compatibility after download
After a download is verified by checksum, the app SHALL load the file's description with its own runtime and MUST reject a model whose type does not match its role, that requires a newer runtime than the app's, for a language model, whose context is smaller than the app needs, or, for an embedding model, that reports no vector size or cannot produce the size its list entry asks for. A rejected file MUST be deleted and the reason shown.

#### Scenario: Newer runtime required
- **WHEN** a downloaded language model requires a newer LiteRT-LM runtime than the app contains
- **THEN** the file is deleted and the model shows "Needs a newer version of the app"

#### Scenario: Context too small
- **WHEN** a downloaded language model's maximum context is smaller than the app's answer context
- **THEN** the file is deleted and the model shows that its context is too small

#### Scenario: Compatible model
- **WHEN** a downloaded language model passes every check
- **THEN** it is installed, inactive, and can be activated

### Requirement: Verified model downloads
Every model downloaded from the Models page SHALL be verified against a SHA-256 checksum before it is installed: the catalog's checksum for an embedder, and the checksum the model repository reports for the file for a language model. A file without a reported checksum MUST NOT be offered for download. Downloads MUST be resumable and stored like the default models.

#### Scenario: Checksum mismatch
- **WHEN** a downloaded language model's SHA-256 differs from the checksum its repository reported
- **THEN** the file is deleted, the model shows as failed, and the user can retry

#### Scenario: Not enough space
- **WHEN** the user starts a download larger than the available storage less the safety margin
- **THEN** the download does not start and the page says how much space to free

### Requirement: Inactive installed models
An installed model that is not active SHALL stay installed until the user deletes it, across launches and app updates. Activating an installed model MUST NOT download anything.

#### Scenario: Switching back
- **WHEN** the user activates Gemma 4 E4B, later activates Gemma 4 E2B again, and then relaunches the app
- **THEN** both models are still installed, and activating either needs no download

### Requirement: Untested embedding models
An embedding model that is not in the built-in list SHALL be used with generic settings: no prompt templates, the vector size the file reports, an input length the file supports, and the distances the app ships with. The Models page and the activation confirmation MUST say that it is untested and that the quality of search with it is unknown.

#### Scenario: Downloading an untested embedder
- **WHEN** the user downloads an embedding model found by search
- **THEN** it is installed, inactive and labelled "Untested", with its vector size and whether it analyzes photos taken from the file

#### Scenario: Activating an untested embedder
- **WHEN** the user chooses to use an untested embedding model
- **THEN** the confirmation says that it has not been tested and that search quality is unknown, besides the number of documents to re-index, and nothing changes unless the user confirms

#### Scenario: Going back
- **WHEN** the user finds that search with an untested embedder is poor and uses the previous embedder again
- **THEN** every document is re-indexed with the previous embedder, as for any switch

### Requirement: Activation confirmation
Activating a model SHALL first ask for confirmation that names its cost. For an embedder, the cost MUST include the number of documents that will be re-indexed, that search uses keywords only for a document until its re-index is done, and that photo search is unavailable until the re-index finishes or, if the embedder cannot embed photos, while it stays active. When sync is on and the embedder is not the fleet model, the cost MUST also say that sync pauses while it is active, naming the fleet model. For a language model, the cost MUST say that an answer being written will stop.

#### Scenario: Activating another embedder
- **WHEN** the user chooses to activate a different embedder with 37 documents in the library
- **THEN** a confirmation says that 37 documents will be re-indexed and photo search is unavailable until that finishes, and nothing changes unless the user confirms

#### Scenario: Leaving the fleet model with sync on
- **WHEN** sync is on and the user chooses to activate an embedder other than the fleet model
- **THEN** the confirmation also says that sync pauses until the fleet model is active again and the library is re-indexed with it

#### Scenario: Cancelling
- **WHEN** the user dismisses the confirmation
- **THEN** the active models, the index and any running work are unchanged

### Requirement: Immediate switch
After confirmation, the app SHALL make the chosen model active straight away. Any answer being written and any indexing in progress MUST be cancelled. Chats, documents and their originals MUST be kept. A new embedder MUST trigger re-indexing of every document whose vectors came from another model. Interrupted indexing MUST resume with the new embedder.

#### Scenario: Switching language model during an answer
- **WHEN** the user confirms a new language model while an answer is streaming
- **THEN** the answer stops and is kept as a stopped answer, and the next question is answered by the new model

#### Scenario: Switching embedder during indexing
- **WHEN** the user confirms a new embedder while a document is being indexed
- **THEN** indexing stops, and that document and every other document are re-indexed with the new embedder

#### Scenario: Searching during the re-index
- **WHEN** the user asks a question while documents are being re-indexed for a new embedder
- **THEN** documents not yet re-indexed are found by keyword search only, and no vectors from the previous embedder are compared with vectors from the new one

### Requirement: Photo search depends on the active embedder
Photo search SHALL be available only when the active embedder can embed photos. When it cannot, photo import and photo questions MUST be disabled with an explanation naming the active embedder, and documents MUST still be imported and searched by text.

#### Scenario: Text-only embedder
- **WHEN** the active embedder cannot embed photos
- **THEN** the photo button explains that the active embedding model does not support photos, and PDF and Word import keep working

### Requirement: Deleting models
The user SHALL be able to delete any installed model that is not active. The active model of a role MUST NOT be deletable. Deleting MUST remove all of the model's files and free their storage.

#### Scenario: Delete an inactive model
- **WHEN** the user deletes an inactive Gemma 4 E4B
- **THEN** its files are removed, the available storage grows by its size, and it is listed again only as downloadable

#### Scenario: Active model
- **WHEN** the user views the active embedder
- **THEN** no delete action is offered for it

### Requirement: Activation persists
The active model of each role SHALL be remembered across launches. If the active model's files are missing at launch, the app MUST NOT fall back silently to another installed model.

#### Scenario: Relaunch
- **WHEN** the user activates Gemma 4 E4B and relaunches the app
- **THEN** chat uses Gemma 4 E4B without asking again
