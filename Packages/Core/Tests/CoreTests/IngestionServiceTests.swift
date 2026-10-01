import Foundation
import Ports
import PortsTesting
import Synchronization
import Testing
@testable import Core

/// Embeds like `FakeEmbedder`, but can stall after N calls (until cancelled) to simulate being killed mid-run.
private final class GatedEmbedder: Embedder {
    let base = FakeEmbedder()
    var identity: EmbeddingModelIdentity { base.identity }
    private let stallAfter: Int?
    private let state = Mutex((calls: 0, texts: 0))

    init(stallAfterCalls: Int? = nil) { stallAfter = stallAfterCalls }

    var calls: Int { state.withLock { $0.calls } }
    var embeddedTexts: Int { state.withLock { $0.texts } }

    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        let n = state.withLock { s -> Int in s.calls += 1; return s.calls }
        if let stallAfter, n > stallAfter { try await Task.sleep(for: .seconds(3600)) }
        state.withLock { $0.texts += texts.count }
        return try await base.embed(texts, kind: kind)
    }
}

private struct WrongDimensionEmbedder: Embedder {
    let identity = EmbeddingModelIdentity(id: "bad", version: "1", dimensions: 32)
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] { texts.map { _ in [1, 2, 3] } }
}

private let smallChunks = Chunker(configuration: ChunkerConfiguration(targetTokens: 40, maxTokens: 70, overlapTokens: 10, minTailTokens: 15))

private func longText(_ sentences: Int, tag: String = "S") -> String {
    (0..<sentences).map { "\(tag)\($0) " + (0..<8).map { "w\($0)" }.joined(separator: " ") + "." }.joined(separator: " ")
}

private func document(pages: Int = 2, sentencesPerPage: Int = 12) -> ExtractedDocument {
    ExtractedDocument(
        blocks: (1...pages).map { Block(text: longText(sentencesPerPage, tag: "P\($0)S"), page: $0) },
        pageCount: pages)
}

private func makeService(
    repo: InMemoryDocumentRepository, extractor: FakeExtractor, embedder: any Embedder = GatedEmbedder(),
    batchSize: Int = 2
) -> IngestionService {
    IngestionService(
        extractor: extractor, embedder: embedder, repository: repo, jobs: repo, chunker: smallChunks,
        batchSize: batchSize, supportedType: { url in
            ["txt": DocumentType.text, "pdf": .pdf, "docx": .docx][url.pathExtension.lowercased()]
        })
}

