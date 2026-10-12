import Foundation
import Ports
import PortsTesting
import Synchronization
import Testing
@testable import Core

/// Originals are limited to what can be shared, and a document can be imported under a fixed ID.
@Suite struct ImportLimitTests {
    private let chunker = Chunker(configuration: ChunkerConfiguration(targetTokens: 40, maxTokens: 70, overlapTokens: 10, minTailTokens: 15))
    private let limit = IngestionService.maxOriginalBytes

    private func text(tag: String) -> ExtractedDocument {
        ExtractedDocument(
            blocks: [Block(text: (0..<10).map { "\(tag)\($0) " + (0..<8).map { "w\($0)" }.joined(separator: " ") + "." }.joined(separator: " "), page: 1)],
            pageCount: 1)
    }

    private func service(_ repo: InMemoryDocumentRepository, extractor: FakeExtractor) -> IngestionService {
        IngestionService(
            extractor: extractor, embedder: FakeEmbedder(), repository: repo, jobs: repo, chunker: chunker,
            batchSize: 4, supportedType: { ["txt": DocumentType.text][$0.pathExtension.lowercased()] })
    }

    /// A real file of `bytes` bytes (sparse, so it costs nothing to write), which the service can measure.
    private func file(_ name: String, bytes: Int64, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("limit-\(UUID().uuidString)")
    }

    @Test func aFileOverTheLimitIsRefusedBeforeAnythingIsStored() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = InMemoryDocumentRepository()
        let big = try file("big.txt", bytes: 34 * 1024 * 1024, in: directory)
        let extractor = FakeExtractor(results: [:])

