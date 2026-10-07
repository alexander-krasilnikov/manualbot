import Foundation
import Ports
import PortsTesting
import Testing
@testable import Core

/// A change of embedding model re-indexes every document by itself (document-ingestion spec).
@Suite struct ReindexOutdatedTests {
    private let modelA = EmbeddingModelIdentity(id: "model-a", version: "1", dimensions: 32)
    private let modelB = EmbeddingModelIdentity(id: "model-b", version: "1", dimensions: 32)
    private let chunker = Chunker(configuration: ChunkerConfiguration(targetTokens: 40, maxTokens: 70, overlapTokens: 10, minTailTokens: 15))

    private func text(_ sentences: Int = 10, tag: String = "S") -> ExtractedDocument {
        ExtractedDocument(
            blocks: [Block(text: (0..<sentences).map { "\(tag)\($0) " + (0..<8).map { "w\($0)" }.joined(separator: " ") + "." }.joined(separator: " "), page: 1)],
            pageCount: 1)
    }

    private func service(
        _ repo: InMemoryDocumentRepository, extractor: FakeExtractor, model: EmbeddingModelIdentity, features: (any ImageFeaturing)? = nil
    ) -> IngestionService {
        IngestionService(
            extractor: extractor, embedder: FakeEmbedder(identity: model), repository: repo, jobs: repo, chunker: chunker,
            batchSize: 4, supportedType: { ["txt": DocumentType.text][$0.pathExtension.lowercased()] }, imageFeatures: features)
    }

    private func extractor() -> FakeExtractor {
        FakeExtractor(results: ["a.txt": .success(text(tag: "A")), "b.txt": .success(text(tag: "B"))])
    }

    private func importBoth(_ repo: InMemoryDocumentRepository, with service: IngestionService) async throws -> [String] {
        let ids = [try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt")), try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/b.txt"))]
        await service.run()
        return ids
    }

    @Test func documentsEmbeddedByAnotherModelAreQueuedAndBecomeCurrent() async throws {
        let repo = InMemoryDocumentRepository()
        let old = service(repo, extractor: extractor(), model: modelA)
        let ids = try await importBoth(repo, with: old)
        for id in ids { #expect(try await repo.activeChunks(docId: id).allSatisfy { $0.embeddingModel == modelA.tag }) }

        let current = service(repo, extractor: extractor(), model: modelB)
        let queued = try await current.reindexOutdated(for: modelB)
        #expect(queued == 2)
        for id in ids {
            #expect(try await repo.job(docId: id)?.state == .queued)
            // Searchable from the old set until the new one is switched in.
            #expect(try await repo.activeChunks(docId: id).allSatisfy { $0.embeddingModel == modelA.tag })
        }

        await current.run()
        for id in ids {
            let chunks = try await repo.activeChunks(docId: id)
            #expect(!chunks.isEmpty && chunks.allSatisfy { $0.embeddingModel == modelB.tag && $0.generation == 2 })
            #expect(try await repo.job(docId: id)?.state == .ready)
        }
        #expect(try await current.reindexOutdated(for: modelB) == 0, "everything is current now")
    }

    @Test func nothingIsQueuedWhenEveryDocumentIsCurrent() async throws {
        let repo = InMemoryDocumentRepository()
        let current = service(repo, extractor: extractor(), model: modelB)
        _ = try await importBoth(repo, with: current)
        let before = try await repo.jobs().map(\.targetGeneration)
        #expect(try await current.reindexOutdated(for: modelB) == 0)
        #expect(try await repo.jobs().map(\.targetGeneration) == before)
        #expect(try await repo.jobs().allSatisfy { $0.state == .ready })
    }

    @Test func anEmptyLibraryQueuesNothing() async throws {
        let repo = InMemoryDocumentRepository()
        #expect(try await service(repo, extractor: extractor(), model: modelB).reindexOutdated(for: modelB) == 0)
    }

    @Test func documentsWithUnfinishedWorkAreLeftToThatWork() async throws {
        let repo = InMemoryDocumentRepository()
        let ids = try await importBoth(repo, with: service(repo, extractor: extractor(), model: modelA))
        // The first document has a re-index running already; the second one's last run failed.
        var running = try #require(try await repo.job(docId: ids[0]))
        running.state = .embedding; running.targetGeneration = 2
        try await repo.upsert(job: running)
        var failed = try #require(try await repo.job(docId: ids[1]))
        failed.state = .failed
        try await repo.upsert(job: failed)

        let current = service(repo, extractor: extractor(), model: modelB)
        #expect(try await current.reindexOutdated(for: modelB) == 1)
        let untouched = try await repo.job(docId: ids[0])
        #expect(untouched?.state == .embedding && untouched?.targetGeneration == 2)
        #expect(try await repo.job(docId: ids[1])?.state == .queued)
    }

    @Test func aDocumentThatNeverFinishedIndexingIsNotQueued() async throws {
        let repo = InMemoryDocumentRepository()
        let current = service(repo, extractor: extractor(), model: modelB)
        let id = try await current.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))   // queued, never run: no active generation
        #expect(try await current.reindexOutdated(for: modelB) == 0)
        #expect(try await repo.job(docId: id)?.targetGeneration == 1)
    }

    @Test func aPhotoFromAnotherImageModelMakesItsDocumentOutdated() async throws {
        let repo = InMemoryDocumentRepository()
        let oldFeatures = FakeImageFeaturer(identity: EmbeddingModelIdentity(id: "old-images", version: "1", dimensions: 192))
        let old = service(repo, extractor: extractor(), model: modelB, features: oldFeatures)
        let ids = try await importBoth(repo, with: old)
        try await repo.writeImages([ImageWrite(
            record: ImageRecord(docId: ids[0], generation: 1, n: 0, page: 1, width: 4, height: 4, features: [1], featureModel: oldFeatures.identity.tag),
            displayCopy: Data([0]))])

        let newFeatures = FakeImageFeaturer(identity: EmbeddingModelIdentity(id: "new-images", version: "1", dimensions: 192))
        let current = service(repo, extractor: extractor(), model: modelB, features: newFeatures)
        #expect(try await current.reindexOutdated(for: modelB) == 1)
        #expect(try await repo.job(docId: ids[0])?.state == .queued)
        #expect(try await repo.job(docId: ids[1])?.state == .ready)
    }
}