@Suite struct IngestionServiceTests {
    @Test func indexesADocumentEndToEnd() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: ["manual.pdf": .success(document(pages: 3))])
        let service = makeService(repo: repo, extractor: extractor)

        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/manual.pdf"))
        #expect(try await repo.job(docId: id)?.state == .queued)
        #expect(try await repo.activeChunks(docId: id).isEmpty)

        await service.run()

        let doc = try #require(try await repo.document(id: id))
        #expect(doc.title == "manual")
        #expect(doc.type == .pdf)
        #expect(doc.pageCount == 3)
        #expect(doc.activeGeneration == 1)
        let chunks = try await repo.activeChunks(docId: id)
        #expect(chunks.count > 3)
        #expect(chunks.map(\.ordinal) == Array(0..<chunks.count))
        #expect(Set(chunks.compactMap(\.page)) == [1, 2, 3])
        let tag = GatedEmbedder().identity.tag
        #expect(chunks.allSatisfy { $0.embeddingModel == tag && $0.embedding.count == 32 })
        let job = try #require(try await repo.job(docId: id))
        #expect(job.state == .ready && job.progress == 1 && job.error == nil)
    }

    @Test func unsupportedFilesAreRejectedBeforeAnythingIsCreated() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: [:]))
        await #expect(throws: IngestionError.unsupportedType("pptx")) {
            try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/deck.pptx"))
        }
        #expect(try await repo.documents().isEmpty)
        #expect(try await repo.jobs().isEmpty)
    }

    @Test func passagesOnlyBecomeSearchableTogether() async throws {
        let repo = InMemoryDocumentRepository()
        let embedder = SpyEmbedder(repo: repo)
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.txt": .success(document())]), embedder: embedder)
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))
        embedder.watch(id)
        await service.run()

        #expect(embedder.batchesSeen > 1, "test needs several batches")
        #expect(embedder.visibleDuringRun.allSatisfy { $0 == 0 }, "chunks were visible mid-ingestion: \(embedder.visibleDuringRun)")
        #expect(try await repo.activeChunks(docId: id).count > 0)
    }

    @Test func killedRunResumesWithExactlyOneChunkSet() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: ["big.pdf": .success(document(pages: 3, sentencesPerPage: 20))])
        let stalling = GatedEmbedder(stallAfterCalls: 2)
        let first = makeService(repo: repo, extractor: extractor, embedder: stalling)
        let id = try await first.enqueue(fileURL: URL(fileURLWithPath: "/in/big.pdf"))

        // Run until the third batch stalls, then "kill" the run.
        let task = Task { await first.run() }
        while stalling.calls < 3 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await task.value

        let interrupted = try #require(try await repo.job(docId: id))
        #expect(interrupted.state != .ready && interrupted.state != .failed)
        #expect(interrupted.nextOrdinal == 4)  // two batches of two completed
        #expect(try await repo.document(id: id)?.activeGeneration == nil)
        #expect(try await repo.activeChunks(docId: id).isEmpty)

        // "Relaunch": a new service over the same stores finishes the job.
        let healthy = GatedEmbedder()
        let second = makeService(repo: repo, extractor: extractor, embedder: healthy)
        await second.run()

        let chunks = try await repo.activeChunks(docId: id)
        let total = chunks.count
        #expect(chunks.map(\.ordinal) == Array(0..<total), "exactly one chunk per ordinal")
        #expect(Set(chunks.map(\.id)).count == total)
        #expect(healthy.embeddedTexts == total - 4, "only unfinished chunks are embedded again")
        #expect(try await repo.job(docId: id)?.state == .ready)
    }

    @Test func aBadFileFailsWithoutBlockingTheQueue() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: [
            "locked.pdf": .failure(ExtractionError.passwordProtected),
            "good.txt": .success(document(pages: 1)),
        ])
        let service = makeService(repo: repo, extractor: extractor)
        let bad = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/locked.pdf"))
        let good = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/good.txt"))
        await service.run()

        let badJob = try #require(try await repo.job(docId: bad))
        #expect(badJob.state == .failed)
        #expect(badJob.error == "The document is password-protected.")
        #expect(try await repo.activeChunks(docId: bad).isEmpty)
        #expect(try await repo.job(docId: good)?.state == .ready)
        #expect(try await repo.activeChunks(docId: good).count > 0)
    }

    @Test func documentsWithoutTextFail() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: ["blank.txt": .success(ExtractedDocument(blocks: [Block(text: "  ")]))])
        let service = makeService(repo: repo, extractor: extractor)
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/blank.txt"))
        await service.run()
        #expect(try await repo.job(docId: id)?.state == .failed)
        #expect(try await repo.job(docId: id)?.error == IngestionError.noText.errorDescription)
    }

    @Test func aMisbehavingEmbedderFailsTheJob() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.txt": .success(document())]), embedder: WrongDimensionEmbedder())
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))
        await service.run()
        #expect(try await repo.job(docId: id)?.state == .failed)
        #expect(try await repo.activeChunks(docId: id).isEmpty)
    }

    @Test func statusesAreReportedInOrderIncludingOCR() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(
            results: ["scan.pdf": .success(document(pages: 2))],
            events: ["scan.pdf": [.page(1, of: 2), .recognizing(page: 1, of: 2), .page(2, of: 2)]])
        let service = makeService(repo: repo, extractor: extractor)
        let stream = await service.updates()
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/scan.pdf"))
        await service.run()

        var states: [IngestState] = []
        for await job in stream {
            if job.docId == id, states.last != job.state { states.append(job.state) }
            if job.state == .ready { break }
        }
        #expect(states.first == .queued)
        #expect(states.contains(.extracting))
        #expect(states.contains(.recognizingText))
        #expect(states.contains(.embedding))
        #expect(states.last == .ready)
        #expect(states.firstIndex(of: .recognizingText)! < states.firstIndex(of: .embedding)!)
    }

    @Test func embeddingProgressIsMonotonic() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.txt": .success(document(pages: 3))]))
        let stream = await service.updates()
        _ = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))
        await service.run()
        var progress: [Double] = []
        for await job in stream {
            if job.state == .embedding { progress.append(job.progress) }
            if job.state == .ready { break }
        }
        #expect(progress.count > 2)
        #expect(progress == progress.sorted())
        #expect(progress.last == 1)
    }

    @Test func reindexingKeepsOldPassagesUntilTheNewSetIsReady() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: ["a.txt": .success(document())])
        let service = makeService(repo: repo, extractor: extractor)
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))
        await service.run()
        let before = try await repo.activeChunks(docId: id)
        #expect(before.allSatisfy { $0.generation == 1 })

        try await service.reindex(docId: id)
        #expect(try await repo.activeChunks(docId: id) == before, "still the old set while queued")
        await service.run()
        let after = try await repo.activeChunks(docId: id)
        #expect(after.allSatisfy { $0.generation == 2 })
        #expect(after.count == before.count)
        #expect(try await repo.chunks(docId: id, generation: 1).isEmpty)
    }

    @Test func jobsRunOldestFirst() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: [
            "1.txt": .success(document(pages: 1)), "2.txt": .success(document(pages: 1)), "3.txt": .success(document(pages: 1)),
        ])
        let service = makeService(repo: repo, extractor: extractor)
        for name in ["1.txt", "2.txt", "3.txt"] {
            _ = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/\(name)"))
            try await Task.sleep(for: .milliseconds(2))
        }
        await service.run()
        #expect(extractor.extractedFiles == ["1.txt", "2.txt", "3.txt"])
    }
}

