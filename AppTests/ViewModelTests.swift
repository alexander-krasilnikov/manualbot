import Adapters
import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import ManualBot

@MainActor private func eventually(_ timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vm-tests-\(UUID().uuidString)")

private func file(_ name: String, _ text: String) throws -> URL {
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let url = scratch.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: - Library

@MainActor @Suite struct LibraryViewModelTests {
    private func make() -> (LibraryViewModel, InMemoryDocumentRepository, IngestionService) {
        let repo = InMemoryDocumentRepository()
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: FakeEmbedder(), repository: repo, jobs: repo,
            supportedType: FileDocumentExtractor.documentType(for:))
        return (LibraryViewModel(documents: repo, jobs: repo, ingestion: ingestion), repo, ingestion)
    }

    @Test func statusReflectsTheJobUnlessAnOlderVersionIsStillSearchable() {
        let fresh = DocumentRecord(id: "d", title: "T", type: .pdf)
        let indexed = DocumentRecord(id: "d", title: "T", type: .pdf, activeGeneration: 1)
        func job(_ s: IngestState, _ p: Double = 0.5, error: String? = nil) -> IngestJobRecord {
            IngestJobRecord(docId: "d", targetGeneration: 1, state: s, progress: p, error: error)
        }
        #expect(LibraryViewModel.status(of: fresh, job: nil) == .queued)
        #expect(LibraryViewModel.status(of: fresh, job: job(.queued)) == .queued)
        #expect(LibraryViewModel.status(of: fresh, job: job(.embedding)) == .embedding(0.5))
        #expect(LibraryViewModel.status(of: fresh, job: job(.recognizingText)) == .recognizing(0.5))
        #expect(LibraryViewModel.status(of: fresh, job: job(.failed, error: "locked")) == .failed("locked"))
        #expect(LibraryViewModel.status(of: fresh, job: job(.ready)) == .ready)
        // A re-index of a searchable document does not make it look unavailable.
        #expect(LibraryViewModel.status(of: indexed, job: job(.embedding)) == .ready)
        #expect(LibraryViewModel.status(of: indexed, job: job(.failed, error: "x")) == .ready)
    }

    @Test func importQueuesSupportedFilesAndReportsTheRest() async throws {
        let (library, _, ingestion) = make()
        let good = try file("notes.txt", "The quick brown fox jumps over the lazy dog. It happened on a Tuesday.")
        let bad = try file("deck.pptx", "not supported")
        await library.importFiles([good, bad])

        #expect(library.rejections.count == 1)
        #expect(library.rejections[0].contains("deck.pptx") && library.rejections[0].contains("not supported"))
        #expect(library.items.map(\.title) == ["notes"])
        let ready = await eventually { await library.refresh(); return library.items.first?.status == .ready }
        #expect(ready, "the queued file should be indexed by the background run")
        _ = ingestion
    }

    @Test func renameDeleteAndReindex() async throws {
        let (library, repo, ingestion) = make()
        await library.importFiles([try file("a.txt", "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu.")])
        _ = await eventually { await library.refresh(); return library.items.first?.status == .ready }
        let id = try #require(library.items.first?.id)

        await library.rename(id, to: "  Renamed  ")
        #expect(library.items.first?.title == "Renamed")
        await library.rename(id, to: "   ")
        #expect(library.items.first?.title == "Renamed", "blank names are ignored")

        await library.reindex(id)
        #expect(library.items.first?.status == .ready, "stays searchable while re-indexing")
        _ = await eventually { (try? await repo.document(id: id))?.activeGeneration == 2 }
        #expect(try await repo.document(id: id)?.activeGeneration == 2)

        await library.delete(id)
        #expect(library.items.isEmpty)
        #expect(try await repo.chunks(docId: id, generation: 2).isEmpty)
        _ = ingestion
    }
}

// MARK: - Chat

private struct ChatHarness {
    let repo = InMemoryDocumentRepository()
    let search = FakeChunkSearch()
    let embedder = FakeEmbedder()
    let ingestion: IngestionService
    let model: ChatViewModel

    @MainActor init(answer: [String] = ["Hold the button [1]."], relevant: Bool = true) async throws {
        ingestion = IngestionService(
            extractor: FakeExtractor(results: [:]), embedder: embedder, repository: repo, jobs: repo,
            supportedType: { _ in .text })
        model = ChatViewModel(chats: repo, documents: repo, ingestion: ingestion)
        let chunk = Chunk(docId: "doc", generation: 1, ordinal: 0, page: 3, text: "Hold the button for ten seconds.",
                          embedding: [], embeddingModel: embedder.identity.tag)
        search.vectorHits = [ScoredChunk(chunk: chunk, score: relevant ? 0.2 : 0.95)]
        try await repo.upsert(DocumentRecord(id: "doc", title: "Manual", type: .pdf, activeGeneration: 1))
        let generator = ScriptedGenerator { $0.maxTokens == 64 ? ["standalone"] : answer }
        model.attach(ChatService(chats: repo, retriever: Retriever(embedder: embedder, search: search, repository: repo), generator: generator))
        model.updateDocuments([.init(id: "doc", title: "Manual", type: .pdf, pageCount: 3, importedAt: Date(), status: .ready)])
    }
}

@MainActor @Suite struct ChatViewModelTests {
    @Test func availabilityFollowsModelsAndDocuments() async throws {
        let repo = InMemoryDocumentRepository()
        let ingestion = IngestionService(extractor: FakeExtractor(results: [:]), embedder: FakeEmbedder(), repository: repo, jobs: repo, supportedType: { _ in .text })
        let model = ChatViewModel(chats: repo, documents: repo, ingestion: ingestion)
        #expect(model.availability == .modelNotReady)

        let harness = try await ChatHarness()
        #expect(harness.model.availability == .ready)
        harness.model.updateDocuments([])
        #expect(harness.model.availability == .noDocuments)
        // Documents that are still indexing cannot be asked about.
        harness.model.updateDocuments([.init(id: "x", title: "X", type: .pdf, pageCount: nil, importedAt: Date(), status: .embedding(0.3))])
        #expect(harness.model.documents.isEmpty)
    }

    @Test func sendingProducesAnAnswerWithCitationsAndTitlesTheChat() async throws {
        let h = try await ChatHarness()
        await h.model.load()
        h.model.draft = "How do I reset it?"
        #expect(h.model.canSend)
        await h.model.send()

        #expect(!h.model.isGenerating && h.model.streaming == nil && h.model.draft.isEmpty)
        #expect(h.model.messages.map(\.role) == [.user, .assistant])
        #expect(h.model.messages[1].citations.map(\.docTitle) == ["Manual"])
        #expect(h.model.current?.title == "How do I reset it?")
        #expect(await h.repo.chats().count == 1)
    }

    @Test func anIrrelevantQuestionIsRefused() async throws {
        let h = try await ChatHarness(relevant: false)
        h.model.draft = "Capital of France?"
        await h.model.send()
        #expect(h.model.messages.last?.notFound == true)
    }

    @Test func blankOrBusyInputCannotBeSent() async throws {
        let h = try await ChatHarness()
        h.model.draft = "   "
        #expect(!h.model.canSend)
        h.model.draft = "real question"
        #expect(h.model.canSend)
    }

    @Test func stoppingKeepsThePartialAnswer() async throws {
        let h = try await ChatHarness(answer: ["Step one [1]. "] + Array(repeating: "and more words ", count: 5_000))
        h.model.draft = "How?"
        let send = Task { await h.model.send() }
        #expect(await eventually { h.model.isGenerating && !(h.model.streaming ?? "").isEmpty })
        h.model.stop()
        await send.value

        #expect(!h.model.isGenerating)
        let reply = try #require(h.model.messages.last)
        #expect(reply.role == .assistant && reply.stopped)
        #expect(reply.text.hasPrefix("Step one [1]."))
    }

    @Test func ingestionIsPausedWhileAnswering() async throws {
        let h = try await ChatHarness(answer: Array(repeating: "word ", count: 3_000) + [" [1]."])
        h.model.draft = "q"
        let send = Task { await h.model.send() }
        #expect(await eventually { h.model.isGenerating })
        h.model.stop()
        await send.value
        // After the answer, ingestion must run again: a run must not block forever.
        let finished = await eventually { await h.ingestion.run(); return true }
        #expect(finished)
    }

    @Test func pinningPersistsPerChatAndCanBeCleared() async throws {
        let h = try await ChatHarness()
        await h.model.load()
        await h.model.togglePin("doc")
        #expect(h.model.pinnedIDs == ["doc"])
        #expect(h.model.pinnedDocuments.map(\.title) == ["Manual"])
        await h.model.togglePin("doc")
        #expect(h.model.pinnedIDs.isEmpty)
        await h.model.togglePin("doc")
        await h.model.clearPins()
        #expect(h.model.pinnedIDs.isEmpty)

        // Each chat has its own scope.
        await h.model.togglePin("doc")
        let first = try #require(h.model.currentID)
        await h.model.newChat()
        #expect(h.model.pinnedIDs.isEmpty)
        await h.model.select(first)
        #expect(h.model.pinnedIDs == ["doc"])
    }

    @Test func chatsCanBeCreatedRenamedSwitchedAndDeleted() async throws {
        let h = try await ChatHarness()
        await h.model.load()
        #expect(h.model.chats.isEmpty && h.model.currentID == nil)
        await h.model.newChat()
        let first = try #require(h.model.currentID)
        await h.model.newChat()
        let second = try #require(h.model.currentID)
        #expect(first != second && h.model.chats.count == 2)

        await h.model.rename(second, to: "Renamed")
        #expect(h.model.current?.title == "Renamed")
        await h.model.select(first)
        #expect(h.model.currentID == first)
        await h.model.delete(first)
        #expect(h.model.chats.map(\.id) == [second])
        #expect(h.model.currentID == second)
    }
}

// MARK: - Source viewer

@MainActor @Suite struct SourceViewerModelTests {
    private func citation(doc: String = "d", page: Int? = 1, snippet: String) -> Citation {
        Citation(n: 1, chunkId: "\(doc):1:0", docId: doc, docTitle: "Doc", page: page, snippet: snippet)
    }

    @Test func aTextDocumentOpensWithTheCitedParagraphsMarked() async throws {
        let repo = InMemoryDocumentRepository()
        let url = try file("manual.md", "# Manual\n\nIntro paragraph here.\n\nHold the power button for ten seconds until it blinks.\n\nClosing remarks.")
        try await repo.upsert(DocumentRecord(id: "d", title: "Manual", type: .markdown, activeGeneration: 1))
        try await repo.attachOriginal(fileURL: url, contentType: "text/markdown", to: "d")
        let model = SourceViewerModel(documents: repo, extractor: FileDocumentExtractor())

        await model.open(citation(snippet: "Hold the power button for ten seconds until it blinks."))
        guard case .text(let title, let paragraphs, let highlighted) = model.content else { Issue.record("expected text"); return }
        #expect(title == "Manual")
        #expect(paragraphs.map(\.isHeading) == [true, false, false, false])
        let marked = paragraphs.filter { highlighted.contains($0.id) }.map(\.text)
        #expect(marked == ["Hold the power button for ten seconds until it blinks."])
    }

    @Test func aPassageSpanningParagraphsMarksAllOfThem() {
        let paragraphs = ["First short paragraph.", "Second one continues.", "Unrelated tail."].enumerated()
            .map { SourceViewerModel.Paragraph(id: $0.offset, text: $0.element, isHeading: false) }
        let marked = SourceViewerModel.highlighted(in: paragraphs, passage: "First short paragraph. Second one continues.")
        #expect(marked == [0, 1])
        #expect(SourceViewerModel.highlighted(in: paragraphs, passage: "").isEmpty)
    }

    @Test func aPdfOpensAtTheCitedPage() async throws {
        let repo = InMemoryDocumentRepository()
        let pdf = scratch.appendingPathComponent("g.pdf")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try StubServiceFactory.makePDF(pages: ["one", "two", "three"]).write(to: pdf)
        try await repo.upsert(DocumentRecord(id: "d", title: "Guide", type: .pdf, pageCount: 3, activeGeneration: 1))
        try await repo.attachOriginal(fileURL: pdf, contentType: "application/pdf", to: "d")
        let model = SourceViewerModel(documents: repo, extractor: FileDocumentExtractor())

        await model.open(citation(page: 3, snippet: "three"))
        #expect(model.content == .pdf(url: pdf, page: 3, passage: "three", title: "Guide"))
        await model.openDocument("d")
        #expect(model.content == .pdf(url: pdf, page: 1, passage: "", title: "Guide"))
    }

    @Test func aDeletedDocumentFallsBackToTheStoredPassage() async {
        let model = SourceViewerModel(documents: InMemoryDocumentRepository(), extractor: FileDocumentExtractor())
        let cited = citation(doc: "gone", snippet: "The quoted passage.")
        await model.open(cited)
        #expect(model.content == .deleted(cited))
    }

    @Test func aMissingOriginalIsExplained() async throws {
        let repo = InMemoryDocumentRepository()
        try await repo.upsert(DocumentRecord(id: "d", title: "NoFile", type: .text, activeGeneration: 1))
        let model = SourceViewerModel(documents: repo, extractor: FileDocumentExtractor())
        await model.open(citation(snippet: "x"))
        guard case .unavailable(let title, _) = model.content else { Issue.record("expected unavailable"); return }
        #expect(title == "NoFile")
    }

    @Test func reopeningBumpsTheOpenCountSoTheViewScrollsAgain() async {
        let model = SourceViewerModel(documents: InMemoryDocumentRepository(), extractor: FileDocumentExtractor())
        await model.open(citation(snippet: "a"))
        let first = model.openCount
        await model.open(citation(snippet: "a"))
        #expect(model.openCount == first + 1)
        model.close()
        #expect(model.content == .none)
    }
}

// MARK: - App model

@MainActor @Suite struct AppModelTests {
    @Test func servicesAreBuiltInStagesAsModelsBecomeReady() async throws {
        let hash = String(repeating: "a", count: 64)
        let manifest = ModelManifest(models: [
            ModelSpec(id: "emb", version: "1", role: .embedder, url: URL(string: "https://x.invalid/e")!, bytes: 300, sha256: hash, fileName: "e"),
            ModelSpec(id: "llm", version: "1", role: .generator, url: URL(string: "https://x.invalid/l")!, bytes: 3000, sha256: hash, fileName: "l"),
        ])
        let backend = FakeModelBackend()
        backend.setBehavior(.failOnce("offline"), for: "llm")
        let store = ModelStore(manifest: manifest, downloader: backend, files: backend, safetyMargin: 0)
        let models = ModelSetupViewModel(store: store)
        let app = AppModel(models: models, factory: StubServiceFactory(options: .init()))
        let run = Task { await app.run() }
        defer { run.cancel() }

        #expect(app.library == nil && app.chat == nil)
        await models.start()   // the embedder installs; the language model fails once

        #expect(await eventually { app.library != nil })
        #expect(app.chat?.availability == .modelNotReady, "search works, chat waits for the language model")

        await models.retry("llm")
        #expect(await eventually { app.chat?.availability != .modelNotReady })
        #expect(app.preparation == .ready)
    }
}
