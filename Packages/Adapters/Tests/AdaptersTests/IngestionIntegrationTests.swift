import Core
import Foundation
import Ports
import PortsTesting
import Synchronization
import Testing
@testable import Adapters

/// The whole ingestion path on real parts: real files, real extractors, real Couchbase Lite.
@Suite(.serialized) struct IngestionIntegrationTests {
    private let fx = Fixtures()

    private func makeService(_ f: RepoFixture, embedder: any Embedder = FakeEmbedder(identity: RepoFixture.identity)) -> IngestionService {
        IngestionService(
            extractor: FileDocumentExtractor(), embedder: embedder, repository: f.repo, jobs: f.repo,
            chunker: Chunker(configuration: ChunkerConfiguration(targetTokens: 60, maxTokens: 100, overlapTokens: 12, minTailTokens: 20)),
            batchSize: 4, supportedType: FileDocumentExtractor.documentType(for:))
    }

    @Test func docxAndPdfBecomeSearchableChunksInCouchbase() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        let sentences = (0..<25).map { "Step \($0) says to check valve number \($0) carefully." }.joined(separator: " ")
        let docx = fx.docx(body: Fixtures.paragraph("Maintenance", style: "Heading1") + Fixtures.paragraph(sentences),
                                 name: "guide.docx")
        let pdf = fx.pdf(pages: ["The reset button is on the back panel of the unit.", "Replace the air filter every six months."],
                               name: "unit.pdf")
        let service = makeService(f)
        let docxID = try await service.enqueue(fileURL: docx)
        let pdfID = try await service.enqueue(fileURL: pdf)
        await service.run()

        for id in [docxID, pdfID] {
            let job = try await f.repo.job(docId: id)
            #expect(job?.state == .ready, "\(String(describing: job))")
            #expect(try await f.repo.document(id: id)?.activeGeneration == 1)
        }
        let docxChunks = try await f.repo.activeChunks(docId: docxID)
        #expect(docxChunks.count > 1)
        #expect(docxChunks.allSatisfy { $0.heading == "Maintenance" && $0.embedding.count == 768 })

        let pdfChunks = try await f.repo.activeChunks(docId: pdfID)
        #expect(pdfChunks.map(\.page) == [1, 2])
        #expect(try await f.repo.document(id: pdfID)?.pageCount == 2)

        // The stored original survives deleting the user's copy and can be re-indexed.
        try FileManager.default.removeItem(at: pdf)
        try await service.reindex(docId: pdfID)
        await service.run()
        #expect(try await f.repo.document(id: pdfID)?.activeGeneration == 2)
        #expect(try await f.repo.activeChunks(docId: pdfID).map(\.generation) == [2, 2])
        #expect(try await f.repo.chunks(docId: pdfID, generation: 1).isEmpty)
    }

    @Test func aCorruptFileFailsAndTheNextOneStillIndexes() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        let bad = fx.write(Data("not a pdf".utf8), as: "broken.pdf")
        let good = fx.write(Data("A readable text file with enough words to make a chunk.".utf8), as: "ok.txt")
        let service = makeService(f)
        let badID = try await service.enqueue(fileURL: bad)
        let goodID = try await service.enqueue(fileURL: good)
        await service.run()

        let badJob = try #require(try await f.repo.job(docId: badID))
        #expect(badJob.state == .failed)
        #expect(badJob.error?.isEmpty == false)
        #expect(try await f.repo.job(docId: goodID)?.state == .ready)
    }

    @Test func aRelaunchedServiceResumesFromTheDatabase() async throws {
        let f = try RepoFixture()
        let text = (0..<80).map { "Sentence number \($0) about the calibration procedure." }.joined(separator: " ")
        let file = fx.write(Data(text.utf8), as: "calib.txt")

        // First run: the embedder stalls after two batches, and the run is cancelled ("app killed").
        let stalling = StallingEmbedder(after: 2)
        let first = makeService(f, embedder: stalling)
        let id = try await first.enqueue(fileURL: file)
        let task = Task { await first.run() }
        while stalling.calls < 3 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await task.value
        let interrupted = try #require(try await f.repo.job(docId: id))
        #expect(interrupted.state == .embedding)
        #expect(interrupted.nextOrdinal == 8)  // two batches of four
        #expect(try await f.repo.activeChunks(docId: id).isEmpty)
        try await f.repo.close()

        // Relaunch over the same directory: only the remaining chunks are embedded.
        let reopened = try RepoFixture(root: f.root)
        defer { Task { await reopened.cleanUp() } }
        let healthy = StallingEmbedder(after: nil)
        await makeService(reopened, embedder: healthy).run()

        let chunks = try await reopened.repo.activeChunks(docId: id)
        #expect(chunks.count > 8)
        #expect(chunks.map(\.ordinal) == Array(0..<chunks.count), "one contiguous set: \(chunks.map(\.ordinal))")
        #expect(healthy.texts == chunks.count - 8)
        #expect(try await reopened.repo.job(docId: id)?.state == .ready)
    }
}

/// Embeds like `FakeEmbedder`; after `after` calls it stalls until cancelled.
private final class StallingEmbedder: Embedder {
    private let base = FakeEmbedder(identity: RepoFixture.identity)
    var identity: EmbeddingModelIdentity { base.identity }
    private let after: Int?
    private let state = Mutex((calls: 0, texts: 0))

    init(after: Int?) { self.after = after }

    var calls: Int { state.withLock { $0.calls } }
    var texts: Int { state.withLock { $0.texts } }

    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        let n = state.withLock { s -> Int in s.calls += 1; return s.calls }
        if let after, n > after { try await Task.sleep(for: .seconds(3600)) }
        state.withLock { $0.texts += texts.count }
        return try await base.embed(texts, kind: kind)
    }
}
