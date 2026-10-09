# Spec Delta

## MODIFIED Requirements

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

### Requirement: Missing model recovery
If the active model of a role is missing or fails verification at launch (for example, after the app was offloaded), the app SHALL return that model to the setup flow instead of crashing, and MUST keep all existing documents, chunks, and chats. It MUST NOT activate another installed model in its place without the user choosing it.

#### Scenario: Model deleted externally
- **WHEN** the active language model file is missing at launch
- **THEN** the app shows the setup screen for that model only, and the library and chat history are still intact

#### Scenario: Another model is installed
- **WHEN** the active language model file is missing at launch and another language model is installed but inactive
- **THEN** the setup screen offers to download the missing model again and the user can choose to activate the installed one from the Models page instead

### Requirement: Offline operation after setup
Once the active models are installed, document import, extraction, OCR, chunking, embedding, indexing, retrieval, answer generation, and chat history SHALL work with no network connection. The app MUST NOT send document content, queries, or answers off the device. Network requests after setup MUST happen only when the user searches for or downloads a model from the Models page.

#### Scenario: Airplane mode
- **WHEN** the device is in airplane mode and the active models are installed
- **THEN** the user can import a PDF, wait for it to index, ask a question about it, and receive a cited answer

#### Scenario: No outbound traffic during core use
- **WHEN** the user imports documents and chats while network traffic is monitored
- **THEN** the app makes no network requests

#### Scenario: Searching for models
- **WHEN** the user searches for a language model on the Models page
- **THEN** the only requests go to the model repository's public API and file host, and they carry no document content, queries or answers
