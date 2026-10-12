import Foundation
import Ports
import PortsTesting
import Synchronization
import Testing
@testable import Core

/// Embeds like `FakeEmbedder` under an identity of its own, and can stall (until cancelled) after N calls: a run that is
/// stopped, or killed, in the middle of a document.
private final class StallingEmbedder: Embedder {
    let identity: EmbeddingModelIdentity
    private let base: FakeEmbedder
    private let state: Mutex<(calls: Int, stallAfter: Int?)>

    init(identity: EmbeddingModelIdentity, stallAfterCalls: Int? = nil) {
        self.identity = identity
        base = FakeEmbedder(identity: identity)
        state = Mutex((calls: 0, stallAfter: stallAfterCalls))
    }

    var calls: Int { state.withLock { $0.calls } }
    func stopStalling() { state.withLock { $0.stallAfter = nil } }

    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        let (n, limit) = state.withLock { s -> (Int, Int?) in s.calls += 1; return (s.calls, s.stallAfter) }
        if let limit, n > limit { try await Task.sleep(for: .seconds(3600)) }
        return try await base.embed(texts, kind: kind)
    }
}

/// Switching the embedding model while documents are being indexed (model-catalog spec: Immediate switch).
@Suite struct ModelSwitchIngestionTests {
    private let modelA = EmbeddingModelIdentity(id: "model-a", version: "1", dimensions: 32)
    private let modelB = EmbeddingModelIdentity(id: "model-b", version: "1", dimensions: 32)
    private let chunker = Chunker(configuration: ChunkerConfiguration(targetTokens: 40, maxTokens: 70, overlapTokens: 10, minTailTokens: 15))

    private func text(_ tag: String) -> ExtractedDocument {
        ExtractedDocument(
            blocks: [Block(text: (0..<30).map { "\(tag)\($0) " + (0..<8).map { "w\($0)" }.joined(separator: " ") + "." }.joined(separator: " "), page: 1)],
            pageCount: 1)
    }

    private func extractor() -> FakeExtractor {
        FakeExtractor(results: ["a.txt": .success(text("A")), "b.txt": .success(text("B"))])
    }

    private func service(_ repo: InMemoryDocumentRepository, embedder: any Embedder) -> IngestionService {
        IngestionService(
            extractor: extractor(), embedder: embedder, repository: repo, jobs: repo, chunker: chunker, batchSize: 2,
            supportedType: { ["txt": DocumentType.text][$0.pathExtension.lowercased()] })
    }

    private func enqueue(_ name: String, with service: IngestionService) async throws -> String {
        try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/\(name)"))
    }

    @Test func stoppingTheRunKeepsTheJobsProgressWhoeverStartedIt() async throws {
        let repo = InMemoryDocumentRepository()
        let stalling = StallingEmbedder(identity: modelA, stallAfterCalls: 2)
        let service = service(repo, embedder: stalling)
        let id = try await enqueue("a.txt", with: service)

        let caller = Task { await service.run() }   // never cancelled: stop() ends the run for it
        while stalling.calls < 3 { try await Task.sleep(for: .milliseconds(5)) }
        await service.stop()
        await caller.value

        let job = try #require(try await repo.job(docId: id))
        #expect(job.state != .ready && job.state != .failed)
        #expect(job.nextOrdinal == 4, "two batches of two were done")
        #expect(job.embeddingModel == modelA.tag)
        #expect(try await repo.document(id: id)?.activeGeneration == nil, "the document stays pending")

        // The same service runs again and finishes where it stopped, with exactly one chunk per position.
        stalling.stopStalling()
        await service.run()
        let chunks = try await repo.activeChunks(docId: id)
        #expect(chunks.map(\.ordinal) == Array(0..<chunks.count))
        #expect(try await repo.job(docId: id)?.state == .ready)
    }

    @Test func stoppingWhenNothingRunsIsHarmless() async {
        let service = service(InMemoryDocumentRepository(), embedder: StallingEmbedder(identity: modelA))
        await service.stop()
        await service.run()
    }

