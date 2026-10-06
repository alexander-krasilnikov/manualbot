import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// Tracing must only observe. The same questions over the same documents give the same passages, answers and
/// citations with it on or off, on the real database with fake models.
@Suite(.serialized) struct TracingParityTests {
    private let fx = Fixtures()
    private static let documents = ["x200-manual.md", "warranty.txt", "bike-repair.md"]

    struct Outcome: Equatable {
        var passages: [String]
        var relevant: Bool
        var bestDistance: Double?
        var reply: String
        var citations: [String]
        var notFound: Bool
    }

    private func run(tracer: any Tracer) async throws -> [Outcome] {
        let suite = try EvalCorpus.suite()
        let files = try Self.documents.map {
            fx.write(try Data(contentsOf: EvalCorpus.directory.appendingPathComponent($0)), as: $0)
        }
        let questions = suite.cases.filter { $0.doc == nil || Self.documents.contains($0.doc! + ".md") ||
            Self.documents.contains($0.doc! + ".txt") }.map(\.question)

        let f = try RepoFixture(tracer: tracer); defer { Task { await f.cleanUp() } }
        let embedder = FakeEmbedder(identity: RepoFixture.identity)
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: embedder, repository: f.repo, jobs: f.repo,
            chunker: Chunker(), supportedType: FileDocumentExtractor.documentType(for:), tracer: tracer)
        for file in files { _ = try await ingestion.enqueue(fileURL: file) }
        await ingestion.run()

        let retriever = Retriever(embedder: embedder, search: f.repo, repository: f.repo, tracer: tracer)
        let generator = ScriptedGenerator(fragments: ["According to the documents [1] and [2]."])
        let chat = ChatService(chats: f.repo, retriever: retriever, generator: generator, tracer: tracer)

        var outcomes: [Outcome] = []
        for question in questions {
            let retrieval = try await retriever.retrieve(question)
            var reply: MessageRecord?
            let chatID = try await f.repo.createChat().id
            for try await event in chat.ask(question, in: chatID) {
                if case .completed(let message) = event { reply = message }
            }
            let message = try #require(reply)
            outcomes.append(Outcome(
                passages: retrieval.passages.map { "\($0.documentTitle)#\($0.chunk.ordinal): \($0.chunk.text)" },
                relevant: retrieval.relevant, bestDistance: retrieval.bestDistance, reply: message.text,
                citations: message.citations.map { "\($0.n) \($0.docTitle) p\($0.page ?? 0) \($0.snippet)" },
                notFound: message.notFound))
        }
        return outcomes
    }

    @Test func sameQuestionsGiveTheSameResultsWithTracingOnOrOff() async throws {
        let off = try await run(tracer: NoTracer())
        let recorder = RecordingTracer()
        let on = try await run(tracer: recorder)

        #expect(off.count > 15)
        #expect(off.contains { $0.notFound } && off.contains { !$0.notFound }, "needs both answered and refused questions")
        #expect(on == off)

        // And the traced run really saw things.
        let asks = Set(recorder.events.compactMap(\.operation).filter { $0.kind == .ask }.map(\.id))
        #expect(asks.count == off.count, "one ask operation per question, got \(asks.count)")
        #expect(recorder.queries.contains { $0.trace.purpose == .vector })
        #expect(recorder.queries.contains { $0.trace.purpose == .keyword })
        let imports = Set(recorder.events.compactMap(\.operation).filter { $0.kind == .importDocument }.map(\.id))
        #expect(imports.count == Self.documents.count)
    }

    @Test func deletingADocumentIsItsOwnOperationWithTheRemovedPassageCount() async throws {
        let tracer = RecordingTracer()
        let f = try RepoFixture(tracer: tracer); defer { Task { await f.cleanUp() } }
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: FakeEmbedder(identity: RepoFixture.identity), repository: f.repo,
            jobs: f.repo, chunker: Chunker(), supportedType: FileDocumentExtractor.documentType(for:), tracer: tracer)
        let file = fx.write(Data("Hold the power button for ten seconds to reset the unit.".utf8), as: "reset.txt")
        let id = try await ingestion.enqueue(fileURL: file)
        await ingestion.run()
        let before = tracer.events.count

        try await ingestion.delete(docId: id)

        let after = tracer.events.dropFirst(before)
        let deletion = try #require(after.first { if case .documentDeleted = $0.kind { true } else { false } })
        #expect(deletion.operation?.id == "delete-\(id)")
        #expect(deletion.operation?.kind == .delete)
        #expect(deletion.kind == .documentDeleted(docId: id, passagesRemoved: 1))
    }

    /// Holds the first batch until released, so a delete can arrive while the document is being indexed.
    private final class GateEmbedder: Embedder, @unchecked Sendable {
        let base = FakeEmbedder(identity: RepoFixture.identity)
        var identity: EmbeddingModelIdentity { base.identity }
        private let lock = NSLock()
        private var waiting = false
        private var release: CheckedContinuation<Void, Never>?
        private var open = false

        var isWaiting: Bool { lock.withLock { waiting } }

        func open_() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                open = true
                defer { release = nil }
                return release
            }
            continuation?.resume()
        }

        func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let proceed = lock.withLock { () -> Bool in
                    if open { return true }
                    waiting = true
                    release = continuation
                    return false
                }
                if proceed { continuation.resume() }
            }
            return try await base.embed(texts, kind: kind)
        }
    }

    @Test func aDeleteRequestedWhileIndexingIsReportedUnderTheOperationThatAskedForIt() async throws {
        let tracer = RecordingTracer()
        let f = try RepoFixture(tracer: tracer); defer { Task { await f.cleanUp() } }
        let gate = GateEmbedder()
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: gate, repository: f.repo, jobs: f.repo, chunker: Chunker(),
            supportedType: FileDocumentExtractor.documentType(for:), tracer: tracer)
        let text = (0..<40).map { "Sentence \($0) about the calibration procedure." }.joined(separator: " ")
        let id = try await ingestion.enqueue(fileURL: fx.write(Data(text.utf8), as: "calib.txt"))
        let running = Task { await ingestion.run() }
        while !gate.isWaiting { try await Task.sleep(for: .milliseconds(5)) }

        let reset = TraceOperation(id: "reset-1", kind: .reset, title: "Reset demo")
        try await TraceContext.$operation.withValue(reset) { try await ingestion.delete(docId: id) }
        gate.open_()
        await running.value

        let deletion = try #require(tracer.events.first { if case .documentDeleted = $0.kind { true } else { false } })
        #expect(deletion.operation == reset, "got \(String(describing: deletion.operation))")
        #expect(try await f.repo.document(id: id) == nil)
    }

    @Test func deletingInsideAnotherOperationKeepsThatOperation() async throws {
        let tracer = RecordingTracer()
        let f = try RepoFixture(tracer: tracer); defer { Task { await f.cleanUp() } }
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: FakeEmbedder(identity: RepoFixture.identity), repository: f.repo,
            jobs: f.repo, chunker: Chunker(), supportedType: FileDocumentExtractor.documentType(for:), tracer: tracer)
        let id = try await ingestion.enqueue(fileURL: fx.write(Data("Hold the power button for ten seconds.".utf8), as: "r.txt"))
        await ingestion.run()
        let reset = TraceOperation(id: "reset-1", kind: .reset, title: "Reset demo")
        try await TraceContext.$operation.withValue(reset) { try await ingestion.delete(docId: id) }
        let deletion = try #require(tracer.events.first { if case .documentDeleted = $0.kind { true } else { false } })
        #expect(deletion.operation == reset)
    }
}