/// Records how many chunks of a document were visible each time a batch was embedded.
private final class SpyEmbedder: Embedder {
    let base = FakeEmbedder()
    var identity: EmbeddingModelIdentity { base.identity }
    private let repo: InMemoryDocumentRepository
    private let state = Mutex((watched: String?.none, visible: [Int]()))

    init(repo: InMemoryDocumentRepository) { self.repo = repo }

    func watch(_ id: String) { state.withLock { $0.watched = id } }
    var visibleDuringRun: [Int] { state.withLock { $0.visible } }
    var batchesSeen: Int { state.withLock { $0.visible.count } }

    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        if let id = state.withLock({ $0.watched }) {
            let visible = try await repo.activeChunks(docId: id).count
            state.withLock { $0.visible.append(visible) }
        }
        return try await base.embed(texts, kind: kind)
    }
}

/// Blocks each embedding call until the test lets it through, so a job can be held mid-run.
private final class HoldingEmbedder: Embedder {
    let base = FakeEmbedder()
    var identity: EmbeddingModelIdentity { base.identity }
    private let state = Mutex((calls: 0, allowed: 0))

    var calls: Int { state.withLock { $0.calls } }
    func allow(_ n: Int = 1_000_000) { state.withLock { $0.allowed += n } }

    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        let index = state.withLock { s -> Int in s.calls += 1; return s.calls }
        while state.withLock({ $0.allowed }) < index {
            try await Task.sleep(for: .milliseconds(2))
        }
        return try await base.embed(texts, kind: kind)
    }
}

private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        if ContinuousClock.now > deadline { Issue.record("timed out waiting for condition"); return }
        try await Task.sleep(for: .milliseconds(3))
    }
}

