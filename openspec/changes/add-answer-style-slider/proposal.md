# Proposal

## Why

The app only answers from the user's documents, and the cutoff for what counts as relevant is fixed. A question about the assistant itself ("Sprichst du italienisch?") reached a best distance of 0.347 against a cutoff of 0.28, so the language model never ran and the user got "I couldn't find an answer". That's correct for a lookup tool, but it feels mute to someone used to chat assistants. Users who want a chattier or more forgiving assistant have no way to get one today.

## What Changes

- A new **Answer style** page in Settings with one slider. Along the slider are four named stops: **Strict**, **Balanced**, **Conversational** and **Open**. The page shows the current stop's name, the exact relevance distance (in steps of 0.01, adjustable within each stop) and a hint explaining what that position does.
- The slider's distance becomes the relevance cutoff for typed questions, replacing the fixed value for text. The image thresholds don't change.
- The stop decides what happens when nothing in the documents answers the question. This covers all three not-found cases: nothing relevant was retrieved, the model replied `NOT_FOUND`, or the answer had no valid citation.
  - **Strict / Balanced**: the not-found reply with the closest chunks, as today.
  - **Conversational**: a short reply from the model, written in the user's language, with no document text in its prompt. It may say what the app is and what it can do, but must not state facts. It's labelled "Not from your documents".
  - **Open**: an answer from the model's general knowledge, labelled "Not from your documents", with the closest chunks still listed below as suggestions.
- Replies not taken from the documents are stored with that label, so it survives relaunch.
- **Default is Balanced at the embedding model's tuned distance (0.28 for EmbeddingGemma 2).** That is exactly today's behaviour, so nothing changes until the user moves the slider.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `grounded-chat`: the requirements "Strictly grounded answers" and "Not-found response" now depend on the answer style. The change adds "Answer style setting", "Replies not from the documents" and "Content of replies not from the documents".

## Impact

- **Core**: `ChatService` takes the answer style per question. `Retriever.retrieve` takes the text distance cutoff per call. `PromptBuilder` gets the conversational and open prompts. A new `AnswerStyle` value type maps a distance to its stop.
- **Ports**: `MessageRecord` gains `fromDocuments` (defaults to `true`, and records stored before this change decode as `true`).
- **Adapters**: none in code. `CouchbaseDocumentRepository` stores messages as their Codable JSON, so the new field is persisted automatically; a round-trip test covers it. Messages are not replicated, so sync is unaffected.
- **App**: `AnswerSettings` (persisted in UserDefaults, like `SyncSettings`), the new Settings page, the label in `ChatView`, and passing the style to each question.
- **Evaluations**: retrieval and answer evaluations keep running at Balanced with the tuned distance, so their baselines stay valid.
- **Docs**: `docs/using.md` describes the setting.