    @Test func aJobStartedByAnotherModelStartsOverInANewGenerationAndNeverMixesVectors() async throws {
        let repo = InMemoryDocumentRepository()
        let stalling = StallingEmbedder(identity: modelA, stallAfterCalls: 2)
        let old = service(repo, embedder: stalling)
        let id = try await enqueue("a.txt", with: old)
        let caller = Task { await old.run() }
        while stalling.calls < 3 { try await Task.sleep(for: .milliseconds(5)) }
        await old.stop()
        await caller.value
        #expect(try await repo.job(docId: id)?.nextOrdinal == 4)

        let current = service(repo, embedder: StallingEmbedder(identity: modelB))
        await current.run()

        let chunks = try await repo.activeChunks(docId: id)
        #expect(!chunks.isEmpty && chunks.allSatisfy { $0.embeddingModel == modelB.tag && $0.generation == 2 })
        #expect(chunks.map(\.ordinal) == Array(0..<chunks.count))
        let job = try #require(try await repo.job(docId: id))
        #expect(job.state == .ready && job.embeddingModel == modelB.tag && job.targetGeneration == 2)
        #expect(try await current.outdatedDocuments(for: modelB).isEmpty)
    }

    @Test func switchingWhileADocumentIsBeingIndexedReindexesEveryDocument() async throws {
        let repo = InMemoryDocumentRepository()
        let stalling = StallingEmbedder(identity: modelA)
        let old = service(repo, embedder: stalling)
        let ready = try await enqueue("a.txt", with: old)
        await old.run()
        #expect(try await repo.activeChunks(docId: ready).allSatisfy { $0.embeddingModel == modelA.tag })

        stalling.stopStalling()
        let blocked = StallingEmbedder(identity: modelA, stallAfterCalls: 1)
        let interrupted = service(repo, embedder: blocked)
        let pending = try await enqueue("b.txt", with: interrupted)
        let caller = Task { await interrupted.run() }
        while blocked.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await interrupted.stop()
        await caller.value
        #expect(try await repo.document(id: pending)?.activeGeneration == nil)

        // The models are switched: what the confirmation counts, then the re-index and the resumed job.
        let current = service(repo, embedder: StallingEmbedder(identity: modelB))
        #expect(try await current.outdatedDocuments(for: modelB) == [ready], "the document still being indexed is not searchable yet")
        #expect(try await current.reindexOutdated(for: modelB) == 1)
        await current.run()

        for id in [ready, pending] {
            let chunks = try await repo.activeChunks(docId: id)
            #expect(!chunks.isEmpty && chunks.allSatisfy { $0.embeddingModel == modelB.tag }, "document \(id) is on the new model")
            #expect(try await repo.job(docId: id)?.state == .ready)
        }
        #expect(try await current.outdatedDocuments(for: modelB).isEmpty)
    }

    @Test func theCountOfDocumentsToReindexIsEverySearchableDocument() async throws {
        let repo = InMemoryDocumentRepository()
        let old = service(repo, embedder: StallingEmbedder(identity: modelA))
        _ = try await enqueue("a.txt", with: old)
        _ = try await enqueue("b.txt", with: old)
        await old.run()
        let searchable = try await repo.documents().filter { $0.activeGeneration != nil }.count
        #expect(searchable == 2)
        #expect(try await old.outdatedDocuments(for: modelB).count == searchable)
        #expect(try await old.outdatedDocuments(for: modelA).isEmpty, "nothing to redo for the model already in use")
    }

    @Test func jobsSavedBeforeModelsCouldChangeStillDecode() throws {
        let json = """
        {"docId":"d","targetGeneration":1,"state":"queued","progress":0,"nextOrdinal":0,"enqueuedAt":0}
        """
        let job = try JSONDecoder().decode(IngestJobRecord.self, from: Data(json.utf8))
        #expect(job.embeddingModel == nil && job.nextImage == 0)
    }
}