        await #expect(throws: IngestionError.tooLarge(bytes: 34 * 1024 * 1024, limit: limit)) {
            try await service(repo, extractor: extractor).enqueue(fileURL: big)
        }
        #expect(try await repo.documents().isEmpty)
        #expect(try await repo.jobs().isEmpty)
    }

    @Test func theRefusalNamesTheSizeAndTheLimit() {
        let message = IngestionError.tooLarge(bytes: 34 * 1024 * 1024, limit: limit).localizedDescription
        #expect(message.contains("34 MB"))
        #expect(message.contains("20 MB"))
    }

    @Test func aFileOfExactlyTheLimitIsImported() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = InMemoryDocumentRepository()
        let exact = try file("exact.txt", bytes: limit, in: directory)
        let extractor = FakeExtractor(results: [exact.lastPathComponent: .success(text(tag: "E"))])

        let id = try await service(repo, extractor: extractor).enqueue(fileURL: exact)
        #expect(try await repo.document(id: id) != nil)
    }

    @Test func oneLargeFileDoesNotStopTheOthersInTheSameImport() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = InMemoryDocumentRepository()
        let big = try file("big.txt", bytes: limit + 1, in: directory)
        let small = try file("small.txt", bytes: 2 * 1024 * 1024, in: directory)
        let extractor = FakeExtractor(results: ["small.txt": .success(text(tag: "S"))])
        let ingestion = service(repo, extractor: extractor)

        var refused: [URL] = []
        for url in [big, small] {
            do { try await ingestion.enqueue(fileURL: url) } catch IngestionError.tooLarge { refused.append(url) }
        }
        #expect(refused == [big])
        #expect(try await repo.documents().map(\.title) == ["small"])
    }

    // MARK: Fixed IDs

    @Test func aDocumentCanBeImportedUnderAGivenID() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: ["a.txt": .success(text(tag: "A"))])
        let ingestion = service(repo, extractor: extractor)

        let id = try await ingestion.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"), id: "sample-a")
        #expect(id == "sample-a")
        await ingestion.run()
        #expect(try await repo.document(id: "sample-a")?.activeGeneration == 1)
    }

    @Test func importingTheSameIDTwiceLeavesOneUntouchedDocument() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: ["a.txt": .success(text(tag: "A"))])
        let ingestion = service(repo, extractor: extractor)
        let url = URL(fileURLWithPath: "/in/a.txt")

        try await ingestion.enqueue(fileURL: url, id: "sample-a")
        await ingestion.run()
        let before = try await repo.document(id: "sample-a")
        let chunksBefore = try await repo.activeChunks(docId: "sample-a").map(\.id)

        // Another device already holds it, indexed: importing it again changes nothing and starts no work.
        #expect(try await ingestion.enqueue(fileURL: url, id: "sample-a") == "sample-a")
        #expect(try await repo.documents().count == 1)
        #expect(try await repo.document(id: "sample-a") == before)
        #expect(try await repo.activeChunks(docId: "sample-a").map(\.id) == chunksBefore)
        #expect(try await repo.job(docId: "sample-a")?.state == .ready)
    }

    @Test func aRecordThatArrivedFromAnotherDeviceIsNotImportedOver() async throws {
        let repo = InMemoryDocumentRepository()
        await repo.upsert(DocumentRecord(id: "sample-a", title: "A", type: .text, activeGeneration: 1, chunkCount: 3, activeImageCount: 0))
        let extractor = FakeExtractor(results: ["a.txt": .success(text(tag: "A"))])

        try await service(repo, extractor: extractor).enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"), id: "sample-a")
        #expect(try await repo.jobs().isEmpty)
        #expect(try await repo.document(id: "sample-a")?.activeGeneration == 1)
    }

    // MARK: Shared text and import bookkeeping

    @Test func sizesAreWrittenInBinaryUnitsSoTheLimitReadsTwentyMB() {
        #expect(IngestionError.sizeText(IngestionService.maxOriginalBytes) == "20 MB")
        #expect(IngestionError.sizeText(34 * 1024 * 1024) == "34 MB")
    }

    @Test func nothingIsReportedAsBeingImportedOnceEnqueueHasReturned() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: ["a.txt": .success(text(tag: "A"))])
        let ingestion = service(repo, extractor: extractor)
        #expect(await ingestion.importingDocumentIDs().isEmpty)
        try await ingestion.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"), id: "sample-a")
        #expect(await ingestion.importingDocumentIDs().isEmpty, "the record has its job now")
        #expect(try await repo.job(docId: "sample-a") != nil)
    }

    // MARK: A delete that is still pending

    /// Embeds like `FakeEmbedder`, but never finishes the first batch until the task is cancelled: a document stays "being indexed".
    private struct StallingEmbedder: Embedder {
        let base = FakeEmbedder()
        var identity: EmbeddingModelIdentity { base.identity }
        func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
            try await Task.sleep(for: .seconds(3600))
            return try await base.embed(texts, kind: kind)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func anImportUnderAnIDWhoseDeleteIsPendingWaitsForItAndThenImportsFresh() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: ["a.txt": .success(text(tag: "A"))])
        let ingestion = IngestionService(
            extractor: extractor, embedder: StallingEmbedder(), repository: repo, jobs: repo, chunker: chunker, batchSize: 4,
            supportedType: { ["txt": DocumentType.text][$0.pathExtension.lowercased()] })
        let url = URL(fileURLWithPath: "/in/a.txt")
        try await ingestion.enqueue(fileURL: url, id: "sample-a")
        let running = Task { await ingestion.run() }
        // Wait until the document is being indexed.
        for _ in 0..<200 where try await repo.job(docId: "sample-a")?.state != .embedding { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await repo.job(docId: "sample-a")?.state == .embedding)

        try await ingestion.delete(docId: "sample-a")            // deferred: the document is being indexed right now
        let finished = Mutex(false)
        let importAgain = Task {
            try await ingestion.enqueue(fileURL: url, id: "sample-a")
            finished.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!finished.withLock { $0 }, "the import waits while the delete is pending")

        // Indexing stops mid-batch (as it does for a switch of model): a stopped run leaves the delete for the next one, so the
        // import itself carries it out and then imports.
        await ingestion.stop()
        running.cancel()
        try await importAgain.value
        #expect(finished.withLock { $0 })
        let record = try await repo.document(id: "sample-a")
        #expect(record != nil && record?.activeGeneration == nil, "a fresh record, not the one that was being deleted")
        #expect(try await repo.job(docId: "sample-a")?.state == .queued, "with a fresh job")
    }
}
