# Spec Delta

## MODIFIED Requirements

### Requirement: Model licences and notices
The app SHALL show the licence terms and notices for the models it uses, including the Apache 2.0 licence of the embedding model and of the language model, in a screen reachable from the library.

#### Scenario: Reading the notices
- **WHEN** the user opens the About screen
- **THEN** it names each model with its licence and links to the full terms

### Requirement: Staged readiness
The app SHALL track readiness separately for each model. Document import and indexing MUST be available as soon as the embedding model is installed, even while the language model is still downloading. Chat MUST be disabled, with an explanation, until the language model is installed.

#### Scenario: Embedding model ready first
- **WHEN** the embedding model is installed and the language model has not been downloaded yet, or is still downloading
- **THEN** the user can import and index documents, and the chat input shows that the language model is still being prepared

#### Scenario: Nothing installed yet
- **WHEN** neither model is installed
- **THEN** the setup screen is shown and documents cannot be imported until the embedding model is installed

## REMOVED Requirements

### Requirement: Built-in embedding model
**Reason**: The embedding model (EmbeddingGemma 2 on LiteRT-LM) is now downloaded on first use like the language model, which makes the app about 330 MB smaller and lets one runtime load every model.
**Migration**: The embedding model is listed in the manifest with its download source, size and checksum, and goes through the existing setup, verified download and recovery flows. Installs that had the built-in model download the new one on the next launch; their documents are re-indexed once it is installed (see document-ingestion).

## ADDED Requirements

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
