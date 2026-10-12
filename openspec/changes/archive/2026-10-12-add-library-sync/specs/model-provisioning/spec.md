# Spec Delta

## MODIFIED Requirements

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