@Suite struct IngestionLifecycleTests {
    @Test func deletingAQueuedDocumentRemovesItEntirely() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.txt": .success(document())]))
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))
        try await service.delete(docId: id)
        #expect(try await repo.document(id: id) == nil)
        #expect(try await repo.job(docId: id) == nil)
        await service.run()  // nothing left to do
        #expect(try await repo.documents().isEmpty)
    }

    @Test func deletingAReadyDocumentRemovesItsPassages() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.txt": .success(document())]))
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))
        await service.run()
        #expect(try await repo.activeChunks(docId: id).count > 0)
        try await service.delete(docId: id)
        #expect(try await repo.activeChunks(docId: id).isEmpty)
        #expect(try await repo.chunks(docId: id, generation: 1).isEmpty)
        #expect(try await repo.job(docId: id) == nil)
    }

    @Test func deletingWhileIndexingStopsAndLeavesNothingBehind() async throws {
        let repo = InMemoryDocumentRepository()
        let embedder = HoldingEmbedder()
        let extractor = FakeExtractor(results: ["a.txt": .success(document(pages: 3, sentencesPerPage: 20)), "b.txt": .success(document(pages: 1))])
        let service = makeService(repo: repo, extractor: extractor, embedder: embedder)
        let first = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))
        let second = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/b.txt"))

        embedder.allow(2)                                   // two batches get written
        let run = Task { await service.run() }
        try await waitUntil { embedder.calls >= 3 }         // the third batch is now waiting
        #expect(try await repo.chunks(docId: first, generation: 1).count == 4)

        try await service.delete(docId: first)              // returns immediately: it is being indexed
        embedder.allow()                                    // let the held batch through
        await run.value

        #expect(try await repo.document(id: first) == nil)
        #expect(try await repo.chunks(docId: first, generation: 1).isEmpty, "no passages may be left behind")
        #expect(try await repo.job(docId: first) == nil)
        // The queue carries on with the next document.
        #expect(try await repo.job(docId: second)?.state == .ready)
    }

    @Test func aFileEnqueuedWhileRunningIsStillIndexed() async throws {
        let repo = InMemoryDocumentRepository()
        let embedder = HoldingEmbedder()
        let extractor = FakeExtractor(results: ["a.txt": .success(document()), "late.txt": .success(document(pages: 1))])
        let service = makeService(repo: repo, extractor: extractor, embedder: embedder)
        let first = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))

        let run = Task { await service.run() }
        try await waitUntil { embedder.calls >= 1 }          // the first job is mid-flight
        let late = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/late.txt"))
        await service.run()                                  // the import screen would call this; it must not start a second loop
        embedder.allow()
        await run.value

        #expect(try await repo.job(docId: first)?.state == .ready)
        #expect(try await repo.job(docId: late)?.state == .ready, "the late file must not be left queued")
    }

    @Test func pausingHoldsBackBatchesUntilResumed() async throws {
        let repo = InMemoryDocumentRepository()
        let embedder = HoldingEmbedder()
        embedder.allow()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.txt": .success(document(pages: 3, sentencesPerPage: 20))]), embedder: embedder)
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))

        await service.setPaused(true)
        let run = Task { await service.run() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(embedder.calls == 0, "nothing should be embedded while paused")
        #expect(try await repo.job(docId: id)?.state != .ready)

        await service.setPaused(false)
        await run.value
        #expect(try await repo.job(docId: id)?.state == .ready)
    }
}

@Suite struct IngestionPendingWorkTests {
    @Test func pendingWorkIsReportedUntilEveryJobFinishes() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: ["a.txt": .success(document()), "bad.pdf": .failure(ExtractionError.passwordProtected)])
        let service = makeService(repo: repo, extractor: extractor)
        #expect(await service.hasPendingWork() == false)
        _ = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.txt"))
        _ = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/bad.pdf"))
        #expect(await service.hasPendingWork())
        await service.run()
        #expect(await service.hasPendingWork() == false, "ready and failed jobs are finished")
    }
}
