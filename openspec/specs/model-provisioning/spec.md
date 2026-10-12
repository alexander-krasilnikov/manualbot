# model-provisioning Specification

## Purpose
Gets the local embedding model and language model onto the device once, verifies them, and guarantees that every core feature works offline afterwards.

## Requirements

### Requirement: Model manifest
The app SHALL ship with a built-in manifest listing the default model for each role (embedding model and language model) with its identifier, version, download source, byte size, and SHA-256 checksum. First-run setup installs these defaults. Any other model MUST come from the Models page (the curated embedder catalog or language model search) and MUST pass its checks before it is installed. The app MUST NOT download or load a model from any other source.

#### Scenario: Multi-file model
- **WHEN** a model consists of several files (such as a compiled Core ML model and its tokenizer)
- **THEN** the manifest lists it as one downloadable archive, which is verified as a whole before being unpacked, and the model counts as installed only after unpacking completes

#### Scenario: Unsafe archive
- **WHEN** a verified archive contains an entry that would be written outside the model's directory
- **THEN** installation fails, nothing is unpacked, and the model is reported as failed

#### Scenario: Manifest drives setup
- **WHEN** the app starts for the first time and evaluates model readiness
- **THEN** it checks exactly the default models listed in the built-in manifest, by identifier, version, and checksum

#### Scenario: Update changes a default the user never chose
- **WHEN** an app update changes a default model in the manifest and the user never activated a model of that role on the Models page
- **THEN** the new default becomes active through the setup flow, and the earlier default's files are deleted

#### Scenario: Update changes a default the user chose
- **WHEN** an app update changes a default model in the manifest and the user had activated the earlier model on the Models page
- **THEN** the earlier model stays installed and active until the user activates another model or deletes it

### Requirement: Model licences and notices
The app SHALL show the licence terms and notices for every installed model, with each model's licence as stated by its catalog entry or its repository, in a screen reachable from the library.

#### Scenario: Reading the notices
- **WHEN** the user opens the About screen
- **THEN** it names each installed model with its licence and links to the full terms

#### Scenario: Model installed from search
- **WHEN** the user has installed a language model found by search
- **THEN** the About screen lists it with the licence its repository states

### Requirement: First-run model setup
When any required model is missing or invalid, the app SHALL present a model setup screen showing each model's name and download size, the total required storage, and the device's available storage. The download MUST NOT start until the user confirms.

#### Scenario: Fresh install
- **WHEN** the user launches the app for the first time
- **THEN** the setup screen lists the embedding model and the language model with their sizes and asks the user to start the download

#### Scenario: Insufficient storage
- **WHEN** available storage is less than the total size of the missing models plus a safety margin
- **THEN** the app does not start the download and tells the user how much space to free

### Requirement: Resumable, verified download
Model downloads SHALL continue while the app is in the background and SHALL resume after interruption without restarting from zero. Each downloaded file MUST be verified against its manifest checksum before it is marked installed. A file that fails verification MUST be deleted and reported as failed, with a retry option.

#### Scenario: Interrupted download
- **WHEN** connectivity is lost partway through a model download and later restored
- **THEN** the download resumes from where it stopped and completes

#### Scenario: Corrupted file
- **WHEN** a downloaded file's SHA-256 does not match the manifest
- **THEN** the file is deleted, the model shows as failed, and the user can retry

### Requirement: Model storage
Installed models SHALL be stored in app-private storage that is excluded from device backup and is not visible in the Files app.

#### Scenario: Backup exclusion
- **WHEN** a model finishes installing
- **THEN** its files are marked excluded from backup

### Requirement: Staged readiness
The app SHALL track readiness separately for each model. Document import and indexing MUST be available as soon as the embedding model is installed, even while the language model is still downloading. Chat MUST be disabled, with an explanation, until the language model is installed.

#### Scenario: Embedding model ready first
- **WHEN** the embedding model is installed and the language model has not been downloaded yet, or is still downloading
- **THEN** the user can import and index documents, and the chat input shows that the language model is still being prepared

#### Scenario: Nothing installed yet
- **WHEN** neither model is installed
- **THEN** the setup screen is shown and documents cannot be imported until the embedding model is installed

### Requirement: Missing model recovery
If the active model of a role is missing or fails verification at launch (for example, after the app was offloaded), the app SHALL return that model to the setup flow instead of crashing, and MUST keep all existing documents, chunks, and chats. It MUST NOT activate another installed model in its place without the user choosing it.

#### Scenario: Model deleted externally
- **WHEN** the active language model file is missing at launch
- **THEN** the app shows the setup screen for that model only, and the library and chat history are still intact

#### Scenario: Another model is installed
- **WHEN** the active language model file is missing at launch and another language model is installed but inactive
- **THEN** the setup screen offers to download the missing model again and the user can choose to activate the installed one from the Models page instead

### Requirement: Offline operation after setup
Once the active models are installed, document import, extraction, OCR, chunking, embedding, indexing, retrieval, answer generation, and chat history SHALL work with no network connection. The app MUST NOT send document content, queries, or answers off the device, except that while the user has turned sync on, the shared library (documents, their originals, chunks and images) is exchanged with the Sync Gateway the user configured. Queries, answers and chats MUST never be sent. Network requests after setup MUST happen only when the user searches for or downloads a model from the Models page, or to the configured Sync Gateway while sync is on.

#### Scenario: Airplane mode
- **WHEN** the device is in airplane mode and the active models are installed
- **THEN** the user can import a PDF, wait for it to index, ask a question about it, and receive a cited answer

#### Scenario: No outbound traffic during core use
- **WHEN** sync is off and the user imports documents and chats while network traffic is monitored
- **THEN** the app makes no network requests

#### Scenario: Traffic while sync is on
- **WHEN** sync is on and the user imports a document and asks a question about it while network traffic is monitored
- **THEN** the only requests go to the configured Sync Gateway, and they carry no question, answer or chat

#### Scenario: Searching for models
- **WHEN** the user searches for a language model on the Models page
- **THEN** the only requests go to the model repository's public API and file host, and they carry no document content, queries or answers

### Requirement: Downloaded embedding model
The embedding model SHALL be downloaded from its manifest source, verified against its checksum, and stored like the language model. The setup screen MUST list it with its download size, and its download MUST be offered first, so import can start before the larger language model has arrived.

#### Scenario: Fresh install
- **WHEN** the user launches a freshly installed app with a network connection
- **THEN** the setup screen lists the embedding model and the language model with their sizes, and once the user starts the download the embedding model completes first

#### Scenario: First launch with no network
- **WHEN** the user launches a freshly installed app with no network connection
- **THEN** the setup screen explains that the models must be downloaded once, and no import is offered until the embedding model is installed

#### Scenario: Embedding model deleted externally
- **WHEN** the embedding model file is missing at launch
- **THEN** the app returns that model to the setup flow, keeps every document and chat, and makes import available again once it is reinstalled
