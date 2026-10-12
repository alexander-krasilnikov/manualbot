# ManualBot

**Ask your manuals. On the iPad, offline.** ManualBot answers questions about your own documents (PDF, Word, text,
photos) entirely on the device, and every answer cites the page or section it came from.

![ManualBot on an iPad: the library, a chat with a cited answer, and the X-ray panel showing the database steps behind it](docs/images/hero.png)

## Answers only from your documents

Import documents, and ask in a chat, with words, with a photo, or both. Answers come only from your documents and cite
the page or section they came from; if the documents don't say, the app says so, without calling the language model.

![An off-topic question answered with "I couldn't find an answer", with X-ray showing the relevance check that stopped the model being called](docs/images/talk-4-follow-up.png)

## A photo finds the page it shows

Photograph a figure, a screen or a nameplate: the app reads the text on it, finds the page whose picture looks like it,
and answers from that document. Typed words find photos too, by meaning, even ones nobody captioned.

![A photo of the Eventing debugger sent alone, answered with page 28 of Couchbase Under the Hood and the figure it matched](docs/images/photo-answer.png)

## One Couchbase Lite database does it all

Documents, chunks with their vectors, photos, chats, the vector indexes and the full-text index live in one Couchbase
Lite database on the iPad, queried with SQL++. The built-in database explorer and X-ray panel show every step.

![The database explorer running a full-text query over the chunks, with its result rows](docs/images/explorer-query.png)

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/ask-flow-dark.svg">
  <img src="docs/images/ask-flow-light.svg" width="960" alt="Asking a question, all on the iPad: a follow-up is rewritten as a standalone query and embedded; vector, keyword and words-to-photos searches run at once in one Couchbase Lite database, plus photo-to-photo with a photo; the results are merged by rank; if nothing is relevant the app says it couldn't find an answer without calling the model; otherwise Gemma 4 E2B answers from the retrieved chunks only, a citation check keeps only real citations, and the answer shows the page or section each part came from.">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/import-sync-flow-dark.svg">
  <img src="docs/images/import-sync-flow-light.svg" width="960" alt="Importing a document, on the iPad: the original is stored as a blob beside its JSON record and an indexing job is queued; text is extracted, with Apple's Vision reading scans and photos; the text is split into overlapping chunks; photos are read and written in one transaction; chunks are embedded and written 16 per transaction with their vectors; then the new chunk set is made searchable in one switch. With sync on, documents, chunks and images go to Sync Gateway with their vectors; chats, messages, the indexing queue and the indexes stay on the iPad.">
</picture>

Both models (EmbeddingGemma 2 for search, Gemma 4 E2B for answers) run on the iPad with LiteRT-LM. After they are
downloaded nothing needs the network. Sync between iPads is optional and talks only to your own Sync Gateway; questions,
answers and chats never leave the iPad. More in [How ManualBot works](docs/architecture.md).

## Run it

Requirements: Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); iPadOS 26
on M4/M5 iPads, or an iPad simulator.

```sh
xcodegen generate             # creates ManualBot.xcodeproj from project.yml
open ManualBot.xcodeproj      # run on an iPad simulator, landscape
```

On first launch the app downloads its two models (about 3 GB). **Reset demo** in the X-ray panel loads the sample
documents, two Couchbase whitepapers. To try the app without the models, add the launch arguments
`-uiTestModelStub happy -uiTestSeedDemo`: stand-in models and the sample documents over the real database.

## More

| | |
|---|---|
| [Using ManualBot](docs/using.md) | set up, models, sync, photos |
| [Demo](docs/demo.md) | X-ray, the database explorer, document contents, and the eight-step talk track |
| [How ManualBot works](docs/architecture.md) | the parts, the import and answer pipelines, what syncs |
| [Testing](docs/testing.md) | tests, model evaluations, regenerating these screenshots |
| [Local sync stack](sync/README.md) | Couchbase Server and Sync Gateway in Docker Compose |
