import Foundation
import Ports
import PortsTesting
import Synchronization
import Testing
@testable import Core

// MARK: - Fixtures

private func chunk(_ n: Int, doc: String = "Manual A", page: Int? = 42, heading: String? = nil, text: String) -> RetrievedChunk {
    RetrievedChunk(
        chunk: Chunk(docId: "doc-\(n)", generation: 1, ordinal: n, page: page, heading: heading, text: text,
                     embedding: [], embeddingModel: "m"),
        documentTitle: doc, distance: 0.2, keywordRank: nil, fusedScore: 0.03)
}

// MARK: - 7.3 Prompt building

@Suite struct PromptBuilderTests {
    @Test func answerPromptNumbersChunksAndAsksTheQuestion() {
        let prompt = PromptBuilder.answerPrompt(question: "How do I reset the X200?", chunks: [
            chunk(1, doc: "Manual A", page: 42, heading: "Reset", text: "Hold the button for 10 seconds."),
            chunk(2, doc: "Guide B", page: nil, heading: "Maintenance", text: "Replace the filter yearly."),
            chunk(3, doc: "Notes", page: 7, heading: nil, text: "Error E-042 means overheating."),
        ])
        #expect(prompt == """
            Chunks:
            [1] (Manual A, page 42, section “Reset”) Hold the button for 10 seconds.
            [2] (Guide B, section “Maintenance”) Replace the filter yearly.
            [3] (Notes, page 7) Error E-042 means overheating.

            Question: How do I reset the X200?
            """)
    }

    @Test func systemPromptEnforcesTheStrictRules() {
        let system = PromptBuilder.answerSystemPrompt
        #expect(system.contains("ONLY the numbered chunks"))
        #expect(system.contains("Never use outside knowledge"))
        #expect(system.contains("reply with exactly: NOT_FOUND"))
        #expect(system.contains("[1]"))
    }

    @Test func rewritePromptIncludesConversationAndShortensLongAnswers() {
        let long = String(repeating: "word ", count: 200)
        let prompt = PromptBuilder.rewritePrompt(question: "What about the X100?", history: [
            (.user, "How do I reset the X200?"), (.assistant, long),
        ])
        #expect(prompt.hasPrefix("Conversation:\nUser: How do I reset the X200?\nAssistant: word word"))
        #expect(prompt.contains("…\n"))
        #expect(prompt.hasSuffix("Last question: What about the X100?\n\nStandalone query:"))
        #expect(prompt.count < 700)
    }

    @Test func promptsWithoutDocumentsCarryNoChunksOrCitationRules() {
        for system in [PromptBuilder.conversationalSystemPrompt, PromptBuilder.openSystemPrompt] {
            #expect(!system.contains("Chunks:") && !system.contains("[1]") && !system.contains(PromptBuilder.notFoundMarker))
            #expect(system.contains("same language"))
        }
        #expect(PromptBuilder.conversationalSystemPrompt.contains("at most two short sentences"))
        #expect(PromptBuilder.conversationalSystemPrompt.contains("Never state facts"))
        #expect(PromptBuilder.fallbackPrompt(question: "Sprichst du italienisch?") == "Sprichst du italienisch?")
    }
}

// MARK: - 7.5 Citation validation

@Suite struct CitationValidatorTests {
    @Test func validMarkersAreKeptInOrderOfFirstUse() {
        let r = CitationValidator.validate("Hold the button [2]. Then wait [1][2].", chunkCount: 3)
        #expect(r.text == "Hold the button [2]. Then wait [1][2].")
        #expect(r.cited == [2, 1])
        #expect(r.isGrounded)
    }

    @Test func inventedMarkersAreRemoved() {
        let r = CitationValidator.validate("Hold it [1]. Also do this [7] and that [0].", chunkCount: 3)
        #expect(r.text == "Hold it [1]. Also do this and that.")
        #expect(r.cited == [1])
    }

    @Test func anAnswerWithOnlyInventedCitationsIsNotGrounded() {
        let r = CitationValidator.validate("Do this [9].", chunkCount: 2)
        #expect(!r.isGrounded)
        #expect(r.text == "Do this.")
    }

    @Test func anAnswerWithoutCitationsIsNotGrounded() {
        let r = CitationValidator.validate("Just trust me.", chunkCount: 4)
        #expect(!r.isGrounded)
        #expect(r.cited.isEmpty)
    }

    @Test func groupedMarkersAreNormalizedAndFiltered() {
        let r = CitationValidator.validate("Both apply [1, 3] and [2; 9].", chunkCount: 3)
        #expect(r.text == "Both apply [1][3] and [2].")
        #expect(r.cited == [1, 3, 2])
    }

    @Test func nothingIsValidWhenThereAreNoChunks() {
        let r = CitationValidator.validate("Claim [1].", chunkCount: 0)
        #expect(!r.isGrounded)
        #expect(r.text == "Claim.")
    }

    @Test func ordinaryBracketsAreLeftAlone() {
        let r = CitationValidator.validate("Use array[i] and [note] see [1].", chunkCount: 1)
        #expect(r.text == "Use array[i] and [note] see [1].")
        #expect(r.cited == [1])
    }

    @Test func duplicateMarkersInOneGroupCountOnce() {
        let r = CitationValidator.validate("Fact [1,1,2].", chunkCount: 2)
        #expect(r.text == "Fact [1][2].")
        #expect(r.cited == [1, 2])
    }
}

// MARK: - 7.2 Follow-up rewriting

@Suite struct QueryRewriterTests {
    private func history(_ pairs: [(String, String)]) -> [MessageRecord] {
        var result: [MessageRecord] = []
        for (i, pair) in pairs.enumerated() {
            let t = Date(timeIntervalSince1970: Double(i) * 10)
            result.append(MessageRecord(id: "u\(i)", chatId: "c", role: .user, text: pair.0, createdAt: t))
            result.append(MessageRecord(id: "a\(i)", chatId: "c", role: .assistant, text: pair.1, createdAt: t.addingTimeInterval(1)))
        }
        return result
    }

    @Test func firstQuestionIsUsedAsIsWithoutCallingTheModel() async {
        let generator = ScriptedGenerator(fragments: ["should not be used"])
        let query = await QueryRewriter(generator: generator).standaloneQuery(for: "How do I reset the X200?", history: [])
        #expect(query == "How do I reset the X200?")
        #expect(generator.callCount == 0)
    }

    @Test func aPronounFollowUpBecomesStandalone() async {
        let generator = ScriptedGenerator { request in
            request.prompt.contains("X200") ? ["How do I reset the X100?"] : ["wrong"]
        }
        let query = await QueryRewriter(generator: generator).standaloneQuery(
            for: "What about the X100?", history: history([("How do I reset the X200?", "Hold the button for 10 s [1].")]))
        #expect(query == "How do I reset the X100?")
        let request = generator.requests[0]
        #expect(request.maxTokens == 64 && request.temperature == 0)
        #expect(request.system == PromptBuilder.rewriteSystemPrompt)
    }

    @Test func onlyTheLastThreeExchangesAreSent() async {
        let generator = ScriptedGenerator(fragments: ["q"])
        let turns = (1...5).map { ("question \($0)", "answer \($0)") }
        _ = await QueryRewriter(generator: generator).standaloneQuery(for: "next?", history: history(turns))
        let prompt = generator.requests[0].prompt
        #expect(!prompt.contains("question 2") && prompt.contains("question 3") && prompt.contains("answer 5"))
    }

    @Test func modelDecorationIsStripped() {
        #expect(QueryRewriter.clean("Standalone query: \"reset the X100\"\nExplanation...") == "reset the X100")
        #expect(QueryRewriter.clean("  “reset the X100”  ") == "reset the X100")
        #expect(QueryRewriter.clean("\n\n  first line  \nsecond") == "first line")
    }

    @Test func unusableRewritesFallBackToTheOriginalQuestion() async {
        for output in [[""], ["   \n"], [String(repeating: "x", count: 400)]] {
            let generator = ScriptedGenerator(fragments: output)
            let query = await QueryRewriter(generator: generator).standaloneQuery(for: "and the X100?", history: history([("a", "b")]))
            #expect(query == "and the X100?")
        }
    }

    @Test func aFailingModelFallsBackToTheOriginalQuestion() async {
        struct Boom: Generator {
            func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish(throwing: URLError(.badServerResponse)) }
            }
        }
        let query = await QueryRewriter(generator: Boom()).standaloneQuery(for: "and the X100?", history: history([("a", "b")]))
        #expect(query == "and the X100?")
    }
}

// MARK: - 7.4 ChatService

/// Records the texts it embeds, so tests can see which query retrieval used.
private final class SpyEmbedder: Embedder {
    let base = FakeEmbedder()
    var identity: EmbeddingModelIdentity { base.identity }
    private let queries = Mutex<[String]>([])
    var embeddedQueries: [String] { queries.withLock { $0 } }
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        if case .query = kind { queries.withLock { $0.append(contentsOf: texts) } }
        return try await base.embed(texts, kind: kind)
    }
}

private struct Harness {
    let repo = InMemoryDocumentRepository()
    let search = FakeChunkSearch()
    let embedder = SpyEmbedder()
    let generator: ScriptedGenerator
    let service: ChatService
    let chatID: String

    init(
        answer: [String], relevantDistance: Double? = 0.2, pinned: [String] = [], maxAnswerTokens: Int = 512,
        tracer: any Tracer = NoTracer(), withoutDocuments: [String] = ["I answer questions about your manuals."]
    ) async throws {
        generator = ScriptedGenerator { request in
            if request.maxTokens == 64 { return ["What about the X100 reset?"] }
            let fallback = [PromptBuilder.conversationalSystemPrompt, PromptBuilder.openSystemPrompt].contains(request.system)
            return fallback ? withoutDocuments : answer
        }
        let modelTag = embedder.identity.tag
        func chunk(_ n: Int, _ text: String) -> Chunk {
            Chunk(docId: "doc", generation: 1, ordinal: n, page: 40 + n, heading: "Reset", text: text,
                  embedding: [Float](repeating: 0, count: 32), embeddingModel: modelTag)
        }
        if let relevantDistance {
            search.vectorHits = [
                ScoredChunk(chunk: chunk(0, "Hold the button for ten seconds."), score: relevantDistance),
                ScoredChunk(chunk: chunk(1, "Release it when the light blinks."), score: relevantDistance + 0.05),
            ]
        } else {
            search.vectorHits = [ScoredChunk(chunk: chunk(0, "Unrelated text."), score: 0.95)]
        }
        try await repo.upsert(DocumentRecord(id: "doc", title: "Manual A", type: .pdf, activeGeneration: 1))
        let retriever = Retriever(embedder: embedder, search: search, repository: repo, tracer: tracer)
        service = ChatService(
            chats: repo, retriever: retriever, generator: generator, maxAnswerTokens: maxAnswerTokens, tracer: tracer)
        chatID = try await repo.createChat(pinnedDocIds: pinned).id
    }

    func ask(_ question: String, style: AnswerStyle = .balanced) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in service.ask(question, in: chatID, style: style) { events.append(event) }
        return events
    }

    func reply(_ events: [ChatEvent]) -> MessageRecord? {
        events.compactMap { if case .completed(let m) = $0 { m } else { nil } }.last
    }

    func text(_ events: [ChatEvent]) -> String {
        events.compactMap { if case .delta(let d) = $0 { d } else { nil } }.joined()
    }
}

@Suite struct ChatServiceTests {
    @Test func answersFromChunksWithValidatedCitations() async throws {
        let h = try await Harness(answer: ["Hold the button ", "for ten seconds [1]. ", "Release when it blinks [2][5]."])
        let events = try await h.ask("How do I reset it?")

        let reply = try #require(h.reply(events))
        #expect(reply.role == .assistant && !reply.notFound && !reply.stopped)
        #expect(reply.text == "Hold the button for ten seconds [1]. Release when it blinks [2].")  // [5] was invented
        #expect(reply.citations.map(\.n) == [1, 2])
        #expect(reply.citations[0].docTitle == "Manual A" && reply.citations[0].page == 40)
        #expect(reply.citations[0].snippet == "Hold the button for ten seconds.")
        #expect(reply.standaloneQuery == "How do I reset it?")

        // Order: query first, then text, then the saved reply.
        #expect(events.first == .query("How do I reset it?"))
        #expect(h.text(events).hasPrefix("Hold the button for ten seconds [1]."))
        if case .completed = events.last {} else { Issue.record("completed must be last") }

        // Both messages are stored, question first.
        let stored = try await h.repo.messages(chatId: h.chatID)
        #expect(stored.map(\.role) == [.user, .assistant])
        #expect(stored[0].text == "How do I reset it?")
        #expect(stored[1] == reply)
    }

    @Test func irrelevantQuestionsNeverReachTheModel() async throws {
        let h = try await Harness(answer: ["should never be generated"], relevantDistance: nil)
        let events = try await h.ask("What is the capital of France?")

        #expect(h.generator.callCount == 0, "no rewrite either, since this is the first question")
        let reply = try #require(h.reply(events))
        #expect(reply.notFound)
        #expect(reply.text == ChatService.notFoundWithSuggestionsText)
        #expect(reply.citations.count == 1 && reply.citations[0].snippet == "Unrelated text.")
        #expect(h.text(events).isEmpty)
    }

    @Test func aNotFoundMarkerFromTheModelBecomesTheNotFoundReply() async throws {
        let h = try await Harness(answer: ["NOT_", "FOUND"])
        let events = try await h.ask("Something unanswerable")
        let reply = try #require(h.reply(events))
        #expect(reply.notFound)
        #expect(!h.text(events).contains("NOT_"), "the marker must never be streamed to the user")
        #expect(!reply.text.contains("NOT_FOUND"))
        #expect(h.generator.callCount == 1)
    }

    @Test func textThatOnlyStartsLikeTheMarkerIsStillShown() async throws {
        let h = try await Harness(answer: ["NOT ", "all steps apply [1]."])
        let events = try await h.ask("Which steps?")
        #expect(h.text(events).hasPrefix("NOT all steps"))
        #expect(h.reply(events)?.notFound == false)
    }

    @Test func anAnswerWithOnlyInventedCitationsBecomesNotFound() async throws {
        let h = try await Harness(answer: ["It is definitely so [9]."])
        let reply = try #require(h.reply(try await h.ask("Is it so?")))
        #expect(reply.notFound)
        #expect(!reply.text.contains("definitely"))
    }

    @Test func anAnswerWithNoCitationsBecomesNotFound() async throws {
        let h = try await Harness(answer: ["Sure, trust me."])
        #expect(try #require(h.reply(try await h.ask("Well?"))).notFound)
    }

    @Test func followUpsAreRewrittenBeforeRetrieval() async throws {
        let h = try await Harness(answer: ["Hold it [1]."])
        _ = try await h.ask("How do I reset the X200?")
        let events = try await h.ask("What about the X100?")

        #expect(events.first == .query("What about the X100 reset?"))
        #expect(h.embedder.embeddedQueries == ["How do I reset the X200?", "What about the X100 reset?"])
        #expect(try #require(h.reply(events)).standaloneQuery == "What about the X100 reset?")
        #expect(h.generator.requests.filter { $0.maxTokens == 64 }.count == 1, "only the second question needs a rewrite")
    }

    @Test func pinnedDocumentsScopeTheSearch() async throws {
        let pinned = try await Harness(answer: ["x [1]"], pinned: ["doc", "other"])
        _ = try await pinned.ask("q")
        #expect(pinned.search.filters.map(\.documentIDs) == [["doc", "other"]])

        let unpinned = try await Harness(answer: ["x [1]"])
        _ = try await unpinned.ask("q")
        #expect(unpinned.search.filters.map(\.documentIDs) == [nil])
    }

    @Test func stoppingKeepsThePartialAnswerMarkedAsStopped() async throws {
        let long = ["Step one is to hold [1]. "] + Array(repeating: "and keep going ", count: 5_000)
        let h = try await Harness(answer: long)
        for try await event in h.service.ask("How?", in: h.chatID) {
            if case .delta = event { break }  // the user taps stop
        }
        var stored: [MessageRecord] = []
        for _ in 0..<400 where stored.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
            stored = try await h.repo.messages(chatId: h.chatID)
        }
        let reply = try #require(stored.last)
        #expect(reply.role == .assistant && reply.stopped)
        #expect(!reply.notFound)
        #expect(reply.text.hasPrefix("Step one is to hold [1]."))
        #expect(reply.text.count < 5_000 * 15, "generation should have stopped early")
        #expect(reply.citations.map(\.n) == [1], "citations of the partial answer are validated")
        while h.generator.cancellationCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.generator.cancellationCount == 1)
    }

    @Test func stoppingBeforeAnyTextSavesNoReply() async throws {
        let h = try await Harness(answer: Array(repeating: "x", count: 100))
        let task = Task { for try await _ in h.service.ask("q", in: h.chatID) {} }
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(100))
        let stored = try await h.repo.messages(chatId: h.chatID)
        #expect(stored.allSatisfy { $0.role == .user || !$0.text.isEmpty })
    }

    @Test func aGeneratorErrorKeepsWhatWasProducedAndThrows() async throws {
        struct Failing: Generator {
            func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { c in
                    c.yield("Partial fact [1]. ")
                    c.finish(throwing: URLError(.cannotConnectToHost))
                }
            }
        }
        let repo = InMemoryDocumentRepository()
        let harness = try await Harness(answer: [])
        let service = ChatService(
            chats: harness.repo, retriever: Retriever(embedder: harness.embedder, search: harness.search, repository: harness.repo),
            generator: Failing())
        _ = repo
        var thrown: Error?
        do { for try await _ in service.ask("q", in: harness.chatID) {} } catch { thrown = error }
        #expect(thrown is URLError)
        let stored = try await harness.repo.messages(chatId: harness.chatID)
        #expect(stored.last?.stopped == true)
        #expect(stored.last?.text == "Partial fact [1].")
    }

    @Test func emptyQuestionsAndUnknownChatsAreRejected() async throws {
        let h = try await Harness(answer: ["x [1]"])
        await #expect(throws: ChatError.emptyQuestion) { for try await _ in h.service.ask("   \n", in: h.chatID) {} }
        await #expect(throws: ChatError.chatNotFound("nope")) { for try await _ in h.service.ask("q", in: "nope") {} }
        #expect(try await h.repo.messages(chatId: h.chatID).isEmpty)
    }

    @Test func theFirstQuestionTitlesAnUntitledChat() async throws {
        let h = try await Harness(answer: ["x [1]"])
        _ = try await h.ask("How do I reset the X200 to factory defaults after a firmware update?")
        let title = try await h.repo.chat(id: h.chatID)?.title
        #expect(title == "How do I reset the X200 to factory defau…")
        _ = try await h.ask("Another question")
        #expect(try await h.repo.chat(id: h.chatID)?.title == title, "later questions leave the title alone")
    }

    @Test func replyAlwaysSortsAfterItsQuestion() async throws {
        let h = try await Harness(answer: ["x [1]"])
        for _ in 0..<20 { _ = try await h.ask("q") }
        let roles = try await h.repo.messages(chatId: h.chatID).map(\.role)
        #expect(roles == Array(repeating: [MessageRole.user, .assistant], count: 20).flatMap { $0 })
    }
}

// MARK: - Tracing

@Suite struct ChatTraceTests {
    private func generation(_ tracer: RecordingTracer) -> TraceEvent? {
        tracer.events.first { if case .generation = $0.kind { true } else { false } }
    }

    @Test func anAnsweredQuestionIsOneGroupWithEmbeddingFusionRelevanceAndModelTiming() async throws {
        let tracer = RecordingTracer()
        let h = try await Harness(answer: ["Hold the button [1]."], tracer: tracer)
        _ = try await h.ask("How do I reset it?")

        let operations = Set(tracer.events.compactMap(\.operation))
        #expect(operations.count == 1)
        let operation = try #require(operations.first)
        #expect(operation.kind == .ask && operation.title == "How do I reset it?")
        #expect(tracer.events.allSatisfy { $0.operation == operation })

        let names = tracer.kinds.map { kind -> String in
            switch kind {
            case .queryEmbedded: "embedded"
            case .fusion: "fusion"
            case .relevance: "relevance"
            case .generation: "generation"
            default: "other"
            }
        }
        #expect(names == ["embedded", "fusion", "relevance", "generation"])
        let event = try #require(generation(tracer))
        guard case .generation(let firstToken, let skipped) = event.kind else { return }
        #expect(!skipped)
        #expect(firstToken != nil)
        #expect((event.duration ?? 0) >= (firstToken ?? 1))
    }

    @Test func anOffTopicQuestionRecordsThatTheModelWasNotCalled() async throws {
        let tracer = RecordingTracer()
        let h = try await Harness(answer: ["never"], relevantDistance: nil, tracer: tracer)
        _ = try await h.ask("What is the meaning of life?")

        #expect(generation(tracer)?.kind == .generation(firstToken: nil, skipped: true))
        let relevance = tracer.kinds.compactMap { kind -> RelevanceOutcome? in
            if case .relevance(_, _, let outcome, _, _) = kind { return outcome } else { return nil }
        }
        #expect(relevance == [.failed])
        #expect(tracer.events.allSatisfy { $0.operation?.kind == .ask })
        #expect(h.generator.callCount == 0)
    }

    @Test func aFollowUpShowsTheOriginalAndTheStandaloneQuery() async throws {
        let tracer = RecordingTracer()
        let h = try await Harness(answer: ["Hold the button [1]."], tracer: tracer)
        _ = try await h.ask("How do I reset the X200?")
        #expect(!tracer.kinds.contains { if case .queryRewritten = $0 { true } else { false } },
                "a first question has nothing to rewrite")
        _ = try await h.ask("And the X100?")
        #expect(tracer.kinds.contains(.queryRewritten(original: "And the X100?", standalone: "What about the X100 reset?")))
    }

    @Test func eachQuestionIsItsOwnOperation() async throws {
        let tracer = RecordingTracer()
        let h = try await Harness(answer: ["Hold the button [1]."], tracer: tracer)
        _ = try await h.ask("First question")
        _ = try await h.ask("Second question")
        let titles = tracer.events.compactMap(\.operation).reduce(into: [String]()) { if !$0.contains($1.title) { $0.append($1.title) } }
        #expect(titles == ["First question", "Second question"])
        #expect(Set(tracer.events.compactMap { $0.operation?.id }).count == 2)
    }

    @Test func tracingDoesNotChangeTheReply() async throws {
        let plain = try await Harness(answer: ["Hold the button [1]. Then wait [2]."])
        let traced = try await Harness(answer: ["Hold the button [1]. Then wait [2]."], tracer: RecordingTracer())
        let a = try #require(plain.reply(try await plain.ask("How do I reset it?")))
        let b = try #require(traced.reply(try await traced.ask("How do I reset it?")))
        #expect(a.text == b.text)
        #expect(a.citations == b.citations)
        #expect(a.notFound == b.notFound)
    }
}

// MARK: - Answer styles

@Suite struct AnswerStyleChatTests {
    private let strict = AnswerStyle(offset: -0.06)
    private let conversational = AnswerStyle(offset: 0.04)
    private let open = AnswerStyle(offset: 0.08)

    @Test func strictAndBalancedNeverAskTheModelWhenNothingIsRelevant() async throws {
        for style in [strict, AnswerStyle.balanced] {
            let h = try await Harness(answer: ["never"], relevantDistance: nil)
            let reply = try #require(h.reply(try await h.ask("Sprichst du italienisch?", style: style)))
            #expect(reply.notFound && reply.fromDocuments)
            #expect(h.generator.callCount == 0)
        }
    }

    @Test func theCutoffFollowsTheStyle() async throws {
        // 0.27 passes the tuned 0.28 but not Strict's 0.22.
        let balanced = try await Harness(answer: ["Hold it [1]."], relevantDistance: 0.27)
        #expect(try #require(balanced.reply(try await balanced.ask("reset?"))).notFound == false)
        let strictHarness = try await Harness(answer: ["Hold it [1]."], relevantDistance: 0.27)
        #expect(try #require(strictHarness.reply(try await strictHarness.ask("reset?", style: strict))).notFound)
        #expect(strictHarness.generator.callCount == 0)
    }

    @Test func conversationalRepliesBrieflyWithoutTheDocuments() async throws {
        let h = try await Harness(answer: ["never"], relevantDistance: nil, withoutDocuments: ["Ich beantworte ", "Fragen zu deinen Handbüchern."])
        let events = try await h.ask("Sprichst du italienisch?", style: conversational)

        #expect(h.generator.callCount == 1)
        let request = try #require(h.generator.requests.first)
        #expect(request.system == PromptBuilder.conversationalSystemPrompt)
        #expect(request.prompt == "Sprichst du italienisch?" && !request.prompt.contains("Unrelated text."))
        #expect(request.maxTokens == 96)
        let reply = try #require(h.reply(events))
        #expect(reply.text == "Ich beantworte Fragen zu deinen Handbüchern.")
        #expect(!reply.fromDocuments && !reply.notFound && reply.citations.isEmpty)
        #expect(h.text(events) == reply.text)
        #expect(try await h.repo.messages(chatId: h.chatID).last == reply)
    }

    @Test func openAnswersAfterANotFoundMarkerAndListsTheClosestChunks() async throws {
        let h = try await Harness(answer: ["NOT_FOUND"], withoutDocuments: ["Rome is the capital of Italy."])
        let reply = try #require(h.reply(try await h.ask("What is the capital of Italy?", style: open)))

        #expect(h.generator.requests.map(\.system) == [PromptBuilder.answerSystemPrompt, PromptBuilder.openSystemPrompt])
        #expect(h.generator.requests[1].maxTokens == 512)
        #expect(reply.text == "Rome is the capital of Italy." && !reply.fromDocuments && !reply.notFound)
        #expect(reply.citations.map(\.snippet) == ["Hold the button for ten seconds.", "Release it when the light blinks."])
    }

    @Test func openDiscardsAnUncitedAnswerAndRestartsTheStream() async throws {
        let h = try await Harness(answer: ["Sure, trust me."], withoutDocuments: ["From general knowledge: yes."])
        let events = try await h.ask("Well?", style: open)
        let reply = try #require(h.reply(events))
        #expect(reply.text == "From general knowledge: yes." && !reply.fromDocuments)
        let restart = try #require(events.firstIndex(of: .restart))
        #expect(events[..<restart].contains(.delta("Sure, trust me.")), "the uncited answer streamed first")
        #expect(events[restart...].contains(.delta("From general knowledge: yes.")))
    }

    @Test func aRelevantQuestionUnderOpenIsAnsweredFromTheDocuments() async throws {
        let h = try await Harness(answer: ["Hold the button [1]."])
        let reply = try #require(h.reply(try await h.ask("How do I reset it?", style: open)))
        #expect(reply.fromDocuments && reply.citations.map(\.n) == [1])
        #expect(h.generator.callCount == 1)
    }

    @Test func markersInAReplyWithoutDocumentsAreRemoved() async throws {
        let h = try await Harness(answer: ["never"], relevantDistance: nil, withoutDocuments: ["Probably yes [1]."])
        let reply = try #require(h.reply(try await h.ask("Is it so?", style: open)))
        #expect(reply.text == "Probably yes.")
    }

    @Test func aFailingReplyWithoutDocumentsGivesTheNotFoundReply() async throws {
        struct Failing: Generator {
            func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish(throwing: URLError(.cannotConnectToHost)) }
            }
        }
        let h = try await Harness(answer: [], relevantDistance: nil)
        let service = ChatService(
            chats: h.repo, retriever: Retriever(embedder: h.embedder, search: h.search, repository: h.repo), generator: Failing())
        var reply: MessageRecord?
        for try await event in service.ask("Hallo?", in: h.chatID, style: conversational) {
            if case .completed(let m) = event { reply = m }
        }
        #expect(reply?.notFound == true && reply?.fromDocuments == true)
    }

    @Test func anEmptyReplyWithoutDocumentsGivesTheNotFoundReply() async throws {
        let h = try await Harness(answer: [], relevantDistance: nil, withoutDocuments: ["  "])
        #expect(try #require(h.reply(try await h.ask("Hallo?", style: conversational))).notFound)
    }
}

