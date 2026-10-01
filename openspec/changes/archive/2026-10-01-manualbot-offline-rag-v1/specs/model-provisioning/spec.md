# Spec Delta

## Purpose

Gets the local embedding model and language model onto the device once, verifies them, and guarantees that every core feature works offline afterwards.

## ADDED Requirements

### Requirement: Model manifest
The app SHALL ship with a built-in manifest listing each required model (embedding model and language model) with its identifier, version, download source, byte size, and SHA-256 checksum. The app MUST NOT download or load any model that is not in the manifest.

#### Scenario: Multi-file model
- **WHEN** a model consists of several files (such as a compiled Core ML model and its tokenizer)
- **THEN** the manifest lists it as one downloadable archive, which is verified as a whole before being unpacked, and the model counts as installed only after unpacking completes

#### Scenario: Unsafe archive
- **WHEN** a verified archive contains an entry that would be written outside the model's directory
- **THEN** installation fails, nothing is unpacked, and the model is reported as failed

#### Scenario: Manifest drives setup
- **WHEN** the app starts and evaluates model readiness
- **THEN** it checks exactly the models listed in the built-in manifest, by identifier, version, and checksum

### Requirement: Built-in embedding model
The embedding model SHALL ship inside the app and be available from the first launch, without any download or network connection. The app MUST NOT download it. If the model is missing from the app, the app SHALL report that it must be reinstalled and MUST NOT try to fetch it.

#### Scenario: First launch with no network
- **WHEN** the user launches a freshly installed app with no network connection
- **THEN** the library opens directly, without a setup screen, and documents can be imported and indexed

#### Scenario: Only the language model is offered
- **WHEN** the app lists models that can be downloaded
- **THEN** only the language model appears, and the storage required counts only its size

#### Scenario: Model missing from the build
- **WHEN** the built-in embedding model is not found inside the app
- **THEN** the app reports that it is missing and asks the user to reinstall, and it does not attempt a download

### Requirement: Model licences and notices
The app SHALL show the licence terms and notices for the models it uses, including the Gemma Terms of Use notice for the embedding model, in a screen reachable from the library.

#### Scenario: Reading the notices
- **WHEN** the user opens the About screen
- **THEN** it names each model with its licence and links to the full terms

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
The app SHALL track readiness separately for each model. Document import and indexing MUST be available as soon as the embedding model is ready, which is from the first launch because it is built in. Chat MUST be disabled, with an explanation, until the language model is installed.

#### Scenario: Embedding model ready first
- **WHEN** the language model has not been downloaded yet, or is still downloading
- **THEN** the user can import and index documents, and the chat input shows that the language model is still being prepared

### Requirement: Missing model recovery
If a previously installed model is missing or fails verification at launch (for example, after the app was offloaded), the app SHALL return that model to the setup flow instead of crashing, and MUST keep all existing documents, chunks, and chats.

#### Scenario: Model deleted externally
- **WHEN** the language model file is missing at launch
- **THEN** the app shows the setup screen for that model only, and the library and chat history are still intact

### Requirement: Offline operation after setup
Once all models are installed, document import, extraction, OCR, chunking, embedding, indexing, retrieval, answer generation, and chat history SHALL work with no network connection. The app MUST NOT send document content, queries, or answers off the device.

#### Scenario: Airplane mode
- **WHEN** the device is in airplane mode and all models are installed
- **THEN** the user can import a PDF, wait for it to index, ask a question about it, and receive a cited answer

#### Scenario: No outbound traffic during core use
- **WHEN** the user imports documents and chats while network traffic is monitored
- **THEN** the app makes no network requests
