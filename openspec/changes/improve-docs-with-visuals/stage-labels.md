# Stage labels against the app

Each stage in the two diagrams, next to the X-ray step it matches (`XrayText.title(for:)` in
`App/Demo/XrayText.swift`) or the code that does it. For the pull request description (task 3.4).

## Ask flow (`docs/images/ask-flow-*.svg`)

| Stage | X-ray step / code |
|---|---|
| Question | the user's message (`ChatService.ask`) |
| Rewrite the follow-up · standalone query | "Rewrote the follow-up as a standalone query" (`QueryRewriter.standaloneQuery`) |
| Embed the question · 256-number vector | "Embedded the question" (`Retriever.retrieve`, `LiteRTEmbedder`) |
| Vector search · chunks_vec | "Vector search" (`CouchbaseChunkSearch.vectorSearch`, index `CouchbaseSchema.vectorIndex`) |
| Keyword search · chunks_fts | "Keyword search" (`CouchbaseSchema.ftsIndex`) |
| Words → photos · images_vec | "Words → photos search" (`Retriever.photosMatching(words:)`, `CouchbaseSchema.imageVectorIndex`) |
| Photo → photos · images_vec · with a photo | "Read the photo you sent" then "Image search" (`PhotoQuery`, `CouchbaseImageSearch`) |
| Rank merge | "Merged the vector and keyword results" (`RankFusion.fuse`) |
| Relevance check · best distance ≤ limit | "Relevance check: relevant / not relevant", detail "best distance … ≤ threshold …" |
| "I couldn't find an answer…" · model not called | "Language model not called"; text is `ChatService.notFoundText` |
| Gemma 4 E2B answers · from these chunks only | "Language model answered" (`PromptBuilder`, `LiteRTGenerator`) |
| Citation check · keeps real citations | `CitationValidator.validate` (`ChatService.swift:168`); no X-ray step of its own |
| Answer + citations · page or section | the saved message's `citations` ("Saved a chat message") |

## Import and sync flow (`docs/images/import-sync-flow-*.svg`)

| Stage | X-ray step / code |
|---|---|
| File | import from picker, share sheet or drag and drop |
| Store original, queue job · documents (blob) · ingestJobs | "Stored the original file as a blob", "Saved the document record", "Indexing job: queued" (`IngestionService.enqueue`) |
| Extract text · Vision reads scans, photos | "Indexing job: extracting" (`IngestionService.extract`, `VisionTextRecognizer`) |
| Chunk · overlapping, with page | `Chunker.chunk` (no X-ray step of its own) |
| Read the photos · 1 transaction · images | "Read photo n", "Wrote n photos in one transaction" (`IngestionService.analyzeImages`) |
| Embed + write chunks · 16 per transaction · chunks | "Wrote n chunks in one transaction" (`IngestionService.embed`, `batchSize: 16`) |
| Make the chunk set searchable · one switch | "Made chunk set n searchable" (`DocumentRepository.activate`) |
| Sync Gateway · documents · chunks · images | "Sent n …" during a *Sync* operation (`CouchbaseSchema.replicated`, `CouchbaseLibrarySync`) |
| Stays on this iPad · chats · messages · ingestJobs · indexes | `CouchbaseSchema.deviceLocal` (also `localMeta`); indexes are built per device |
