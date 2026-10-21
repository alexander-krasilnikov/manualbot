import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import ManualBot

@MainActor @Suite struct AnswerSettingsTests {
    private func suite() -> UserDefaults {
        let name = "answer-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func balancedAtTheTunedDistanceUntilTheUserMovesTheSlider() {
        let settings = AnswerSettings(defaults: suite())
        #expect(settings.offset == 0)
        #expect(settings.style.stop == .balanced)
        #expect(settings.distance == 0.28)
    }

    @Test func theStyleIsRememberedAcrossLaunches() {
        let defaults = suite()
        AnswerSettings(defaults: defaults).offset = 0.08
        let relaunched = AnswerSettings(defaults: defaults)
        #expect(relaunched.style.stop == .open)
        #expect(relaunched.distance == 0.36)
    }

    @Test func aStoredValueOutsideTheRangeIsClamped() {
        let defaults = suite()
        defaults.set(5.0, forKey: "answers.offset")
        #expect(AnswerSettings(defaults: defaults).offset == AnswerStyle.range.upperBound)
    }

    @Test func theDistanceFollowsTheEmbeddingModelsTunedOne() {
        let settings = AnswerSettings(defaults: suite())
        settings.offset = 0.02
        settings.tunedDistance = 0.66
        #expect(settings.distance == 0.68)
        settings.reset()
        #expect(settings.style == .balanced)
    }

    @Test func eachQuestionIsAskedWithTheCurrentStyle() async throws {
        let repo = InMemoryDocumentRepository()
        let embedder = FakeEmbedder()
        let search = FakeChunkSearch()
        let ingestion = IngestionService(
            extractor: FakeExtractor(results: [:]), embedder: embedder, repository: repo, jobs: repo, supportedType: { _ in .text })
        let model = ChatViewModel(chats: repo, documents: repo, ingestion: ingestion)
        let chunk = Chunk(docId: "doc", generation: 1, ordinal: 0, page: 3, text: "Hold the button for ten seconds.",
                          embedding: [], embeddingModel: embedder.identity.tag)
        search.vectorHits = [ScoredChunk(chunk: chunk, score: 0.95)]
        try await repo.upsert(DocumentRecord(id: "doc", title: "Manual", type: .pdf, activeGeneration: 1))
        let generator = ScriptedGenerator { _ in ["I answer questions about your manuals."] }
        model.attach(ChatService(chats: repo, retriever: Retriever(embedder: embedder, search: search, repository: repo), generator: generator))
        model.updateDocuments([.init(id: "doc", title: "Manual", type: .pdf, pageCount: 3, importedAt: Date(), status: .ready)])
        let answers = AnswerSettings(defaults: suite())
        model.answers = answers

        model.draft = "Sprichst du italienisch?"
        await model.send()
        #expect(model.messages.last?.notFound == true, "Balanced: the not-found reply")
        #expect(generator.callCount == 0)

        answers.offset = 0.04
        model.draft = "Und Englisch?"
        await model.send()
        #expect(generator.requests.last?.system == PromptBuilder.conversationalSystemPrompt)
        #expect(model.messages.last?.fromDocuments == false)
        #expect(model.messages.last?.text == "I answer questions about your manuals.")
    }
}
