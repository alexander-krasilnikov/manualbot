# Design

## Context

- The text relevance cutoff is `RetrievalConfiguration.maxDistance`. It comes from the embedding model's `EmbedderProfile.thresholds.text` (0.28 for EmbeddingGemma 2; untested models get the same default). It is set once, when `Services` builds the `Retriever`.
- `ChatService` is built once per language model (`AppModel` → `Services.makeChat`) and holds no per-question options. It has three not-found exits, all ending in `finish(notFound:)`: nothing relevant retrieved (the model is never run), the model replied `NOT_FOUND`, or the answer had no valid citation.
- Settings follow the `SyncSettings` pattern: an `@MainActor @Observable` class backed by `UserDefaults`, owned by `AppModel`, and shown on a page pushed from `SettingsView`.
- `MessageRecord` is Codable, and the repository stores it as JSON, so a new field with a `decodeIfPresent` default is backward compatible.
- The answer evaluation (`AnswerEvalRunner`) builds its own `ChatService` with defaults.

## Goals / Non-Goals

**Goals:**
- One continuous control. The stop is derived from the distance, never stored separately.
- The default reproduces today's behaviour exactly.
- The setting applies to the next question without rebuilding services.

**Non-Goals:**
- Changing the image distance thresholds or the identifier pass of the relevance gate.
- Per-chat styles. The setting is app-wide.
- Re-tuning the cutoff. That belongs to the answer-quality work.

## Decisions

### D1. The slider's value is an offset from the model's tuned distance

The slider runs from the tuned distance `t` − 0.06 to `t` + 0.10, in steps of 0.01. The page shows the absolute distance (`t` + offset). What's stored is the **offset**, so switching to an embedding model with a different scale keeps the same meaning: Balanced stays at that model's tuned point. The stops are fixed ranges of offset:

| Stop | Offset | For EmbeddingGemma 2 (`t` = 0.28) | When nothing answers |
|---|---|---|---|
| Strict | −0.06 … −0.03 | 0.22 … 0.25 | not-found, model not run |
| Balanced | −0.02 … +0.02 | 0.26 … 0.30 (default 0.28) | not-found, model not run |
| Conversational | +0.03 … +0.06 | 0.31 … 0.34 | short reply, labelled |
| Open | +0.07 … +0.10 | 0.35 … 0.38 | general-knowledge answer, labelled |

A stop's ranges are inclusive of its own steps, and every 0.01 step belongs to exactly one stop. Strict and Balanced behave the same way apart from the cutoff; Strict is the end for users who want fewer, surer answers.

Alternative: storing an absolute distance. Rejected, because a model switch would leave a value tuned for another scale. The proposal noted 0.66 versus 0.28 between models.

Alternative: storing the stop and the distance separately. Rejected, because the two could disagree. The stop follows from the distance by construction.

### D2. `AnswerStyle` lives in Core and is passed per question

`AnswerStyle` is a `Sendable` struct with `offset` and a computed `stop` (an enum with the four cases), plus `maxDistance(tuned:)`. `ChatService.ask(_:in:photo:style:)` gains a `style` parameter that defaults to `.balanced` (offset 0), so existing callers and the evaluation are unchanged. `Retriever.retrieve` gains `maxDistance: Double? = nil`, which overrides `configuration.maxDistance` for that call only. `ChatViewModel` reads `AnswerSettings.style` when it sends each question.

Alternative: rebuilding the `Retriever` and `ChatService` when the setting changes. Rejected: it's heavier, it races with an answer in progress, and it's unnecessary.

### D3. One fallback path for all three not-found exits

`finish(notFound:)` becomes `finishWithoutAnswer(...)`, which checks the style. Strict and Balanced keep today's reply. Conversational and Open make one more generation request:

- **Conversational**: `PromptBuilder.conversationalSystemPrompt`. It says the assistant is ManualBot, an offline helper for the user's manuals; nothing in the manuals matched the question; it should reply in at most two sentences in the user's language; it may say what it is, what it can do, and suggest rephrasing; and it must not state facts about the world or the documents. The request uses `maxTokens` 96 and temperature 0.3.
- **Open**: `PromptBuilder.openSystemPrompt`. It says to answer concisely from general knowledge, in the user's language, and to say plainly when unsure. The request uses `maxTokens` 512 and the usual temperature.
- The prompt is only the question (the standalone query). Chunks are never included, so nothing from them can be passed off as cited.
- Both stream through the same `NotFoundGate`-free path, and both are saved with `fromDocuments: false`, no citations and `notFound: false`. Open also attaches `retrieval.closest()` as suggestions. Conversational doesn't, to keep it short.
- If the fallback request fails or returns empty text, the reply falls back to the Strict not-found response, so the user is never left with nothing.

For exits B and C (`NOT_FOUND`, uncited), this means a second generation after the first. It costs a few hundred milliseconds on Gemma 4 E2B, and the log lines from `Diagnostics.chat` show it as its own step.

Alternative: under Open, showing the uncited answer from exit C as is. Rejected: it was generated from chunks but cites none, so it would read as grounded when it isn't.

### D4. `MessageRecord.fromDocuments`

The new field defaults to `true` and decodes as `true` when absent. `ChatView` shows a "Not from your documents" caption, in secondary style with an SF Symbol (`globe` for Open, `bubble.left` for Conversational, both labelled), above a reply where it is `false`. Suggestions for Open use the existing "Closest chunks" section.

### D5. The Settings page

The `SettingsPage.answers` page is reached from an "Answer style" row whose detail is the current stop's name. The page contains:

- A heading with the stop's name and the distance in a monospaced font (for example "Balanced · 0.28").
- `Slider(value: offset, in: -0.06...0.10, step: 0.01)`, with the four stop names in a row beneath, each placed under its range and the current one emphasised. VoiceOver's value reads "Balanced, distance 0.28".
- One hint paragraph per stop, saying what the cutoff does and what happens when nothing answers. For Open it adds that the replies can be wrong.
- "Reset to Balanced" sets the offset to 0.

`AnswerSettings` (App) stores the offset under `answers.offset` in `UserDefaults`, clamped to the range when read.

## Risks / Trade-offs

- [Open lets a 2B offline model state wrong facts confidently] → It's opt-in, at the end of the slider, with a hint that says so and a label on every such reply.
- [Conversational may still state facts despite the prompt] → The prompt forbids it, `maxTokens` is 96, and the label still applies. The behaviour is checked in the real-stack test (task 4.3).
- [A looser cutoff sends weaker chunks to the model, so more `NOT_FOUND` replies] → Under Conversational and Open those turn into the labelled reply. Under Balanced the range is narrow (±0.02).
- [A second generation adds latency for exits B and C] → It's measured and logged. It only happens under the two talkative stops.

## Migration Plan

There's nothing to migrate. Existing messages decode with `fromDocuments = true`, and the default setting is today's behaviour. To roll back, revert the change; messages stored with the new field decode fine in the old build, which ignores unknown keys.
